import SwiftUI

struct LaunchSecurityRecoveryPasscodeScreen: View {
    let onPasscodeEntered: (String) -> Void

    @State private var isComplete = false

    var body: some View {
        ZStack {
            WalletBackground()

            PasscodeResponsiveContainer {
                PINCodeEntryView(
                    length: 6,
                    isEnabled: !isComplete,
                    prompt: {
                        SecurityPasscodeHeader(
                            title:
                                "security.recovery.passcode.set.title",
                            message: EnglishNumbers.localized(
                                "security.recovery.passcode.set.message",
                                6
                            ),
                            replacementIdentity: "recovery_set"
                        )
                    },
                    onComplete: complete
                )
            }
        }
        .navigationTitle("passcode.navigation.set")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func complete(_ passcode: String) {
        guard !isComplete else { return }
        isComplete = true
        UniHaptic.play(.passcodeComplete)
        Task { @MainActor in
            await PasscodeKeyboard.dismissBeforeTransition()
            onPasscodeEntered(passcode)
        }
    }
}
