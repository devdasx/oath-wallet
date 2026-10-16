import OathDiagnostics
import Foundation
import Observation

@MainActor @Observable final class OathSecurityModel {
    enum Action { case disablePasscode, changePasscode }
    enum Phase { case idle, verify, newPasscode }
    private(set) var phase: Phase = .idle
    private(set) var busy = false
    private(set) var authorization: UUID?
    private(set) var enrollBiometricsAfterPasscode = false
    var notice: OathStringKey?
    private var action: Action?
    private let session: OathWalletSession
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()

    init(session: OathWalletSession) { self.session = session }

    func begin(_ action: Action) {
        guard session.isUnlocked, !busy else { return }
        cancel()
        self.action = action
        phase = .verify
    }

    func enablePasscode() {
        guard session.isUnlocked, !session.security.passcodeEnabled, !busy else { return }
        cancel()
        enrollBiometricsAfterPasscode = true
        phase = .newPasscode
    }

    func verify(_ input: [UInt8], strings: OathLocalizer) {
        guard phase == .verify, !busy, let action, session.isUnlocked else { return }
        busy = true; notice = nil
        let token = generation
        work = Task { [weak self, session] in
            var digits = input
            defer { _ = digits.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
            do {
                let authorization = try await session.vault.authorizeSecurityChange(digits: digits)
                guard let self, self.generation == token, !Task.isCancelled else {
                    await session.vault.cancelSecurityAuthorization(authorization)
                    return
                }
                self.authorization = authorization
                switch action {
                case .changePasscode:
                    self.busy = false; self.phase = .newPasscode
                    return
                case .disablePasscode:
                    try await session.vault.setPasscode(nil, authorization: authorization)
                }
                try await session.refreshSecurity()
                guard self.generation == token else { return }
                OathHaptics.shared.play(.success)
                self.cancel()
            } catch { OathDiagnostics.record(error);
                await OathDiagnostics.attempt("refresh_security") { try await session.refreshSecurity() }
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.busy = false
                switch error as? OathWalletError {
                case .wrongPasscode: self.notice = .unlockIncorrect
                case .throttled: self.notice = .unlockWait
                default:
                    if error as? OathBiometricCredentialError == .cancelled { self.cancel() }
                    else { self.notice = .securityChangeFailed }
                }
            }
        }
    }

    func enableBiometrics(strings: OathLocalizer) {
        guard session.isUnlocked, session.security.passcodeEnabled,
              !session.security.biometricsEnabled, !busy, phase == .idle else { return }
        cancel()
        busy = true
        let token = generation
        work = Task { [weak self, session] in
            do {
                let result = try await session.vault.enableBiometrics(strings: strings)
                try await session.refreshSecurity()
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.busy = false; self.work = nil
                switch result {
                case .enabled: OathHaptics.shared.play(.success)
                case .failed(_, .cancelled): break
                default: self.notice = .securityChangeFailed
                }
            } catch { OathDiagnostics.record(error);
                await OathDiagnostics.attempt("refresh_security") { try await session.refreshSecurity() }
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.busy = false; self.work = nil
                if !(error is CancellationError) { self.notice = .securityChangeFailed }
            }
        }
    }

    func disableBiometrics() {
        guard session.isUnlocked, !busy else { return }
        busy = true
        let token = generation
        work = Task { [weak self, session] in
            do { try await session.vault.disableBiometrics() }
            catch { OathDiagnostics.record(error);
                if self?.generation == token, !Task.isCancelled { self?.notice = .securityChangeFailed }
            }
            await OathDiagnostics.attempt("refresh_security") { try await session.refreshSecurity() }
            guard self?.generation == token else { return }
            self?.busy = false
        }
    }

    func returnToVerification() {
        guard let action else { cancel(); return }
        busy = false
        begin(action)
    }

    func completed() { cancel() }

    func cancel() {
        generation = UUID()
        work?.cancel(); work = nil
        if let authorization { Task { [session] in await session.vault.cancelSecurityAuthorization(authorization) } }
        authorization = nil; busy = false; notice = nil; phase = .idle; action = nil
        enrollBiometricsAfterPasscode = false
    }
}

/// A visit-scoped gate, independent of the authorization for changing a PIN.
/// Leaving Security, backgrounding, or locking invalidates even late OS replies.
@MainActor @Observable final class OathSecurityAccessModel {
    enum Phase: Equatable { case idle, authenticating, passcode, authorized }
    private(set) var phase: Phase = .idle
    private(set) var busy = false
    var notice: OathStringKey?
    private let session: OathWalletSession
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()

    init(session: OathWalletSession) { self.session = session }

    var isAuthorized: Bool { phase == .authorized && session.isUnlocked }

    func begin(reason: String) {
        guard session.isUnlocked, !session.changingWallet, !busy else { return }
        cancel()
        phase = .authenticating
        authenticate(digits: nil, reason: reason)
    }

    func submit(_ input: [UInt8]) {
        guard phase == .passcode, input.count == 6, input.allSatisfy({ $0 <= 9 }) else { return }
        authenticate(digits: input, reason: "")
    }

    private func authenticate(digits: [UInt8]?, reason: String) {
        guard session.isUnlocked, !busy else { return }
        busy = true; notice = nil
        let token = generation
        work = Task { [weak self, session] in
            var digits = digits
            defer { if digits != nil { _ = digits!.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } } }
            do {
                try await session.vault.authenticateSecurityAccess(digits: digits, reason: reason)
                guard let self, self.generation == token, !Task.isCancelled, session.isUnlocked else { return }
                self.busy = false; self.work = nil; self.phase = .authorized
            } catch { OathDiagnostics.record(error);
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.busy = false; self.work = nil
                if error is CancellationError {
                    self.cancel()
                } else if error is OathBiometricCredentialError {
                    self.phase = .passcode
                } else if error as? OathWalletError == .wrongPasscode {
                    self.notice = .unlockIncorrect
                } else if case OathWalletError.throttled = error {
                    self.notice = .unlockWait
                } else {
                    self.cancel(); self.notice = .walletUnavailable
                }
            }
        }
    }

    func cancel() {
        generation = UUID()
        work?.cancel(); work = nil
        busy = false; notice = nil; phase = .idle
    }
}

struct OathSecurityPasscodeStore: OathPasscodeSaving {
    let session: OathWalletSession
    let authorization: UUID?
    func save(_ digits: [UInt8]) async throws {
        try await session.vault.setPasscode(digits, authorization: authorization)
        // The credential has committed even if the view has since disappeared.
        await OathDiagnostics.attempt("refresh_security") { try await session.refreshSecurity() }
    }
}

/// First-time passcode setup in Settings uses the same automatic enrollment
/// stage as onboarding. Changing an existing PIN preserves the user's choice.
struct OathSecurityBiometrics: OathBiometricsEnabling {
    let session: OathWalletSession
    let shouldEnroll: Bool

    func enableIfAvailable() async -> OathBiometricSetupResult {
        guard shouldEnroll else { return .unavailable }
        let result: OathBiometricSetupResult
        do { result = try await session.vault.enableBiometrics(strings: .current) }
        catch is CancellationError { result = .failed(kind: nil, reason: .interrupted) }
        catch { OathDiagnostics.record(error); result = .failed(kind: nil, reason: .storage) }
        await OathDiagnostics.attempt("refresh_security") { try await session.refreshSecurity() }
        return result
    }
}
