import Foundation
import CryptoKit

protocol OathInstallationKeyStoring: Sendable {
    /// Only a genuinely absent file returns nil. Protection/I/O errors throw.
    func read() throws -> Data?
    func write(_ data: Data) throws
}

protocol OathInstallationCredentialClearing: Sendable {
    func clear() throws
}

enum OathInstallationSecurityError: Error {
    case invalidKey, invalidRecord, unsafePath
    case keychain(Int32)
}

/// An installation owns the only outer encryption key for its Keychain data.
/// iOS deletes this key with the app's container, rendering retained records
/// unusable even before the next launch removes them. Never cache the key: a
/// protected-file read failure must not be mistaken for a fresh installation.
/// Call from the vault/biometric actors, never from the UI thread.
final class OathInstallationSecurity: @unchecked Sendable {
    private struct KeyRecord: Codable {
        let version: Int
        let id: UUID
        let key: Data
    }

    private struct SealedRecord: Codable {
        let version: Int
        let installationID: UUID
        let sealed: Data
    }

    private let lock = NSLock()
    private let keys: any OathInstallationKeyStoring
    private let credentials: any OathInstallationCredentialClearing

    init(keys: any OathInstallationKeyStoring, credentials: any OathInstallationCredentialClearing) {
        self.keys = keys
        self.credentials = credentials
    }

    func prepare() throws {
        try lock.withLock { _ = try loadKey() }
    }

    /// Revoke every old installation-wrapped credential and rotate its outer
    /// key. A fresh empty installation can create a new wallet after reset.
    func reset() throws {
        try lock.withLock {
            try credentials.clear()
            let record = KeyRecord(version: 1, id: UUID(),
                key: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
            try keys.write(JSONEncoder().encode(record))
        }
    }

    func seal(_ data: Data, context: String) throws -> Data {
        try lock.withLock {
            let record = try loadKey()
            let sealed = try AES.GCM.seal(data, using: SymmetricKey(data: record.key),
                                          authenticating: authenticationData(record.id, context: context))
            guard let combined = sealed.combined else { throw OathInstallationSecurityError.invalidRecord }
            return try JSONEncoder().encode(SealedRecord(version: 1, installationID: record.id, sealed: combined))
        }
    }

    func open(_ data: Data, context: String) throws -> Data {
        try lock.withLock {
            let key = try loadKey()
            let record = try JSONDecoder().decode(SealedRecord.self, from: data)
            guard record.version == 1, record.installationID == key.id else {
                throw OathInstallationSecurityError.invalidRecord
            }
            return try AES.GCM.open(AES.GCM.SealedBox(combined: record.sealed),
                                    using: SymmetricKey(data: key.key),
                                    authenticating: authenticationData(key.id, context: context))
        }
    }

    private func loadKey() throws -> KeyRecord {
        if let data = try keys.read() {
            let record = try JSONDecoder().decode(KeyRecord.self, from: data)
            guard record.version == 1, record.key.count == 32 else {
                throw OathInstallationSecurityError.invalidKey
            }
            return record
        }

        // No marker existed in the old prototype. The first fixed launch also
        // clears those legacy credentials once. Do not infer ownership from
        // preferences, timestamps, device IDs, or a successful Face ID match.
        // Commit the key only AFTER every scoped deletion succeeds. A partial
        // failure is unavailable/retry, never onboarding with stale records.
        try credentials.clear()
        let record = KeyRecord(version: 1, id: UUID(),
                               key: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
        try keys.write(JSONEncoder().encode(record))
        return record
    }

    private func authenticationData(_ id: UUID, context: String) -> Data {
        Data("org.oathwallet.installation.v1:\(id.uuidString):\(context)".utf8)
    }
}

struct OathInstallationKeyFile: OathInstallationKeyStoring {
    let directory: URL
    var url: URL { directory.appendingPathComponent("key-v1.json", isDirectory: false) }

    func read() throws -> Data? {
        try rejectSymlink(directory)
        try rejectSymlink(url)
        do { return try Data(contentsOf: url) }
        catch CocoaError.fileReadNoSuchFile { return nil }
    }

    func write(_ data: Data) throws {
        let manager = FileManager.default
        try rejectSymlink(directory)
        try rejectSymlink(url)
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        #if os(iOS)
        attributes[.protectionKey] = FileProtectionType.complete
        #endif
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: attributes)
        // Exclude the containing directory BEFORE the key first reaches disk.
        var folder = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: url, options: .atomic)
        #endif
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        var file = url
        try file.setResourceValues(values)
    }

    private func rejectSymlink(_ url: URL) throws {
        do {
            if try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                throw OathInstallationSecurityError.unsafePath
            }
        } catch CocoaError.fileReadNoSuchFile { }
    }
}
