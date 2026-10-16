import SwiftUI
import LocalAuthentication

/// Foreground content for the native over-full-screen lock presentation.
/// It deliberately has no background: UIKit blurs the actual screen beneath it.
struct OathWalletUnlockScreen: View {
    let session: OathWalletSession
    let isVisible: Bool
    @Environment(\.oathLocalizer) private var strings
    @Environment(\.scenePhase) private var scenePhase
    @State private var digits: [UInt8] = []
    // Retain only the visual completion, never the entered PIN, during reveal.
    @State private var showsAcceptedPasscode = false
    @State private var automaticPrompt = OathAutomaticBiometricPrompt()
    @State private var availableBiometrics: OathNumericKeypad.Biometrics?

    private var biometrics: OathNumericKeypad.Biometrics? {
        session.biometricRepairNeeded || !session.security.biometricsEnabled ? nil : availableBiometrics
    }

    private var filledPINCount: Int { showsAcceptedPasscode ? 6 : digits.count }
    private var hasPasscodeError: Bool { session.notice == .unlockIncorrect || session.notice == .unlockWait }

    var body: some View {
        OathPasscodeEntry(title: strings.text(.unlockPasscodeTitle), filledCount: filledPINCount,
            isEnabled: !session.busy && scenePhase == .active && isVisible,
            isDeleteEnabled: !digits.isEmpty, biometrics: biometrics,
            errorMessage: hasPasscodeError ? session.notice.map { strings.text($0) } : nil,
            isPresented: isVisible,
            titleIdentifier: "wallet.unlock.title", pinsIdentifier: "wallet.unlock.dots", onKey: handleKey)
        .accessibilityIdentifier("wallet.unlock")
        .alert(strings.text(.unlockWallet), isPresented: Binding(
            get: { session.notice != nil && !hasPasscodeError && scenePhase == .active && isVisible },
            set: { if !$0 && !hasPasscodeError { session.notice = nil } }
        )) {
            if #available(iOS 26.0, *) {
                OathButton(role: .confirm) { session.notice = nil }
                    .accessibilityLabel(strings.text(.done))
                    .accessibilityIdentifier("confirmation.done")
                    .oathConfirmationControl()
            } else {
                OathButton(strings.text(.done)) { session.notice = nil }
                    .accessibilityIdentifier("confirmation.done")
                    .oathConfirmationControl()
            }
        } message: {
            if let notice = session.notice { Text(strings.text(notice)) }
        }
        .oathErrorFeedback(hasPasscodeError ? nil : session.notice)
        .task { await automaticallyUnlockIfNeeded() }
        .onChange(of: isVisible) { _, visible in
            if visible { Task { await automaticallyUnlockIfNeeded() } }
            else { resetInput() }
        }
        .onChange(of: session.isLocked) { _, locked in
            if locked { resetInput() }
            else if isVisible { OathHaptics.shared.play(.success) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { resetInput() }
            if phase == .background { automaticPrompt.didEnterBackground() }
            if phase == .active { Task { await automaticallyUnlockIfNeeded() } }
        }
        .onDisappear { resetInput() }
    }

    private func handleKey(_ key: OathNumericKeypad.Key) {
        guard isVisible, scenePhase == .active, session.isLocked, !session.busy else { return }
        switch key {
        case .digit(let digit):
            guard digits.count < 6 else { return }
            if hasPasscodeError { session.notice = nil }
            automaticPrompt.userChoseAuthentication()
            digits.append(UInt8(digit))
            if digits.count == 6 {
                var entry = digits
                Task {
                    await session.unlock(entry)
                    _ = entry.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) }
                    showsAcceptedPasscode = !session.isLocked && isVisible && scenePhase == .active
                    clearDigits()
                }
            }
        case .delete:
            if !digits.isEmpty { digits.removeLast() }
        case .biometrics:
            if hasPasscodeError { session.notice = nil }
            automaticPrompt.userChoseAuthentication()
            clearDigits()
            Task { await session.unlockWithBiometrics() }
        }
    }

    private func clearDigits() {
        _ = digits.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) }
        digits.removeAll()
    }

    private func resetInput() {
        showsAcceptedPasscode = false
        if hasPasscodeError { session.notice = nil }
        clearDigits()
    }

    private func automaticallyUnlockIfNeeded() async {
        guard !Task.isCancelled, isVisible, scenePhase == .active, session.isLocked else { return }
        // Probe once on presentation/activation, not on every digit or redraw.
        let context = LAContext()
        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) {
            availableBiometrics = context.biometryType == .faceID ? .faceID : .touchID
        } else { availableBiometrics = nil }
        // Still discover the biometric button above when automatic prompting is
        // suppressed, so a manually locked wallet can use Face ID on demand.
        guard session.allowsAutomaticBiometricUnlock,
              automaticPrompt.claim(isActive: true, isBusy: session.busy,
                                    canUseBiometrics: biometrics != nil,
                                    hasPasscodeInput: !digits.isEmpty,
                                    hasNotice: session.notice != nil) else { return }
        await session.unlockWithBiometrics(automatically: true)
    }
}
