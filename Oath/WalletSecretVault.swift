import Foundation
import Security

enum WalletSecretKind: String, Sendable {
    case recoveryPhrase
    case privateKey
    case muunRecovery
    case bitcoinImportedWallet
    case bitcoinHDChildKeyCache
    case bitcoinSilentPaymentAccount
    case bitcoinSilentPaymentOutput
    case passcodeVerifier
    case databaseEncryptionKey
    case cloudBackupDataKey
}

enum WalletSecretVaultError: Error {
    case invalidReference
    case itemNotFound
    case temporarilyUnavailable(OSStatus)
    case unexpectedStatus(OSStatus)
    case invalidStoredData
    case persistenceVerificationFailed
    case referenceConflict

    var diagnosticDescription: String {
        switch self {
        case .invalidReference:
            return "invalid_reference"
        case .itemNotFound:
            return "item_not_found"
        case let .temporarilyUnavailable(status):
            return "temporarily_unavailable keychain_status=\(status)"
        case let .unexpectedStatus(status):
            return "unexpected_keychain_status=\(status)"
        case .invalidStoredData:
            return "invalid_stored_data"
        case .persistenceVerificationFailed:
            return "persistence_verification_failed"
        case .referenceConflict:
            return "reference_conflict"
        }
    }
}

final class WalletSecretVault: @unchecked Sendable {
    static let shared = WalletSecretVault()
    // Preserve this historical Keychain service label across bundle changes.
    // Existing recovery phrases and private keys depend on its stability.
    static let keychainService = "com.codex.prototype.evmwallet.secrets"

    private let service: String
    private let passcodeBackupSuffix = ".passcode-verifier-backup"
    private let passcodeBackupMarker = ".passcode-verifier-backup"
    private let transientReadAttemptCount = 3
    private let transientReadDelay: TimeInterval = 0.04

    init(service: String = keychainService) {
        precondition(!service.isEmpty)
        self.service = service
    }

    func store(
        _ data: Data,
        kind: WalletSecretKind,
        reference: String = UUID().uuidString.lowercased()
    ) throws -> String {
        guard !reference.isEmpty else {
            throw WalletSecretVaultError.invalidReference
        }

        _ = try storeNewOrMatching(data, kind: kind, reference: reference)
        return reference
    }

    func replace(
        _ data: Data,
        kind: WalletSecretKind,
        reference: String
    ) throws {
        try replaceVerified(
            data,
            kind: kind,
            reference: reference
        )
    }

    private enum StoreOutcome: Equatable {
        case created
        case matchedExisting
    }

    private func storeNewOrMatching(
        _ data: Data,
        kind: WalletSecretKind,
        reference: String
    ) throws -> StoreOutcome {
        guard !reference.isEmpty else {
            throw WalletSecretVaultError.invalidReference
        }
        let query = WalletKeychainConfiguration.scopedQuery([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference,
            kSecAttrLabel as String: kind.rawValue,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecAttrAccessible as String:
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: data
        ])
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            guard try self.data(reference: reference) == data else {
                throw WalletSecretVaultError.referenceConflict
            }
            return .matchedExisting
        }
        guard status == errSecSuccess else {
            throw WalletSecretVaultError.unexpectedStatus(status)
        }
        guard try self.data(reference: reference) == data else {
            throw WalletSecretVaultError.persistenceVerificationFailed
        }
        return .created
    }

    func data(reference: String) throws -> Data {
        guard !reference.isEmpty else {
            throw WalletSecretVaultError.invalidReference
        }

        let query = WalletKeychainConfiguration.scopedQuery([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecReturnData as String: kCFBooleanTrue as Any,
            kSecMatchLimit as String: kSecMatchLimitOne
        ])

        for attempt in 0..<transientReadAttemptCount {
            var result: CFTypeRef?
            let status = SecItemCopyMatching(
                query as CFDictionary,
                &result
            )
            switch status {
            case errSecSuccess:
                guard let data = result as? Data else {
                    throw WalletSecretVaultError.invalidStoredData
                }
                return data
            case errSecItemNotFound:
                throw WalletSecretVaultError.itemNotFound
            case errSecInteractionNotAllowed, errSecNotAvailable:
                guard attempt + 1 < transientReadAttemptCount else {
                    throw WalletSecretVaultError.temporarilyUnavailable(
                        status
                    )
                }
                Thread.sleep(
                    forTimeInterval:
                        transientReadDelay * Double(attempt + 1)
                )
            case errSecDecode:
                throw WalletSecretVaultError.invalidStoredData
            default:
                throw WalletSecretVaultError.unexpectedStatus(status)
            }
        }

        throw WalletSecretVaultError.temporarilyUnavailable(
            errSecNotAvailable
        )
    }

    func storePasscodeCredential(
        _ data: Data,
        reference: String = UUID().uuidString.lowercased()
    ) throws -> String {
        let backupReference = try passcodeBackupReference(
            for: reference
        )
        var createdReferences: [String] = []
        do {
            if try storeNewOrMatching(
                data,
                kind: .passcodeVerifier,
                reference: reference
            ) == .created {
                createdReferences.append(reference)
            }
            if try storeNewOrMatching(
                data,
                kind: .passcodeVerifier,
                reference: backupReference
            ) == .created {
                createdReferences.append(backupReference)
            }
            try? removeSupersededPasscodeBackups(
                reference: reference
            )
            return reference
        } catch {
            for createdReference in createdReferences {
                try? deleteIfPresent(reference: createdReference)
            }
            throw error
        }
    }

    func validatedPasscodeCredential<Value>(
        reference: String,
        decode: (Data) throws -> Value
    ) throws -> Value {
        let primaryData: Data
        do {
            primaryData = try data(reference: reference)
        } catch WalletSecretVaultError.itemNotFound {
            return try recoverPasscodeCredential(
                reference: reference,
                decode: decode
            )
        } catch WalletSecretVaultError.invalidStoredData {
            return try recoverPasscodeCredential(
                reference: reference,
                decode: decode
            )
        }

        do {
            let credential = try decode(primaryData)
            try? ensurePasscodeBackup(
                primaryData,
                reference: reference
            )
            return credential
        } catch {
            return try recoverPasscodeCredential(
                reference: reference,
                decode: decode
            )
        }
    }

    /// Finds an existing app-lock verifier when the database reference was
    /// lost or became stale. The verifier never leaves Keychain: this only
    /// rebuilds the primary/backup aliases and returns the repaired account
    /// reference for the database to persist.
    func recoverablePasscodeCredentialReference<Value>(
        decode: (Data) throws -> Value
    ) throws -> String? {
        let items = try passcodeCredentialItems()
        var validItemsByData: [Data: [PasscodeCredentialItem]] = [:]

        for item in items {
            do {
                _ = try decode(item.data)
                validItemsByData[item.data, default: []].append(item)
            } catch {
                continue
            }
        }

        guard !validItemsByData.isEmpty else {
            guard !items.isEmpty else { return nil }
            throw WalletSecretVaultError.invalidStoredData
        }

        let groups = validItemsByData.map { data, items in
            PasscodeCredentialGroup(
                data: data,
                items: items,
                latestModificationDate:
                    items.map(\.modificationDate).max()
                    ?? .distantPast
            )
        }.sorted { lhs, rhs in
            if lhs.latestModificationDate
                != rhs.latestModificationDate {
                return lhs.latestModificationDate
                    > rhs.latestModificationDate
            }
            return lhs.preferredReference < rhs.preferredReference
        }

        guard let selected = groups.first else { return nil }
        if groups.count > 1,
           groups[1].latestModificationDate
            == selected.latestModificationDate {
            // Two equally current but different credentials cannot be
            // selected without guessing which passcode the user chose.
            throw WalletSecretVaultError.invalidStoredData
        }

        let reference = primaryPasscodeReference(
            for: selected.preferredReference
        )
        try replaceVerified(
            selected.data,
            kind: .passcodeVerifier,
            reference: reference
        )
        try ensurePasscodeBackup(
            selected.data,
            reference: reference
        )
        return reference
    }

    func deletePasscodeCredential(reference: String) throws {
        let backupReference = try passcodeBackupReference(
            for: reference
        )
        var firstError: (any Error)?
        var candidates = [reference, backupReference]

        do {
            candidates.append(
                contentsOf: try passcodeBackupReferences(
                    for: reference
                )
            )
        } catch {
            firstError = error
        }

        for candidate in Set(candidates) {
            do {
                try deleteIfPresent(reference: candidate)
            } catch {
                if firstError == nil {
                    firstError = error
                }
            }
        }

        if let firstError {
            throw firstError
        }
    }

    func delete(reference: String) throws {
        try delete(reference: reference, ignoresMissingItem: false)
    }

    func deleteIfPresent(reference: String) throws {
        try delete(reference: reference, ignoresMissingItem: true)
    }

    func deleteAll() throws {
        let query = WalletKeychainConfiguration.scopedQuery([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ])
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw WalletSecretVaultError.unexpectedStatus(status)
        }

        var verificationQuery = query
        verificationQuery[kSecReturnAttributes as String] =
            kCFBooleanTrue as Any
        verificationQuery[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let verificationStatus = SecItemCopyMatching(
            verificationQuery as CFDictionary,
            &result
        )
        guard verificationStatus == errSecItemNotFound else {
            throw WalletSecretVaultError.unexpectedStatus(
                verificationStatus
            )
        }
    }

    func allReferences() throws -> [String] {
        let query = WalletKeychainConfiguration.scopedQuery([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnAttributes as String: kCFBooleanTrue as Any,
            kSecMatchLimit as String: kSecMatchLimitAll
        ])
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            let attributes: [[String: Any]]
            if let values = result as? [[String: Any]] {
                attributes = values
            } else if let value = result as? [String: Any] {
                attributes = [value]
            } else {
                throw WalletSecretVaultError.invalidStoredData
            }
            let references = try attributes.map { attributes in
                guard let reference =
                    attributes[kSecAttrAccount as String] as? String,
                    !reference.isEmpty
                else {
                    throw WalletSecretVaultError.invalidStoredData
                }
                return reference
            }
            return Array(Set(references)).sorted()
        case errSecItemNotFound:
            return []
        case errSecInteractionNotAllowed, errSecNotAvailable:
            throw WalletSecretVaultError.temporarilyUnavailable(status)
        case errSecDecode:
            throw WalletSecretVaultError.invalidStoredData
        default:
            throw WalletSecretVaultError.unexpectedStatus(status)
        }
    }

    private func delete(
        reference: String,
        ignoresMissingItem: Bool
    ) throws {
        let query = WalletKeychainConfiguration.scopedQuery([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ])
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess
                || (ignoresMissingItem && status == errSecItemNotFound)
        else {
            throw WalletSecretVaultError.unexpectedStatus(status)
        }

        var verificationQuery = query
        verificationQuery[kSecReturnAttributes as String] =
            kCFBooleanTrue as Any
        verificationQuery[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let verificationStatus = SecItemCopyMatching(
            verificationQuery as CFDictionary,
            &result
        )
        guard verificationStatus == errSecItemNotFound else {
            throw WalletSecretVaultError.unexpectedStatus(
                verificationStatus
            )
        }
    }

    private func passcodeBackupReference(
        for reference: String
    ) throws -> String {
        guard !reference.isEmpty else {
            throw WalletSecretVaultError.invalidReference
        }
        return reference + passcodeBackupSuffix
    }

    private struct PasscodeCredentialItem {
        let reference: String
        let data: Data
        let modificationDate: Date
    }

    private struct PasscodeCredentialGroup {
        let data: Data
        let items: [PasscodeCredentialItem]
        let latestModificationDate: Date

        var preferredReference: String {
            items.sorted { lhs, rhs in
                let lhsIsBackup = lhs.reference.contains(
                    ".passcode-verifier-backup"
                )
                let rhsIsBackup = rhs.reference.contains(
                    ".passcode-verifier-backup"
                )
                if lhsIsBackup != rhsIsBackup {
                    return !lhsIsBackup
                }
                if lhs.modificationDate != rhs.modificationDate {
                    return lhs.modificationDate > rhs.modificationDate
                }
                return lhs.reference < rhs.reference
            }.first?.reference ?? ""
        }
    }

    private func passcodeCredentialItems() throws
        -> [PasscodeCredentialItem] {
        let query = WalletKeychainConfiguration.scopedQuery([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrLabel as String:
                WalletSecretKind.passcodeVerifier.rawValue,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnAttributes as String: kCFBooleanTrue as Any,
            kSecReturnData as String: kCFBooleanTrue as Any,
            kSecMatchLimit as String: kSecMatchLimitAll
        ])
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            let attributes: [[String: Any]]
            if let values = result as? [[String: Any]] {
                attributes = values
            } else if let value = result as? [String: Any] {
                attributes = [value]
            } else {
                throw WalletSecretVaultError.invalidStoredData
            }
            return try attributes.map { attributes in
                guard let reference =
                        attributes[kSecAttrAccount as String] as? String,
                      !reference.isEmpty,
                      let data =
                        attributes[kSecValueData as String] as? Data else {
                    throw WalletSecretVaultError.invalidStoredData
                }
                return PasscodeCredentialItem(
                    reference: reference,
                    data: data,
                    modificationDate:
                        attributes[
                            kSecAttrModificationDate as String
                        ] as? Date ?? .distantPast
                )
            }
        case errSecItemNotFound:
            return []
        case errSecInteractionNotAllowed, errSecNotAvailable:
            throw WalletSecretVaultError.temporarilyUnavailable(status)
        case errSecDecode:
            throw WalletSecretVaultError.invalidStoredData
        default:
            throw WalletSecretVaultError.unexpectedStatus(status)
        }
    }

    private func primaryPasscodeReference(
        for reference: String
    ) -> String {
        guard let markerRange = reference.range(
            of: passcodeBackupMarker,
            options: .backwards
        ), markerRange.lowerBound != reference.startIndex else {
            return reference
        }
        return String(reference[..<markerRange.lowerBound])
    }

    private func diagnosticCode(for error: any Error) -> String {
        if let vaultError = error as? WalletSecretVaultError {
            return vaultError.diagnosticDescription
        }
        return String(reflecting: type(of: error))
    }

    private func ensurePasscodeBackup(
        _ primaryData: Data,
        reference: String
    ) throws {
        defer {
            try? removeSupersededPasscodeBackups(
                reference: reference
            )
        }
        let backupReference = try passcodeBackupReference(
            for: reference
        )
        do {
            let backupData = try data(reference: backupReference)
            guard backupData != primaryData else { return }
            try replaceVerified(
                primaryData,
                kind: .passcodeVerifier,
                reference: backupReference
            )
            return
        } catch WalletSecretVaultError.itemNotFound {
            // The backup is created below.
        } catch WalletSecretVaultError.invalidStoredData {
            try replaceVerified(
                primaryData,
                kind: .passcodeVerifier,
                reference: backupReference
            )
            return
        }
        _ = try store(
            primaryData,
            kind: .passcodeVerifier,
            reference: backupReference
        )
    }

    private func recoverPasscodeCredential<Value>(
        reference: String,
        decode: (Data) throws -> Value
    ) throws -> Value {
        let backupReference = try passcodeBackupReference(
            for: reference
        )
        let currentFailure: any Error
        do {
            let backupData = try data(reference: backupReference)
            let credential = try decode(backupData)
            try? replaceVerified(
                backupData,
                kind: .passcodeVerifier,
                reference: reference
            )
            try? removeSupersededPasscodeBackups(
                reference: reference
            )
            return credential
        } catch {
            currentFailure = error
        }

        let supersededReferences = try passcodeBackupReferences(
            for: reference
        ).filter { $0 != backupReference }
        var lastFailure = currentFailure
        for candidate in supersededReferences {
            do {
                let backupData = try data(reference: candidate)
                let credential = try decode(backupData)
                try? replaceVerified(
                    backupData,
                    kind: .passcodeVerifier,
                    reference: reference
                )
                try? ensurePasscodeBackup(
                    backupData,
                    reference: reference
                )
                return credential
            } catch {
                lastFailure = error
            }
        }
        throw lastFailure
    }

    private func passcodeBackupReferences(
        for reference: String
    ) throws -> [String] {
        let prefix = try passcodeBackupReference(for: reference)
        return try allReferences().filter { candidate in
            candidate.hasPrefix(prefix)
        }
    }

    private func removeSupersededPasscodeBackups(
        reference: String
    ) throws {
        let currentReference = try passcodeBackupReference(
            for: reference
        )
        var firstError: (any Error)?
        for candidate in try passcodeBackupReferences(
            for: reference
        ) where candidate != currentReference {
            do {
                try deleteIfPresent(reference: candidate)
            } catch {
                if firstError == nil {
                    firstError = error
                }
            }
        }
        if let firstError {
            throw firstError
        }
    }

    private func replaceVerified(
        _ data: Data,
        kind: WalletSecretKind,
        reference: String
    ) throws {
        guard !reference.isEmpty else {
            throw WalletSecretVaultError.invalidReference
        }
        let query = WalletKeychainConfiguration.scopedQuery([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ])
        let attributes: [String: Any] = [
            kSecAttrLabel as String: kind.rawValue,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecAttrAccessible as String:
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: data
        ]
        let status = SecItemUpdate(
            query as CFDictionary,
            attributes as CFDictionary
        )
        if status == errSecItemNotFound {
            _ = try storeNewOrMatching(
                data,
                kind: kind,
                reference: reference
            )
            return
        }
        guard status == errSecSuccess else {
            throw WalletSecretVaultError.unexpectedStatus(status)
        }
        guard try self.data(reference: reference) == data else {
            throw WalletSecretVaultError.persistenceVerificationFailed
        }
    }
}

extension WalletSecretVault: WalletSecureCleanupVault {}
