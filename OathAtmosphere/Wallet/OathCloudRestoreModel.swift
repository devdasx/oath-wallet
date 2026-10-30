import OathDiagnostics
import Foundation
import Observation
import OathCloudBackup

@MainActor @Observable
final class OathCloudRestoreModel {
    enum Phase { case searching, ready, downloading, decrypting, saving, completed }
    private(set) var phase = Phase.searching
    private(set) var entries: [CloudBackupEntry] = []
    private(set) var selected: CloudBackupEntry?
    private(set) var notice: OathStringKey?
    private(set) var attempt = UUID()
    var busy: Bool { phase == .downloading || phase == .decrypting || phase == .saving }
    var downloadProgress: Double? {
        guard phase == .downloading else { return nil }
        return entries.first { $0.id == selected?.id }?.percentDownloaded.map { $0 / 100 }
    }
    @ObservationIgnored private let drive = CloudDrive()
    @ObservationIgnored private var location: CloudLocation?
    @ObservationIgnored private var discovery: CloudBackupDiscovery?
    @ObservationIgnored private var observation: Task<Void, Never>?
    @ObservationIgnored private var deadline: Task<Void, Never>?
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()

    func start() {
        guard observation == nil else { return }
        stop()
        let token = generation
        phase = .searching; notice = nil
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, self.generation == token, self.phase == .searching else { return }
            self.stop()
            self.phase = .ready
            self.notice = .restoreDiscoveryFailed
        }
        observation = Task { [weak self, drive] in
            do {
                let location = try await drive.location()
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.location = location
                let discovery = try CloudBackupDiscovery(location: location)
                self.discovery = discovery
                for try await entries in discovery.updates {
                    try Task.checkCancellation()
                    guard self.generation == token else { return }
                    try await drive.verifyAccount(location.accountID)
                    guard self.generation == token, !Task.isCancelled else { return }
                    self.entries = entries
                    self.deadline?.cancel(); self.deadline = nil
                    if self.phase == .searching { self.phase = .ready }
                }
            } catch { OathDiagnostics.record(error);
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.stop()
                self.phase = .ready
                self.notice = Self.message(for: error)
            }
        }
    }

    func choose(_ entry: CloudBackupEntry) {
        guard !busy, location != nil, entries.contains(where: { $0.id == entry.id }) else { return }
        selected = entry; notice = nil; attempt = UUID()
    }

    func backToList() {
        operation?.cancel(); operation = nil
        selected = nil; notice = nil; attempt = UUID()
        phase = .ready
    }

    func restore(password: String, onRestore: @escaping @MainActor (OathRestoredWallet) async throws -> Void) {
        guard phase == .ready, let selected, let location else { return }
        let token = generation, attempt = self.attempt
        phase = .downloading; notice = nil
        operation = Task { [weak self, drive] in
            do {
                let data = try await drive.read(selected, at: location)
                try Task.checkCancellation()
                guard let self, self.generation == token, self.attempt == attempt else { return }
                self.phase = .decrypting
                let decryption = Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    let backup = try BackupDocument.open(data, password: password)
                    try Task.checkCancellation()
                    return try OathRestoredWallet(backup: backup)
                }
                let restored = try await withTaskCancellationHandler {
                    try await decryption.value
                } onCancel: { decryption.cancel() }
                try await drive.verifyAccount(location.accountID)
                try Task.checkCancellation()
                guard self.generation == token, self.attempt == attempt else { return }
                self.phase = .saving
                try await onRestore(restored)
                guard self.generation == token, self.attempt == attempt, !Task.isCancelled else { return }
                self.operation = nil
                self.phase = .completed
            } catch { OathDiagnostics.record(error);
                guard let self, self.generation == token, self.attempt == attempt, !Task.isCancelled else { return }
                self.operation = nil; self.phase = .ready
                self.notice = Self.message(for: error)
                self.attempt = UUID() // New empty secure field; never retain the failed password.
            }
        }
    }

    func stop() {
        generation = UUID()
        operation?.cancel(); operation = nil
        deadline?.cancel(); deadline = nil
        observation?.cancel(); observation = nil
        discovery?.stop(); discovery = nil
        location = nil; selected = nil; entries = []
        phase = .searching; notice = nil; attempt = UUID()
    }

    private static func message(for error: Error) -> OathStringKey {
        switch error {
        case CloudBackupError.authenticationFailed: .restoreWrongPassword
        case CloudBackupError.passwordTooShort, CloudBackupError.passwordTooLong: .restorePasswordDetail
        case CloudBackupError.unavailable: .cloudBackupUnavailable
        case CloudBackupError.accountChanged: .cloudBackupAccountChanged
        case CloudBackupError.invalidDocument, OathWalletError.invalidPhrase,
             OathWalletError.invalidPrivateKey, OathWalletError.derivationFailed: .restoreInvalidBackup
        case CloudBackupError.fileConflict: .restoreConflict
        case CloudRestoreError.missingFile: .restoreMissing
        case CloudRestoreError.downloadTimedOut, CloudRestoreError.downloadFailed: .restoreDownloadFailed
        case CloudRestoreError.discoveryFailed: .restoreDiscoveryFailed
        default: .restoreFailed
        }
    }
}
