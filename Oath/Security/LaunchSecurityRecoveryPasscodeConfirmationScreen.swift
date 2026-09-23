import SwiftUI

struct LaunchSecurityRecoveryPasscodeConfirmationScreen: View {
    let database: WalletDatabase
    let expectedPasscode: String
    let authorization: WalletLaunchSecurityRecoveryProof?
    let onRecovered: () -> Void

    @State private var isSaving = false
    @State private var entryIdentity = UUID()
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            WalletBackground()

            PasscodeResponsiveContainer {
                PINCodeEntryView(
                    length: 6,
                    isEnabled: !isSaving,
                    resetID: entryIdentity,
                    errorMessage: errorMessage,
                    errorFeedbackID: errorMessage == nil
                        ? nil
                        : entryIdentity,
                    prompt: {
                        SecurityPasscodeHeader(
                            title:
                                "security.recovery.passcode.confirm.title",
                            message: WalletLocalization.string(
                                "passcode.message.confirm"
                            ),
                            replacementIdentity: "recovery_confirm"
                        )
                    },
                    onComplete: confirm
                )
            }
        }
        .navigationTitle("passcode.navigation.confirm")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func confirm(_ passcode: String) {
        guard !isSaving else { return }
        guard PasscodeConfirmation.matches(
            confirmation: passcode,
            original: expectedPasscode
        ) else {
            errorMessage = WalletLocalization.string(
                "passcode.error.mismatch"
            )
            entryIdentity = UUID()
            return
        }
        guard let authorization else {
            showRecoveryError()
            return
        }

        isSaving = true
        errorMessage = nil
        Task {
            do {
                try await database.recoverPasscodeCredential(
                    passcode: passcode,
                    authorization: authorization
                )
                await PasscodeKeyboard.dismissBeforeTransition()
                UniHaptic.play(.success)
                onRecovered()
            } catch WalletLaunchSecurityRecoveryError
                .passcodeCredentialAvailable {
                await PasscodeKeyboard.dismissBeforeTransition()
                onRecovered()
            } catch {
                showRecoveryError()
            }
        }
    }

    private func showRecoveryError() {
        isSaving = false
        errorMessage = WalletLocalization.string(
            "security.recovery.passcode.error"
        )
        entryIdentity = UUID()
    }
}
