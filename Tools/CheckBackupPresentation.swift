// Synthetic completion barriers; the tested model is extracted from production source.
import Foundation
import Observation
struct CloudBackupRecord: Sendable { let walletID: String; var state = "queued"; var enabled = true; var failureCode: String?; var encryptedDocument: Data? = Data() }
enum OathStringKey { case cloudBackupEncrypting, cloudBackupFailed, backupNotYet, cloudBackupComplete, cloudBackupUploading }
enum ProbeError: Error { case readFailed }
enum OathDiagnostics { static func record(_ error: any Error) {} }
struct OathWalletVault: Sendable {}
actor ProbeDB {
    static let shared = ProbeDB()
    private var pending: [String: CheckedContinuation<CloudBackupRecord?, Error>] = [:]
    private var entered: [String: CheckedContinuation<Void, Never>] = [:]
    func cloudBackup(walletID: String) async throws -> CloudBackupRecord? {
        try await withCheckedThrowingContinuation { continuation in
            pending[walletID] = continuation
            entered.removeValue(forKey: walletID)?.resume()
        }
    }
    func wait(_ id: String) async {
        if pending[id] != nil { return }
        await withCheckedContinuation { entered[id] = $0 }
    }
    func release(_ id: String, fail: Bool) {
        guard let c = pending.removeValue(forKey: id) else { fatalError("missing controlled read") }
        if fail { c.resume(throwing: ProbeError.readFailed) }
        else { c.resume(returning: CloudBackupRecord(walletID: id)) }
    }
    func reconcileRemovedCloudBackups() async throws {}
    nonisolated func observeCloudBackups() -> AsyncThrowingStream<[CloudBackupRecord], Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
actor OathDataEnvironment {
    static let shared = OathDataEnvironment()
    func database() async throws -> ProbeDB { .shared }
}
actor OathCloudBackupService {
    static let shared = OathCloudBackupService()
    private var completed = Set<String>()
    private var waiting: [String: CheckedContinuation<Void, Never>] = [:]
    func createAll(walletIDs: [String], password: String, vault: OathWalletVault,
                   didFinish: @Sendable (String, (any Error)?) async -> Void) async throws {
        for id in walletIDs {
            await didFinish(id, nil)
            completed.insert(id); waiting.removeValue(forKey: id)?.resume()
        }
    }
    func wait(_ id: String) async {
        if completed.contains(id) { return }
        await withCheckedContinuation { waiting[id] = $0 }
    }
    func checkAvailability(for record: CloudBackupRecord?) async throws {}
    func resume() async throws {}
    nonisolated static func failureCode(_ error: any Error) -> String { "failed" }
}
@main struct Probe {
    @MainActor static func main() async throws {
        var passed = 0, failed = 0
        func check(_ value: Bool, _ name: String) {
            if value { passed += 1; print("PASS: \(name)") }
            else { failed += 1; print("FAIL: \(name)") }
        }
        for oldFails in [false, true] {
            let prefix = oldFails ? "failed read" : "successful read"
            let old = "old-\(oldFails)", new = "new-\(oldFails)"
            let model = OathAllWalletBackupModel()
            model.create(walletIDs: [old], password: "synthetic password", vault: .init())
            await ProbeDB.shared.wait(old)
            model.cancelPreparation()
            model.create(walletIDs: [new], password: "synthetic password", vault: .init())
            await ProbeDB.shared.wait(new)
            await ProbeDB.shared.release(old, fail: oldFails)
            await OathCloudBackupService.shared.wait(old)
            check(model.failure == nil, "\(prefix): old completion cannot set new failure")
            check(model.finishedCount == 0, "\(prefix): old completion cannot advance new progress")
            check(model.preparing && model.totalCount == 1, "\(prefix): new preparation remains active")
            check(model.records[old] == nil, "\(prefix): old record is not published")
            await ProbeDB.shared.release(new, fail: false)
            await OathCloudBackupService.shared.wait(new)
            check(model.finishedCount == 1, "\(prefix): current completion counts once")
            check(model.records[new]?.walletID == new, "\(prefix): current record appears")
        }
        let current = OathAllWalletBackupModel()
        current.create(walletIDs: ["current-failure"], password: "synthetic password", vault: .init())
        await ProbeDB.shared.wait("current-failure")
        await ProbeDB.shared.release("current-failure", fail: true)
        await OathCloudBackupService.shared.wait("current-failure")
        check(current.failure == "failed", "current failure remains visible")
        check(current.finishedCount == 1, "current failure counts once")
        check(current.records["current-failure"] == nil, "failed read cannot invent a record")
        print("Backup presentation checks: \(passed) passed, \(failed) failed")
        fflush(nil)
        if failed != 0 { exit(1) }
    }
}
