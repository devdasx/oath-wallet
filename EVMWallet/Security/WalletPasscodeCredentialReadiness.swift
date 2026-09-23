import Foundation
import GRDB
import Security

enum WalletPasscodeCredentialIssue: Equatable, Sendable {
    case missingSecurityRecord
    case credentialNotFound
    case invalidCredentialData
    case keychainTemporarilyUnavailable(OSStatus)
    case keychainAccessFailed(OSStatus)
    case persistenceVerificationFailed
    case databaseUnavailable
    case unexpected

    var diagnosticCode: String {
        switch self {
        case .missingSecurityRecord:
            "missing_security_record"
        case .credentialNotFound:
            "credential_not_found_in_current_keychain_access_group"
        case .invalidCredentialData:
            "invalid_credential_data"
        case let .keychainTemporarilyUnavailable(status):
            "keychain_temporarily_unavailable status=\(status)"
        case let .keychainAccessFailed(status):
            "keychain_access_failed status=\(status)"
        case .persistenceVerificationFailed:
            "keychain_persistence_verification_failed"
        case .databaseUnavailable:
            "security_database_unavailable"
        case .unexpected:
            "unexpected_security_error"
        }
    }

    var messageKey: String {
        switch self {
        case .keychainTemporarilyUnavailable:
            "security.authentication.unavailable"
        case .credentialNotFound, .missingSecurityRecord,
             .invalidCredentialData, .keychainAccessFailed,
             .persistenceVerificationFailed, .databaseUnavailable,
             .unexpected:
            "settings.security.load.error.message"
        }
    }

    static func classify(_ error: any Error) -> Self {
        if let readinessError =
            error as? WalletPasscodeCredentialReadinessError {
            return readinessError.issue
        }
        if let vaultError = error as? WalletSecretVaultError {
            switch vaultError {
            case .invalidReference:
                return .missingSecurityRecord
            case .itemNotFound:
                return .credentialNotFound
            case let .temporarilyUnavailable(status):
                return .keychainTemporarilyUnavailable(status)
            case let .unexpectedStatus(status):
                return .keychainAccessFailed(status)
            case .invalidStoredData:
                return .invalidCredentialData
            case .persistenceVerificationFailed:
                return .persistenceVerificationFailed
            case .referenceConflict:
                // A reference that resolves to different bytes is a failed
                // persistence invariant, not a missing or transient item.
                return .persistenceVerificationFailed
            }
        }
        if let persistenceError =
            error as? WalletCreationPersistenceError,
           case .missingSecret = persistenceError {
            return .missingSecurityRecord
        }
        if error is DecodingError {
            return .invalidCredentialData
        }
        return .unexpected
    }
}

enum WalletPasscodeCredentialReadiness: Equatable, Sendable {
    case protectionDisabled
    case available
    case unavailable(WalletPasscodeCredentialIssue)
}

struct WalletPasscodeCredentialReadinessError: Error, Sendable {
    let issue: WalletPasscodeCredentialIssue
}

extension WalletDatabase {
    func passcodeCredentialReadiness(
        vault: WalletSecretVault = .shared
    ) async throws -> WalletPasscodeCredentialReadiness {
        let reference = try await pool.read { database -> String? in
            guard let settings = try DBUserSettingsRecord.fetchOne(
                database,
                key: Self.defaultProfileID
            ) else {
                throw WalletPasscodeCredentialReadinessError(
                    issue: .databaseUnavailable
                )
            }
            guard settings.appLockEnabled else {
                return nil
            }
            return try DBProfileSecurityRecord.fetchOne(
                database,
                key: Self.defaultProfileID
            )?.passcodeKeychainReference
        }

        let settings = try await walletSecuritySettings()
        guard settings.appLockEnabled else {
            return .protectionDisabled
        }

        if let reference {
            do {
                let _: WalletPasscodeCredential =
                    try vault.validatedPasscodeCredential(
                        reference: reference,
                        decode: WalletPasscodeCredential.decodeStoredData
                    )
                return .available
            } catch {
                let issue = WalletPasscodeCredentialIssue.classify(error)
                switch issue {
                case .credentialNotFound, .invalidCredentialData:
                    return try await repairPasscodeCredentialReadiness(
                        expectedReference: reference,
                        originalIssue: issue,
                        vault: vault
                    )
                case .missingSecurityRecord,
                     .keychainTemporarilyUnavailable,
                     .keychainAccessFailed,
                     .persistenceVerificationFailed,
                     .databaseUnavailable,
                     .unexpected:
                    return .unavailable(issue)
                }
            }
        }

        return try await repairPasscodeCredentialReadiness(
            expectedReference: nil,
            originalIssue: .missingSecurityRecord,
            vault: vault
        )
    }

    private func repairPasscodeCredentialReadiness(
        expectedReference: String?,
        originalIssue: WalletPasscodeCredentialIssue,
        vault: WalletSecretVault
    ) async throws -> WalletPasscodeCredentialReadiness {
        let recoveredReference: String
        do {
            guard let reference =
                    try vault.recoverablePasscodeCredentialReference(
                        decode: WalletPasscodeCredential.decodeStoredData
                    ) else {
                return .unavailable(originalIssue)
            }
            recoveredReference = reference
        } catch {
            return .unavailable(
                WalletPasscodeCredentialIssue.classify(error)
            )
        }

        let didRepair = try await pool.write { database in
            guard let settings = try DBUserSettingsRecord.fetchOne(
                database,
                key: Self.defaultProfileID
            ), settings.appLockEnabled else {
                return false
            }
            let current = try DBProfileSecurityRecord.fetchOne(
                database,
                key: Self.defaultProfileID
            )
            guard current?.passcodeKeychainReference
                    == expectedReference else {
                return false
            }

            let now = Date().timeIntervalSince1970
            if var current {
                current.passcodeKeychainReference = recoveredReference
                current.updatedAt = now
                try current.update(database)
            } else {
                try DBProfileSecurityRecord(
                    profileID: Self.defaultProfileID,
                    passcodeKeychainReference: recoveredReference,
                    failedAttemptCount: 0,
                    lockedUntil: nil,
                    updatedAt: now
                ).insert(database)
            }
            return true
        }

        guard didRepair else {
            return .unavailable(.persistenceVerificationFailed)
        }

        do {
            let _: WalletPasscodeCredential =
                try vault.validatedPasscodeCredential(
                    reference: recoveredReference,
                    decode: WalletPasscodeCredential.decodeStoredData
                )
            return .available
        } catch {
            return .unavailable(
                WalletPasscodeCredentialIssue.classify(error)
            )
        }
    }
}
