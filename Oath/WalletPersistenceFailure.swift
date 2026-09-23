import Foundation
import GRDB
import Security

enum WalletPersistenceOperation: String, Sendable {
    case create
    case importWallet = "import"
}

struct WalletPersistenceFailure: Hashable, Sendable {
    let messageKey: String
    let diagnosticCode: String

    init(error: any Error) {
        let resolution = WalletPersistenceErrorResolver.resolution(for: error)
        messageKey = resolution.messageKey
        diagnosticCode = resolution.diagnosticCode
    }

    var supportURL: URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = WalletSupport.emailAddress
        components.queryItems = [
            URLQueryItem(
                name: "subject",
                value: WalletLocalization.string(
                    "wallet.persistence.support.subject"
                )
            ),
            URLQueryItem(
                name: "body",
                value: EnglishNumbers.localized(
                    "wallet.persistence.support.body",
                    diagnosticCode
                )
            )
        ]
        return components.url
    }
}

enum WalletSupport {
    static let emailAddress = "care@oathwallet.org"
}

enum WalletPersistenceErrorResolver {
    struct Resolution: Equatable, Sendable {
        let messageKey: String
        let diagnosticCode: String
    }


    static func resolution(for error: any Error) -> Resolution {
        if let error = error as? WalletCreationPersistenceError {
            return resolution(for: error)
        }
        if let error = error as? WalletSecretVaultError {
            return resolution(for: error)
        }
        if let error = error as? WalletSecurityPersistenceError {
            return resolution(for: error)
        }
        if let error = error as? DatabaseError {
            return resolution(for: error)
        }
        if let error = error as? CocoaError {
            return resolution(for: error)
        }
        return Resolution(
            messageKey: "wallet.persistence.error.unexpected",
            diagnosticCode:
                "unexpected_\(sanitizedTypeName(type(of: error)))"
        )
    }

    private static func resolution(
        for error: WalletCreationPersistenceError
    ) -> Resolution {
        switch error {
        case .invalidDraft:
            Resolution(
                messageKey: "wallet.persistence.error.invalid_data",
                diagnosticCode: "wallet_data_validation_failed"
            )
        case .invalidPasscode:
            Resolution(
                messageKey: "wallet.persistence.error.passcode_mismatch",
                diagnosticCode: "profile_passcode_mismatch"
            )
        case .passcodeDerivationFailed:
            Resolution(
                messageKey: "wallet.persistence.error.passcode_protection",
                diagnosticCode: "passcode_derivation_failed"
            )
        case let .randomGenerationFailed(status):
            Resolution(
                messageKey: "wallet.persistence.error.secure_random",
                diagnosticCode: "secure_random_status_\(status)"
            )
        case .missingSecret:
            Resolution(
                messageKey: "wallet.persistence.error.missing_security",
                diagnosticCode: "required_security_record_missing"
            )
        }
    }

    private static func resolution(
        for error: WalletSecretVaultError
    ) -> Resolution {
        switch error {
        case .invalidReference:
            Resolution(
                messageKey: "wallet.persistence.error.secure_storage",
                diagnosticCode: "keychain_invalid_reference"
            )
        case .itemNotFound:
            Resolution(
                messageKey: "wallet.persistence.error.secure_item_missing",
                diagnosticCode: "keychain_item_not_found"
            )
        case let .temporarilyUnavailable(status):
            keychainStatusResolution(status)
        case let .unexpectedStatus(status):
            keychainStatusResolution(status)
        case .invalidStoredData:
            Resolution(
                messageKey: "wallet.persistence.error.secure_storage_data",
                diagnosticCode: "keychain_invalid_stored_data"
            )
        case .persistenceVerificationFailed:
            Resolution(
                messageKey: "wallet.persistence.error.secure_storage_data",
                diagnosticCode: "keychain_verification_failed"
            )
        case .referenceConflict:
            Resolution(
                messageKey: "wallet.persistence.error.secure_storage_data",
                diagnosticCode: "keychain_reference_conflict"
            )
        }
    }

    private static func keychainStatusResolution(
        _ status: OSStatus
    ) -> Resolution {
        switch status {
        case errSecInteractionNotAllowed:
            Resolution(
                messageKey: "wallet.persistence.error.secure_storage_locked",
                diagnosticCode: "keychain_locked_\(status)"
            )
        case errSecNotAvailable:
            Resolution(
                messageKey:
                    "wallet.persistence.error.secure_storage_unavailable",
                diagnosticCode: "keychain_unavailable_\(status)"
            )
        case errSecMissingEntitlement:
            Resolution(
                messageKey:
                    "wallet.persistence.error.secure_storage_entitlement",
                diagnosticCode: "keychain_missing_entitlement_\(status)"
            )
        default:
            Resolution(
                messageKey: "wallet.persistence.error.secure_storage",
                diagnosticCode: "keychain_status_\(status)"
            )
        }
    }

    private static func resolution(
        for error: WalletSecurityPersistenceError
    ) -> Resolution {
        switch error {
        case .missingSettings:
            Resolution(
                messageKey: "wallet.persistence.error.settings_missing",
                diagnosticCode: "profile_settings_missing"
            )
        case .appLockAlreadyEnabled:
            Resolution(
                messageKey: "wallet.persistence.error.settings_conflict",
                diagnosticCode: "profile_security_conflict"
            )
        }
    }

    private static func resolution(for error: DatabaseError) -> Resolution {
        let code = error.extendedResultCode.rawValue
        switch error.resultCode {
        case .SQLITE_FULL:
            return Resolution(
                messageKey: "wallet.persistence.error.storage_full",
                diagnosticCode: "sqlite_full_\(code)"
            )
        case .SQLITE_BUSY, .SQLITE_LOCKED:
            return Resolution(
                messageKey: "wallet.persistence.error.database_busy",
                diagnosticCode: "sqlite_busy_\(code)"
            )
        case .SQLITE_READONLY, .SQLITE_PERM, .SQLITE_CANTOPEN,
             .SQLITE_IOERR:
            return Resolution(
                messageKey: "wallet.persistence.error.database_write",
                diagnosticCode: "sqlite_write_\(code)"
            )
        case .SQLITE_CORRUPT, .SQLITE_NOTADB:
            return Resolution(
                messageKey: "wallet.persistence.error.database_integrity",
                diagnosticCode: "sqlite_integrity_\(code)"
            )
        case .SQLITE_CONSTRAINT:
            return Resolution(
                messageKey: "wallet.persistence.error.database_constraint",
                diagnosticCode: "sqlite_constraint_\(code)"
            )
        default:
            return Resolution(
                messageKey: "wallet.persistence.error.database",
                diagnosticCode: "sqlite_\(code)"
            )
        }
    }

    private static func resolution(for error: CocoaError) -> Resolution {
        switch error.code {
        case .fileWriteOutOfSpace:
            Resolution(
                messageKey: "wallet.persistence.error.storage_full",
                diagnosticCode: "cocoa_storage_full_\(error.errorCode)"
            )
        case .fileWriteNoPermission, .fileWriteVolumeReadOnly,
             .fileWriteUnknown:
            Resolution(
                messageKey: "wallet.persistence.error.database_write",
                diagnosticCode: "cocoa_write_\(error.errorCode)"
            )
        default:
            Resolution(
                messageKey: "wallet.persistence.error.unexpected",
                diagnosticCode: "cocoa_\(error.errorCode)"
            )
        }
    }

    private static func sanitizedTypeName(_ type: Any.Type) -> String {
        String(reflecting: type)
            .lowercased()
            .map { character in
                character.isLetter || character.isNumber
                    ? character
                    : "_"
            }
            .reduce(into: "") { result, character in
                if character != "_" || result.last != "_" {
                    result.append(character)
                }
            }
            .prefix(80)
            .description
    }

}
