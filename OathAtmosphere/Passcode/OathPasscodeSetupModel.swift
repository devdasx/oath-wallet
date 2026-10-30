import OathDiagnostics
import Foundation
import Observation

protocol OathPasscodeSaving: Sendable {
    func save(_ digits: [UInt8]) async throws
}

enum OathPasscodeSaveError: Error, Equatable, Sendable {
    case invalidPasscode
    case alreadyConfigured
    case deviceLocked
    case unavailable
}

/// Owns both entry steps. Views only receive a count, never the entered digits.
@MainActor @Observable
final class OathPasscodeSetupModel {
    enum Step: Equatable { case set, confirm }
    enum Phase: Equatable {
        case entering, advancing, mismatch, saving, awaitingBiometrics, enablingBiometrics, succeeded, cancelled
        case failed(OathPasscodeSaveError)
        case biometricsFailed
    }
    enum Notice: Equatable { case mismatch, interrupted }
    struct Timing: Sendable {
        var advance: Duration = .milliseconds(220)
        var mismatch: Duration = .milliseconds(720)
    }

    static let length = 6
    private(set) var step: Step = .set
    private(set) var phase: Phase = .entering
    private(set) var filledCount = 0
    private(set) var notice: Notice?
    private(set) var errorRevision = 0
    private(set) var successRevision = 0
    private(set) var biometricResult: OathBiometricSetupResult = .unavailable

    @ObservationIgnored private var digits: [UInt8] = []
    @ObservationIgnored private var candidate: [UInt8] = []
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private let store: any OathPasscodeSaving
    @ObservationIgnored private let biometrics: any OathBiometricsEnabling
    @ObservationIgnored private let timing: Timing
    @ObservationIgnored private var isActive = true
    @ObservationIgnored private var passcodeSaved = false
    @ObservationIgnored private var completionClaimed = false

    init(store: any OathPasscodeSaving, biometrics: any OathBiometricsEnabling, timing: Timing = .init()) {
        self.store = store
        self.biometrics = biometrics
        self.timing = timing
    }

    var acceptsInput: Bool { phase == .entering }
    var canDelete: Bool { acceptsInput && filledCount > 0 }
    var canLeave: Bool {
        phase != .saving && phase != .awaitingBiometrics && phase != .enablingBiometrics
    }

    /// A completed save/enrollment can advance beneath Face ID's finishing UI.
    /// Still defer real background completion and deliver navigation only once.
    func claimCompletion(isForeground: Bool) -> Bool {
        guard phase == .succeeded, isForeground, !completionClaimed else { return false }
        completionClaimed = true
        return true
    }

    /// Return true only when the navigation destination should be dismissed.
    /// Native swipe-back bypasses this button action and pops the destination.
    func backButtonPressed() -> Bool {
        guard canLeave else { return false }
        if step == .confirm && !passcodeSaved {
            reset(notice: nil)
            return false
        }
        cancel()
        return true
    }

    func enter(_ digit: Int) {
        guard acceptsInput, (0...9).contains(digit), digits.count < Self.length else { return }
        notice = nil
        digits.append(UInt8(digit))
        filledCount = digits.count
        guard filledCount == Self.length else { return }

        if step == .set {
            phase = .advancing
            let token = generation
            work = Task { [weak self, delay = timing.advance] in
                do { try await Task.sleep(for: delay) } catch { return }
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.candidate = self.digits
                self.clearEntry()
                self.step = .confirm
                self.phase = .entering
            }
        } else if candidate == digits {
            saveConfirmedPasscode()
        } else {
            // Discard both secrets immediately; hold the filled dots for the shake.
            clearSecrets()
            phase = .mismatch
            errorRevision &+= 1
            notice = .mismatch
            let token = generation
            work = Task { [weak self, delay = timing.mismatch] in
                do { try await Task.sleep(for: delay) } catch { return }
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.filledCount = 0
                self.step = .set
                self.phase = .entering
            }
        }
    }

    func deleteLast() {
        guard canDelete else { return }
        digits[digits.count - 1] = 0
        digits.removeLast()
        filledCount = digits.count
    }

    func startOver() {
        guard canLeave, !passcodeSaved, phase != .succeeded, phase != .cancelled else { return }
        reset(notice: nil)
    }

    func acknowledgeNotice() { notice = nil }

    func retry() {
        guard case .failed = phase else { return }
        reset(notice: nil)
    }

    func suspend() {
        isActive = false
        // A Keychain commit is atomic. Let an in-flight commit finish and report its
        // result on return, instead of reporting cancellation after a successful save.
        // The native biometric sheet may make the app inactive. It must never
        // reset a saved passcode or interrupt its own authentication request.
        guard canLeave, !passcodeSaved, phase != .succeeded, phase != .cancelled else { return }
        if case .failed = phase { return }
        let wasInProgress = filledCount > 0 || step == .confirm
        reset(notice: wasInProgress ? .interrupted : notice)
    }

    func resume() {
        isActive = true
        if phase == .awaitingBiometrics { enableBiometrics() }
    }

    func retryBiometrics() {
        guard phase == .biometricsFailed, passcodeSaved else { return }
        phase = .awaitingBiometrics
        if isActive { enableBiometrics() }
    }

    func continueWithPasscode() {
        guard phase == .biometricsFailed, passcodeSaved else { return }
        complete()
    }

    func cancel() {
        guard canLeave else { return }
        invalidateWork()
        clearSecrets()
        filledCount = 0
        notice = nil
        phase = .cancelled
    }

    private func saveConfirmedPasscode() {
        phase = .saving
        var confirmed = candidate
        clearSecrets()
        let token = generation
        work = Task { [weak self, store] in
            defer { _ = confirmed.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
            do {
                try await store.save(confirmed)
                guard let self, self.generation == token else { return }
                self.passcodeSaved = true
                self.phase = .awaitingBiometrics
                if self.isActive { self.enableBiometrics() }
            } catch { OathDiagnostics.record(error);
                guard let self, self.generation == token else { return }
                self.filledCount = 0
                self.phase = .failed(error as? OathPasscodeSaveError ?? .unavailable)
                self.errorRevision &+= 1
            }
        }
    }

    private func enableBiometrics() {
        guard phase == .awaitingBiometrics, isActive, passcodeSaved else { return }
        phase = .enablingBiometrics
        let token = generation
        work = Task { [weak self, biometrics] in
            let result = await biometrics.enableIfAvailable()
            guard let self, self.generation == token else { return }
            self.biometricResult = result
            switch result {
            case .enabled, .unavailable: self.complete()
            case .failed:
                self.phase = .biometricsFailed
                self.errorRevision &+= 1
            }
        }
    }

    private func complete() {
        phase = .succeeded
        successRevision &+= 1
    }

    private func reset(notice: Notice?) {
        invalidateWork()
        clearSecrets()
        filledCount = 0
        step = .set
        phase = .entering
        self.notice = notice
    }

    private func invalidateWork() {
        generation = UUID()
        work?.cancel()
        work = nil
    }

    private func clearEntry() {
        _ = digits.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) }
        digits.removeAll(keepingCapacity: false)
        filledCount = 0
    }

    private func clearSecrets() {
        _ = digits.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) }
        _ = candidate.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) }
        digits.removeAll(keepingCapacity: false)
        candidate.removeAll(keepingCapacity: false)
    }
}
