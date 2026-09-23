import Foundation
import GRDB
import WalletCore

struct WalletPrivateKeyExportItem: Identifiable, Sendable {
    enum Detail: Sendable {
        case derivationPath(String)
        case localized(String)
        case verbatim(String)
    }

    let id: String
    let titleKey: String
    let logoSource: AssetLogoSource
    let backupNetwork: PrivateKeyImportNetwork
    let detail: Detail
    let privateKeys: [WalletPrivateKeyExportValue]
    let bitcoinCatalog: WalletBitcoinPrivateKeyExportCatalog?

    init(
        id: String,
        titleKey: String,
        logoSource: AssetLogoSource,
        backupNetwork: PrivateKeyImportNetwork,
        detail: Detail,
        privateKey: String
    ) {
        self.id = id
        self.titleKey = titleKey
        self.logoSource = logoSource
        self.backupNetwork = backupNetwork
        self.detail = detail
        privateKeys = [
            WalletPrivateKeyExportValue(
                kind: .standard,
                value: privateKey
            )
        ]
        bitcoinCatalog = nil
    }

    init(
        id: String,
        titleKey: String,
        logoSource: AssetLogoSource,
        backupNetwork: PrivateKeyImportNetwork,
        detail: Detail,
        privateKeys: [WalletPrivateKeyExportValue]
    ) {
        self.id = id
        self.titleKey = titleKey
        self.logoSource = logoSource
        self.backupNetwork = backupNetwork
        self.detail = detail
        self.privateKeys = privateKeys
        bitcoinCatalog = nil
    }

    init(
        bitcoinCatalog: WalletBitcoinPrivateKeyExportCatalog
    ) {
        id = BitcoinFamilyChain.bitcoin.rawValue
        titleKey = BitcoinFamilyChain.bitcoin.nameKey
        logoSource = .nativeCoin(blockchain: .bitcoin)
        backupNetwork = .bitcoin
        detail = .localized("bitcoin.settings.generated_addresses")
        privateKeys = []
        self.bitcoinCatalog = bitcoinCatalog
    }

    var localizedTitle: String {
        WalletLocalization.string(titleKey)
    }

    var localizedDetail: String {
        switch detail {
        case let .derivationPath(path):
            EnglishNumbers.localized(
                "settings.wallets.private_key.export.derivation_path",
                path
            )
        case let .localized(key):
            WalletLocalization.string(key)
        case let .verbatim(value):
            value
        }
    }

    var warningKey: String {
        "settings.wallets.private_key.export.warning"
    }
}

struct WalletBitcoinPrivateKeyExportCatalog: Sendable {
    struct AddressType: Identifiable, Sendable {
        let addressType: BitcoinHDAddressType
        let addresses: [Address]

        var id: BitcoinHDAddressType { addressType }

        var generatedCount: Int { addresses.count }

        var usedCount: Int {
            addresses.lazy.filter(\.isUsed).count
        }

        var balanceAtomic: BitcoinFamilyAtomicInteger {
            addresses.reduce(.zero) {
                $0.adding($1.balanceAtomic)
            }
        }
    }

    struct Address: Identifiable, Sendable {
        let state: BitcoinHDAddressState
        let wif: String

        var id: String {
            "\(state.derived.branch.rawValue):\(state.derived.index)"
        }

        var isUsed: Bool { state.isUsed }

        var balanceAtomic: BitcoinFamilyAtomicInteger {
            state.balanceAtomic
        }

        var displayItem: WalletPrivateKeyExportItem {
            WalletPrivateKeyExportItem(
                id: "bitcoin-\(state.derived.addressType.rawValue)-\(id)",
                titleKey: BitcoinFamilyChain.bitcoin.nameKey,
                logoSource: .nativeCoin(blockchain: .bitcoin),
                backupNetwork: .bitcoin,
                detail: .derivationPath(state.derived.derivationPath),
                privateKey: wif
            )
        }
    }

    struct SilentPayments: Sendable {
        let address: String
        let outputs: [SilentPaymentOutput]
    }

    struct SilentPaymentOutput: Identifiable, Sendable {
        let output: BitcoinSilentPaymentOutput
        let descriptor: String

        var id: String {
            "\(output.transactionHash):\(output.outputIndex)"
        }

        var displayItem: WalletPrivateKeyExportItem {
            WalletPrivateKeyExportItem(
                id: "bitcoin-silent-\(id)",
                titleKey: "bitcoin.settings.silent.output.title",
                logoSource: .nativeCoin(blockchain: .bitcoin),
                backupNetwork: .bitcoin,
                detail: .localized("bitcoin.settings.silent.wif.footer"),
                privateKey: descriptor
            )
        }
    }

    let addressTypes: [AddressType]
    let silentPayments: SilentPayments?

    init(
        hdEntries: [BitcoinHDPrivateKeyExportEntry],
        silentPaymentAccount: BitcoinSilentPaymentAccount?,
        silentPaymentEntries: [
            BitcoinSilentPaymentPrivateKeyExportEntry
        ]
    ) {
        addressTypes = BitcoinHDAddressType.allCases.compactMap { type in
            let addresses = hdEntries.compactMap { entry -> Address? in
                guard entry.state.derived.addressType == type else {
                    return nil
                }
                return Address(state: entry.state, wif: entry.wif)
            }
            guard !addresses.isEmpty else { return nil }
            return AddressType(
                addressType: type,
                addresses: addresses
            )
        }
        silentPayments = silentPaymentAccount.map { account in
            SilentPayments(
                address: account.address.encoded,
                outputs: silentPaymentEntries.map {
                    SilentPaymentOutput(
                        output: $0.output,
                        descriptor: $0.descriptor
                    )
                }
            )
        }
    }

    func address(
        type: BitcoinHDAddressType,
        branch: BitcoinHDAddressBranch,
        index: Int
    ) -> Address? {
        addressTypes.first { $0.addressType == type }?
            .addresses.first {
                $0.state.derived.branch == branch
                    && $0.state.derived.index == index
            }
    }

    func silentPaymentOutput(
        transactionHash: String,
        outputIndex: Int
    ) -> SilentPaymentOutput? {
        silentPayments?.outputs.first {
            $0.output.transactionHash == transactionHash
                && $0.output.outputIndex == outputIndex
        }
    }
}

struct WalletPrivateKeyExportValue: Identifiable, Sendable {
    enum Kind: String, Hashable, Sendable {
        case standard

        var titleKey: String {
            "settings.wallets.private_key.section"
        }
    }

    let kind: Kind
    let value: String

    var id: Kind { kind }

    var localizedTitle: String {
        WalletLocalization.string(kind.titleKey)
    }

    var localizedCopyTitle: String {
        WalletLocalization.string(
            "settings.wallets.private_key.export.copy"
        )
    }
}

struct WalletImportedPrivateKeyMetadata: Sendable {
    let network: PrivateKeyImportNetwork
    let format: PrivateKeyImportFormat
    let address: String

    func matches(address candidate: String) -> Bool {
        if network == .evm {
            return address.caseInsensitiveCompare(candidate)
                == .orderedSame
        }
        return address == candidate
    }
}

private extension BitcoinFamilyChain {
    var privateKeyImportNetwork: PrivateKeyImportNetwork {
        switch self {
        case .bitcoin:
            .bitcoin
        case .bitcoinCash:
            .bitcoinCash
        case .litecoin:
            .litecoin
        case .dogecoin:
            .dogecoin
        }
    }
}

enum WalletPrivateKeyExportError: Error {
    case unsupportedWallet
    case invalidSecret
    case missingAccount
}

extension WalletDatabase {
    func privateKeyExportItems(
        walletID: String,
        authorization: WalletSecretExportAuthorization,
        vault: WalletSecretVault = .shared
    ) async throws -> [WalletPrivateKeyExportItem] {
        let material = try await sensitiveMaterial(
            walletID: walletID,
            authorization: authorization,
            vault: vault
        )
        switch material {
        case let .bitcoinImportedWallet(imported):
            guard let text = String(data: try imported.encoded(), encoding: .utf8) else {
                throw WalletPrivateKeyExportError.invalidSecret
            }
            return [WalletPrivateKeyExportItem(id: "bitcoin", titleKey: BitcoinFamilyChain.bitcoin.nameKey,
                logoSource: .nativeCoin(blockchain: .bitcoin), backupNetwork: .bitcoin,
                detail: .localized("bitcoin.settings.generated_addresses"), privateKey: text)]
        case let .recoveryPhrase(credential):
            _ = try await ensureBitcoinHDWallet(
                walletID: walletID,
                vault: vault
            )
            let hdEntries = try await bitcoinHDPrivateKeyExportEntries(
                walletID: walletID,
                authorization: authorization,
                vault: vault
            )

            var silentPaymentAccount: BitcoinSilentPaymentAccount?
            var silentPaymentEntries: [
                BitcoinSilentPaymentPrivateKeyExportEntry
            ] = []
            if credential.electrumKind == nil {
                _ = try await ensureBitcoinSilentPaymentAccount(
                    walletID: walletID,
                    vault: vault
                )
                silentPaymentAccount = try await bitcoinSilentPaymentAccount(
                    walletID: walletID
                )
                silentPaymentEntries = try await
                    bitcoinSilentPaymentPrivateKeyExportEntries(
                        walletID: walletID,
                        authorization: authorization,
                        vault: vault
                    )
            }
            var items = try await Task.detached(
                priority: .userInitiated
            ) {
                try Self.recoveryPhrasePrivateKeyExportItems(
                    credential: credential
                )
            }.value
            let bitcoinItem = WalletPrivateKeyExportItem(
                bitcoinCatalog: WalletBitcoinPrivateKeyExportCatalog(
                    hdEntries: hdEntries,
                    silentPaymentAccount: silentPaymentAccount,
                    silentPaymentEntries: silentPaymentEntries
                )
            )
            if credential.electrumKind != nil {
                return [bitcoinItem]
            }
            guard let bitcoinIndex = items.firstIndex(where: {
                $0.id == BitcoinFamilyChain.bitcoin.rawValue
            }) else {
                throw WalletPrivateKeyExportError.missingAccount
            }
            items[bitcoinIndex] = bitcoinItem
            return items
        case let .privateKey(hexadecimal):
            guard let data = Data(hexString: hexadecimal),
                  data.count == 32
            else {
                throw WalletPrivateKeyExportError.invalidSecret
            }
            let descriptor = try await importedPrivateKeyMetadata(
                walletID: walletID
            )
            return try await Task.detached(priority: .userInitiated) {
                let validatedDraft = try PrivateKeyImportService
                    .revalidate(
                        privateKeyData: data,
                        network: descriptor.network,
                        format: descriptor.format
                    )
                guard descriptor.matches(
                    address: validatedDraft.address
                ) else {
                    throw WalletPrivateKeyExportError.invalidSecret
                }
                return [
                    try Self.importedPrivateKeyExportItem(
                        data: data,
                        descriptor: descriptor
                    )
                ]
            }.value
        }
    }

    func importedPrivateKeyMetadata(
        walletID: String
    ) async throws -> WalletImportedPrivateKeyMetadata {
        try await pool.read { database in
            guard
                let wallet = try DBWalletRecord.fetchOne(
                    database,
                    key: walletID
                ),
                wallet.profileID == Self.defaultProfileID,
                wallet.archivedAt == nil,
                wallet.kind
                    == DatabaseWalletKind.importedPrivateKey.rawValue
            else {
                throw WalletPrivateKeyExportError.unsupportedWallet
            }

            let accounts = try DBWalletAccountRecord
                .filter(Column("walletID") == walletID)
                .order(Column("createdAt"), Column("networkID"))
                .fetchAll(database)
            if let account = accounts.first(where: { $0.networkID == "bitcoin" && $0.derivationPath == BitcoinImportedWalletMaterial.accountMarker }) {
                return WalletImportedPrivateKeyMetadata(network: .bitcoin, format: .wifCompressed, address: account.address)
            }
            let networkIDs = Set(accounts.map(\.networkID))
            guard
                let network = Self.privateKeyImportNetwork(
                    enabledNetworkIDs: networkIDs
                ),
                let account = accounts.first(where: {
                    $0.networkID == network.networkID
                }) ?? accounts.first,
                let format = PrivateKeyImportFormat(
                    accountMarker: account.derivationPath
                )
            else {
                throw WalletPrivateKeyExportError.missingAccount
            }
            return WalletImportedPrivateKeyMetadata(
                network: network,
                format: format,
                address: account.address
            )
        }
    }

    static func recoveryPhrasePrivateKeyExportItems(
        credential: WalletRecoveryCredential
    ) throws -> [WalletPrivateKeyExportItem] {
        if let kind = credential.electrumKind {
            let derivation = BitcoinHDDerivationService()
            return try [
                BitcoinHDAddressBranch.external,
                .change,
            ].map { branch in
                let key = try derivation.privateKey(
                    credential: credential,
                    addressType: kind.addressType,
                    branch: branch,
                    index: 0
                )
                let derived = try derivation.deriveAddress(
                    credential: credential,
                    addressType: kind.addressType,
                    branch: branch,
                    index: 0
                )
                return WalletPrivateKeyExportItem(
                    id: "bitcoin-electrum-\(branch.rawValue)-0",
                    titleKey: BitcoinFamilyChain.bitcoin.nameKey,
                    logoSource: .nativeCoin(blockchain: .bitcoin),
                    backupNetwork: .bitcoin,
                    detail: .derivationPath(derived.derivationPath),
                    privateKey: bitcoinWIF(
                        data: key.data,
                        chain: .bitcoin,
                        compressed: true
                    )
                )
            }
        }
        guard let wallet = credential.makeHDWallet()
        else {
            throw WalletPrivateKeyExportError.invalidSecret
        }

        let evmPath = CoinType.ethereum.derivationPath()
        let evmKey = try recoveryPhraseKey(
            wallet: wallet,
            coin: .ethereum,
            derivationPath: evmPath
        )
        var items = ReceiveNetworkCatalog.all
            .filter { $0.blockchain.isEVM }
            .map { network in
                WalletPrivateKeyExportItem(
                    id: "evm-\(network.id)",
                    titleKey: network.nameKey,
                    logoSource: network.logoSource,
                    backupNetwork: .evm,
                    detail: .derivationPath(evmPath),
                    privateKey: evmKey.data.hexString
                )
            }

        items.append(
            contentsOf: try BitcoinFamilyChain.allCases.map { chain in
                let key = try recoveryPhraseKey(
                    wallet: wallet,
                    coin: chain.coin,
                    derivationPath: chain.derivationPath
                )
                return WalletPrivateKeyExportItem(
                    id: chain.rawValue,
                    titleKey: chain.nameKey,
                    logoSource: .nativeCoin(
                        blockchain: chain.blockchain
                    ),
                    backupNetwork: chain.privateKeyImportNetwork,
                    detail: .derivationPath(chain.derivationPath),
                    privateKey: bitcoinWIF(
                        data: key.data,
                        chain: chain,
                        compressed: true
                    )
                )
            }
        )

        let tronPath = CoinType.tron.derivationPath()
        items.append(
            WalletPrivateKeyExportItem(
                id: "tron",
                titleKey: "network.tron.name",
                logoSource: .nativeCoin(blockchain: .tron),
                backupNetwork: .tron,
                detail: .derivationPath(tronPath),
                privateKey: wallet.getKeyForCoin(coin: .tron)
                    .data.hexString
            )
        )

        items.append(
            contentsOf: try SolanaDerivationKind.allCases.map { kind in
                let key = try recoveryPhraseKey(
                    wallet: wallet,
                    coin: .solana,
                    derivationPath: kind.derivationPath
                )
                var keypair = key.data
                keypair.append(key.getPublicKeyEd25519().data)
                return WalletPrivateKeyExportItem(
                    id: "solana-\(kind.rawValue)",
                    titleKey: kind == .phantom
                        ? "settings.wallets.private_key.export.chain.solana.phantom"
                        : "settings.wallets.private_key.export.chain.solana.trust_wallet",
                    logoSource: .nativeCoin(blockchain: .solana),
                    backupNetwork: .solana,
                    detail: .derivationPath(kind.derivationPath),
                    privateKey: Base58.encodeNoCheck(data: keypair)
                )
            }
        )

        let tonPath = TONConstants.derivationPath
        items.append(
            WalletPrivateKeyExportItem(
                id: "ton",
                titleKey: "network.ton.name",
                logoSource: .nativeCoin(blockchain: .ton),
                backupNetwork: .ton,
                detail: .derivationPath(tonPath),
                privateKey: try recoveryPhraseKey(
                    wallet: wallet,
                    coin: .ton,
                    derivationPath: tonPath
                ).data.hexString
            )
        )
        let suiPath = SuiConstants.derivationPath
        items.append(
            WalletPrivateKeyExportItem(
                id: SuiConstants.networkID,
                titleKey: "network.sui.name",
                logoSource: .nativeCoin(blockchain: .sui),
                backupNetwork: .sui,
                detail: .derivationPath(suiPath),
                privateKey: try recoveryPhraseKey(
                    wallet: wallet,
                    coin: .sui,
                    derivationPath: suiPath
                ).data.hexString
            )
        )
        let xrpPath = XRPConstants.derivationPath
        items.append(
            WalletPrivateKeyExportItem(
                id: XRPConstants.networkID,
                titleKey: "network.xrp.name",
                logoSource: .nativeCoin(blockchain: .xrp),
                backupNetwork: .xrp,
                detail: .derivationPath(xrpPath),
                privateKey: try recoveryPhraseKey(
                    wallet: wallet,
                    coin: .xrp,
                    derivationPath: xrpPath
                ).data.hexString
            )
        )
        let nearPath = NEARConstants.derivationPath
        items.append(
            WalletPrivateKeyExportItem(
                id: NEARConstants.networkID,
                titleKey: "network.near.name",
                logoSource: .nativeCoin(blockchain: .near),
                backupNetwork: .near,
                detail: .derivationPath(nearPath),
                privateKey: try recoveryPhraseKey(
                    wallet: wallet,
                    coin: .near,
                    derivationPath: nearPath
                ).data.hexString
            )
        )
        let aptosPath = AptosConstants.derivationPath
        items.append(
            WalletPrivateKeyExportItem(
                id: AptosConstants.networkID,
                titleKey: "network.aptos.name",
                logoSource: .nativeCoin(blockchain: .aptos),
                backupNetwork: .aptos,
                detail: .derivationPath(aptosPath),
                privateKey: wallet.getKeyForCoin(coin: .aptos)
                    .data.hexString
            )
        )
        let stellarPath = StellarConstants.derivationPath
        items.append(
            WalletPrivateKeyExportItem(
                id: StellarConstants.networkID,
                titleKey: "network.stellar.name",
                logoSource: .nativeCoin(blockchain: .stellar),
                backupNetwork: .stellar,
                detail: .derivationPath(stellarPath),
                privateKey: try recoveryPhraseKey(
                    wallet: wallet,
                    coin: .stellar,
                    derivationPath: stellarPath
                ).data.hexString
            )
        )
        return items
    }

    private static func recoveryPhraseKey(
        wallet: HDWallet,
        coin: CoinType,
        derivationPath: String
    ) throws -> PrivateKey {
        guard let key = wallet.getKey(
            coin: coin,
            derivationPath: derivationPath
        ) else {
            throw WalletPrivateKeyExportError.invalidSecret
        }
        return key
    }

    private static func importedPrivateKeyExportItem(
        data: Data,
        descriptor: WalletImportedPrivateKeyMetadata
    ) throws -> WalletPrivateKeyExportItem {
        let encoded: String
        let detailKey: String
        switch descriptor.network {
        case .aptos, .stellar, .evm, .tron, .ton, .sui, .xrp,
             .near:
            encoded = data.hexString
            detailKey =
                "settings.wallets.private_key.export.format.hexadecimal"
        case .bitcoin, .litecoin, .dogecoin, .bitcoinCash:
            guard let chain = descriptor.network.bitcoinFamilyChain
            else {
                throw WalletPrivateKeyExportError.invalidSecret
            }
            encoded = bitcoinWIF(
                data: data,
                chain: chain,
                compressed: descriptor.format != .wifUncompressed
            )
            detailKey = descriptor.format == .wifUncompressed
                ? "settings.wallets.private_key.export.format.wif_uncompressed"
                : "settings.wallets.private_key.export.format.wif_compressed"
        case .solana:
            guard let privateKey = PrivateKey(data: data) else {
                throw WalletPrivateKeyExportError.invalidSecret
            }
            if descriptor.format == .solanaKeypair {
                var keypair = data
                keypair.append(
                    privateKey.getPublicKeyEd25519().data
                )
                encoded = Base58.encodeNoCheck(data: keypair)
                detailKey =
                    "settings.wallets.private_key.export.format.solana_keypair"
            } else {
                encoded = Base58.encodeNoCheck(data: data)
                detailKey =
                    "settings.wallets.private_key.export.format.solana_seed"
            }
        }

        return WalletPrivateKeyExportItem(
            id: "imported-\(descriptor.network.rawValue)",
            titleKey: descriptor.network.titleKey,
            logoSource: .nativeCoin(
                blockchain: descriptor.network.blockchain
            ),
            backupNetwork: descriptor.network,
            detail: .localized(detailKey),
            privateKey: encoded
        )
    }

    private static func bitcoinWIF(
        data: Data,
        chain: BitcoinFamilyChain,
        compressed: Bool
    ) -> String {
        let prefix: UInt8
        switch chain {
        case .bitcoin, .bitcoinCash:
            prefix = 0x80
        case .litecoin:
            prefix = 0xb0
        case .dogecoin:
            prefix = 0x9e
        }
        var payload = Data([prefix])
        payload.append(data)
        if compressed {
            payload.append(0x01)
        }
        return Base58.encode(data: payload)
    }
}
