import SwiftUI

struct OathPassphraseIntroductionPage: View {
    let walletName: String
    let onContinue: () -> Void
    @Environment(\.oathLocalizer) private var strings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Image(systemName: "key.horizontal")
                    .font(.system(size: 38, weight: .medium))
                    .frame(width: 76, height: 76)
                    .background(Color(uiColor: OathSurfaceColors.field), in: .rect(cornerRadius: 24))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 10) {
                    Text(strings.text(.passphraseIntroTitle)).oathFont(.title, weight: .semibold)
                    Text(walletName).oathFont(.body).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                }
                OathSettingsIntroduction(icon: "square.3.layers.3d", text: strings.text(.passphraseIntroSeparate))
                OathSettingsIntroduction(icon: "textformat.abc", text: strings.text(.passphraseIntroExact))
                OathSettingsIntroduction(icon: "lock.shield", text: strings.text(.passphraseIntroRecovery))
                Text(strings.text(.passphraseStorageDetail)).oathFont(.footnote).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(24).frame(maxWidth: 600, alignment: .leading).frame(maxWidth: .infinity)
        }
        .oathBottomActions {
            OathActionButton(title: strings.text(.passphraseContinue), action: onContinue)
        }
        .accessibilityIdentifier("passphrase.introduction")
    }
}

struct OathPassphraseWalletPage: View {
    let session: OathWalletSession
    let onCreated: (String) -> Void
    let onOpenExisting: (UUID) -> Void
    @State private var model: OathPassphraseWalletModel
    @State private var focus: Field?
    @Environment(\.oathLocalizer) private var strings
    @Environment(\.scenePhase) private var scenePhase
    private enum Field { case passphrase, confirmation }

    init(session: OathWalletSession, sourceID: String, usesSeedPassword: Bool = false, onCreated: @escaping (String) -> Void,
         onOpenExisting: @escaping (UUID) -> Void) {
        self.session = session; self.onCreated = onCreated; self.onOpenExisting = onOpenExisting
        _model = State(initialValue: OathPassphraseWalletModel(sourceID: sourceID, session: session, usesSeedPassword: usesSeedPassword))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(strings.text(model.usesSeedPassword ? .seedPasswordDetail : .passphraseEntryDetail)).oathFont(.body).foregroundStyle(.secondary)
                OathInputGroup {
                    field(title: model.usesSeedPassword ? .seedPasswordLabel : .walletPassphrase, text: $model.passphrase, field: .passphrase)
                    OathInputSeparator()
                    field(title: model.usesSeedPassword ? .seedPasswordConfirm : .passphraseConfirm, text: $model.confirmation, field: .confirmation)
                }
                .disabled(model.busy)
                Text(strings.text(model.usesSeedPassword ? .seedPasswordNormalization : .passphraseIntroExact)).oathFont(.footnote).foregroundStyle(.secondary)
                if let notice = model.notice ?? model.validationNotice {
                    Text(strings.text(notice)).oathFont(.footnote).foregroundStyle(.red)
                        .accessibilityIdentifier("passphrase.notice")
                }
                OathActionButton(title: strings.text(model.usesSeedPassword ? .seedPasswordCreate : .passphraseCreate), isWorking: model.busy, action: submit)
                    .disabled(!model.canSubmit || model.busy || !session.isUnlocked || session.changingWallet)
                    .accessibilityIdentifier("passphrase.create")
                    .oathActionArea(existingInset: 24)
                if let id = model.duplicateWalletID {
                    OathActionButton(title: strings.text(.passphraseOpenExisting), appearance: .secondary) { onOpenExisting(id) }
                        .oathActionArea(existingInset: 24)
                        .disabled(!session.isUnlocked || session.changingWallet)
                        .accessibilityIdentifier("passphrase.openExisting")
                }
            }
            .padding(24).frame(maxWidth: 600, alignment: .leading).frame(maxWidth: .infinity)
        }
        .background {
            OathKeyboardDismissal(requested: model.dismissingKeyboard, onDismiss: model.keyboardDismissed)
                .frame(width: 0, height: 0)
        }
        .navigationBarBackButtonHidden(model.busy || session.changingWallet)
        .oathAutofocus(when: session.isUnlocked && !session.changingWallet && !model.busy) {
            if focus == nil { focus = .passphrase }
        }
        .oathErrorFeedback(model.notice)
        .onChange(of: model.createdWalletID) { _, id in if let id { onCreated(id) } }
        .onChange(of: session.isUnlocked) { _, value in if !value { focus = nil; model.cancel() } }
        .onChange(of: scenePhase) { _, phase in if phase == .background { focus = nil; model.cancel() } }
        .onDisappear { focus = nil; model.cancel() }
        .accessibilityIdentifier("passphrase.form")
    }

    private func field(title: OathStringKey, text: Binding<String>, field: Field) -> some View {
        OathSecureInput(text: text, title: strings.text(title),
            identifier: field == .passphrase ? "passphrase.value" : "passphrase.confirmation",
            returnKey: field == .passphrase ? .next : .go,
            wantsFocus: focus == field, resignsFocus: focus == nil,
            onFocus: { focus = field }, onDismissKeyboard: { focus = nil },
            onSubmit: { if field == .passphrase { focus = .confirmation } else { submit() } },
            minimumPasswordLength: nil)
            .oathInputRow()
    }

    private func submit() {
        guard scenePhase == .active else { return }
        model.prepareSubmission()
        if model.validationNotice != nil { OathHaptics.shared.play(.error) }
        if model.dismissingKeyboard { focus = nil }
    }
}
