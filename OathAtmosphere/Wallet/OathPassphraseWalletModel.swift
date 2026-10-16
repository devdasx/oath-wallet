import OathDiagnostics
import Foundation
import Observation
import OathCloudBackup

/// Screen-local draft only. A passphrase is never put in a navigation path,
/// preferences, search history, wallet name, network request or diagnostic.
@MainActor @Observable final class OathPassphraseWalletModel {
    let sourceID: String
    var passphrase = "" { didSet { if !busy { requestID = UUID(); edited() } } }
    var confirmation = "" { didSet { if !busy { edited() } } }
    private(set) var busy = false
    private(set) var dismissingKeyboard = false
    private(set) var createdWalletID: String?
    private(set) var duplicateWalletID: UUID?
    private(set) var notice: OathStringKey?
    @ObservationIgnored private var requestID = UUID()
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var work: Task<Void, Never>?
    private let session: OathWalletSession

    init(sourceID: String, session: OathWalletSession) { self.sourceID = sourceID; self.session = session }

    var canSubmit: Bool {
        guard let value = try? RecoveryPassphrase.normalized(passphrase),
              let repeated = try? RecoveryPassphrase.normalized(confirmation) else { return false }
        return value == repeated
    }
    var validationNotice: OathStringKey? {
        if !passphrase.isEmpty {
            do { _ = try RecoveryPassphrase.normalized(passphrase) }
            catch RecoveryPassphraseError.tooLong { return .passphraseTooLong }
            catch { OathDiagnostics.record(error); return .passphraseInvalid }
        }
        if !confirmation.isEmpty && !canSubmit { return .passphraseMismatch }
        return nil
    }

    func prepareSubmission() {
        guard !busy, session.isUnlocked, !session.changingWallet, canSubmit else { return }
        busy = true; notice = nil; duplicateWalletID = nil; dismissingKeyboard = true
    }

    func keyboardDismissed() {
        guard busy, dismissingKeyboard else { return }
        guard canSubmit, session.isUnlocked else { cancel(); return }
        dismissingKeyboard = false
        let token = generation, requestID = requestID, value = passphrase
        work = Task { [weak self, session, sourceID] in
            do {
                let id = try await session.addPassphraseWallet(sourceID: sourceID, passphrase: value, requestID: requestID)
                guard let self, token == self.generation else { return }
                guard !Task.isCancelled, session.isUnlocked else { self.cancel(); return }
                self.passphrase = ""; self.confirmation = ""
                self.createdWalletID = id; self.busy = false; self.work = nil
            } catch { OathDiagnostics.record(error);
                guard let self, token == self.generation else { return }
                if Task.isCancelled || error is CancellationError { self.cancel(); return }
                self.busy = false; self.work = nil
                if case OathWalletError.duplicatePassphraseWallet(let id) = error {
                    self.duplicateWalletID = id; self.notice = .passphraseAlreadyExists
                } else { self.notice = .walletChangeFailedDetail }
            }
        }
    }

    func cancel() {
        generation = UUID(); work?.cancel(); work = nil
        dismissingKeyboard = false
        passphrase = ""; confirmation = ""; busy = false
        createdWalletID = nil; duplicateWalletID = nil; notice = nil
    }

    private func edited() { notice = nil; duplicateWalletID = nil }
}
