import Foundation
import GRDB
import WalletCore

/// A public account identity that can be persisted without retaining any
/// private key or recovery-phrase material.
struct WalletDerivedAccount: Equatable, Sendable {
    let networkID: String
    let address: String
    let normalizedAddress: String
    let label: String?
    let derivationPath: String?
    let accountIndex: Int
    let publicKey: String

    func record(
        walletID: String,
        now: Double
    ) -> DBWalletAccountRecord {
        DBWalletAccountRecord(
            id: accountID(walletID: walletID),
            walletID: walletID,
            networkID: networkID,
            address: address,
            normalizedAddress: normalizedAddress,
            label: label,
            derivationPath: derivationPath,
            accountIndex: accountIndex,
            publicKey: publicKey,
            isWatchOnly: false,
            isEnabled: true,
            createdAt: now,
            updatedAt: now,
            lastSyncedAt: nil
        )
    }

    func matches(_ account: DBWalletAccountRecord) -> Bool {
        account.networkID == networkID
            && account.address == address
            && account.normalizedAddress == normalizedAddress
            && account.label == label
            && account.derivationPath == derivationPath
            && account.accountIndex == accountIndex
            && account.publicKey == publicKey
            && !account.isWatchOnly
            && account.isEnabled
    }

    private func accountID(walletID: String) -> String {
        if networkID == SolanaConstants.networkID,
           let label,
           let kind = SolanaDerivationKind(rawValue: label) {
            return WalletDatabase.solanaAccountID(
                walletID: walletID,
                kind: kind
            )
        }
        return "\(walletID):\(networkID):\(accountIndex)"
    }
}

/// An immutable view of the public account identities already persisted for
/// a wallet. Balance rows are deliberately not involved: an account remains
/// usable for Send and Receive even when it has never held an asset.
struct WalletAccountAddressIndex: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        let networkID: String
        let address: String
        let label: String?
        let derivationPath: String?
        let accountIndex: Int?
        let publicKey: String?
    }

    static let empty = WalletAccountAddressIndex(entries: [])

    private let entriesByNetworkID: [String: [Entry]]

    init(entries: [Entry]) {
        entriesByNetworkID = Dictionary(
            grouping: entries.filter {
                !$0.address.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty
            },
            by: \Entry.networkID
        )
        .mapValues { entries in
            entries.sorted(by: Self.precedes)
        }
    }

    init(records: [DBWalletAccountRecord]) {
        self.init(
            entries: records.map {
                Entry(
                    networkID: $0.networkID,
                    address: $0.address,
                    label: $0.label,
                    derivationPath: $0.derivationPath,
                    accountIndex: $0.accountIndex,
                    publicKey: $0.publicKey
                )
            }
        )
    }

    var accountCount: Int {
        entriesByNetworkID.values.reduce(0) { $0 + $1.count }
    }

    func address(for blockchain: WalletBlockchain) -> String? {
        guard
            let networkID = AssetNetworkSelectorOption.networkID(
                for: blockchain
            ),
            let address = entriesByNetworkID[networkID]?.first?.address
        else {
            return nil
        }
        if ReceiveAddressResolver.requiresIndependentAddress(
            for: blockchain
        ) {
            return ReceiveAddressResolver.validatedIndependentAddress(
                address,
                for: blockchain
            )
        }
        return AnkrAPIClient.isValidAddress(address) ? address : nil
    }

    var solanaAccounts: SolanaAccountSet? {
        let materials = (entriesByNetworkID[SolanaConstants.networkID] ?? [])
            .compactMap { entry -> SolanaAccountMaterial? in
                guard
                    let label = entry.label,
                    let kind = SolanaDerivationKind(rawValue: label),
                    ReceiveAddressResolver.validatedIndependentAddress(
                        entry.address,
                        for: .solana
                    ) != nil
                else {
                    return nil
                }
                return SolanaAccountMaterial(
                    kind: kind,
                    address: entry.address,
                    publicKey: entry.publicKey ?? "",
                    derivationPath: entry.derivationPath
                )
            }
        guard let primary = materials.first else { return nil }
        return SolanaAccountSet(
            primary: primary,
            alternatives: Array(materials.dropFirst())
        )
    }

    private static func precedes(_ lhs: Entry, _ rhs: Entry) -> Bool {
        let lhsPriority = priority(lhs)
        let rhsPriority = priority(rhs)
        if lhsPriority != rhsPriority {
            return lhsPriority < rhsPriority
        }
        let lhsIndex = lhs.accountIndex ?? Int.max
        let rhsIndex = rhs.accountIndex ?? Int.max
        if lhsIndex != rhsIndex {
            return lhsIndex < rhsIndex
        }
        return lhs.address < rhs.address
    }

    private static func priority(_ entry: Entry) -> Int {
        guard entry.networkID == SolanaConstants.networkID else {
            return 0
        }
        return switch entry.label.flatMap(SolanaDerivationKind.init) {
        case .phantom: 0
        case .trustWallet: 1
        case nil: 2
        }
    }
}

extension WalletDatabase {
    func accountAddressIndex(
        walletID: String
    ) async throws -> WalletAccountAddressIndex {
        try await pool.read { database in
            let records = try DBWalletAccountRecord
                .filter(Column("walletID") == walletID)
                .filter(Column("isEnabled") == true)
                .fetchAll(database)
            return WalletAccountAddressIndex(records: records)
        }
    }
}

/// Derives every account-0 mainnet identity supported by a recovery-phrase
/// wallet. The resulting values are public data only and are committed
/// atomically with the wallet record.
struct WalletFullDerivationMaterial: Equatable, Sendable {
    let accounts: [WalletDerivedAccount]
}

enum WalletAccountDerivationService {
    static let currentPersistenceVersion = 1

    static let requiredNetworkIDs = Set(
        ReceiveNetworkCatalog.all.map(\.id)
            + BitcoinFamilyChain.allCases.map(\.networkID)
    )

    static var requiredAccountCount: Int {
        requiredNetworkIDs.count + SolanaDerivationKind.allCases.count - 1
    }

    static func supportsFullDerivation(
        walletKind: String
    ) -> Bool {
        walletKind == DatabaseWalletKind.created.rawValue
            || walletKind
                == DatabaseWalletKind.importedRecoveryPhrase.rawValue
    }

    static func deriveFullWallet(
        credential: WalletRecoveryCredential,
        expectedEVMAddress: String? = nil,
        expectedEVMPublicKey: String? = nil,
        operation: WalletPersistenceOperation = .create
    ) throws -> [WalletDerivedAccount] {
        let wallet: HDWallet = try {
            guard let wallet = credential.makeHDWallet() else {
                throw WalletCreationPersistenceError.invalidDraft
            }
            return wallet
        }()
        let accounts = try deriveWalletCoreAccounts(
            wallet: wallet,
            expectedEVMAddress: expectedEVMAddress,
            expectedEVMPublicKey: expectedEVMPublicKey,
            operation: operation
        )
        return try {
            try completingFullWalletAccounts(accounts)
        }()
    }

    /// Keeps account derivation on the caller's detached executor so no
    /// cryptography runs on the main actor.
    static func deriveFullWalletMaterial(
        credential: WalletRecoveryCredential,
        expectedEVMAddress: String? = nil,
        expectedEVMPublicKey: String? = nil,
        operation: WalletPersistenceOperation = .create
    ) async throws -> WalletFullDerivationMaterial {
        let wallet: HDWallet = try {
            guard let wallet = credential.makeHDWallet() else {
                throw WalletCreationPersistenceError.invalidDraft
            }
            return wallet
        }()
        let accounts = try deriveWalletCoreAccounts(
            wallet: wallet,
            expectedEVMAddress: expectedEVMAddress,
            expectedEVMPublicKey: expectedEVMPublicKey,
            operation: operation
        )
        return WalletFullDerivationMaterial(
            accounts: try {
                try completingFullWalletAccounts(accounts)
            }()
        )
    }

    private static func deriveWalletCoreAccounts(
        wallet: HDWallet,
        expectedEVMAddress: String?,
        expectedEVMPublicKey: String?,
        operation: WalletPersistenceOperation
    ) throws -> [WalletDerivedAccount] {
        let evm = try evmAccount(
            wallet: wallet,
            expectedAddress: expectedEVMAddress,
            expectedPublicKey: expectedEVMPublicKey
        )
        let aptos = try aptosAccount(wallet: wallet)
        let stellar = try stellarAccount(wallet: wallet)
        let tron = try tronAccount(wallet: wallet)
        let solana = try solanaAccounts(wallet: wallet)
        let ton = try tonAccount(wallet: wallet)
        let sui = try suiAccount(wallet: wallet)
        let near = try nearAccount(wallet: wallet)
        let xrp = try xrpAccount(wallet: wallet)
        let bitcoinFamily = try BitcoinFamilyDerivationService()
            .derive(wallet: wallet).map(bitcoinFamilyAccount)

        var accounts: [WalletDerivedAccount] = []
        for network in ReceiveNetworkCatalog.all {
            if network.blockchain.isEVM {
                accounts.append(
                    replacingNetwork(evm, with: network.id)
                )
                continue
            }

            switch network.blockchain {
            case .aptos:
                accounts.append(aptos)
            case .stellar:
                accounts.append(stellar)
            case .tron:
                accounts.append(tron)
            case .solana:
                accounts.append(contentsOf: solana)
            case .ton:
                accounts.append(ton)
            case .sui:
                accounts.append(sui)
            case .near:
                accounts.append(near)
            case .xrp:
                accounts.append(xrp)
            case .bitcoin, .bitcoincash, .litecoin, .dogecoin,
                 .ethereum, .smartchain, .polygon, .arbitrum,
                 .avalanchec, .optimism, .base, .xdai, .scroll,
                 .linea, .taiko, .telos, .xlayer, .arc:
                throw WalletCreationPersistenceError.invalidDraft
            }
        }
        accounts.append(contentsOf: bitcoinFamily)
        return accounts
    }

    private static func completingFullWalletAccounts(
        _ accounts: [WalletDerivedAccount]
    ) throws -> [WalletDerivedAccount] {
        let networkIDs = Set(accounts.map(\.networkID))
        guard networkIDs == requiredNetworkIDs,
              accounts.count == requiredAccountCount,
              Dictionary(grouping: accounts, by: \WalletDerivedAccount.networkID)
                .allSatisfy({ networkID, values in
                    values.count == (
                        networkID == SolanaConstants.networkID
                            ? SolanaDerivationKind.allCases.count : 1
                    )
                })
        else {
            throw WalletCreationPersistenceError.invalidDraft
        }
        return accounts
    }

    /// A complete current wallet never needs Keychain access merely to show
    /// Receive or start account synchronization.
    static func isStructurallyComplete(
        accounts: [DBWalletAccountRecord],
        bitcoinHDAddresses: [DBBitcoinHDAddressRecord] = []
    ) -> Bool {
        let enabled = accounts.filter { $0.isEnabled && !$0.isWatchOnly }
        guard Set(enabled.map(\.networkID)).isSuperset(
            of: requiredNetworkIDs
        ) else {
            return false
        }

        var persistedEVMAccounts: [DBWalletAccountRecord] = []
        for network in ReceiveNetworkCatalog.all {
            let matches = enabled.filter { $0.networkID == network.id }
            if network.id == SolanaConstants.networkID {
                let kinds = Set(matches.compactMap {
                    $0.label.flatMap(SolanaDerivationKind.init(rawValue:))
                })
                guard kinds == Set(SolanaDerivationKind.allCases),
                      matches.allSatisfy(validSolanaAccount)
                else {
                    return false
                }
            } else {
                guard let match = matches.first(where: {
                    validAccount($0, blockchain: network.blockchain)
                }) else {
                    return false
                }
                if network.blockchain.isEVM {
                    persistedEVMAccounts.append(match)
                }
            }
        }

        guard Set(persistedEVMAccounts.map(\.normalizedAddress)).count == 1,
              Set(persistedEVMAccounts.compactMap(\.publicKey)).count == 1
        else {
            return false
        }

        for chain in BitcoinFamilyChain.allCases {
            guard enabled.contains(where: {
                ($0.networkID == chain.networkID
                    && validBitcoinFamilyAccount($0, chain: chain))
                    || (chain == .bitcoin
                        && BitcoinHDReceiveAccountProjection.matches(
                            $0,
                            addresses: bitcoinHDAddresses
                        ))
            }) else {
                return false
            }
        }
        return true
    }

    private static func evmAccount(
        wallet: HDWallet,
        expectedAddress: String?,
        expectedPublicKey: String?
    ) throws -> WalletDerivedAccount {
        let path = CoinType.ethereum.derivationPath()
        let key = try privateKey(wallet: wallet, coin: .ethereum, path: path)
        let address = CoinType.ethereum.deriveAddress(privateKey: key)
        let walletCoreAddress = wallet.getAddressForCoin(coin: .ethereum)
        let publicKey = key.getPublicKeySecp256k1(compressed: false)
            .description
        guard CoinType.ethereum.validate(address: address),
              address.caseInsensitiveCompare(walletCoreAddress) == .orderedSame,
              expectedAddress.map({
                  address.caseInsensitiveCompare($0) == .orderedSame
              }) ?? true,
              expectedPublicKey.map({ $0 == publicKey }) ?? true
        else {
            throw WalletCreationPersistenceError.invalidDraft
        }
        return WalletDerivedAccount(
            networkID: "eth",
            address: address,
            normalizedAddress: address.lowercased(),
            label: nil,
            derivationPath: path,
            accountIndex: 0,
            publicKey: publicKey
        )
    }

    private static func aptosAccount(
        wallet: HDWallet
    ) throws -> WalletDerivedAccount {
        let material = try AptosAddress.material(hdWallet: wallet)
        return WalletDerivedAccount(
            networkID: AptosConstants.networkID,
            address: material.address,
            normalizedAddress: material.address,
            label: AptosConstants.accountLabel,
            derivationPath: material.derivationPath,
            accountIndex: 0,
            publicKey: material.publicKey
        )
    }

    private static func stellarAccount(
        wallet: HDWallet
    ) throws -> WalletDerivedAccount {
        let key = try privateKey(
            wallet: wallet,
            coin: .stellar,
            path: StellarConstants.derivationPath
        )
        let material = try StellarAddress.material(
            privateKey: key,
            derivationPath: StellarConstants.derivationPath
        )
        guard material.address == wallet.getAddressForCoin(coin: .stellar)
        else {
            throw WalletCreationPersistenceError.invalidDraft
        }
        return WalletDerivedAccount(
            networkID: StellarConstants.networkID,
            address: material.address,
            normalizedAddress: material.address,
            label: StellarConstants.accountLabel,
            derivationPath: material.derivationPath,
            accountIndex: 0,
            publicKey: material.publicKey
        )
    }

    private static func tronAccount(
        wallet: HDWallet
    ) throws -> WalletDerivedAccount {
        let key = wallet.getKeyForCoin(coin: .tron)
        let address = CoinType.tron.deriveAddress(privateKey: key)
        guard CoinType.tron.validate(address: address),
              address == wallet.getAddressForCoin(coin: .tron),
              TronValueParser.accountHexAddress(address) != nil
        else {
            throw WalletCreationPersistenceError.invalidDraft
        }
        return WalletDerivedAccount(
            networkID: TronConstants.networkID,
            address: address,
            normalizedAddress: address,
            label: nil,
            derivationPath: CoinType.tron.derivationPath(),
            accountIndex: 0,
            publicKey: key.getPublicKeySecp256k1(compressed: false)
                .data.base64EncodedString()
        )
    }

    private static func solanaAccounts(
        wallet: HDWallet
    ) throws -> [WalletDerivedAccount] {
        let accounts = try SolanaDerivationKind.allCases.map { kind in
            let key = try privateKey(
                wallet: wallet,
                coin: .solana,
                path: kind.derivationPath
            )
            let address = CoinType.solana.deriveAddress(privateKey: key)
            guard CoinType.solana.validate(address: address) else {
                throw WalletCreationPersistenceError.invalidDraft
            }
            return WalletDerivedAccount(
                networkID: SolanaConstants.networkID,
                address: address,
                normalizedAddress: address,
                label: kind.rawValue,
                derivationPath: kind.derivationPath,
                accountIndex: 0,
                publicKey: key.getPublicKeyEd25519()
                    .data.base64EncodedString()
            )
        }
        guard let trustWallet = accounts.first(where: {
            $0.label == SolanaDerivationKind.trustWallet.rawValue
        }), trustWallet.address == wallet.getAddressForCoin(coin: .solana)
        else {
            throw WalletCreationPersistenceError.invalidDraft
        }
        return accounts
    }

    private static func tonAccount(
        wallet: HDWallet
    ) throws -> WalletDerivedAccount {
        let key = try privateKey(
            wallet: wallet,
            coin: .ton,
            path: TONConstants.derivationPath
        )
        let material = try TONAddress.material(
            privateKey: key,
            derivationPath: TONConstants.derivationPath
        )
        guard TONAddress.matches(
            material.address,
            wallet.getAddressForCoin(coin: .ton)
        ) else {
            throw WalletCreationPersistenceError.invalidDraft
        }
        return WalletDerivedAccount(
            networkID: TONConstants.networkID,
            address: material.address,
            normalizedAddress: material.rawAddress,
            label: TONConstants.accountLabel,
            derivationPath: material.derivationPath,
            accountIndex: 0,
            publicKey: material.publicKey
        )
    }

    private static func suiAccount(
        wallet: HDWallet
    ) throws -> WalletDerivedAccount {
        let key = try privateKey(
            wallet: wallet,
            coin: .sui,
            path: SuiConstants.derivationPath
        )
        let address = CoinType.sui.deriveAddress(privateKey: key)
        guard let canonical = SuiCoinType.validatedAccountAddress(address),
              let walletCoreAddress = SuiCoinType.validatedAccountAddress(
                  wallet.getAddressForCoin(coin: .sui)
              ), canonical == walletCoreAddress
        else {
            throw WalletCreationPersistenceError.invalidDraft
        }
        return WalletDerivedAccount(
            networkID: SuiConstants.networkID,
            address: canonical,
            normalizedAddress: canonical,
            label: SuiConstants.accountLabel,
            derivationPath: SuiConstants.derivationPath,
            accountIndex: 0,
            publicKey: key.getPublicKeyEd25519().description
        )
    }

    private static func nearAccount(
        wallet: HDWallet
    ) throws -> WalletDerivedAccount {
        let key = try privateKey(
            wallet: wallet,
            coin: .near,
            path: NEARConstants.derivationPath
        )
        let material = try NEARAddress.material(
            privateKey: key,
            derivationPath: NEARConstants.derivationPath
        )
        guard material.address == wallet.getAddressForCoin(coin: .near)
        else {
            throw WalletCreationPersistenceError.invalidDraft
        }
        return WalletDerivedAccount(
            networkID: NEARConstants.networkID,
            address: material.address,
            normalizedAddress: material.address,
            label: NEARConstants.accountLabel,
            derivationPath: material.derivationPath,
            accountIndex: 0,
            publicKey: material.publicKey
        )
    }

    private static func xrpAccount(
        wallet: HDWallet
    ) throws -> WalletDerivedAccount {
        let key = try privateKey(
            wallet: wallet,
            coin: .xrp,
            path: XRPConstants.derivationPath
        )
        let address = CoinType.xrp.deriveAddress(privateKey: key)
        guard AnyAddress(string: address, coin: .xrp) != nil,
              address == wallet.getAddressForCoin(coin: .xrp)
        else {
            throw WalletCreationPersistenceError.invalidDraft
        }
        return WalletDerivedAccount(
            networkID: XRPConstants.networkID,
            address: address,
            normalizedAddress: address,
            label: XRPConstants.accountLabel,
            derivationPath: XRPConstants.derivationPath,
            accountIndex: 0,
            publicKey: key.getPublicKeySecp256k1(compressed: true)
                .description
        )
    }

    private static func bitcoinFamilyAccount(
        _ material: BitcoinFamilyAccountMaterial
    ) -> WalletDerivedAccount {
        WalletDerivedAccount(
            networkID: material.chain.networkID,
            address: material.address,
            normalizedAddress: material.address.lowercased(),
            label: nil,
            derivationPath: material.derivationPath,
            accountIndex: 0,
            publicKey: material.publicKey
        )
    }

    private static func replacingNetwork(
        _ account: WalletDerivedAccount,
        with networkID: String
    ) -> WalletDerivedAccount {
        WalletDerivedAccount(
            networkID: networkID,
            address: account.address,
            normalizedAddress: account.normalizedAddress,
            label: account.label,
            derivationPath: account.derivationPath,
            accountIndex: account.accountIndex,
            publicKey: account.publicKey
        )
    }

    private static func privateKey(
        wallet: HDWallet,
        coin: CoinType,
        path: String
    ) throws -> PrivateKey {
        guard let key = wallet.getKey(
            coin: coin,
            derivationPath: path
        ) else {
            throw WalletCreationPersistenceError.invalidDraft
        }
        return key
    }

    private static func validAccount(
        _ account: DBWalletAccountRecord,
        blockchain: WalletBlockchain
    ) -> Bool {
        guard account.accountIndex == 0,
              publicIdentityMatches(account)
        else {
            return false
        }
        if blockchain.isEVM {
            return CoinType.ethereum.validate(address: account.address)
                && account.normalizedAddress == account.address.lowercased()
                && account.label == nil
                && account.derivationPath
                    == CoinType.ethereum.derivationPath()
        }
        switch blockchain {
        case .aptos:
            return AptosAddress.validatedPersistedMaterial(
                address: account.address,
                normalizedAddress: account.normalizedAddress,
                publicKey: account.publicKey,
                derivationPath: account.derivationPath
            ) != nil
                && account.label == AptosConstants.accountLabel
                && account.derivationPath == AptosConstants.derivationPath
        case .stellar:
            return StellarAddress.validated(account.address) != nil
                && account.normalizedAddress == account.address
                && account.label == StellarConstants.accountLabel
                && account.derivationPath == StellarConstants.derivationPath
        case .near:
            return NEARAddress.isValid(account.address)
                && account.normalizedAddress == account.address
                && account.label == NEARConstants.accountLabel
                && account.derivationPath == NEARConstants.derivationPath
        case .xrp:
            return AnyAddress(string: account.address, coin: .xrp) != nil
                && account.normalizedAddress == account.address
                && account.label == XRPConstants.accountLabel
                && account.derivationPath == XRPConstants.derivationPath
        case .sui:
            return SuiCoinType.validatedAccountAddress(account.address)
                == account.normalizedAddress
                && account.label == SuiConstants.accountLabel
                && account.derivationPath == SuiConstants.derivationPath
        case .ton:
            return TONAddress.rawAddress(from: account.address)
                == account.normalizedAddress
                && account.label == TONConstants.accountLabel
                && account.derivationPath == TONConstants.derivationPath
        case .tron:
            return CoinType.tron.validate(address: account.address)
                && account.normalizedAddress == account.address
                && account.label == nil
                && account.derivationPath == CoinType.tron.derivationPath()
        case .solana:
            return validSolanaAccount(account)
        case .bitcoin, .bitcoincash, .litecoin, .dogecoin,
             .ethereum, .smartchain, .polygon, .arbitrum,
             .avalanchec, .optimism, .base, .xdai, .scroll,
             .linea, .taiko, .telos, .xlayer, .arc:
            return false
        }
    }

    private static func validSolanaAccount(
        _ account: DBWalletAccountRecord
    ) -> Bool {
        guard let label = account.label,
              let kind = SolanaDerivationKind(rawValue: label),
              account.accountIndex == 0,
              account.derivationPath == kind.derivationPath,
              publicIdentityMatches(account)
        else {
            return false
        }
        return CoinType.solana.validate(address: account.address)
            && account.normalizedAddress == account.address
    }

    private static func validBitcoinFamilyAccount(
        _ account: DBWalletAccountRecord,
        chain: BitcoinFamilyChain
    ) -> Bool {
        guard account.accountIndex == 0,
              account.label == nil,
              account.derivationPath == chain.derivationPath,
              chain.coin.validate(address: account.address),
              publicIdentityMatches(account)
        else {
            return false
        }
        return account.normalizedAddress == account.address.lowercased()
            && !BitcoinScript.lockScriptForAddress(
                address: account.address,
                coin: chain.coin
            ).data.isEmpty
    }

    private static func publicIdentityMatches(
        _ account: DBWalletAccountRecord
    ) -> Bool {
        guard let publicKey = account.publicKey, !publicKey.isEmpty,
              let family = try? DeviceMigrationAccountSecretVerifier
                .accountFamily(networkID: account.networkID)
        else {
            return false
        }
        do {
            try DeviceMigrationAccountSecretVerifier
                .verifyHardwarePublicKeyIfPresent(
                    account,
                    family: family
                )
            return true
        } catch {
            return false
        }
    }
}
