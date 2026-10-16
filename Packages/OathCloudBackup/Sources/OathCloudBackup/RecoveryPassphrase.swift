import Foundation

public enum RecoveryPassphraseError: Error, Equatable, Sendable {
    case empty, tooLong, unsupportedCharacter
}

/// BIP-39 uses UTF-8 NFKD. Case and whitespace are significant. Wallet Core
/// 4.8.4's mnemonic_to_seed uses a 256-byte C buffer: reject, never truncate.
/// This is shared by local creation, key derivation and portable backups.
public enum RecoveryPassphrase {
    /// Compatibility only: retain old wallet input exactly (including its old
    /// Wallet Core behavior). Never use this for creating new passphrase wallets.
    public static func normalizedLegacy(_ input: String) throws -> String {
        guard input.utf8.count <= 16_384 else { throw RecoveryPassphraseError.tooLong }
        let value = input.decomposedStringWithCompatibilityMapping
        guard value.utf8.count <= 4_096 else { throw RecoveryPassphraseError.tooLong }
        return value
    }

    public static func normalized(_ input: String) throws -> String {
        guard !input.isEmpty else { throw RecoveryPassphraseError.empty }
        guard input.utf8.count <= 16_384 else { throw RecoveryPassphraseError.tooLong }
        let value = input.decomposedStringWithCompatibilityMapping
        guard value.utf8.count <= 256 else { throw RecoveryPassphraseError.tooLong }
        guard !value.utf8.contains(0) else { throw RecoveryPassphraseError.unsupportedCharacter }
        return value
    }
}
