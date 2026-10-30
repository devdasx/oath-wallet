import OathDiagnostics
import Foundation
import Observation

struct OathWalletRemovalAction: Equatable, Sendable {
    let ids: Set<String>
    let permanently: Bool
    var resetsApp = false
    var recentlyDeletedIDs: Set<String> = []
}

@MainActor @Observable final class OathWalletRemovalModel {
    enum Phase: Equatable { case idle, authenticating, passcode, recentlyDeletedConfirmation, confirmation }
    private(set) var phase: Phase = .idle
    private(set) var busy = false
    private(set) var confirming = false
    private(set) var action: OathWalletRemovalAction?
    var notice: OathStringKey?
    @ObservationIgnored private var grant: UUID?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var work: Task<Void, Never>?
    private let session: OathWalletSession

    init(session: OathWalletSession) { self.session = session }

    func begin(_ action: OathWalletRemovalAction, reason: String) {
        guard session.isUnlocked, !session.changingWallet, !busy, !confirming, !action.ids.isEmpty else { return }
        cancel()
        var action = action
        let activeIDs = Set(session.wallets.map(\.id))
        if !action.permanently, !activeIDs.isEmpty, action.ids == activeIDs {
            // Bind both confirmations to exactly this membership. A wallet
            // added/restored while the alert is open must never be erased.
            action.resetsApp = true
            action.recentlyDeletedIDs = Set(session.recentlyDeletedWallets.map(\.id))
        }
        self.action = action
        phase = .authenticating
        authorize(digits: nil, reason: reason)
    }

    func submit(_ input: [UInt8]) {
        guard phase == .passcode, input.count == 6, input.allSatisfy({ $0 <= 9 }) else { return }
        authorize(digits: input, reason: "")
    }

    private func authorize(digits: [UInt8]?, reason: String) {
        guard let action, !busy, session.isUnlocked else { return }
        busy = true; notice = nil
        let token = generation
        work = Task { [weak self, session] in
            await OathDiagnostics.$operationID.withValue(UUID()) {
                var digits = digits
                defer { if digits != nil { _ = digits!.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } } }
                do {
                    let grant = try await session.vault.authorizeWalletRemoval(action, digits: digits, reason: reason)
                    guard let self, self.generation == token, !Task.isCancelled, session.isUnlocked else {
                        await session.vault.cancelWalletRemovalAuthorization(grant)
                        return
                    }
                    self.grant = grant
                    self.phase = action.resetsApp && !action.recentlyDeletedIDs.isEmpty
                        ? .recentlyDeletedConfirmation : .confirmation
                    self.busy = false; self.work = nil
                } catch {
                    guard let self, self.generation == token else { return }
                    self.busy = false; self.work = nil
                    // Expected biometric fallback and rejected app PINs are control
                    // flow. Corrupt protected credentials and OS failures still report.
                    if error is CancellationError {
                        self.cancel()
                    } else if let biometric = error as? OathBiometricCredentialError {
                        if !biometric.isExpectedAuthenticationOutcome {
                            OathDiagnostics.record(error, component: "wallet_lifecycle", operation: "authorize_removal", context: ["stage": "biometric"])
                        }
                        self.phase = .passcode
                    } else if case OathWalletError.wrongPasscode = error {
                        self.notice = .unlockIncorrect
                    } else if case OathWalletError.throttled = error {
                        self.phase = .passcode; self.notice = .unlockWait
                    } else {
                        OathDiagnostics.record(error, component: "wallet_lifecycle", operation: "authorize_removal")
                        self.cancel(); self.notice = .walletRemovalFailed
                    }
                }
            }
        }
    }

    func confirmRecentlyDeleted() {
        guard phase == .recentlyDeletedConfirmation, !busy, !confirming,
              session.isUnlocked, action?.resetsApp == true, grant != nil else { return }
        // Both native dialogs must be accepted before any destructive work.
        // Cancel on the final dialog still preserves Recently Deleted too.
        phase = .authenticating
        busy = true
        let token = generation
        work = Task { [weak self] in
            // Let the first native alert finish dismissing before presenting
            // the second. This task owns no mutation and cancellation is safe.
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            guard let self, self.generation == token else { return }
            guard self.session.isUnlocked else { self.cancel(); return }
            self.busy = false; self.work = nil; self.phase = .confirmation
        }
    }

    func confirm(onRemoved: ((OathWalletRemovalAction) -> Void)? = nil) {
        guard phase == .confirmation, let action, let grant, !busy, !confirming, session.isUnlocked else { return }
        confirming = true
        // A confirmed mutation belongs to the session; leaving the page must
        // not abandon a half-completed Keychain/SQL reconciliation.
        Task { [self, session] in
            await OathDiagnostics.$operationID.withValue(UUID()) {
                var removed = false
                do {
                    try await session.removeWallets(action, authorization: grant)
                    removed = !action.resetsApp || session.presentsOnboarding
                }
                catch { OathDiagnostics.record(error, component: "wallet_lifecycle", operation: "remove_wallets"); notice = .walletRemovalFailed }
                confirming = false
                cancel(preserveNotice: true)
                // Navigation follows committed deletion, never authentication or a
                // failed write. The session already emits the success haptic.
                if removed { onRemoved?(action) }
            }
        }
    }

    func cancel(preserveNotice: Bool = false) {
        guard !confirming else { return }
        generation = UUID(); work?.cancel(); work = nil; busy = false; phase = .idle
        if let grant { Task { [session] in await session.vault.cancelWalletRemovalAuthorization(grant) } }
        grant = nil; action = nil
        if !preserveNotice { notice = nil }
    }
}
