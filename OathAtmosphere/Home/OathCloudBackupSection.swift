import OathDiagnostics
import SwiftUI
import OathCloudBackup
import OathDatabase

struct OathCloudBackupSection: View {
    let session: OathWalletSession
    let walletID: String
    let model: OathCloudBackupModel
    let onChoosePassword: () -> Void
    @Environment(\.oathLocalizer) private var strings
    @State private var requestingBackup = false

    private var isBackedUp: Bool {
        guard let record = model.record else { return false }
        return record.enabled && record.state == "uploaded" && !model.preparing
            && model.failure == nil && record.failureCode == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Toggle(isOn: Binding(get: { requestingBackup || model.record?.enabled == true || model.preparing }, set: { enabled in
                guard !model.preparing, session.isUnlocked, !session.changingWallet else { return }
                if enabled {
                    // Accept the native switch interaction before navigating.
                    // A removed backup stays disabled in storage until a fresh
                    // encrypted document is committed, not when setup opens.
                    requestingBackup = true
                } else if !requestingBackup, model.record?.enabled == true {
                    model.disable(walletID: walletID)
                }
            })) {
                HStack(spacing: 16) {
                    OathSettingsIcon(symbol: isBackedUp ? "checkmark.icloud" : "icloud")
                    Text(strings.text(.cloudBackupSwitch))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .oathSwitchStyle()
            .oathFont(.body)
            .padding(.horizontal, 20)
            .padding(.vertical, 17)
            .frame(minHeight: 74)
            // Starting a new backup needs the unlocked vault and a password,
            // not completion of the old backup's status observation.
            .disabled(model.preparing || !session.isUnlocked || session.changingWallet)
            .accessibilityIdentifier("walletSettings.iCloud")
            OathSettingsFooter {
                if model.preparing {
                    HStack(spacing: 10) { ProgressView(); Text(strings.text(.cloudBackupEncrypting)) }
                        .oathFont(.footnote).foregroundStyle(.secondary)
                } else if let record = model.record, record.enabled,
                          record.state == "queued" || record.state == "uploading" {
                    VStack(alignment: .leading, spacing: 8) {
                        if let percent = record.percent, percent > 0 {
                            ProgressView(value: percent, total: 100)
                        } else { ProgressView() }
                        Text(strings.text(.cloudBackupUploading)).oathFont(.footnote)
                        Text(strings.text(.cloudBackupWaiting)).oathFont(.footnote).foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("walletSettings.iCloudProgress")
                }
                if let failure = model.failure ?? model.record?.failureCode {
                    Text(strings.text(Self.message(failure))).oathFont(.footnote).foregroundStyle(.red)
                    OathActionButton(title: strings.text(.tryAgain), appearance: .secondary) {
                        if model.record?.enabled == true && model.record?.encryptedDocument != nil {
                            model.retry(walletID: walletID)
                        } else { onChoosePassword() }
                    }
                        .oathActionArea(existingInset: 20)
                        .disabled(model.preparing)
                }
                Text(strings.text(.cloudBackupDetail))
            }
        }
        .onChange(of: requestingBackup) { _, requested in
            guard requested else { return }
            guard session.isUnlocked, !session.changingWallet else {
                requestingBackup = false
                return
            }
            onChoosePassword()
        }
        .onAppear { requestingBackup = false }
        .oathErrorFeedback(model.failure ?? model.record?.failureCode)
        .onChange(of: model.record?.state) { previous, current in
            if previous == "uploading" || previous == "queued", current == "uploaded" { OathHaptics.shared.play(.success) }
        }
    }

    static func message(_ code: String) -> OathStringKey {
        switch code {
        case "unavailable": .cloudBackupUnavailable
        case "accountChanged": .cloudBackupAccountChanged
        case "quota": .cloudBackupQuota
        case "missing": .cloudBackupMissing
        default: .cloudBackupFailed
        }
    }
}

@MainActor @Observable final class OathCloudBackupModel {
    var record: CloudBackupRecord?
    var preparing = false
    var loaded = false
    var failure: String?
    private var work: Task<Void, Never>?
    private var operationID = UUID()

    func observe(walletID: String) async {
        cancelPreparation()
        record = nil; loaded = false; failure = nil
        do {
            let db = try await OathDataEnvironment.shared.database()
            try Task.checkCancellation()
            try await db.reconcileRemovedCloudBackups()
            let initial = try await db.cloudBackup(walletID: walletID)
            try Task.checkCancellation()
            record = initial
            loaded = true
            if record?.enabled == true { retry(walletID: walletID) }
            for try await record in db.observeCloudBackup(walletID: walletID) {
                try Task.checkCancellation()
                let newlyUploaded = record?.state == "uploaded" && self.record?.state != "uploaded"
                self.record = record
                if newlyUploaded { failure = nil }
            }
        } catch is CancellationError { }
        catch { OathDiagnostics.record(error); if !Task.isCancelled { failure = "failed" } }
    }
    func create(walletID: String, password: String, vault: OathWalletVault) {
        guard !preparing else { return }
        cancelPreparation()
        let operation = operationID
        preparing = true; failure = nil
        work = Task {
            defer { finish(operation) }
            do { try await OathCloudBackupService.shared.create(walletID: walletID, password: password, vault: vault) }
            catch is CancellationError { }
            catch { OathDiagnostics.record(error); if !Task.isCancelled { failure = OathCloudBackupService.failureCode(error) } }
        }
    }
    func disable(walletID: String) {
        cancelPreparation()
        let operation = operationID
        work = Task {
            defer { finish(operation) }
            do {
                try await OathCloudBackupService.shared.disable(walletID: walletID)
                try Task.checkCancellation()
                failure = nil
            } catch { OathDiagnostics.record(error); if !Task.isCancelled { failure = "failed" } }
        }
    }
    func retry(walletID: String) {
        cancelPreparation()
        let operation = operationID
        let record = record
        work = Task {
            defer { finish(operation) }
            do {
                try await OathCloudBackupService.shared.checkAvailability(for: record)
                try await OathCloudBackupService.shared.resume()
                try Task.checkCancellation()
                failure = nil
            } catch { OathDiagnostics.record(error); if !Task.isCancelled { failure = OathCloudBackupService.failureCode(error) } }
        }
    }
    func cancelPreparation() {
        work?.cancel(); work = nil; preparing = false
        operationID = UUID()
    }
    private func finish(_ operation: UUID) {
        // A cancelled job for a previously viewed wallet must not clear the
        // progress or task of the wallet currently open in this same sheet.
        guard operationID == operation else { return }
        preparing = false; work = nil
    }
}
