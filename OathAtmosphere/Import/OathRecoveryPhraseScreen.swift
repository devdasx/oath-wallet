import SwiftUI

struct OathRecoveryPhraseScreen: View {
    @Environment(\.oathLocalizer) private var strings
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var draft: OathRecoveryPhraseDraft
    var isImporting = false
    let onImport: (OathValidatedMnemonic) -> Void
    @State private var isFocused = false
    @State private var showsScanner = false
    @State private var scanError: OathRecoveryScanError?
    @State private var pendingScanError: OathRecoveryScanError?
    @State private var validationRevision = 0

    private var accent: Color {
        colorScheme == .dark
            ? Color(red: 0.36, green: 0.56, blue: 1)
            : Color(red: 0.12, green: 0.30, blue: 0.90)
    }

    var body: some View {
        ScrollViewReader { proxy in
            page.onChange(of: validationRevision) { _, _ in
                OathHaptics.shared.play(.error)
                withAnimation(reduceMotion ? nil : .default) {
                    proxy.scrollTo("recovery.validation", anchor: .bottom)
                }
            }
        }
    }

    private var page: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(strings.text(.recoveryDetail))
                    .oathFont(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 12) {
                    phraseField
                    validationMessage
                }

                importButton
                    .oathActionArea(existingInset: 24)
            }
            .frame(maxWidth: 600, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(24)
        }
        .scrollDismissesKeyboard(.interactively)
        .accessibilityIdentifier("recovery.content")
        .disabled(isImporting)
        .background(Color(uiColor: OathSurfaceColors.canvas).ignoresSafeArea())
        .toolbarBackground(Color(uiColor: OathSurfaceColors.canvas), for: .navigationBar)
        .navigationTitle(strings.text(.importWallet))
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                scanButton
            }
        }
        .oathNativeLocalization()
        .tint(accent)
        .oathAutofocus(when: !isImporting && !showsScanner && !draft.inputRejected) {
            isFocused = true
        }
        .onDisappear { isFocused = false }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { isFocused = false }
        }
        .oathErrorFeedback(scanError)
        .onChange(of: draft.inputRejected) { _, rejected in
            if rejected { isFocused = false; validationRevision &+= 1 }
        }
        .oathScannerCover(isPresented: $showsScanner, onDismiss: {
            scanError = pendingScanError
            pendingScanError = nil
        }) {
            OathScanner(strings: strings, onPayload: { payload in
                if !draft.receiveScan(payload) { pendingScanError = .invalidPhrase }
                showsScanner = false
            }, onFailure: { error in
                pendingScanError = error
                showsScanner = false
            }, onClose: { showsScanner = false })
            .oathLanguage(strings.language)
            .ignoresSafeArea()
            .statusBarHidden(false)
        }
        .alert(strings.text(.recoveryScanErrorTitle), isPresented: Binding(
            get: { scanError != nil }, set: { if !$0 { scanError = nil } }
        ), presenting: scanError) { error in
            if error == .denied {
                OathButton(strings.text(.openSettings)) {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            }
            OathButton(strings.text(.close), role: .cancel) {}
        } message: { error in
            Text(strings.text(error.message))
        }
    }

    private var phraseField: some View {
        OathPasteInput(hasText: !draft.text.isEmpty, identifier: "recovery.paste",
                       clearIdentifier: "recovery.clear", multiline: true, onPaste: {
            guard !isImporting, !showsScanner else { return }
            // Read only after this deliberate tap; native paste permission remains.
            guard let text = OathClipboard.paste() else { return }
            draft.replace(with: text)
            isFocused = !draft.inputRejected
        }, onClear: {
            guard !isImporting, !showsScanner else { return }
            draft.clear()
            isFocused = true
        }) {
            ZStack(alignment: .topLeading) {
                OathMnemonicTextInput(draft: draft, isFocused: $isFocused, strings: strings)
                if draft.text.isEmpty {
                    Text(strings.text(.recoveryPhrase))
                        .oathFont(.body)
                        .foregroundStyle(.tertiary)
                        .padding(OathMnemonicTextInput.contentPadding)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("recovery.field")
    }

    @ViewBuilder private var validationMessage: some View {
        let state = draft.validation
        let hasError = draft.attemptedImport || state == .unavailable
        if state.isValid || hasError {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if state.isValid {
                    Image(systemName: "checkmark.circle.fill").accessibilityHidden(true)
                    Text(strings.text(.recoveryValid))
                } else {
                    Text(message(for: state))
                }
            }
            .oathFont(.footnote)
            .foregroundStyle(state.isValid ? Color.green : Color.red)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("recovery.validation")
            .id("recovery.validation")
        }
    }

    private func message(for state: OathMnemonicValidation) -> String {
        switch state {
        case .empty: strings.text(.recoveryEmpty)
        case .tooLong: strings.text(.recoveryTooLong)
        case .unavailable: strings.text(.recoveryUnavailable)
        case .wordCount: strings.text(.recoveryWordCounts)
        case .unknownWord(let number): strings.format(.recoveryUnknownWord, strings.number(number))
        case .mixedLanguages: strings.text(.recoveryMixedWords)
        case .checksum: strings.text(.recoveryChecksum)
        case .valid: strings.text(.recoveryValid)
        }
    }

    private var scanButton: some View {
        // A native icon-only bar item uses the navigation bar's own control
        // metrics and glass treatment, just like its Back button.
        OathButton(strings.text(.scan), systemImage: "viewfinder", feedback: .scan) {
            isFocused = false
            showsScanner = true
        }
        .labelStyle(.iconOnly)
        .oathNeutralControl()
        .disabled(isImporting)
        .accessibilityIdentifier("recovery.scan")
    }

    private var importButton: some View {
        OathActionButton(title: strings.text(.importAction), accent: accent) {
            isFocused = false
            guard let phrase = draft.submit() else {
                UIAccessibility.post(notification: .announcement, argument: message(for: draft.validation))
                validationRevision &+= 1
                return
            }
            onImport(phrase)
        }
        .disabled(draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.validator == nil || draft.isComposing)
        .accessibilityIdentifier("recovery.import")
    }
}
