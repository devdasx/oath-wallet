import SwiftUI

struct ChangePasscodeSettingsView: View {
    let database: WalletDatabase

    private enum Step {
        case current
        case new
        case confirm
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var lockout = PasscodeLockoutCountdownModel()
    @State private var step: Step = .current
    @State private var currentPasscode = ""
    @State private var newPasscode = ""
    @State private var entryIdentity = UUID()
    @State private var replacementPosition:
        PasscodeStepReplacementPosition = .entry
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var lockoutFeedbackID: UUID?

    var body: some View {
        ZStack {
            WalletBackground()

            PasscodeResponsiveContainer {
                PINCodeEntryView(
                    length: 6,
                    isEnabled: isPasscodeEntryEnabled,
                    resetID: entryIdentity,
                    errorMessage: presentedErrorMessage,
                    errorFeedbackID: lockout.isLockedOut
                        ? lockoutFeedbackID
                        : errorMessage == nil ? nil : entryIdentity,
                    isLockedOut: lockout.isLockedOut,
                    lockoutRemainingSeconds: lockout.remainingSeconds,
                    showsStaticLock: true,
                    replacementIdentity: replacementIdentity,
                    replacementPosition: replacementPosition,
                    prompt: {
                        PINStepHeader(
                            title: titleKey,
                            message: WalletLocalization.string(
                                messageKey
                            )
                        )
                    },
                    onComplete: handlePasscode
                )
            }
        }
        .navigationTitle(
            step == .current
                ? LocalizedStringKey("security.authentication.navigation_title")
                : LocalizedStringKey("settings.security.change_passcode")
        )
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await refreshLockoutState()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                await refreshLockoutState()
            }
        }
    }

    private var isPasscodeEntryEnabled: Bool {
        lockout.hasResolvedState
            && !lockout.isLockedOut
            && !isWorking
    }

    private var presentedErrorMessage: String? {
        guard let seconds = lockout.remainingSeconds else {
            return errorMessage
        }
        return PasscodeLockoutMessageFormatter.message(
            remainingSeconds: seconds
        )
    }

    private var replacementIdentity: String {
        switch step {
        case .current:
            "current"
        case .new:
            "new"
        case .confirm:
            "confirm"
        }
    }

    private var titleKey: LocalizedStringKey {
        switch step {
        case .current:
            "security.authentication.passcode.title"
        case .new:
            "settings.security.change.new.title"
        case .confirm:
            "settings.security.change.confirm.title"
        }
    }

    private var messageKey: String {
        switch step {
        case .current:
            "settings.security.change.current.message"
        case .new:
            "settings.security.change.new.message"
        case .confirm:
            "settings.security.change.confirm.message"
        }
    }

    private func handlePasscode(_ passcode: String) {
        errorMessage = nil
        lockoutFeedbackID = nil
        guard !lockout.isLockedOut else { return }
        switch step {
        case .current:
            verifyCurrentPasscode(passcode)
        case .new:
            guard passcode != currentPasscode else {
                showError(
                    WalletLocalization.string(
                        "settings.security.change.same.error"
                    )
                )
                return
            }
            currentStepUpdate {
                newPasscode = passcode
                step = .confirm
                replacementPosition = .confirmation
                entryIdentity = UUID()
            }
        case .confirm:
            guard passcode == newPasscode else {
                currentStepUpdate {
                    newPasscode = ""
                    step = .new
                    replacementPosition = .entry
                    entryIdentity = UUID()
                    errorMessage = WalletLocalization.string(
                        "passcode.error.mismatch"
                    )
                }
                return
            }
            saveNewPasscode(passcode)
        }
    }

    private func verifyCurrentPasscode(_ passcode: String) {
        isWorking = true
        Task {
            do {
                let result = try await database.authenticatePasscode(passcode)
                switch result {
                case .success:
                    currentStepUpdate {
                        currentPasscode = passcode
                        step = .new
                        replacementPosition = .intermediate
                        isWorking = false
                        entryIdentity = UUID()
                    }
                case .incorrect:
                    showError(
                        WalletLocalization.string(
                            "security.authentication.passcode.error"
                        )
                    )
                case let .locked(until):
                    showLockout(until: until)
                }
            } catch {
                showError(
                    WalletLocalization.string(
                        "security.authentication.unavailable"
                    )
                )
            }
        }
    }

    private func saveNewPasscode(_ confirmation: String) {
        guard confirmation == newPasscode else { return }
        isWorking = true
        Task { @MainActor in
            do {
                try await database.changePasscode(
                    currentPasscode: currentPasscode,
                    newPasscode: newPasscode
                )
                await PasscodeKeyboard.dismissBeforeTransition()
                currentPasscode = ""
                newPasscode = ""
                isWorking = false
                errorMessage = nil
                UniHaptic.play(.success)
                dismiss()
            } catch {
                currentStepUpdate {
                    newPasscode = ""
                    isWorking = false
                    step = .current
                    replacementPosition = .entry
                    entryIdentity = UUID()
                    errorMessage = WalletLocalization.string(
                        "settings.security.change.error"
                    )
                }
            }
        }
    }

    private func showError(_ message: String) {
        currentStepUpdate {
            isWorking = false
            errorMessage = message
            entryIdentity = UUID()
        }
    }

    private func showLockout(until deadline: Date) {
        isWorking = false
        errorMessage = nil
        let feedbackID = UUID()
        entryIdentity = feedbackID
        lockoutFeedbackID = feedbackID
        lockout.begin(until: deadline)
    }

    @MainActor
    private func refreshLockoutState() async {
        await lockout.refresh(from: database)
        guard lockout.isLockedOut else { return }
        isWorking = false
        errorMessage = nil
        lockoutFeedbackID = nil
        entryIdentity = UUID()
    }

    private func currentStepUpdate(_ update: () -> Void) {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.32)) {
            update()
        }
    }
}
