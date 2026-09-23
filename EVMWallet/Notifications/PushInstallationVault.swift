import Foundation
import Security

enum PushInstallationVaultError: Error {
    case invalidStoredValue
    case randomGenerationFailed(OSStatus)
    case keychainFailure(OSStatus)

    var diagnosticCode: String {
        switch self {
        case .invalidStoredValue:
            "invalid_stored_value"
        case let .randomGenerationFailed(status):
            "random_generation_failed_\(status)"
        case let .keychainFailure(status):
            "keychain_failure_\(status)"
        }
    }
}

private struct PushResetCredentialEnvelope: Decodable {
    let installationID: String
    let credential: Data
}

final class PushInstallationVault: @unchecked Sendable {
    static let shared = PushInstallationVault()

    // This is a stable Keychain service label, not the current bundle ID.
    // Renaming it would orphan existing installation credentials and tokens.
    static let keychainService =
        "com.codex.prototype.evmwallet.push-installation"
    private let service: String
    private let identityAccount = "current-installation-v1"
    private let tombstonesAccount = "deactivation-tombstones-v1"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(service: String = keychainService) {
        self.service = service
        encoder.dateEncodingStrategy = .millisecondsSince1970
        decoder.dateDecodingStrategy = .millisecondsSince1970
    }

    func loadOrCreateIdentity() throws -> PushInstallationIdentity {
        if let data = try read(account: identityAccount) {
            guard let identity = try? decoder.decode(
                PushInstallationIdentity.self,
                from: data
            ), UUID(uuidString: identity.installationID) != nil,
            identity.credential.count == 32,
            Self.isValidRemoteUserID(identity.remoteUserID) else {
                throw PushInstallationVaultError.invalidStoredValue
            }
            return identity
        }

        let identity = PushInstallationIdentity(
            installationID: UUID().uuidString.lowercased(),
            credential: try randomData(count: 32),
            apnsToken: nil,
            remoteUserID: UUID().uuidString.lowercased()
        )
        try write(
            try encoder.encode(identity),
            account: identityAccount
        )
        return identity
    }

    func storeAPNSToken(
        _ token: Data,
        topic: String,
        environment: String
    ) throws -> PushInstallationIdentity {
        guard !token.isEmpty,
              !topic.isEmpty,
              environment == "sandbox" || environment == "production"
        else {
            throw PushInstallationVaultError.invalidStoredValue
        }
        var identity = try loadOrCreateIdentity()
        identity.apnsToken = token
        identity.apnsTopic = topic
        identity.apnsEnvironment = environment
        try write(
            try encoder.encode(identity),
            account: identityAccount
        )
        return identity
    }

    @discardableResult
    func prepareAPNSContext(
        topic: String,
        environment: String
    ) throws -> PushInstallationIdentity {
        guard !topic.isEmpty,
              environment == "sandbox" || environment == "production"
        else {
            throw PushInstallationVaultError.invalidStoredValue
        }
        var identity = try loadOrCreateIdentity()
        if identity.bindAPNSContext(
            topic: topic,
            environment: environment
        ) {
            try write(
                try encoder.encode(identity),
                account: identityAccount
            )
        }
        return identity
    }

    func rotateIdentityPreservingAPNSToken() throws
        -> PushInstallationIdentity {
        let current = try loadOrCreateIdentity()
        let replacement = PushInstallationIdentity(
            installationID: UUID().uuidString.lowercased(),
            credential: try randomData(count: 32),
            apnsToken: current.apnsToken,
            remoteUserID: UUID().uuidString.lowercased(),
            apnsTopic: current.apnsTopic,
            apnsEnvironment: current.apnsEnvironment
        )
        try write(
            try encoder.encode(replacement),
            account: identityAccount
        )
        return replacement
    }

    func currentIdentity() throws -> PushInstallationIdentity? {
        guard let data = try read(account: identityAccount) else {
            return nil
        }
        guard let identity = try? decoder.decode(
            PushInstallationIdentity.self,
            from: data
        ), UUID(uuidString: identity.installationID) != nil,
        identity.credential.count == 32,
        Self.isValidRemoteUserID(identity.remoteUserID) else {
            throw PushInstallationVaultError.invalidStoredValue
        }
        return identity
    }

    func assignRemoteUserID(
        _ remoteUserID: String
    ) throws -> PushInstallationIdentity {
        guard UUID(uuidString: remoteUserID) != nil else {
            throw PushInstallationVaultError.invalidStoredValue
        }
        var identity = try loadOrCreateIdentity()
        identity.remoteUserID = remoteUserID.lowercased()
        try write(
            try encoder.encode(identity),
            account: identityAccount
        )
        return identity
    }

    func replaceCurrentWithTombstone() throws {
        guard let identity = try currentIdentity() else { return }
        var tombstones = try deactivationTombstones()
        tombstones.removeAll {
            $0.installationID == identity.installationID
        }
        tombstones.append(
            PushDeactivationTombstone(
                installationID: identity.installationID,
                credential: identity.credential,
                createdAt: Date()
            )
        )
        try write(
            try encoder.encode(tombstones),
            account: tombstonesAccount
        )
        try delete(account: identityAccount)
    }

    func resetCleanupReadiness() throws -> Bool {
        let tombstones = try deactivationTombstones()
        guard let identityData = try read(account: identityAccount) else {
            return !tombstones.isEmpty
        }
        _ = try resetTombstone(from: identityData)
        return true
    }

    func prepareCurrentIdentityForReset() throws {
        guard let identityData = try read(account: identityAccount) else {
            return
        }
        let currentTombstone = try resetTombstone(from: identityData)
        var tombstones = try deactivationTombstones()
        tombstones.removeAll {
            $0.installationID == currentTombstone.installationID
        }
        tombstones.append(currentTombstone)

        // The tombstone is written and verified by Keychain before the
        // current identity is removed. A crash or deletion failure can
        // therefore only leave duplicate retryable material, never erase
        // the sole credential needed for server deactivation.
        try write(
            try encoder.encode(tombstones),
            account: tombstonesAccount
        )
        try delete(account: identityAccount)
    }

    func deleteAllResetState() throws {
        try delete(account: identityAccount)
        try delete(account: tombstonesAccount)
        guard try read(account: identityAccount) == nil,
              try read(account: tombstonesAccount) == nil else {
            throw PushInstallationVaultError.invalidStoredValue
        }
    }

    func deleteCurrentIdentity() throws {
        try delete(account: identityAccount)
    }

    func deleteCurrentIdentity(
        ifInstallationID installationID: String
    ) throws {
        guard let current = try currentIdentity(),
              current.installationID == installationID else {
            return
        }
        try delete(account: identityAccount)
    }

    func deactivationTombstones() throws
        -> [PushDeactivationTombstone] {
        guard let data = try read(account: tombstonesAccount) else {
            return []
        }
        guard let values = try? decoder.decode(
            [PushDeactivationTombstone].self,
            from: data
        ), values.allSatisfy({
            $0.credential.count == 32
                && UUID(uuidString: $0.installationID) != nil
        }) else {
            throw PushInstallationVaultError.invalidStoredValue
        }
        return values
    }

    func removeTombstone(installationID: String) throws {
        var values = try deactivationTombstones()
        values.removeAll { $0.installationID == installationID }
        if values.isEmpty {
            try delete(account: tombstonesAccount)
        } else {
            try write(
                try encoder.encode(values),
                account: tombstonesAccount
            )
        }
    }

    private func randomData(count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(
                kSecRandomDefault,
                count,
                bytes.baseAddress!
            )
        }
        guard status == errSecSuccess else {
            throw PushInstallationVaultError
                .randomGenerationFailed(status)
        }
        return data
    }

    private func resetTombstone(
        from data: Data
    ) throws -> PushDeactivationTombstone {
        if let identity = try? decoder.decode(
            PushInstallationIdentity.self,
            from: data
        ),
        UUID(uuidString: identity.installationID) != nil,
        identity.credential.count == 32 {
            return PushDeactivationTombstone(
                installationID: identity.installationID.lowercased(),
                credential: identity.credential,
                createdAt: Date()
            )
        }

        // APNs context or the local remote-user binding may be malformed
        // while the authenticated server-deactivation credential remains
        // recoverable. Decode only the two fields required to tombstone the
        // server installation; do not silently treat unreadable data as an
        // absent identity.
        guard let envelope = try? decoder.decode(
            PushResetCredentialEnvelope.self,
            from: data
        ), UUID(uuidString: envelope.installationID) != nil,
        envelope.credential.count == 32 else {
            throw PushInstallationVaultError.invalidStoredValue
        }
        return PushDeactivationTombstone(
            installationID: envelope.installationID.lowercased(),
            credential: envelope.credential,
            createdAt: Date()
        )
    }

    private func read(account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecReturnData as String: kCFBooleanTrue as Any,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(
            query as CFDictionary,
            &result
        )
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw PushInstallationVaultError.invalidStoredValue
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw PushInstallationVaultError.keychainFailure(status)
        }
    }

    private func write(_ data: Data, account: String) throws {
        let lookup: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any
        ]
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String:
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(
            lookup as CFDictionary,
            update as CFDictionary
        )
        if updateStatus == errSecItemNotFound {
            var insertion = lookup
            insertion.merge(update) { _, new in new }
            let addStatus = SecItemAdd(insertion as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw PushInstallationVaultError
                    .keychainFailure(addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw PushInstallationVaultError
                .keychainFailure(updateStatus)
        }

        guard try read(account: account) == data else {
            throw PushInstallationVaultError.invalidStoredValue
        }
    }

    private func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PushInstallationVaultError.keychainFailure(status)
        }
    }

    private static func isValidRemoteUserID(
        _ remoteUserID: String?
    ) -> Bool {
        guard let remoteUserID else {
            // Version-one Keychain identities did not yet contain this
            // value. The coordinator adopts the matching GRDB value once
            // and writes the upgraded identity back to Keychain.
            return true
        }
        return UUID(uuidString: remoteUserID) != nil
    }
}
