import Foundation
import GRDB
import WalletCore

enum DeviceMigrationAccountSecretVerifier {
    static func validate(
        source: any DatabaseReader,
        secrets: [DeviceMigrationWalletSecret]
    ) throws {
        let contents = try source.read { database in
            (
                wallets: try DBWalletRecord.fetchAll(database),
                accounts: try DBWalletAccountRecord.fetchAll(database),
                muunWallets:
                    try DBMuunRecoveryWalletRecord.fetchAll(database),
                muunAddresses:
                    try DBMuunRecoveryAddressRecord.fetchAll(database)
            )
        }
        let secretGroups = Dictionary(grouping: secrets, by: \.walletID)
        guard secretGroups.values.allSatisfy({ $0.count == 1 }) else {
            throw DeviceMigrationError.incompleteSecretSet
        }
        let accountsByWallet = Dictionary(
            grouping: contents.accounts,
            by: \.walletID
        )
        let muunWalletByID = Dictionary(
            uniqueKeysWithValues: contents.muunWallets.map {
                ($0.walletID, $0)
            }
        )
        let muunAddressesByWallet = Dictionary(
            grouping: contents.muunAddresses,
            by: \.walletID
        )

        for wallet in contents.wallets {
            guard let kind = DatabaseWalletKind(rawValue: wallet.kind) else {
                throw DeviceMigrationError.invalidDatabase
            }
            let accounts = accountsByWallet[wallet.id] ?? []
            do {
                switch kind {
                case .created, .importedRecoveryPhrase:
                    guard
                        let secret = secretGroups[wallet.id]?.first,
                        secret.kind == .recoveryPhrase
                    else {
                        throw VerificationFailure(
                            reason: .secretCoverage,
                            family: .unknown
                        )
                    }
                    try verifyRecoveryPhrase(
                        secret.data,
                        recordedWordCount: wallet.mnemonicWordCount,
                        accounts: accounts
                    )
                case .importedPrivateKey:
                    guard let secret = secretGroups[wallet.id]?.first else {
                        throw VerificationFailure(
                            reason: .secretCoverage,
                            family: .unknown
                        )
                    }
                    if secret.kind == .bitcoinImportedWallet {
                        let imported = try BitcoinImportedWalletMaterial.decode(secret.data)
                        let primary = try imported.primaryAddress()
                        guard accounts.count == 1, let account = accounts.first,
                              account.networkID == "bitcoin",
                              account.derivationPath == BitcoinImportedWalletMaterial.accountMarker,
                              account.address == primary.address,
                              account.normalizedAddress == primary.address.lowercased(),
                              account.publicKey == primary.publicKey.hexString else {
                            throw DeviceMigrationError.invalidWalletSecret
                        }
                        try DeviceMigrationBitcoinImportedVerifier.validate(source: source, walletID: wallet.id, material: imported)
                    } else if let recovery = muunWalletByID[wallet.id] {
                        guard secret.kind == .muunRecovery else {
                            throw VerificationFailure(
                                reason: .secretCoverage,
                                family: .bitcoinFamily
                            )
                        }
                        try verifyMuunRecovery(
                            secret.data,
                            recordedWordCount: wallet.mnemonicWordCount,
                            recovery: recovery,
                            addresses:
                                muunAddressesByWallet[wallet.id] ?? [],
                            accounts: accounts
                        )
                    } else {
                        guard secret.kind == .privateKey else {
                            throw VerificationFailure(
                                reason: .secretCoverage,
                                family: .unknown
                            )
                        }
                        try verifyPrivateKey(
                            secret.data,
                            recordedWordCount: wallet.mnemonicWordCount,
                            accounts: accounts
                        )
                    }
                case .watchOnly, .hardware:
                    try verifyWalletWithoutLocalSecret(
                        secret: secretGroups[wallet.id]?.first,
                        recordedWordCount: wallet.mnemonicWordCount,
                        accounts: accounts
                    )
                }
            } catch let failure as VerificationFailure {
                throw failure.reason.deviceMigrationError
            } catch {
                throw DeviceMigrationError.invalidWalletSecret
            }
        }
    }
}

extension DeviceMigrationAccountSecretVerifier {
    struct DerivedIdentity {
        let address: String
        let normalizedAddress: String
        let publicKey: String
    }

    enum AccountFamily: String {
        case evm
        case bitcoinFamily = "bitcoin_family"
        case tron
        case solana
        case ton
        case sui
        case xrp
        case near
        case aptos
        case stellar
        case unknown
    }

    enum FailureReason: String {
        case addressMismatch = "address_mismatch"
        case derivationFailed = "derivation_failed"
        case derivationPathMismatch = "derivation_path_mismatch"
        case invalidAccountIndex = "invalid_account_index"
        case invalidAccountLabel = "invalid_account_label"
        case invalidAccountRole = "invalid_account_role"
        case invalidAddress = "invalid_address"
        case invalidMnemonicWordCount = "invalid_mnemonic_word_count"
        case invalidPrivateKeyScope = "invalid_private_key_scope"
        case invalidPublicKey = "invalid_public_key"
        case missingPublicKey = "missing_public_key"
        case normalizedAddressMismatch = "normalized_address_mismatch"
        case publicKeyMismatch = "public_key_mismatch"
        case secretCoverage = "secret_coverage"
        case unsupportedNetwork = "unsupported_network"

        var deviceMigrationError: DeviceMigrationError {
            switch self {
            case .invalidAccountIndex, .invalidAccountLabel,
                 .invalidAccountRole, .invalidAddress,
                 .invalidMnemonicWordCount, .invalidPublicKey,
                 .missingPublicKey, .normalizedAddressMismatch,
                 .unsupportedNetwork:
                .invalidDatabase
            case .addressMismatch, .derivationFailed,
                 .derivationPathMismatch, .invalidPrivateKeyScope,
                 .publicKeyMismatch, .secretCoverage:
                .invalidWalletSecret
            }
        }
    }

    struct VerificationFailure: Error {
        let reason: FailureReason
        let family: AccountFamily
    }

    static func verifyRecoveryPhrase(
        _ data: Data,
        recordedWordCount: Int?,
        accounts: [DBWalletAccountRecord]
    ) throws {
        guard !accounts.isEmpty,
              accounts.allSatisfy({ !$0.isWatchOnly }) else {
            throw VerificationFailure(
                reason: .invalidAccountRole,
                family: .unknown
            )
        }
        guard let credential = try? WalletRecoveryCredential.decode(data)
        else {
            throw VerificationFailure(
                reason: .derivationFailed,
                family: .unknown
            )
        }
        let actualWordCount = credential.wordCount
        guard recordedWordCount == nil
                || recordedWordCount == actualWordCount else {
            throw VerificationFailure(
                reason: .invalidMnemonicWordCount,
                family: .unknown
            )
        }

        if credential.electrumKind != nil {
            for account in accounts {
                try verifyAccountIndex(account)
                let identity = try electrumRecoveryPhraseIdentity(
                    credential: credential,
                    account: account
                )
                try verify(
                    identity,
                    matches: account,
                    family: .bitcoinFamily
                )
            }
            return
        }

        guard let wallet = credential.makeHDWallet() else {
            throw VerificationFailure(
                reason: .derivationFailed,
                family: .unknown
            )
        }

        for account in accounts {
            try verifyAccountIndex(account)
            let family = try accountFamily(
                networkID: account.networkID
            )
            let identity = try recoveryPhraseIdentity(
                credential: credential,
                wallet: wallet,
                account: account,
                family: family
            )
            try verify(
                identity,
                matches: account,
                family: family
            )
        }
    }

    static func electrumRecoveryPhraseIdentity(
        credential: WalletRecoveryCredential,
        account: DBWalletAccountRecord
    ) throws -> DerivedIdentity {
        let family = AccountFamily.bitcoinFamily
        guard account.networkID == BitcoinFamilyChain.bitcoin.networkID,
              let kind = credential.electrumKind,
              let location = account.derivationPath.flatMap(
                  BitcoinHDAddressType.location(for:)
              ), location.addressType == kind.addressType else {
            throw VerificationFailure(
                reason: .derivationPathMismatch,
                family: family
            )
        }
        let derived: BitcoinHDDerivedAddress
        do {
            derived = try BitcoinHDDerivationService().deriveAddress(
                credential: credential,
                addressType: location.addressType,
                branch: location.branch,
                index: location.index
            )
        } catch {
            throw VerificationFailure(
                reason: .derivationFailed,
                family: family
            )
        }
        return DerivedIdentity(
            address: derived.address,
            normalizedAddress: derived.address.lowercased(),
            publicKey: derived.publicKey.hexString
        )
    }

    static func recoveryPhraseIdentity(
        credential: WalletRecoveryCredential,
        wallet: HDWallet,
        account: DBWalletAccountRecord,
        family: AccountFamily
    ) throws -> DerivedIdentity {
        switch family {
        case .bitcoinFamily:
            if account.networkID == "bitcoin",
               let path = account.derivationPath,
               let location = BitcoinHDAddressType.location(
                   for: path, address: account.address, credential: credential
               ) {
                let child = try BitcoinHDDerivationService().deriveAddress(
                    credential: credential, addressType: location.addressType,
                    branch: location.branch, index: location.index
                )
                return DerivedIdentity(address: child.address,
                                       normalizedAddress: child.address.lowercased(),
                                       publicKey: child.publicKey.hexString)
            }
            guard
                let chain = BitcoinFamilyChain(
                    rawValue: account.networkID
                ),
                account.derivationPath == chain.derivationPath
            else {
                throw VerificationFailure(
                    reason: .derivationPathMismatch,
                    family: family
                )
            }
            let key = try requiredRecoveryPhraseKey(
                wallet: wallet,
                coin: chain.coin,
                derivationPath: chain.derivationPath,
                family: family
            )
            let material: BitcoinFamilyAccountMaterial
            do {
                material = try BitcoinFamilyDerivationService().derive(
                    privateKey: key.data,
                    chain: chain,
                    format: .extendedNativeSegwit,
                    derivationPath: chain.derivationPath
                )
            } catch {
                throw VerificationFailure(
                    reason: .derivationFailed,
                    family: family
                )
            }
            return DerivedIdentity(
                address: material.address,
                normalizedAddress: material.address.lowercased(),
                publicKey: material.publicKey
            )
        case .solana:
            guard
                let label = account.label,
                let kind = SolanaDerivationKind(rawValue: label),
                account.derivationPath == kind.derivationPath
            else {
                throw VerificationFailure(
                    reason: .derivationPathMismatch,
                    family: family
                )
            }
            let key = try requiredRecoveryPhraseKey(
                wallet: wallet,
                coin: .solana,
                derivationPath: kind.derivationPath,
                family: family
            )
            let address = CoinType.solana.deriveAddress(
                privateKey: key
            )
            return DerivedIdentity(
                address: address,
                normalizedAddress: address,
                publicKey: key.getPublicKeyEd25519()
                    .data.base64EncodedString()
            )
        case .tron:
            let path = CoinType.tron.derivationPath()
            guard account.derivationPath == path else {
                throw VerificationFailure(
                    reason: .derivationPathMismatch,
                    family: family
                )
            }
            let key = try requiredRecoveryPhraseKey(
                wallet: wallet,
                coin: .tron,
                derivationPath: path,
                family: family
            )
            let address = CoinType.tron.deriveAddress(
                privateKey: key
            )
            return DerivedIdentity(
                address: address,
                normalizedAddress: address,
                publicKey: key
                    .getPublicKeySecp256k1(compressed: false)
                    .data.base64EncodedString()
            )
        case .ton:
            let path = TONConstants.derivationPath
            guard account.derivationPath == path else {
                throw VerificationFailure(
                    reason: .derivationPathMismatch,
                    family: family
                )
            }
            let key = try requiredRecoveryPhraseKey(
                wallet: wallet,
                coin: .ton,
                derivationPath: path,
                family: family
            )
            guard let material = try? TONAddress.material(
                privateKey: key,
                derivationPath: path
            ) else {
                throw VerificationFailure(
                    reason: .derivationFailed,
                    family: family
                )
            }
            return DerivedIdentity(
                address: material.address,
                normalizedAddress: material.rawAddress,
                publicKey: material.publicKey
            )
        case .sui:
            let path = SuiConstants.derivationPath
            guard account.derivationPath == path else {
                throw VerificationFailure(
                    reason: .derivationPathMismatch,
                    family: family
                )
            }
            let key = try requiredRecoveryPhraseKey(
                wallet: wallet,
                coin: .sui,
                derivationPath: path,
                family: family
            )
            let address = CoinType.sui.deriveAddress(privateKey: key)
            guard let canonical = SuiCoinType
                .canonicalAccountAddress(address) else {
                throw VerificationFailure(
                    reason: .derivationFailed,
                    family: family
                )
            }
            return DerivedIdentity(
                address: canonical,
                normalizedAddress: canonical,
                publicKey: key.getPublicKeyEd25519()
                    .description
            )
        case .xrp:
            let path = XRPConstants.derivationPath
            guard account.derivationPath == path else {
                throw VerificationFailure(
                    reason: .derivationPathMismatch,
                    family: family
                )
            }
            let key = try requiredRecoveryPhraseKey(
                wallet: wallet,
                coin: .xrp,
                derivationPath: path,
                family: family
            )
            let address = CoinType.xrp.deriveAddress(privateKey: key)
            return DerivedIdentity(
                address: address,
                normalizedAddress: address,
                publicKey: key
                    .getPublicKeySecp256k1(compressed: true)
                    .description
            )
        case .near:
            let path = NEARConstants.derivationPath
            guard account.derivationPath == path else {
                throw VerificationFailure(
                    reason: .derivationPathMismatch,
                    family: family
                )
            }
            let key = try requiredRecoveryPhraseKey(
                wallet: wallet,
                coin: .near,
                derivationPath: path,
                family: family
            )
            guard let material = try? NEARAddress.material(
                privateKey: key,
                derivationPath: path
            ) else {
                throw VerificationFailure(
                    reason: .derivationFailed,
                    family: family
                )
            }
            return DerivedIdentity(
                address: material.address,
                normalizedAddress: material.address,
                publicKey: material.publicKey
            )
        case .aptos:
            let path = AptosConstants.derivationPath
            guard account.derivationPath == path else {
                throw VerificationFailure(
                    reason: .derivationPathMismatch,
                    family: family
                )
            }
            guard let material = try? AptosAddress.material(
                hdWallet: wallet
            ) else {
                throw VerificationFailure(
                    reason: .derivationFailed,
                    family: family
                )
            }
            return DerivedIdentity(
                address: material.address,
                normalizedAddress: material.address,
                publicKey: material.publicKey
            )
        case .stellar:
            let path = StellarConstants.derivationPath
            guard account.derivationPath == path else {
                throw VerificationFailure(
                    reason: .derivationPathMismatch,
                    family: family
                )
            }
            let key = try requiredRecoveryPhraseKey(
                wallet: wallet,
                coin: .stellar,
                derivationPath: path,
                family: family
            )
            guard let material = try? StellarAddress.material(
                privateKey: key,
                derivationPath: path
            ) else {
                throw VerificationFailure(
                    reason: .derivationFailed,
                    family: family
                )
            }
            return DerivedIdentity(
                address: material.address,
                normalizedAddress: material.address,
                publicKey: material.publicKey
            )
        case .evm:
            let path = CoinType.ethereum.derivationPath()
            guard account.derivationPath == path else {
                throw VerificationFailure(
                    reason: .derivationPathMismatch,
                    family: family
                )
            }
            let key = try requiredRecoveryPhraseKey(
                wallet: wallet,
                coin: .ethereum,
                derivationPath: path,
                family: family
            )
            let address = CoinType.ethereum.deriveAddress(
                privateKey: key
            )
            return DerivedIdentity(
                address: address,
                normalizedAddress: address.lowercased(),
                publicKey: key
                    .getPublicKeySecp256k1(compressed: false)
                    .description
            )
        case .unknown:
            throw VerificationFailure(
                reason: .unsupportedNetwork,
                family: family
            )
        }
    }

    static func verifyPrivateKey(
        _ data: Data,
        recordedWordCount: Int?,
        accounts: [DBWalletAccountRecord]
    ) throws {
        guard data.count == 32 else {
            throw VerificationFailure(
                reason: .derivationFailed,
                family: .unknown
            )
        }
        guard !accounts.isEmpty,
              accounts.allSatisfy({ !$0.isWatchOnly }) else {
            throw VerificationFailure(
                reason: .invalidAccountRole,
                family: .unknown
            )
        }
        guard recordedWordCount == nil else {
            throw VerificationFailure(
                reason: .invalidMnemonicWordCount,
                family: .unknown
            )
        }
        let scope = try privateKeyScope(accounts: accounts)
        let family = accountFamily(for: scope)
        guard isValidPrivateKey(data, for: scope) else {
            throw VerificationFailure(
                reason: .derivationFailed,
                family: family
            )
        }

        for account in accounts {
            try verifyAccountIndex(account)
            guard
                try privateKeyNetwork(for: account) == scope,
                let format = PrivateKeyImportFormat(
                    accountMarker: account.derivationPath
                ),
                privateKeyFormat(
                    format,
                    isAllowedFor: scope
                )
            else {
                throw VerificationFailure(
                    reason: .invalidPrivateKeyScope,
                    family: family
                )
            }
            if scope == .solana,
               account.label != SolanaDerivationKind.phantom.rawValue {
                throw VerificationFailure(
                    reason: .invalidAccountLabel,
                    family: family
                )
            }
            let draft: WalletImportDraft
            do {
                draft = try PrivateKeyImportService.revalidate(
                    privateKeyData: data,
                    network: scope,
                    format: format
                )
            } catch {
                throw VerificationFailure(
                    reason: .derivationFailed,
                    family: family
                )
            }
            guard draft.derivationPath == account.derivationPath else {
                throw VerificationFailure(
                    reason: .derivationPathMismatch,
                    family: family
                )
            }
            try verify(
                DerivedIdentity(
                    address: draft.address,
                    normalizedAddress: draft.normalizedAddress,
                    publicKey: draft.publicKey
                ),
                matches: account,
                family: family
            )
        }
    }

    static func privateKeyScope(
        accounts: [DBWalletAccountRecord]
    ) throws -> PrivateKeyImportNetwork {
        let networks = try Set(
            accounts.map { account in
                try privateKeyNetwork(for: account)
            }
        )
        guard networks.count == 1, let network = networks.first else {
            throw VerificationFailure(
                reason: .invalidPrivateKeyScope,
                family: .unknown
            )
        }
        if network != .evm, accounts.count != 1 {
            throw VerificationFailure(
                reason: .invalidPrivateKeyScope,
                family: accountFamily(for: network)
            )
        }
        return network
    }

    static func privateKeyNetwork(
        for account: DBWalletAccountRecord
    ) throws -> PrivateKeyImportNetwork {
        if let chain = BitcoinFamilyChain(
            rawValue: account.networkID
        ) {
            return switch chain {
            case .bitcoin: .bitcoin
            case .bitcoinCash: .bitcoinCash
            case .litecoin: .litecoin
            case .dogecoin: .dogecoin
            }
        }
        if account.networkID == TronConstants.networkID {
            return .tron
        }
        if account.networkID == SolanaConstants.networkID {
            return .solana
        }
        if account.networkID == TONConstants.networkID {
            return .ton
        }
        if account.networkID == SuiConstants.networkID {
            return .sui
        }
        if account.networkID == XRPConstants.networkID {
            return .xrp
        }
        if account.networkID == NEARConstants.networkID {
            return .near
        }
        if account.networkID == AptosConstants.networkID {
            return .aptos
        }
        if account.networkID == StellarConstants.networkID {
            return .stellar
        }
        guard try accountFamily(
            networkID: account.networkID
        ) == .evm else {
            throw VerificationFailure(
                reason: .unsupportedNetwork,
                family: .unknown
            )
        }
        return .evm
    }

    static func privateKeyFormat(
        _ format: PrivateKeyImportFormat,
        isAllowedFor network: PrivateKeyImportNetwork
    ) -> Bool {
        switch network {
        case .evm, .tron, .xrp:
            format == .rawSecp256k1
        case .solana:
            format == .solanaSeed || format == .solanaKeypair
        case .aptos, .ton, .sui, .near, .stellar:
            format == .rawEd25519
        case .bitcoin:
            switch format {
            case .wifCompressed, .wifUncompressed,
                 .extendedLegacy, .extendedNestedSegwit,
                 .extendedNativeSegwit:
                true
            case .rawSecp256k1, .solanaSeed, .solanaKeypair,
                 .rawEd25519:
                false
            }
        case .litecoin:
            switch format {
            case .wifCompressed, .wifUncompressed,
                 .extendedLegacy, .extendedNestedSegwit:
                true
            case .extendedNativeSegwit, .rawSecp256k1,
                 .solanaSeed, .solanaKeypair, .rawEd25519:
                false
            }
        case .bitcoinCash, .dogecoin:
            switch format {
            case .wifCompressed, .wifUncompressed, .extendedLegacy:
                true
            case .extendedNestedSegwit, .extendedNativeSegwit,
                 .rawSecp256k1, .solanaSeed, .solanaKeypair,
                 .rawEd25519:
                false
            }
        }
    }

    static func verifyWalletWithoutLocalSecret(
        secret: DeviceMigrationWalletSecret?,
        recordedWordCount: Int?,
        accounts: [DBWalletAccountRecord]
    ) throws {
        guard secret == nil,
              recordedWordCount == nil,
              !accounts.isEmpty,
              accounts.allSatisfy(\.isWatchOnly) else {
            throw VerificationFailure(
                reason: .invalidAccountRole,
                family: .unknown
            )
        }
        for account in accounts {
            try verifyAccountIndex(account)
            let family = try accountFamily(
                networkID: account.networkID
            )
            guard isValidAddress(
                account.address,
                family: family,
                networkID: account.networkID
            ) else {
                throw VerificationFailure(
                    reason: .invalidAddress,
                    family: family
                )
            }
            let normalized = family == .evm
                || family == .bitcoinFamily
                ? account.address.lowercased()
                : account.address
            guard account.normalizedAddress == normalized else {
                throw VerificationFailure(
                    reason: .normalizedAddressMismatch,
                    family: family
                )
            }
            try verifyHardwarePublicKeyIfPresent(
                account,
                family: family
            )
        }
    }

    static func requiredRecoveryPhraseKey(
        wallet: HDWallet,
        coin: CoinType,
        derivationPath: String,
        family: AccountFamily
    ) throws -> PrivateKey {
        guard let key = wallet.getKey(
            coin: coin,
            derivationPath: derivationPath
        ) else {
            throw VerificationFailure(
                reason: .derivationFailed,
                family: family
            )
        }
        return key
    }

    static func verify(
        _ identity: DerivedIdentity,
        matches account: DBWalletAccountRecord,
        family: AccountFamily
    ) throws {
        let addressesMatch = family == .evm
            ? identity.address.caseInsensitiveCompare(account.address)
                == .orderedSame
            : identity.address == account.address
        guard addressesMatch else {
            throw VerificationFailure(
                reason: .addressMismatch,
                family: family
            )
        }
        guard identity.normalizedAddress == account.normalizedAddress else {
            throw VerificationFailure(
                reason: .normalizedAddressMismatch,
                family: family
            )
        }
        guard let publicKey = account.publicKey,
              !publicKey.isEmpty else {
            throw VerificationFailure(
                reason: .missingPublicKey,
                family: family
            )
        }
        guard publicKey == identity.publicKey else {
            throw VerificationFailure(
                reason: .publicKeyMismatch,
                family: family
            )
        }
    }

    static func verifyAccountIndex(
        _ account: DBWalletAccountRecord
    ) throws {
        guard account.accountIndex == 0 else {
            throw VerificationFailure(
                reason: .invalidAccountIndex,
                family: .unknown
            )
        }
    }

    static func isValidPrivateKey(
        _ data: Data,
        for network: PrivateKeyImportNetwork
    ) -> Bool {
        switch network {
        case .aptos, .solana, .ton, .sui, .near, .stellar:
            PrivateKey(data: data) != nil
        case .evm, .bitcoin, .bitcoinCash, .litecoin, .dogecoin,
             .tron, .xrp:
            PrivateKey.isValid(data: data, curve: .secp256k1)
        }
    }

    static func verifyHardwarePublicKeyIfPresent(
        _ account: DBWalletAccountRecord,
        family: AccountFamily
    ) throws {
        guard let encoded = account.publicKey else { return }
        guard !encoded.isEmpty,
              let data = decodedPublicKey(encoded, family: family)
        else {
            throw VerificationFailure(
                reason: .invalidPublicKey,
                family: family
            )
        }

        let publicKey: PublicKey?
        switch family {
        case .aptos, .solana, .ton, .sui, .near, .stellar:
            publicKey = PublicKey(data: data, type: .ed25519)
        case .tron:
            guard data.count == 65 else {
                throw VerificationFailure(
                    reason: .invalidPublicKey,
                    family: family
                )
            }
            publicKey = PublicKey(
                data: data,
                type: .secp256k1Extended
            )
        case .evm, .bitcoinFamily, .xrp:
            let type: PublicKeyType
            switch data.count {
            case 33:
                type = .secp256k1
            case 65:
                type = .secp256k1Extended
            default:
                throw VerificationFailure(
                    reason: .invalidPublicKey,
                    family: family
                )
            }
            publicKey = PublicKey(data: data, type: type)
        case .unknown:
            publicKey = nil
        }
        guard let publicKey,
              isCurveValid(publicKey, family: family),
              hardwarePublicKey(
                publicKey,
                matches: account,
                family: family
              ) else {
            throw VerificationFailure(
                reason: .invalidPublicKey,
                family: family
            )
        }
    }

}
