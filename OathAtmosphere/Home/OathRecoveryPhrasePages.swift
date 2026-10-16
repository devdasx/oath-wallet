import SwiftUI

struct OathRecoveryWarningPage: View {
    let model: OathRecoveryPhraseModel
    let session: OathWalletSession
    @Environment(\.oathLocalizer) private var strings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                VStack(alignment: .leading, spacing: 18) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 38, weight: .medium))
                        .foregroundStyle(.orange)
                        .frame(width: 76, height: 76)
                        .background(Color.orange.opacity(0.1), in: .rect(cornerRadius: 24))
                        .accessibilityHidden(true)
                    Text(strings.text(.recoveryWarningTitle))
                        .oathFont(.title, weight: .semibold)
                        .accessibilityAddTraits(.isHeader)
                    Text(strings.text(.recoveryWarningDetail))
                        .oathFont(.body).foregroundStyle(.secondary)
                }
                VStack(spacing: 28) {
                    warning("person.crop.circle.badge.xmark", title: .recoveryNeverShare, detail: .recoveryNeverShareDetail)
                    warning("camera", title: .recoveryAvoidScreenshots, detail: .recoveryAvoidScreenshotsDetail)
                    warning("lock.shield", title: .recoveryStoreSecurely, detail: .recoveryStoreSecurelyDetail)
                }
                if let notice = model.notice {
                    Text(strings.text(notice)).oathFont(.footnote).foregroundStyle(.red)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(24)
            .frame(maxWidth: 600, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .oathBottomActions {
            OathActionButton(title: strings.text(.recoveryUnderstand), isInteractionBlocked: model.busy) {
                model.acknowledge(reason: strings.text(.recoveryAuthenticationReason))
            }
            .disabled(!session.isUnlocked)
            .accessibilityIdentifier("recoveryDisclosure.understand")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("recoveryDisclosure.warning")
    }

    private func warning(_ icon: String, title: OathStringKey, detail: OathStringKey) -> some View {
        HStack(alignment: .top, spacing: 16) {
            OathSettingsIcon(symbol: icon)
            VStack(alignment: .leading, spacing: 6) {
                Text(strings.text(title)).oathFont(.body, weight: .semibold)
                Text(strings.text(detail)).oathFont(.subheadline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct OathRecoveryPasscodePage: View {
    let model: OathRecoveryPhraseModel
    let session: OathWalletSession

    var body: some View {
        OathSecretPasscodePage(session: session, busy: model.busy,
            notice: Binding(get: { model.notice }, set: { model.notice = $0 }),
            title: .viewRecoveryPhrase, identifier: "recoveryDisclosure.passcode", onSubmit: model.submit)
    }
}

/// Shared native keypad for freshly authorizing recovery words or one key.
struct OathSecretPasscodePage: View {
    let session: OathWalletSession
    let busy: Bool
    @Binding var notice: OathStringKey?
    let title: OathStringKey
    let identifier: String
    let onSubmit: ([UInt8]) -> Void
    @Environment(\.oathLocalizer) private var strings
    @Environment(\.scenePhase) private var scenePhase
    @State private var digits: [UInt8] = []
    private var hasPasscodeError: Bool { notice == .unlockIncorrect || notice == .unlockWait }

    var body: some View {
        OathPasscodeEntry(title: strings.text(.unlockPasscodeTitle), filledCount: digits.count,
            isEnabled: !busy && session.isUnlocked && scenePhase == .active,
            isDeleteEnabled: !digits.isEmpty,
            errorMessage: hasPasscodeError ? notice.map { strings.text($0) } : nil,
            titleIdentifier: identifier + ".title",
            pinsIdentifier: identifier + ".dots", onKey: handle)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
        .alert(strings.text(title), isPresented: Binding(
            get: { notice != nil && !hasPasscodeError && scenePhase == .active },
            set: { if !$0 && !hasPasscodeError { notice = nil } }
        )) {
            if #available(iOS 26.0, *) {
                OathButton(role: .confirm) { notice = nil }
                    .accessibilityLabel(strings.text(.done))
                    .accessibilityIdentifier("confirmation.done")
                    .oathConfirmationControl()
            } else {
                OathButton(strings.text(.done)) { notice = nil }
                    .accessibilityIdentifier("confirmation.done")
                    .oathConfirmationControl()
            }
        } message: {
            if let notice { Text(strings.text(notice)) }
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { clear() } }
        .onDisappear { clear() }
    }

    private func handle(_ key: OathNumericKeypad.Key) {
        guard !busy, session.isUnlocked, scenePhase == .active else { return }
        switch key {
        case .digit(let value):
            guard digits.count < 6 else { return }
            if hasPasscodeError { notice = nil }
            digits.append(UInt8(value))
            if digits.count == 6 { onSubmit(digits); clear() }
        case .delete: if !digits.isEmpty { digits.removeLast() }
        case .biometrics: break
        }
    }

    private func clear() {
        _ = digits.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) }
        digits.removeAll()
    }
}

struct OathRecoveryWordsPage: View {
    let model: OathRecoveryPhraseModel
    let session: OathWalletSession
    @Environment(\.oathLocalizer) private var strings
    @Environment(\.scenePhase) private var scenePhase
    @State private var copied = false
    @State private var passphraseCopied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Label(strings.text(.recoveryKeepSafe), systemImage: "exclamationmark.shield")
                    .oathFont(.subheadline, weight: .semibold)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Text(strings.text(.recoveryViewDetail))
                    .oathFont(.body).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), alignment: .leading)], spacing: 12) {
                    ForEach(Array(model.words.enumerated()), id: \.offset) { index, word in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(String(index + 1))
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                .frame(minWidth: 18, alignment: .trailing)
                            Text(verbatim: word)
                                .font(.body.weight(.medium))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(Color(uiColor: OathSurfaceColors.field), in: .rect(cornerRadius: 16))
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("recoveryDisclosure.word.\(index + 1)")
                    }
                }
                // Phrase order is invariant even when the surrounding app is RTL.
                .environment(\.layoutDirection, .leftToRight)
                if let passphrase = model.passphrase {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(strings.text(.walletPassphrase)).oathFont(.headline)
                        Text(strings.text(.passphraseRecoveryDetail)).oathFont(.subheadline).foregroundStyle(.secondary)
                        Text(verbatim: passphrase)
                            .font(.body.monospaced()).textSelection(.disabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                            .background(Color(uiColor: OathSurfaceColors.field), in: .rect(cornerRadius: 16))
                            .environment(\.layoutDirection, .leftToRight)
                            .accessibilityIdentifier("recoveryDisclosure.passphrase")
                        OathActionButton(title: strings.text(passphraseCopied ? .recoveryCopied : .passphraseCopy),
                                         icon: passphraseCopied ? "checkmark" : "doc.on.doc", appearance: .secondary) {
                            guard session.isUnlocked, scenePhase == .active else { return }
                            OathSensitiveClipboard.copy(passphrase)
                            passphraseCopied = true
                        }
                        .oathActionArea(existingInset: 24)
                        .disabled(!session.isUnlocked)
                        .oathInteractionBlocked()
                        .accessibilityIdentifier("recoveryDisclosure.copyPassphrase")
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 600, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .oathBottomActions {
            OathActionButton(title: strings.text(copied ? .recoveryCopied : .recoveryCopy),
                                      icon: copied ? "checkmark" : "doc.on.doc") {
                guard !model.words.isEmpty, session.isUnlocked, scenePhase == .active else { return }
                OathSensitiveClipboard.copy(model.words.joined(separator: " "))
                copied = true
            }
            .disabled(model.words.isEmpty || !session.isUnlocked)
            .accessibilityIdentifier("recoveryDisclosure.copy")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("recoveryDisclosure.words")
    }
}
