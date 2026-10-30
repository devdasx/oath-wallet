import SwiftUI
import UIKit
import OathCloudBackup

/// A page in the existing Settings flow, with native secure fields and focus.
struct OathBackupPasswordForm: View {
    let onConfirm: (String) -> Void
    @Environment(\.oathLocalizer) private var strings
    @State private var password = ""
    @State private var confirmation = ""
    @State private var submitting = false
    @State private var focus: Field?

    private enum Field: Hashable { case password, confirmation }
    private var canSubmit: Bool {
        (try? BackupDocument.validate(password: password)) != nil && password == confirmation
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            OathSettingsIntroduction(icon: "lock.icloud", text: strings.text(.cloudBackupPasswordDetail))

            OathInputGroup {
                OathSecureInput(text: $password, title: strings.text(.cloudBackupPassword),
                                      identifier: "cloudBackup.password", returnKey: .next,
                                      wantsFocus: focus == .password, resignsFocus: focus == nil,
                                      onFocus: { focus = .password }, onDismissKeyboard: { focus = nil }, onSubmit: { focus = .confirmation })
                    .oathInputRow()
                OathInputSeparator()
                OathSecureInput(text: $confirmation, title: strings.text(.cloudBackupConfirmPassword),
                                      identifier: "cloudBackup.confirmPassword", returnKey: .go,
                                      wantsFocus: focus == .confirmation, resignsFocus: focus == nil,
                                      onFocus: { focus = .confirmation }, onDismissKeyboard: { focus = nil }, onSubmit: submit)
                    .oathInputRow()
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .disabled(submitting)

            if !confirmation.isEmpty && password != confirmation {
                Text(strings.text(.cloudBackupPasswordMismatch))
                    .oathFont(.footnote).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            submitButton
                .oathActionArea(existingInset: 20)
                .disabled(!canSubmit || submitting)
                .accessibilityIdentifier("cloudBackup.submit")
        }
        .accessibilityIdentifier("cloudBackup.passwordForm")
        .oathAutofocus(when: !submitting) {
            if focus == nil { focus = .password }
        }
        .background {
            OathKeyboardDismissal(requested: submitting) {
                guard submitting, canSubmit else { return }
                let value = password
                password = ""; confirmation = ""
                onConfirm(value)
            }
            .frame(width: 0, height: 0)
        }
        .onDisappear {
            submitting = false
            focus = nil
            password = ""; confirmation = ""
        }
    }

    private var submitButton: some View {
        OathActionButton(title: strings.text(.cloudBackupStart), action: submit)
    }

    private func submit() {
        guard !submitting else { return }
        guard canSubmit else {
            OathHaptics.shared.play(.error)
            return
        }
        submitting = true
        focus = nil
    }
}
