import SwiftUI

struct OnboardingPhysicalEntropyPasscodeState: Equatable, Sendable {
    enum Step: Equatable, Sendable {
        case enter
        case confirm
    }

    enum Submission: Equatable, Sendable {
        case awaitingConfirmation
        case confirmed(String)
        case mismatch
        case invalid
    }

    private(set) var step = Step.enter
    private var firstPasscode = ""

    mutating func submit(_ passcode: String) -> Submission {
        guard let draft = PasscodeDraft(passcode) else {
            reset()
            return .invalid
        }

        switch step {
        case .enter:
            firstPasscode = draft.value
            step = .confirm
            return .awaitingConfirmation

        case .confirm:
            guard PasscodeConfirmation.matches(
                confirmation: draft.value,
                original: firstPasscode
            ) else {
                reset()
                return .mismatch
            }

            firstPasscode = ""
            return .confirmed(draft.value)
        }
    }

    mutating func reset() {
        firstPasscode = ""
        step = .enter
    }
}

struct OnboardingPhysicalEntropyPasscodeScreen: View {
    let isSaving: Bool
    let onPasscodeConfirmed: (String) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var passcodeState =
        OnboardingPhysicalEntropyPasscodeState()
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
                    isEnabled: !isConfirmed && !isSaving,
                    resetID: entryIdentity,
                    errorMessage: mismatchMessage,
                    errorFeedbackID: mismatchMessage == nil
                        ? nil
                        : entryIdentity,
                    showsStaticLock: true,
                    replacementIdentity:
                        passcodeState.step == .enter
                            ? "set"
                            : "confirm",
                    replacementPosition:
                        passcodeState.step == .enter
                            ? .entry
                            : .confirmation,
                    prompt: {
                        PINStepHeader(
                            title: passcodeState.step == .enter
                                ? "passcode.title.set"
                                : "passcode.title.confirm",
                            message: passcodeState.step == .enter
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
        .navigationBarBackButtonHidden(isConfirmed || isSaving)
        .onAppear {
            guard isConfirmed else { return }
            replaceState {
                passcodeState.reset()
                mismatchMessage = nil
                isConfirmed = false
                entryIdentity = UUID()
            }
        }
        .onDisappear {
            completionTask?.cancel()
            completionTask = nil
            passcodeState.reset()
        }
    }

    private func handleCompletedPasscode(_ passcode: String) {
        var updatedState = passcodeState
        let submission = updatedState.submit(passcode)

        switch submission {
        case .awaitingConfirmation:
            UniHaptic.play(.passcodeComplete)
            replaceState {
                passcodeState = updatedState
                mismatchMessage = nil
                entryIdentity = UUID()
            }

        case let .confirmed(confirmedPasscode):
            UniHaptic.play(.passcodeComplete)
            replaceState {
                passcodeState = updatedState
                mismatchMessage = nil
                isConfirmed = true
                entryIdentity = UUID()
            }
            completionTask = Task { @MainActor in
                await PasscodeKeyboard.dismissBeforeTransition()
                guard !Task.isCancelled else { return }
                onPasscodeConfirmed(confirmedPasscode)
            }

        case .mismatch, .invalid:
            replaceState {
                passcodeState = updatedState
                mismatchMessage = WalletLocalization.string(
                    "passcode.error.mismatch"
                )
                isConfirmed = false
                entryIdentity = UUID()
            }
        }
    }

    private func replaceState(_ updates: () -> Void) {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.32)) {
            updates()
        }
    }
}
