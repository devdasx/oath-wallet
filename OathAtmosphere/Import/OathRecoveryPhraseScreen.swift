import SwiftUI
import OathAezeed
import OathBitcoin
import OathDiagnostics

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
    @State private var decoding = false
    @State private var decodeError: String?
    @State private var decodeTask: Task<Void, Never>?

    private var accent: Color {
        colorScheme == .dark
            ? Color(red: 0.36, green: 0.56, blue: 1)
            : Color(red: 0.12, green: 0.30, blue: 0.90)
    }

    private var canImport: Bool {
        // Paste permission can temporarily deactivate the scene without changing form readiness.
        !isImporting && !decoding && !showsScanner
            && !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && draft.validator != nil && !draft.isComposing && !draft.inputRejected
            && (draft.preferredFormat != nil || !draft.requiresExplicitChoice(in: draft.matchingFormats))
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
                    let formats = draft.matchingFormats
                    let selected = draft.selectedFormat(in: formats)
                    let needsChoice = draft.requiresExplicitChoice(in: formats)
                    if formats.count > 1 || needsChoice {
                        Picker(strings.text(.recoveryFormat), selection: Binding(
                            get: { draft.selectedFormat(in: formats) }, set: draft.selectFormat
                        )) {
                            if needsChoice {
                                Text(strings.text(.recoveryFormat)).tag(nil as OathRecoveryFormat?)
                            }
                            ForEach(formats, id: \.self) { format in
                                Text(strings.invariant(format.rawValue)).tag(Optional(format))
                            }
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("recovery.format")
                        if formats.count == 2 {
                            Text(strings.text(.electrumAmbiguous)).oathFont(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    if selected == .electrum {
                        Text(strings.text(.electrumType)).oathFont(.footnote).foregroundStyle(.secondary)
                        if draft.electrumKind?.isTwoFactor == true {
                            Text(strings.text(.electrumTwoFactorDetail))
                                .oathFont(.footnote).foregroundStyle(.secondary)
                        }
                    } else if selected == .aezeed {
                        Text(strings.text(.aezeedType))
                            .oathFont(.footnote).foregroundStyle(.secondary)
                    } else { validationMessage }
                    if let decodeError {
                        Text(decodeError).oathFont(.footnote).foregroundStyle(.red)
                            .id("recovery.validation")
                    }
                }
            }
            .frame(maxWidth: 600, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(24)
        }
        .scrollDismissesKeyboard(.interactively)
        .accessibilityIdentifier("recovery.content")
        .disabled(isImporting || decoding)
        .background(Color(uiColor: OathSurfaceColors.canvas).ignoresSafeArea())
        .toolbarBackground(Color(uiColor: OathSurfaceColors.canvas), for: .navigationBar)
        .navigationTitle(strings.text(.importWallet))
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            OathToolbarAction(title: .importAction, kind: .walletImport, progressLabel: .importAction,
                              isEnabled: canImport, isWorking: isImporting || decoding,
                              identifier: "recovery.import", action: importPhrase)
        }
        .oathNativeLocalization()
        .tint(accent)
        .oathAutofocus(when: !isImporting && !decoding && !showsScanner && !draft.inputRejected) {
            isFocused = true
        }
        .onDisappear { isFocused = false; decodeTask?.cancel(); decodeTask = nil; decoding = false }
        .onChange(of: draft.text) { _, _ in decodeError = nil }
        .onChange(of: draft.preferredFormat) { _, _ in decodeError = nil }
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
                       clearIdentifier: "recovery.clear", multiline: true,
                       scanIdentifier: "recovery.scan", onScan: {
            guard !isImporting, !showsScanner, scenePhase == .active else { return }
            isFocused = false
            showsScanner = true
        }, onPaste: {
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

    private func importPhrase() {
        guard canImport, scenePhase == .active else { return }
        isFocused = false
        if draft.isElectrum {
            let text = draft.text
            decoding = true; decodeError = nil
            decodeTask = Task {
                await OathDiagnostics.$chain.withValue("bitcoin") {
                    await OathDiagnostics.$operationID.withValue(UUID()) {
                        defer { decoding = false }
                        do {
                            let material = try await Task.detached(priority: .userInitiated) {
                                try ElectrumMnemonic.decode(text)
                            }.value
                            try Task.checkCancellation()
                            guard draft.text == text, draft.isElectrum else { return }
                            onImport(.init(phrase: ElectrumMnemonic.recoveryPhrase(text, kind: material.kind), language: "electrum", electrum: material))
                        } catch is CancellationError { /* Leaving the import page cancels delivery. */ }
                        catch let error as ElectrumMnemonicError where error != .derivation {
                            // diagnostics: electrum-form-validation; invalid input is not an app failure.
                            guard !Task.isCancelled else { return }
                            decodeError = strings.text(.electrumInvalidPhrase); validationRevision &+= 1
                        } catch {
                            OathDiagnostics.record(DiagnosticFailure("electrum_decode_failed"), component: "recovery_import", operation: "decode_electrum", context: ["stage": "decode"])
                            decodeError = strings.text(.recoveryUnavailable); validationRevision &+= 1
                        }
                    }
                }
            }
            return
        }
        if draft.isAezeed {
            let text = draft.text
            decoding = true; decodeError = nil
            decodeTask = Task {
                await OathDiagnostics.$chain.withValue("bitcoin") {
                    await OathDiagnostics.$operationID.withValue(UUID()) {
                        defer { decoding = false }
                        do {
                            let material = try await Task.detached(priority: .userInitiated) {
                                try Aezeed.decode(text)
                            }.value
                            try Task.checkCancellation()
                            guard draft.text == text, draft.isAezeed else { return }
                            onImport(.init(phrase: Aezeed.canonical(text), language: "english", aezeed: material))
                        } catch is CancellationError {
                            // Navigation or app lock invalidated this local import attempt.
                        } catch let error as AezeedError {
                            guard !Task.isCancelled else { return }
                            // diagnostics: aezeed-form-validation
                            // Expected input validation, never report recovery material.
                            switch error {
                            case .incorrectPassphrase: decodeError = strings.text(.aezeedWrongPassphrase)
                            case .unsupportedVersion: decodeError = strings.text(.aezeedUnsupportedVersion)
                            case .invalidMnemonic: decodeError = strings.text(.aezeedInvalidPhrase)
                            }
                            validationRevision &+= 1
                        } catch {
                            OathDiagnostics.record(error, component: "recovery_import", operation: "decode_aezeed", context: ["stage": "decode"])
                            decodeError = strings.text(.recoveryUnavailable)
                            validationRevision &+= 1
                        }
                    }
                }
            }
            return
        }
        guard let phrase = draft.submit() else {
            UIAccessibility.post(notification: .announcement, argument: message(for: draft.validation))
            validationRevision &+= 1
            return
        }
        onImport(phrase)
    }
}
