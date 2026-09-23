import Foundation
import WalletCore

enum WalletRecoveryCredentialError: Error {
    case invalidMnemonic
    case unsupportedMnemonic
    case passphraseTooLong
    case invalidEncoding
    case unsupportedVersion
}

/// The complete BIP-39 input required to reproduce a recovery-phrase wallet.
///
/// Existing Keychain records contain only UTF-8 mnemonic text. `decode(_:)`
/// intentionally continues to accept that representation as an empty
/// passphrase, while all newly saved records use the versioned envelope.
struct WalletRecoveryCredential: Equatable, Sendable {
    enum Scheme: String, Codable, Sendable {
        case bip39
        case electrumStandard
        case electrumSegwit
    }

    static let maximumPassphraseUTF8Count = 4_096

    let mnemonic: String
    let passphrase: String
    let scheme: Scheme

    var electrumKind: ElectrumSeedKind? {
        switch scheme {
        case .bip39: nil
        case .electrumStandard: .standard
        case .electrumSegwit: .segwit
        }
    }

    var hasPassphrase: Bool {
        !passphrase.isEmpty
    }

    var wordCount: Int {
        mnemonic.split(separator: " ").count
    }

    init(
        mnemonic: String,
        passphrase: String = ""
    ) throws {
        let normalizedPassphrase = passphrase
            .decomposedStringWithCompatibilityMapping
        guard normalizedPassphrase.utf8.count
                <= Self.maximumPassphraseUTF8Count else {
            throw WalletRecoveryCredentialError.passphraseTooLong
        }
        self.passphrase = normalizedPassphrase
        if let validation = BIP39Mnemonic.validation(of: mnemonic) {
            self.mnemonic = validation.normalizedPhrase
            scheme = .bip39
        } else if let electrumKind = ElectrumSeed.kind(of: mnemonic) {
            self.mnemonic = ElectrumSeed.normalized(mnemonic)
            switch electrumKind {
            case .standard: scheme = .electrumStandard
            case .segwit: scheme = .electrumSegwit
            }
        } else if ElectrumSeed.validatesAsUnsupportedTwoFactor(mnemonic) {
            throw WalletRecoveryCredentialError.unsupportedMnemonic
        } else {
            throw WalletRecoveryCredentialError.invalidMnemonic
        }
    }

    private init(
        mnemonic: String,
        passphrase: String,
        scheme: Scheme
    ) throws {
        try self.init(mnemonic: mnemonic, passphrase: passphrase)
        guard self.scheme == scheme else {
            throw WalletRecoveryCredentialError.invalidMnemonic
        }
    }

    func makeHDWallet() -> HDWallet? {
        guard scheme == .bip39 else { return nil }
        return BIP39Mnemonic.hdWallet(
            mnemonic: mnemonic,
            passphrase: passphrase
        )
    }

    func encodedData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            return try encoder.encode(
                StorageEnvelope(
                    format: StorageEnvelope.expectedFormat,
                    version: StorageEnvelope.currentVersion,
                    mnemonic: mnemonic,
                    passphrase: passphrase,
                    scheme: scheme
                )
            )
        } catch {
            throw WalletRecoveryCredentialError.invalidEncoding
        }
    }

    static func decode(_ data: Data) throws -> Self {
        let decoder = JSONDecoder()
        if let envelope = try? decoder.decode(
            StorageEnvelope.self,
            from: data
        ) {
            guard envelope.format == StorageEnvelope.expectedFormat,
                  [1, StorageEnvelope.currentVersion].contains(
                    envelope.version
                  ) else {
                throw WalletRecoveryCredentialError.unsupportedVersion
            }
            return try Self(
                mnemonic: envelope.mnemonic,
                passphrase: envelope.passphrase,
                scheme: envelope.scheme ?? .bip39
            )
        }

        guard let legacyMnemonic = String(data: data, encoding: .utf8)
        else {
            throw WalletRecoveryCredentialError.invalidEncoding
        }
        return try Self(mnemonic: legacyMnemonic)
    }
}

private extension WalletRecoveryCredential {
    struct StorageEnvelope: Codable {
        static let expectedFormat = "aperture.wallet.recovery-credential"
        static let currentVersion = 2

        let format: String
        let version: Int
        let mnemonic: String
        let passphrase: String
        let scheme: Scheme?
    }
}
