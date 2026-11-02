import OathDiagnostics
import Foundation
import OathCloudBackup
import OathDatabase

/// Owns the ciphertext outbox and native iCloud observations independently of
/// the sheet. Neither a navigation change nor suspension cancels iOS uploads.
actor OathCloudBackupService {
    static let shared = OathCloudBackupService()
    private let drive = CloudDrive()
    private var preparing: Set<String> = []
    private var observation: CloudUploadObservation?
    private var observedAccount: String?
    private var pendingObservation: (id: UUID, accountID: String, task: Task<CloudUploadObservation, Error>)?
    private var monitoring: Task<Void, Never>?
    private var resuming = false
    private var resetPaused = false
    private var generation = UUID()
    private var resetWaiters: [CheckedContinuation<Void, Never>] = []

    private func checkGeneration(_ token: UUID) throws {
        try Task.checkCancellation()
        guard !resetPaused, generation == token else { throw CancellationError() }
    }

    func suspendForReset() async {
        resetPaused = true; generation = UUID()
        monitoring?.cancel(); monitoring = nil
        let previous = observation
        observation = nil; observedAccount = nil
        let pending = pendingObservation
        pendingObservation = nil
        pending?.task.cancel()
        if let pending, let watcher = try? await pending.task.value { await watcher.stop() }
        if let previous { await previous.stop() }
        await drive.resetBarrier()
        // A backup can still be deriving its password key on a worker. Join
        // those preparations before reporting that in-memory secrets are gone.
        if !preparing.isEmpty { await withCheckedContinuation { resetWaiters.append($0) } }
    }

    func reopenAfterReset() { resetPaused = false }

    func createAll(walletIDs: [String], password: String, vault: OathWalletVault,
                   didFinish: @Sendable (String, (any Error)?) async -> Void) async throws {
        let token = generation
        try checkGeneration(token)
        let location = try await drive.location()
        try checkGeneration(token)
        try await BackupBatch.prepare(walletIDs: walletIDs, operation: { id in
            try await self.create(walletID: id, password: password, vault: vault,
                                  expectedAccount: location.accountID, expectedGeneration: token)
        }, didFinish: didFinish)
    }

    func create(walletID: String, password: String, vault: OathWalletVault,
                expectedAccount: String? = nil, expectedGeneration: UUID? = nil) async throws {
        let token = expectedGeneration ?? generation
        try checkGeneration(token)
        guard preparing.insert(walletID).inserted else { throw CloudBackupError.unavailable }
        defer {
            preparing.remove(walletID)
            if preparing.isEmpty {
                let waiters = resetWaiters; resetWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
        }
        // Fail early if Drive is unavailable, before asking the vault to export.
        let location = try await drive.location()
        if let expectedAccount { try await drive.verifyAccount(expectedAccount) }
        try checkGeneration(token)
        let document = try await vault.encryptedCloudBackup(walletID: walletID, password: password)
        try Task.checkCancellation()
        try await drive.verifyAccount(location.accountID)
        let db = try await OathDataEnvironment.shared.database()
        try checkGeneration(token)
        let record = CloudBackupRecord(walletID: walletID, backupID: UUID(), accountID: location.accountID, encryptedDocument: document)
        try await db.queueCloudBackup(record)
        // From this point the encrypted job is durable and contains no password.
        Task {
            do {
                try checkGeneration(token)
                try await observe(location)
                try await upload(record, at: location, db: db, token: token)
            } catch { OathDiagnostics.record(error);
                await OathDiagnostics.attempt("updateCloudBackup", body: { try await db.updateCloudBackup(backupID: record.backupID, state: "failed", failureCode: Self.failureCode(error)) })
            }
        }
    }

    func disable(walletID: String) async throws {
        let db = try await OathDataEnvironment.shared.database()
        try await db.disableCloudBackup(walletID: walletID)
    }

    /// Called on foreground entry and when opening backup settings. No secret
    /// or password is required to resume a committed encrypted backup.
    func resume() async throws {
        guard !resuming, !resetPaused else { return }
        let token = generation
        resuming = true
        defer { resuming = false }
        let db = try await OathDataEnvironment.shared.database()
        try checkGeneration(token)
        try await db.reconcileRemovedCloudBackups()
        let records = try await db.cloudBackups()
        guard !records.isEmpty else { return }
        let location = try await drive.location()
        try checkGeneration(token)
        try await observe(location)
        for record in records {
            try checkGeneration(token)
            guard try await drive.matchesAccount(record.accountID) else {
                try await db.invalidateCloudBackup(backupID: record.backupID, failureCode: "accountChanged")
                continue
            }
            guard record.state != "uploaded" else { continue }
            do { try await upload(record, at: location, db: db, token: token) }
            catch is CancellationError { throw CancellationError() }
            catch { OathDiagnostics.record(error); /* Individual failures are persisted by upload. */ }
        }
    }

    func checkAvailability(for record: CloudBackupRecord?) async throws {
        let location = try await drive.location()
        try await drive.verifyAccount(location.accountID)
        if let record, record.enabled { try await drive.verifyAccount(record.accountID) }
    }

    private func upload(_ record: CloudBackupRecord, at location: CloudLocation, db: OathDatabase, token: UUID) async throws {
        guard let document = record.encryptedDocument, let id = UUID(uuidString: record.backupID) else { return }
        // An obsolete job must not restart after switching off/replacing it.
        guard let current = try await db.cloudBackup(walletID: record.walletID),
              current.enabled, current.backupID == record.backupID else { return }
        do {
            try checkGeneration(token)
            try await drive.write(document, backupID: id, at: location)
            try checkGeneration(token)
            try await db.updateCloudBackup(backupID: record.backupID, state: "uploading")
        } catch { OathDiagnostics.record(error);
            await OathDiagnostics.attempt("updateCloudBackup", body: { try await db.updateCloudBackup(backupID: record.backupID, state: "failed", failureCode: Self.failureCode(error)) })
            throw error
        }
    }

    private func observe(_ location: CloudLocation) async throws {
        guard !resetPaused else { throw CancellationError() }
        guard observedAccount != location.accountID else { return }
        // Actor reentrancy: two wallets can finish encryption together. Share
        // one setup task, so awaiting UIKit never creates duplicate watchers.
        if pendingObservation?.accountID != location.accountID {
            pendingObservation = (UUID(), location.accountID, Task { @MainActor in
                try CloudUploadObservation(location: location)
            })
        }
        guard let pending = pendingObservation else { return }
        let observation: CloudUploadObservation
        do { observation = try await pending.task.value }
        catch { OathDiagnostics.record(error);
            if pendingObservation?.id == pending.id { pendingObservation = nil }
            throw error
        }
        guard pendingObservation?.id == pending.id else {
            await observation.stop()
            throw CloudBackupError.accountChanged
        }
        guard self.observation !== observation else { return }
        let previous = self.observation
        monitoring?.cancel()
        observedAccount = location.accountID
        self.observation = observation
        monitoring = Task { [weak self] in
            for await updates in observation.updates {
                guard !Task.isCancelled else { return }
                await self?.receive(updates, at: location)
            }
        }
        if let previous { await previous.stop() }
    }

    private func receive(_ updates: [CloudUpload], at location: CloudLocation) async {
        let accountID = location.accountID
        guard !resetPaused, observedAccount == accountID else { return }
        let token = generation
        do {
            try await drive.verifyAccount(accountID)
            let db = try await OathDataEnvironment.shared.database()
            let records = try await db.cloudBackups()
            var byName: [String: CloudBackupRecord] = [:]
            for record in records {
                if try await drive.matchesAccount(record.accountID), let id = UUID(uuidString: record.backupID) {
                    byName[CloudDrive.fileName(id)] = record
                }
            }
            let available = Set(updates.map(\.fileName))
            for (fileName, record) in byName where record.state == "uploaded" && !available.contains(fileName) {
                try checkGeneration(token)
                try await db.reconcileRemovedCloudBackups(confirmedMissingBackupID: record.backupID)
            }
            for update in updates {
                try checkGeneration(token)
                guard let record = byName[update.fileName] else { continue }
                let state = update.failure != nil ? "failed" : (update.uploaded ? "uploaded" : "uploading")
                if state == "uploaded" {
                    if record.state == "uploaded" { continue }
                    guard let bytes = record.encryptedDocument, let id = UUID(uuidString: record.backupID) else { continue }
                    do {
                        guard try await drive.confirmsUpload(bytes, backupID: id, at: location) else { continue }
                    } catch is CancellationError { return }
                    catch { OathDiagnostics.record(error); continue }
                    try checkGeneration(token)
                }
                try await db.updateCloudBackup(backupID: record.backupID, state: state,
                    percent: update.percent, failureCode: update.failure.map(Self.failureCode))
            }
        } catch { OathDiagnostics.record(error); /* Never mark a file uploaded when account/storage verification fails. */ }
    }

    static func failureCode(_ error: Error) -> String {
        let native = error as NSError
        if native.domain == NSCocoaErrorDomain {
            if native.code == NSUbiquitousFileNotUploadedDueToQuotaError { return "quota" }
            if native.code == NSUbiquitousFileUbiquityServerNotAvailable { return "unavailable" }
        }
        return switch error as? CloudBackupError {
        case .unavailable: "unavailable"
        case .accountChanged: "accountChanged"
        case .quotaExceeded: "quota"
        default: "failed"
        }
    }
}
