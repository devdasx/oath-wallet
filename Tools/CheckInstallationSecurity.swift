import Foundation
import CryptoKit

private enum FixtureError: Error { case denied, interrupted }

private final class Fixture: OathInstallationKeyStoring, OathInstallationCredentialClearing, @unchecked Sendable {
    private let lock = NSLock()
    private var key: Data?
    private var retained = ["vault", "attempts", "biometrics", "passcode"]
    private var deletionCount = 0
    private var saveCount = 0
    var readFailure = false
    var writeFailure = false
    var partialDeletionFailure = false

    func read() throws -> Data? {
        try lock.withLock {
            if readFailure { throw FixtureError.denied }
            return key
        }
    }
    func write(_ data: Data) throws {
        try lock.withLock {
            if writeFailure { throw FixtureError.interrupted }
            key = data
            saveCount += 1
        }
    }
    func clear() throws {
        try lock.withLock {
            deletionCount += 1
            if partialDeletionFailure {
                retained.removeFirst()
                throw FixtureError.interrupted
            }
            retained.removeAll()
        }
    }
    func replaceKey(_ data: Data?) { lock.withLock { key = data } }
    var counts: (deleted: Int, saved: Int, remaining: Int) {
        lock.withLock { (deletionCount, saveCount, retained.count) }
    }
    func security() -> OathInstallationSecurity { .init(keys: self, credentials: self) }
}

@main
struct CheckInstallationSecurity {
    static func main() throws {
        var checks = 0
        func check(_ condition: Bool, _ reason: String) {
            precondition(condition, reason)
            checks += 1
        }
        func rejects(_ reason: String, _ operation: () throws -> Void) {
            do { try operation(); preconditionFailure(reason) }
            catch { checks += 1 }
        }

        let fixture = Fixture()
        let install = fixture.security()
        check(fixture.counts.deleted == 0, "Construction must not erase or perform I/O on the UI thread")
        try install.prepare()
        check(fixture.counts.deleted == 1 && fixture.counts.saved == 1 && fixture.counts.remaining == 0,
              "A missing installation key clears every legacy credential before committing readiness")
        let firstKey = try fixture.read()
        let plaintext = Data("public-fixture-only".utf8)
        let contexts = ["vault:vault-v1", "vault:unlock-attempts-v1", "biometric:test", "passcode:test"]
        var records: [Data] = []
        for context in contexts {
            let record = try install.seal(plaintext, context: context)
            records.append(record)
            check(try install.open(record, context: context) == plaintext, "Bound records round trip")
            check(record.range(of: plaintext) == nil, "Keychain bytes do not contain unwrapped values")
            rejects("A different record purpose must not decrypt") { _ = try install.open(record, context: context + ".other") }
            var damaged = record
            damaged[damaged.count / 2] ^= 1
            rejects("Tampered records must not decrypt") { _ = try install.open(damaged, context: context) }
        }
        let relaunched = fixture.security()
        try relaunched.prepare()
        for (context, record) in zip(contexts, records) {
            check(try relaunched.open(record, context: context) == plaintext, "Relaunch/update retains this installation")
        }
        check(fixture.counts.deleted == 1 && fixture.counts.saved == 1, "Existing installs do not clear or rotate their key")

        // Deletion removes the container, while the old Keychain bytes survive.
        fixture.replaceKey(nil)
        let reinstalled = fixture.security()
        try reinstalled.prepare()
        check(try fixture.read() != firstKey, "Reinstall generates unrelated installation key material")
        check(fixture.counts.deleted == 2, "Reinstall clears stale credentials before opening onboarding")
        for (context, record) in zip(contexts, records) {
            rejects("An old wallet, retry record or credential must never open after reinstall") {
                _ = try reinstalled.open(record, context: context)
            }
        }
        rejects("Legacy unwrapped data must not be resurrected") {
            _ = try reinstalled.open(plaintext, context: contexts[0])
        }
        let fresh = try reinstalled.seal(plaintext, context: contexts[0])
        check(try reinstalled.open(fresh, context: contexts[0]) == plaintext, "Fresh wallet records can be created normally")

        for bytes in [Data(), Data("not-json".utf8),
                      Data("{\"version\":2,\"id\":\"00000000-0000-0000-0000-000000000000\",\"key\":\"AA==\"}".utf8)] {
            let corrupt = Fixture()
            corrupt.replaceKey(bytes)
            rejects("Malformed key files fail closed") { try corrupt.security().prepare() }
            check(corrupt.counts.deleted == 0 && corrupt.counts.saved == 0,
                  "Corruption is not permission to erase an existing wallet")
        }
        let protected = Fixture()
        protected.readFailure = true
        rejects("Locked/protected or unreadable key files are not fresh installs") { try protected.security().prepare() }
        check(protected.counts.deleted == 0 && protected.counts.saved == 0, "Read failure never erases credentials")

        let partial = Fixture()
        partial.partialDeletionFailure = true
        rejects("Partial cleanup cannot commit a fresh installation") { try partial.security().prepare() }
        check(try partial.read() == nil && partial.counts.saved == 0, "No key is committed after incomplete cleanup")
        partial.partialDeletionFailure = false
        try partial.security().prepare()
        check(partial.counts.deleted == 2 && partial.counts.remaining == 0 && partial.counts.saved == 1,
              "Retry completes all deletions before becoming ready")

        let failedSave = Fixture()
        failedSave.writeFailure = true
        rejects("Failed key persistence cannot report startup success") { try failedSave.security().prepare() }
        check(try failedSave.read() == nil, "No cached-only installation key can permit a wallet commit")
        failedSave.writeFailure = false
        try failedSave.security().prepare()
        check(failedSave.counts.deleted == 2 && failedSave.counts.saved == 1, "A failed initial write is safely retryable")

        let concurrent = Fixture()
        let shared = concurrent.security()
        DispatchQueue.concurrentPerform(iterations: 64) { _ in try! shared.prepare() }
        check(concurrent.counts.deleted == 1 && concurrent.counts.saved == 1,
              "Concurrent vault and biometric startup share exactly one installation")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Oath-install-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = OathInstallationKeyFile(directory: directory)
        check(try file.read() == nil, "Only a missing key file returns nil")
        let native = OathInstallationSecurity(keys: file, credentials: Fixture())
        try native.prepare()
        check(try file.read() != nil, "The real file store persists a key")
        check(try file.url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true,
              "Installation key is excluded from device backups")
        check(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true,
              "The directory excludes a newly written key before any file metadata update")
        let permissions = try FileManager.default.attributesOfItem(atPath: file.url.path)[.posixPermissions] as? NSNumber
        check(permissions?.intValue == 0o600, "The key file has owner-only access")
        let nativeRecord = try native.seal(plaintext, context: contexts[0])
        let reopened = OathInstallationSecurity(keys: file, credentials: Fixture())
        check(try reopened.open(nativeRecord, context: contexts[0]) == plaintext, "A fresh process can reopen the persistent file")
        try FileManager.default.removeItem(at: file.url)
        rejects("Losing the real installation file makes previous ciphertext unusable") {
            _ = try reopened.open(nativeRecord, context: contexts[0])
        }
        try FileManager.default.removeItem(at: file.url)
        let target = directory.appendingPathComponent("untouched-test-file")
        try plaintext.write(to: target)
        try FileManager.default.createSymbolicLink(at: file.url, withDestinationURL: target)
        rejects("Never follow a key-file symlink") { _ = try file.read() }
        rejects("Never overwrite a symlink target") { try file.write(Data()) }
        check(try Data(contentsOf: target) == plaintext, "Unrelated file remains untouched")

        print("Passed \(checks) installation ownership, encryption, reinstall, failure recovery and protected-file host checks.")
    }
}
