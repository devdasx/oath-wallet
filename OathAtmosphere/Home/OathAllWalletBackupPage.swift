import OathDiagnostics
import SwiftUI
import OathDatabase

struct OathAllWalletBackupPage: View {
    let session: OathWalletSession
    let model: OathAllWalletBackupModel
    let onChoosePassword: () -> Void
    @Environment(\.oathLocalizer) private var strings

    var body: some View {
        Group {
            if session.wallets.isEmpty {
                OathEmptyState(strings.text(.backupAllEmpty), systemImage: "lock.icloud")
            } else {
                backupContent
            }
        }
        .oathErrorFeedback(model.failure)
        .oathHapticFeedback(.error, trigger: model.failures, when: !model.failures.isEmpty)
        .onChange(of: model.records) { previous, current in
            let pending = previous.values.filter { $0.state == "queued" || $0.state == "uploading" }
            if !pending.isEmpty, pending.allSatisfy({ current[$0.walletID]?.state == "uploaded" }) {
                OathHaptics.shared.play(.success)
            }
        }
    }

    private var backupContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            OathSettingsIntroduction(icon: "lock.icloud", text: strings.text(.backupAllDetail))
                .padding(20)
            OathActionButton(title: strings.text(.backupAllWallets), action: onChoosePassword)
                .oathActionArea()
                .disabled(session.wallets.isEmpty || !model.loaded || model.preparing || !session.isUnlocked || session.changingWallet)
                .accessibilityIdentifier("backup.all.start")
            if model.preparing {
                HStack(spacing: 12) {
                    ProgressView()
                    Text(strings.format(.backupAllProgress, strings.number(model.finishedCount), strings.number(model.totalCount)))
                        .oathFont(.footnote).foregroundStyle(.secondary)
                }
                .padding(20)
                .accessibilityIdentifier("backup.all.progress")
            }
            if let failure = model.failure {
                OathSettingsFooter { Text(strings.text(OathCloudBackupSection.message(failure))).foregroundStyle(.red) }
            }
            if model.canRetryUploads || model.failure != nil {
                OathActionButton(title: strings.text(.tryAgain), appearance: .secondary) { model.retryFailedWork() }
                    .oathActionArea().padding(.top, 12)
                    .disabled(model.preparing || model.retrying || !session.isUnlocked)
            }
            OathSettingsSectionRule()
            ForEach(session.wallets, id: \.id) { wallet in
                let status = model.status(walletID: wallet.id)
                OathSettingsRow(title: session.walletName(wallet, strings: strings), icon: "square.3.layers.3d",
                    accessory: .none, subtitle: strings.text(status.title), isWorking: status.working)
                    .accessibilityIdentifier("backup.all.wallet.\(wallet.id)")
                if let failure = model.failures[wallet.id] ?? model.records[wallet.id]?.failureCode {
                    OathSettingsFooter { Text(strings.text(OathCloudBackupSection.message(failure))).foregroundStyle(.red) }
                }
            }
            OathSettingsFooter { Text(strings.text(.cloudBackupWaiting)) }
        }
    }
}

@MainActor @Observable final class OathAllWalletBackupModel {
    private(set) var records: [String: CloudBackupRecord] = [:]
    private(set) var failures: [String: String] = [:]
    private(set) var preparing = false
    private(set) var retrying = false
    private(set) var loaded = false
    private(set) var finishedCount = 0
    private(set) var totalCount = 0
    private(set) var failure: String?
    private(set) var observationID = UUID()
    private var observationFailed = false
    private var remaining = Set<String>()
    private var work: Task<Void, Never>?
    private var retry: Task<Void, Never>?
    private var operationID = UUID()

    var canRetryUploads: Bool {
        records.values.contains { $0.state == "failed" && $0.encryptedDocument != nil }
    }

    func status(walletID: String) -> (title: OathStringKey, working: Bool) {
        if remaining.contains(walletID) { return (.cloudBackupEncrypting, true) }
        if failures[walletID] != nil { return (.cloudBackupFailed, false) }
        guard let record = records[walletID], record.enabled else { return (.backupNotYet, false) }
        switch record.state {
        case "uploaded" where record.failureCode == nil: return (.cloudBackupComplete, false)
        case "queued", "uploading": return (.cloudBackupUploading, true)
        default: return (.cloudBackupFailed, false)
        }
    }

    func observe() async {
        observationFailed = false
        do {
            let db = try await OathDataEnvironment.shared.database()
            retryUploads()
            for try await updates in db.observeCloudBackups() {
                try Task.checkCancellation()
                records = Dictionary(uniqueKeysWithValues: updates.map { ($0.walletID, $0) })
                loaded = true
            }
        } catch is CancellationError { }
        catch { OathDiagnostics.record(error);
            if !Task.isCancelled { failure = "failed"; observationFailed = true }
        }
    }

    func retryFailedWork() {
        if observationFailed || !loaded {
            failure = nil
            observationID = UUID()
        } else { retryUploads() }
    }

    func create(walletIDs: [String], password: String, vault: OathWalletVault) {
        guard !preparing, !walletIDs.isEmpty else { return }
        cancelPreparation()
        let operation = operationID
        preparing = true; failure = nil; failures = [:]
        remaining = Set(walletIDs); totalCount = remaining.count; finishedCount = 0
        work = Task {
            defer {
                if operationID == operation { preparing = false; remaining = []; work = nil }
            }
            do {
                try await OathCloudBackupService.shared.createAll(walletIDs: walletIDs, password: password, vault: vault) { [weak self] id, error in
                    await self?.finished(id, error: error, operation: operation)
                }
            } catch is CancellationError { }
            catch { OathDiagnostics.record(error);
                guard !Task.isCancelled, operationID == operation else { return }
                failure = OathCloudBackupService.failureCode(error)
            }
        }
    }

    private func finished(_ id: String, error: (any Error)?, operation: UUID) async {
        guard operationID == operation, !Task.isCancelled else { return }
        if let error { failures[id] = OathCloudBackupService.failureCode(error) }
        else {
            // Replace an older successful record before removing the preparing
            // state. A fresh queued backup is never presented as uploaded.
            do {
                let db = try await OathDataEnvironment.shared.database()
                let record = try await db.cloudBackup(walletID: id)
                guard operationID == operation, !Task.isCancelled else { return }
                records[id] = record
            } catch { OathDiagnostics.record(error); failure = "failed" }
        }
        remaining.remove(id); finishedCount += 1
    }

    func retryUploads() {
        guard retry == nil else { return }
        retrying = true
        retry = Task {
            defer { retrying = false; retry = nil }
            do {
                try await OathCloudBackupService.shared.checkAvailability(for: nil)
                try await OathCloudBackupService.shared.resume()
                try Task.checkCancellation()
                failure = nil
            } catch is CancellationError { }
            catch { OathDiagnostics.record(error); if !Task.isCancelled { failure = OathCloudBackupService.failureCode(error) } }
        }
    }

    func cancelPreparation() {
        operationID = UUID()
        work?.cancel(); work = nil
        preparing = false; remaining = []
        retry?.cancel()
        // Already committed encrypted jobs continue through the durable outbox.
    }
}
