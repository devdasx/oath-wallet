import OathDiagnostics
import Foundation
import Observation
import OathCloudBackup
import OathBitcoin

/// Screen-local draft only. A passphrase is never put in a navigation path,
/// preferences, search history, wallet name or diagnostics. A confirmed wallet
/// preserves the existing recovery policy for each wallet type.
@MainActor @Observable final class OathPassphraseWalletModel {
    let sourceID: String
    let usesSeedPassword: Bool
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

    init(sourceID: String, session: OathWalletSession, usesSeedPassword: Bool = false) { self.sourceID = sourceID; self.session = session; self.usesSeedPassword = usesSeedPassword }

    var canSubmit: Bool {
        if usesSeedPassword {
            guard passphrase.utf8.count <= 4096, confirmation.utf8.count <= 4096 else { return false }
            let value = ElectrumMnemonic.normalize(passphrase)
            return !value.isEmpty && value == ElectrumMnemonic.normalize(confirmation)
        }
        guard let value = try? RecoveryPassphrase.normalized(passphrase),
              let repeated = try? RecoveryPassphrase.normalized(confirmation) else { return false }
        return value == repeated
    }
    var validationNotice: OathStringKey? {
        if usesSeedPassword {
            if passphrase.utf8.count > 4096 || confirmation.utf8.count > 4096 { return .passphraseTooLong }
            return !confirmation.isEmpty && !canSubmit ? .passphraseMismatch : nil
        }
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
        let token = generation, requestID = requestID, value = passphrase, usesSeedPassword = usesSeedPassword
        work = Task { [weak self, session, sourceID] in
            do {
                let id: String
                if usesSeedPassword {
                    id = try await OathDiagnostics.$chain.withValue("bitcoin") {
                        try await OathDiagnostics.$operationID.withValue(UUID()) {
                            try await session.addSeedPasswordWallet(sourceID: sourceID, password: value, requestID: requestID)
                        }
                    }
                } else { id = try await session.addPassphraseWallet(sourceID: sourceID, passphrase: value, requestID: requestID) }
                guard let self, token == self.generation else { return }
                guard !Task.isCancelled, session.isUnlocked else { self.cancel(); return }
                self.passphrase = ""; self.confirmation = ""
                self.createdWalletID = id; self.busy = false; self.work = nil
            } catch {
                guard let self, token == self.generation else { return }
                if Task.isCancelled || error is CancellationError { self.cancel(); return }
                self.busy = false; self.work = nil
                if case OathWalletError.duplicatePassphraseWallet(let id) = error {
                    self.duplicateWalletID = id; self.notice = .passphraseAlreadyExists
                } else {
                    if usesSeedPassword {
                        OathDiagnostics.record(DiagnosticFailure("electrum_password_wallet_failed"), component: "wallet", operation: "add_seed_password", context: ["chain": "bitcoin"])
                    } else { OathDiagnostics.record(error) }
                    self.notice = .walletChangeFailedDetail
                }
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
