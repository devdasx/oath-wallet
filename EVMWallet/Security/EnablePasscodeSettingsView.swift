import SwiftUI

struct EnablePasscodeSettingsView: View {
    let database: WalletDatabase
    let onEnabled: () -> Void

    private enum Step {
        case enter
        case confirm
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step: Step = .enter
    @State private var newPasscode = ""
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
                    showsStaticLock: true,
                    replacementIdentity: step == .enter
                        ? "set"
                        : "confirm",
                    replacementPosition: step == .enter
                        ? .entry
                        : .confirmation,
                    prompt: {
                        PINStepHeader(
                            title: titleKey,
                            message: message
                        )
                    },
                    onComplete: handleCompletedPasscode
                )
            }
        }
        .navigationTitle("passcode.navigation.set")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                WalletCloseButton {
                    dismiss()
                }
            }
        }
    }

    private var titleKey: LocalizedStringKey {
        step == .enter
            ? "passcode.title.set"
            : "passcode.title.confirm"
    }

    private var message: String {
        switch step {
        case .enter:
            EnglishNumbers.localized("passcode.message.set", 6)
        case .confirm:
            WalletLocalization.string("passcode.message.confirm")
        }
    }

    private func handleCompletedPasscode(_ passcode: String) {
        switch step {
        case .enter:
            UniHaptic.play(.passcodeComplete)
            replaceState {
                newPasscode = passcode
                errorMessage = nil
                step = .confirm
                entryIdentity = UUID()
            }
        case .confirm:
            confirmPasscode(passcode)
        }
    }

    private func confirmPasscode(_ confirmation: String) {
        guard PasscodeConfirmation.matches(
            confirmation: confirmation,
            original: newPasscode
        ) else {
            errorMessage = WalletLocalization.string(
                "passcode.error.mismatch"
            )
            entryIdentity = UUID()
            return
        }

        isSaving = true
        errorMessage = nil
        Task {
            do {
                try await database.enableAppLock(passcode: newPasscode)
                await PasscodeKeyboard.dismissBeforeTransition()
                UniHaptic.play(.success)
                onEnabled()
            } catch {
                isSaving = false
                errorMessage = enableErrorMessage(for: error)
                entryIdentity = UUID()
            }
        }
    }

    private func enableErrorMessage(for error: any Error) -> String {
        let failure = WalletPersistenceFailure(error: error)
        let actionableKeys = [
            "wallet.persistence.error.settings_missing",
            "wallet.persistence.error.settings_conflict",
            "wallet.persistence.error.secure_storage_locked",
            "wallet.persistence.error.secure_storage_unavailable",
            "wallet.persistence.error.secure_storage_entitlement",
            "wallet.persistence.error.storage_full",
            "wallet.persistence.error.database_busy",
            "wallet.persistence.error.database_write",
            "wallet.persistence.error.database_integrity",
            "wallet.persistence.error.database_constraint"
        ]
        guard actionableKeys.contains(failure.messageKey) else {
            return WalletLocalization.string(
                "settings.security.enable.error"
            )
        }
        return WalletLocalization.string(failure.messageKey)
    }

    private func replaceState(_ updates: () -> Void) {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.32)) {
            updates()
        }
    }
}
