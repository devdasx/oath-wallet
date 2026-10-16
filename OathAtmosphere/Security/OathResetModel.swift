import OathDiagnostics
import Foundation
import Observation

@MainActor @Observable final class OathResetModel {
    enum Phase: Equatable { case idle, authenticating, passcode, warning }
    private(set) var phase: Phase = .idle
    private(set) var busy = false
    private(set) var confirming = false
    var notice: OathStringKey?
    @ObservationIgnored private var grant: UUID?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var work: Task<Void, Never>?
    private let session: OathWalletSession

    init(session: OathWalletSession) { self.session = session }

    func begin(reason: String) {
        guard session.isUnlocked, !session.changingWallet, !busy, !confirming else { return }
        cancel()
        phase = .authenticating
        authorize(digits: nil, reason: reason)
    }

    func submit(_ input: [UInt8]) {
        guard phase == .passcode, input.count == 6, input.allSatisfy({ $0 <= 9 }) else { return }
        authorize(digits: input, reason: "")
    }

    private func authorize(digits: [UInt8]?, reason: String) {
        guard !busy, session.isUnlocked else { return }
        busy = true; notice = nil
        let token = generation
        work = Task { [weak self, session] in
            var digits = digits
            defer { if digits != nil { _ = digits!.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } } }
            do {
                let grant = try await session.vault.authorizeReset(digits: digits, reason: reason)
                guard let self, self.generation == token, !Task.isCancelled, session.isUnlocked else {
                    await session.vault.cancelResetAuthorization(grant)
                    return
                }
                self.grant = grant; self.phase = .warning; self.busy = false; self.work = nil
            } catch { OathDiagnostics.record(error);
                guard let self, self.generation == token else { return }
                self.busy = false; self.work = nil
                if error is CancellationError {
                    self.cancel()
                } else if error is OathBiometricCredentialError {
                    self.phase = .passcode
                } else if case OathWalletError.wrongPasscode = error {
                    self.notice = .unlockIncorrect
                } else if case OathWalletError.throttled = error {
                    self.notice = .unlockWait
                } else {
                    self.cancel(); self.notice = .resetAuthorizationFailed
                }
            }
        }
    }

    func confirm() {
        guard phase == .warning, let grant, !busy, !confirming, session.isUnlocked else { return }
        confirming = true
        // The session owns the confirmed reset. Navigating away or removing
        // Settings from the view tree must not cancel an erase in progress.
        Task { [self, session] in
            do { try await session.resetApp(authorization: grant) }
            catch { OathDiagnostics.record(error); notice = .resetAuthorizationFailed }
            confirming = false
            cancel(preserveNotice: true)
        }
    }

    func cancel(preserveNotice: Bool = false) {
        guard !confirming else { return }
        generation = UUID(); work?.cancel(); work = nil; busy = false; phase = .idle
        if let grant { Task { [session] in await session.vault.cancelResetAuthorization(grant) } }
        grant = nil
        if !preserveNotice { notice = nil }
    }
}
