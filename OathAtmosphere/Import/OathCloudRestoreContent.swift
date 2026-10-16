import SwiftUI
import OathCloudBackup

/// The same rows and password page are used by Welcome, the wallet switcher
/// and Settings. Their existing native navigation containers own presentation.
struct OathCloudRestoreList: View {
    let model: OathCloudRestoreModel
    let onChoose: (CloudBackupEntry) -> Void
    @Environment(\.oathLocalizer) private var strings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.phase == .searching {
                ProgressView(strings.text(.restoreSearching))
                    .frame(maxWidth: .infinity).padding(32)
            } else if let notice = model.notice, model.selected == nil {
                OathEmptyState(title: strings.text(.restoreICloud), systemImage: "icloud.slash",
                               description: strings.text(notice)) {
                    OathActionButton(title: strings.text(.tryAgain), appearance: .secondary) { model.start() }
                        .oathActionArea()
                }
            } else if model.entries.isEmpty {
                OathEmptyState(title: strings.text(.noBackups), systemImage: "icloud",
                               description: strings.text(.noBackupsDetail)) {
                    OathActionButton(title: strings.text(.tryAgain), appearance: .secondary) { model.stop(); model.start() }
                        .oathActionArea()
                }
            } else {
                Text(strings.text(.restoreChooseDetail))
                    .oathFont(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20).padding(.vertical, 12)
                ForEach(Array(model.entries.enumerated()), id: \.element.id) { index, entry in
                    OathButton { onChoose(entry) } label: {
                        OathSettingsRow(title: strings.format(.restoreBackupNumber, strings.number(index + 1)), icon: "lock.icloud",
                            subtitle: entry.modifiedAt.map {
                                $0.formatted(.dateTime.year().month().day().hour().minute().locale(strings.language.locale))
                            })
                    }
                    .buttonStyle(OathSettingsRowButtonStyle())
                    .accessibilityIdentifier("cloudRestore.backup.\(index)")
                }
            }
        }
        .oathFont(.body)
        .accessibilityIdentifier("cloudRestore.list")
    }
}

struct OathCloudRestorePasswordPage: View {
    let model: OathCloudRestoreModel
    let onRestore: @MainActor (OathRestoredWallet) async throws -> Void
    @Environment(\.oathLocalizer) private var strings

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if model.phase == .completed {
                Label(strings.text(.restoreComplete), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).frame(maxWidth: .infinity).padding(.vertical, 44)
            } else if model.busy {
                ProgressView(value: model.downloadProgress) {
                    Text(strings.text(progressTitle))
                }
                .frame(maxWidth: .infinity).padding(.vertical, 44)
                .accessibilityIdentifier("cloudRestore.progress")
            } else {
                if let date = model.selected?.modifiedAt {
                    Text(date.formatted(.dateTime.year().month().day().hour().minute().locale(strings.language.locale)))
                        .oathFont(.subheadline).foregroundStyle(.secondary)
                }
                OathRestorePasswordForm(notice: model.notice) {
                    model.restore(password: $0, onRestore: onRestore)
                }
                .id(model.attempt)
            }
        }
        .oathFont(.body)
        .padding(20)
        .oathErrorFeedback(model.notice)
        .oathHapticFeedback(.success, trigger: model.phase, when: model.phase == .completed)
        .accessibilityIdentifier("cloudRestore.passwordPage")
    }

    private var progressTitle: OathStringKey {
        switch model.phase {
        case .downloading: .restoreDownloading
        case .decrypting: .restoreDecrypting
        case .saving: .restoreSaving
        default: .restoreSearching
        }
    }
}

private struct OathRestorePasswordForm: View {
    let notice: OathStringKey?
    let onSubmit: (String) -> Void
    @Environment(\.oathLocalizer) private var strings
    @State private var password = ""
    @State private var focused = false
    @State private var submitting = false
    private var canSubmit: Bool { (try? BackupDocument.validate(password: password)) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            OathSettingsIntroduction(icon: "lock.icloud", text: strings.text(.restorePasswordDetail))
            OathSecureInput(text: $password, title: strings.text(.cloudBackupPassword),
                identifier: "cloudRestore.password", returnKey: .go,
                wantsFocus: focused, resignsFocus: !focused,
                onFocus: { focused = true }, onDismissKeyboard: { focused = false }, onSubmit: submit,
                isExistingPassword: true)
                .oathSettingsField()
                .disabled(submitting)
            if let notice {
                Text(strings.text(notice))
                    .oathFont(.footnote).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("cloudRestore.error")
            }
            restoreButton
                .oathActionArea(existingInset: 20)
                .disabled(!canSubmit || submitting)
                .accessibilityIdentifier("cloudRestore.submit")
        }
        .background {
            OathKeyboardDismissal(requested: submitting) {
                guard submitting, canSubmit else { return }
                let value = password
                password = ""
                onSubmit(value)
            }.frame(width: 0, height: 0)
        }
        .onDisappear { password = ""; focused = false; submitting = false }
        .oathAutofocus(when: !submitting) { focused = true }
    }

    private var restoreButton: some View {
        OathActionButton(title: strings.text(.restoreAction), action: submit)
    }

    private func submit() {
        guard canSubmit, !submitting else { return }
        focused = false; submitting = true
    }
}
