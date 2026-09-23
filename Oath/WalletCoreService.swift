import Foundation
import WalletCore

struct WalletCreationDraft: Equatable, Sendable {
    let mnemonic: String
    let passphrase: String
    let words: [String]
    let address: String
    let normalizedAddress: String
    let derivationPath: String
    let publicKey: String
}

struct WalletImportDraft: Equatable, Sendable {
    enum Secret: Equatable, Sendable {
        case recoveryPhrase(
            mnemonic: String,
            passphrase: String,
            wordCount: Int
        )
        case privateKey(
            data: Data,
            network: PrivateKeyImportNetwork,
            format: PrivateKeyImportFormat
        )
        case muunRecovery(MuunRecoveryKeyMaterial)
        case bitcoinImportedWallet(BitcoinImportedWalletMaterial)
    }

    var hasRecoveryPhrase: Bool {
        if case .recoveryPhrase = secret { return true }
        return false
    }

    let secret: Secret
    let address: String
    let normalizedAddress: String
    let derivationPath: String?
    let publicKey: String
}

enum WalletCoreServiceError: Error {
    case generationFailed
    case invalidEntropy
    case invalidMnemonic
    case invalidPrivateKey
    case invalidAddress
    case invalidDerivationPath
    case derivationMismatch
}

enum WalletCoreService {
    static func generateEVMWallet() throws -> WalletCreationDraft {
        guard let wallet = HDWallet(strength: 128, passphrase: "") else {
            throw WalletCoreServiceError.generationFailed
        }

        let draft = try draft(from: wallet, passphrase: "")
        guard draft.words.count == 12 else {
            throw WalletCoreServiceError.generationFailed
        }
        return draft
    }

    static func generateEVMWallet(
        entropy: Data,
        passphrase: String = ""
    ) throws -> WalletCreationDraft {
        guard entropy.count == 32 else {
            throw WalletCoreServiceError.invalidEntropy
        }

        let normalizedPassphrase = passphrase
            .decomposedStringWithCompatibilityMapping
        guard let wallet = HDWallet(
            entropy: entropy,
            passphrase: normalizedPassphrase
        ) else {
            throw WalletCoreServiceError.generationFailed
        }

        let draft = try draft(
            from: wallet,
            passphrase: normalizedPassphrase
        )
        guard draft.words.count == 24 else {
            throw WalletCoreServiceError.generationFailed
        }
        return draft
    }

    static func restoreEVMWallet(
        mnemonic: String,
        passphrase: String = ""
    ) throws -> WalletCreationDraft {
        guard let validation = BIP39Mnemonic.validation(of: mnemonic) else {
            throw WalletCoreServiceError.invalidMnemonic
        }
        guard let wallet = BIP39Mnemonic.hdWallet(
            mnemonic: validation.normalizedPhrase,
            passphrase: passphrase
        ) else {
            throw WalletCoreServiceError.generationFailed
        }

        return try draft(from: wallet, passphrase: passphrase)
    }

    static func importRecoveryPhrase(
        _ mnemonic: String,
        passphrase: String = ""
    ) throws -> WalletImportDraft {
        let credential: WalletRecoveryCredential
        do {
            credential = try WalletRecoveryCredential(
                mnemonic: mnemonic,
                passphrase: passphrase
            )
        } catch {
            throw WalletCoreServiceError.invalidMnemonic
        }
        if credential.electrumKind != nil {
            let descriptor = try BitcoinHDDerivationService()
                .accountDescriptors(credential: credential)[0]
            let receiveAddress = try BitcoinHDDerivationService()
                .deriveAddress(
                    descriptor: descriptor,
                    branch: .external,
                    index: 0
                )
            return WalletImportDraft(
                secret: .recoveryPhrase(
                    mnemonic: credential.mnemonic,
                    passphrase: credential.passphrase,
                    wordCount: credential.wordCount
                ),
                address: receiveAddress.address,
                normalizedAddress: receiveAddress.address.lowercased(),
                derivationPath: receiveAddress.derivationPath,
                publicKey: receiveAddress.publicKey.hexString
            )
        }
        let restored = try restoreEVMWallet(
            mnemonic: credential.mnemonic,
            passphrase: credential.passphrase
        )
        return WalletImportDraft(
            secret: .recoveryPhrase(
                mnemonic: restored.mnemonic,
                passphrase: restored.passphrase,
                wordCount: restored.words.count
            ),
            address: restored.address,
            normalizedAddress: restored.normalizedAddress,
            derivationPath: restored.derivationPath,
            publicKey: restored.publicKey
        )
    }

    static func importPrivateKey(
        _ encodedPrivateKey: String
    ) throws -> WalletImportDraft {
        try PrivateKeyImportService.importKey(
            encodedPrivateKey,
            network: .evm
        )
    }

    static func importMuunRecovery(
        _ material: MuunRecoveryKeyMaterial
    ) throws -> WalletImportDraft {
        let validated = try material.validated()
        let address = try MuunRecoveryAddressFactory.derive(
            material: validated,
            version: .v5,
            branch: .external,
            addressIndex: 0
        )
        guard address.scriptPubKey.count == 34 else {
            throw WalletCoreServiceError.invalidAddress
        }
        return WalletImportDraft(
            secret: .muunRecovery(validated),
            address: address.address,
            normalizedAddress: address.address.lowercased(),
            derivationPath: MuunRecoveryKeyMaterial.accountMarker,
            publicKey: Data(address.scriptPubKey.dropFirst(2)).hexString
        )
    }

    static func isValidRecoveryPhrase(_ mnemonic: String) -> Bool {
        (try? WalletRecoveryCredential(mnemonic: mnemonic)) != nil
    }

    static func isValidPrivateKey(_ encodedPrivateKey: String) -> Bool {
        guard let data = normalizedPrivateKeyData(encodedPrivateKey) else {
            return false
        }
        return PrivateKey.isValid(data: data, curve: .secp256k1)
    }

    private static func normalizedPrivateKeyData(
        _ encodedPrivateKey: String
    ) -> Data? {
        var normalized = encodedPrivateKey.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if normalized.hasPrefix("0x") || normalized.hasPrefix("0X") {
            normalized.removeFirst(2)
        }
        guard normalized.utf8.count == 64,
              normalized.unicodeScalars.allSatisfy({ scalar in
                switch scalar.value {
                case 48...57, 65...70, 97...102:
                    true
                default:
                    false
                }
              }),
              let data = Data(hexString: normalized),
              data.count == 32
        else {
            return nil
        }
        return data
    }

    private static func draft(
        from wallet: HDWallet,
        passphrase: String
    ) throws -> WalletCreationDraft {
        guard let validation = BIP39Mnemonic.validation(
            of: wallet.mnemonic
        ) else {
            throw WalletCoreServiceError.invalidMnemonic
        }
        let mnemonic = validation.normalizedPhrase
        let words = mnemonic.split(separator: " ").map(String.init)

        let derivationPath = CoinType.ethereum.derivationPath()
        guard let privateKey = wallet.getKey(
            coin: .ethereum,
            derivationPath: derivationPath
        ) else {
            throw WalletCoreServiceError.invalidDerivationPath
        }
        let derivedAddress = CoinType.ethereum.deriveAddress(
            privateKey: privateKey
        )
        let defaultAddress = wallet.getAddressForCoin(coin: .ethereum)

        guard derivedAddress.caseInsensitiveCompare(defaultAddress) == .orderedSame else {
            throw WalletCoreServiceError.derivationMismatch
        }
        guard CoinType.ethereum.validate(address: derivedAddress) else {
            throw WalletCoreServiceError.invalidAddress
        }

        let publicKey = privateKey
            .getPublicKeySecp256k1(compressed: false)
            .description

        return WalletCreationDraft(
            mnemonic: mnemonic,
            passphrase: passphrase.decomposedStringWithCompatibilityMapping,
            words: words,
            address: derivedAddress,
            normalizedAddress: derivedAddress.lowercased(),
            derivationPath: derivationPath,
            publicKey: publicKey
        )
    }
}
