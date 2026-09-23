import SwiftUI

struct OnboardingImportPasscodeScreen: View {
    let onPasscodeConfirmed: @MainActor (String) async -> Void

    private enum Step {
        case enter
        case confirm
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step: Step = .enter
    @State private var firstPasscode = ""
    @State private var entryIdentity = UUID()
    @State private var mismatchMessage: String?
    @State private var isConfirmed = false
    @State private var completionTask: Task<Void, Never>?

    private let passcodeLength = PasscodeDraft.requiredLength

    var body: some View {
        ZStack {
            WalletBackground()

            PasscodeResponsiveContainer {
                PINCodeEntryView(
                    length: passcodeLength,
                    isEnabled: !isConfirmed,
                    resetID: entryIdentity,
                    errorMessage: mismatchMessage,
                    errorFeedbackID: mismatchMessage == nil
                        ? nil
                        : entryIdentity,
                    showsStaticLock: true,
                    replacementIdentity: step == .enter
                        ? "set"
                        : "confirm",
                    replacementPosition: step == .enter
                        ? .entry
                        : .confirmation,
                    prompt: {
                        PINStepHeader(
                            title: step == .enter
                                ? "passcode.title.set"
                                : "passcode.title.confirm",
                            message: step == .enter
                                ? EnglishNumbers.localized(
                                    "passcode.message.set",
                                    passcodeLength
                                )
                                : WalletLocalization.string(
                                    "passcode.message.confirm"
                                )
                        )
                    },
                    onComplete: handleCompletedPasscode
                )
            }
        }
        .navigationTitle("passcode.navigation.set")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isConfirmed)
        .onDisappear {
            completionTask?.cancel()
            completionTask = nil
            firstPasscode = ""
            step = .enter
            mismatchMessage = nil
            isConfirmed = false
            entryIdentity = UUID()
        }
    }

    private func handleCompletedPasscode(_ passcode: String) {
        switch step {
        case .enter:
            UniHaptic.play(.passcodeComplete)
            replaceState {
                firstPasscode = passcode
                mismatchMessage = nil
                step = .confirm
                entryIdentity = UUID()
            }
        case .confirm:
            if PasscodeConfirmation.matches(
                confirmation: passcode,
                original: firstPasscode
            ) {
                UniHaptic.play(.passcodeComplete)
                replaceState {
                    firstPasscode = ""
                    isConfirmed = true
                    entryIdentity = UUID()
                }
                completionTask = Task { @MainActor in
                    await PasscodeKeyboard.dismissBeforeTransition()
                    guard !Task.isCancelled else { return }
                    await onPasscodeConfirmed(passcode)
                }
            } else {
                replaceState {
                    firstPasscode = ""
                    mismatchMessage = WalletLocalization.string(
                        "passcode.error.mismatch"
                    )
                    isConfirmed = false
                    step = .enter
                    entryIdentity = UUID()
                }
            }
        }
    }

    private func replaceState(_ updates: () -> Void) {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.32)) {
            updates()
        }
    }
}
