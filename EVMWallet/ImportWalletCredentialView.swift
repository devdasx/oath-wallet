import SwiftUI
import UIKit

enum WalletImportCredential: Hashable {
    case recoveryPhrase
    case privateKey

    var navigationTitle: LocalizedStringKey {
        switch self {
        case .recoveryPhrase:
            "import.recovery.title"
        case .privateKey:
            "import.private_key.title"
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .recoveryPhrase:
            "import.credential.recovery.title"
        case .privateKey:
            "import.credential.private_key.title"
        }
    }

    var message: LocalizedStringKey {
        switch self {
        case .recoveryPhrase:
            "import.credential.recovery.message"
        case .privateKey:
            "import.credential.private_key.message"
        }
    }

    var placeholder: LocalizedStringKey {
        switch self {
        case .recoveryPhrase:
            "import.credential.recovery.placeholder"
        case .privateKey:
            "import.credential.private_key.placeholder"
        }
    }

}

@MainActor
struct ImportWalletCredentialView: View {
    let credential: WalletImportCredential
    let onImport: (WalletImportDraft) -> Void
    private let onPassphraseChange: (String) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.layoutDirection) private var layoutDirection
    @FocusState private var isFieldFocused: Bool
    @State private var isRecoveryFieldFocused = true
    @State private var input: String
    @State private var recoveryEditor: RecoveryPhraseEditorState
    @State private var presentedSheet: ImportCredentialSheet?
    @State private var importErrorMessage: String?
    @State private var validatedDraft: WalletImportDraft?
    @State private var completedValidationRequest: CredentialValidationRequest?
    @State private var recoveryPassphrase: String
    @State private var presentsRecoveryPassphrase = false
    @State private var presentsBIP39WordList = false

    init(
        credential: WalletImportCredential,
        initialInput: String = "",
        initialPassphrase: String = "",
        onPassphraseChange: @escaping (String) -> Void = { _ in },
        onImport: @escaping (WalletImportDraft) -> Void
    ) {
        self.credential = credential
        self.onImport = onImport
        self.onPassphraseChange = onPassphraseChange
        _input = State(initialValue: initialInput)
        _recoveryEditor = State(initialValue: RecoveryPhraseEditorState(input: initialInput))
        _recoveryPassphrase = State(initialValue: initialPassphrase)
    }

    @State private var backgroundExpiry = WalletSensitiveContentLifecycleState()

    var body: some View {
        ZStack {
            WalletBackground()

            ScrollView {
                VStack(spacing: 0) {
                    Text(credential.title)
                        .font(WalletTypography.title(.title))
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)

                    Text(credential.message)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 12)
                        .padding(.horizontal, 20)

                    credentialField
                        .padding(.top, 34)

                    credentialAssistance
                }
                .walletActionScreenMargins()
                .padding(.top, 44)
                .padding(.bottom, 36)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .modifier(RecoveryPhraseScrollVisibility())
        }
        .walletSecretScreenExpiry(lifecycle: $backgroundExpiry)
        .navigationTitle(credential.navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .walletFocusOnPresentation { setCredentialFocus(true) }
        .toolbar {
            if credential == .recoveryPhrase {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(
                            recoveryPassphrase.isEmpty
                                ? "import.recovery.passphrase.add"
                                : "import.recovery.passphrase.edit"
                        , action: UniHaptic.action(nil) {
                            presentRecoveryPassphraseOptions()
                        })

                        Button("import.recovery.word_list.menu", action: UniHaptic.action(nil) {
                            presentBIP39WordList()
                        })

                        if recoveryEditor.hasContent {
                            Button("common.clear", role: .destructive, action: UniHaptic.action {
                                updateRecoveryEditor { $0.clear() }
                                setCredentialFocus(true)
                            })
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel(
                        Text("import.recovery.options.toolbar")
                    )
                }
            }
        }
        // Recovery entry deliberately uses the same layout in every app language.
        // Keep the override inside this screen, below its separate destinations.
        .environment(\.layoutDirection, credential == .recoveryPhrase ? .leftToRight : layoutDirection)
        .navigationDestination(
            isPresented: $presentsRecoveryPassphrase
        ) {
            ImportWalletRecoveryPassphraseScreen(
                initialPassphrase: recoveryPassphrase
            ) { passphrase in
                recoveryPassphrase = passphrase
            }
        }
        .navigationDestination(
            isPresented: $presentsBIP39WordList
        ) {
            ImportWalletBIP39WordListScreen(
                initialLanguage: preferredWordListLanguage
            )
        }
        .walletKeyboardUsesScreenAction()
        .walletSafeAreaBar(edge: .bottom, spacing: 0) {
            VStack(spacing: 12) {
                if importErrorMessage != nil || (credential == .privateKey && !isValid) {
                    credentialStatus
                        .walletActionScreenMargins()
                }

                PrimaryWalletButton(
                    title: "import.credential.action.import"
                ) {
                    guard isValid else {
                        return
                    }

                    importWallet()
                }
                .disabled(!isValid)
                .accessibilityIdentifier("importCredentialContinue")
                .walletActionScreenMargins()
            }
            .padding(.top, 12)
            .padding(.bottom, 8)
        }
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .scanner:
                ImportWalletCredentialScannerScreen(
                    mode: scannerMode,
                    onRecognized: { recognizedText in
                        replaceInput(with: recognizedText)
                        presentedSheet = nil
                    }
                )
                .walletScannerPresentation()
            case let .unsafeCredential(warning):
                UnsafeCredentialImportWarningSheet(
                    warning: warning,
                    onChooseDifferent: chooseDifferentUnsafeCredential
                )
            }
        }
        .onChange(of: input) { _, _ in
            importErrorMessage = nil
            if credential == .recoveryPhrase {
                validatedDraft = nil
            }
        }
        .onChange(of: recoveryPassphrase) { _, value in
            onPassphraseChange(value)
        }
        .task(id: validationRequest) {
            await validatePreparedInput(validationRequest)
        }
    }

    @ViewBuilder
    private var credentialStatus: some View {
        ZStack {
            if let importErrorMessage {
                Text(importErrorMessage)
                    .foregroundStyle(WalletTheme.danger)
            } else if credential == .privateKey, !isValid {
                Text(EnglishNumbers.localized(
                    "import.credential.private_key.requirement",
                    64
                ))
                .foregroundStyle(.secondary)
            }
        }
        .font(.footnote)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .animation(
            reduceMotion ? nil : .smooth(duration: 0.22),
            value: isValid
        )
    }

    private func setCredentialFocus(_ focused: Bool) {
        if credential == .recoveryPhrase {
            isRecoveryFieldFocused = focused
        } else {
            isFieldFocused = focused
        }
    }

    private func presentRecoveryPassphraseOptions() {
        setCredentialFocus(false)
        presentsRecoveryPassphrase = true
    }

    private func presentBIP39WordList() {
        setCredentialFocus(false)
        presentsBIP39WordList = true
    }

    @ViewBuilder
    private var credentialField: some View {
        switch credential {
        case .recoveryPhrase:
            RecoveryPhraseEditor(state: $recoveryEditor, isFocused: $isRecoveryFieldFocused) {
                input = $0
            }

        case .privateKey:
            HStack(spacing: 8) {
                TextField(
                    "",
                    text: $input,
                    prompt: Text(credential.placeholder),
                    axis: .vertical
                )
                .walletTextInputDirection()
                .walletNonHyphenatingInput()
                .font(.body)
                .lineLimit(2, reservesSpace: true)
                .walletSensitiveValue()
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($isFieldFocused)
                .padding(.leading, 18)
                .padding(.vertical, 10)
                .accessibilityLabel(Text(credential.title))
                .accessibilityHint(Text(EnglishNumbers.localized(
                    "import.credential.private_key.requirement",
                    64
                )))

                if !input.isEmpty {
                    clearButton
                        .padding(.trailing, 10)
                }
            }
            .frame(minHeight: 62)
            .background(fieldBackground)
            .animation(
                reduceMotion ? nil : .smooth(duration: 0.22),
                value: input.isEmpty
            )
        }
    }

    private var clearButton: some View {
        Button("common.clear", action: UniHaptic.action {
            input = ""
        })
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(WalletTheme.accent)
        .buttonStyle(.plain)
        .frame(minWidth: 44, minHeight: 44)
    }

    @ViewBuilder
    private var credentialAssistance: some View {
        if credential != .recoveryPhrase || input.isEmpty {
            utilityActions
                .padding(.top, 16)
        }
    }

    private var utilityActions: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 12) {
                    scanButton
                    pasteButton
                }
            } else {
                HStack(spacing: 12) {
                    scanButton
                    pasteButton
                }
            }
        }
    }

    private var scanButton: some View {
        ImportUtilityButton(title: "common.scan", hapticPolicy: .silent) {
            setCredentialFocus(false)
            presentedSheet = .scanner
        }
    }

    private var pasteButton: some View {
        ImportUtilityButton(title: "common.paste") {
            guard let clipboardText = UIPasteboard.general.string else {
                return
            }

            replaceInput(with: clipboardText)
        }
    }

    private var fieldBackground: some View {
        WalletConcentricRectangle(minimumCornerRadius: 22)
            .fill(WalletTheme.textFieldSecretsSurface)
    }

    private var preparedInput: String {
        switch credential {
        case .recoveryPhrase:
            return normalizedRecoveryPhrase(input)
        case .privateKey:
            return input.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private var scannerMode: ImportWalletCredentialScannerMode {
        switch credential {
        case .recoveryPhrase:
            .recoveryPhrase
        case .privateKey:
            .privateKey(.evm)
        }
    }

    private var isValid: Bool {
        completedValidationRequest == validationRequest && validatedDraft != nil
    }

    private var recoveryWordsBeforeFragment: [String] {
        guard credential == .recoveryPhrase else { return [] }
        return recoveryEditor.wordsBeforeFragment
    }

    private var preferredWordListLanguage: BIP39Language {
        let candidates = BIP39Mnemonic.candidateLanguages(
            for: recoveryWordsBeforeFragment
        )
        if candidates.contains(.english) {
            return .english
        }
        return candidates.first ?? .english
    }

    private var validationRequest: CredentialValidationRequest {
        CredentialValidationRequest(
            input: preparedInput,
            rawInput: input,
            recoveryPassphrase: credential == .recoveryPhrase
                ? recoveryPassphrase
                : ""
        )
    }

    private func chooseDifferentUnsafeCredential() {
        // Clear both the token editor and its bound input before dismissing.
        // Changing the validation request also invalidates any in-flight result.
        updateRecoveryEditor { $0.clear() }
        validatedDraft = nil
        completedValidationRequest = nil
        importErrorMessage = nil
        recoveryPassphrase = ""
        onPassphraseChange("")
        presentedSheet = nil
        setCredentialFocus(true)
    }

    private func replaceInput(with newValue: String) {
        switch credential {
        case .recoveryPhrase:
            updateRecoveryEditor { $0.replace(with: normalizedRecoveryPhrase(newValue)) }
            // Paste and scanner acceptance use the same validity rule as Return.
            // Check the new editor value, without waiting for async key derivation.
            if (try? WalletRecoveryCredential(mnemonic: recoveryEditor.text)) != nil {
                setCredentialFocus(false)
            }
        case .privateKey:
            input = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func updateRecoveryEditor(_ mutation: (inout RecoveryPhraseEditorState) -> Void) {
        mutation(&recoveryEditor)
        input = recoveryEditor.text
    }

    private func importWallet() {
        guard let draft = validatedDraft else { return }
        if credential == .recoveryPhrase {
            updateRecoveryEditor { $0.finishWord() }
        }
        setCredentialFocus(false)
        if let finding = WalletCredentialSafetyService.finding(for: draft) {
            presentedSheet = .unsafeCredential(
                UnsafeCredentialImportWarning(
                    finding: finding
                )
            )
            return
        }
        completeImport(draft)
    }

    private func completeImport(_ draft: WalletImportDraft) {
        importErrorMessage = nil
        onImport(draft)
    }

    @MainActor
    private func validatePreparedInput(
        _ request: CredentialValidationRequest
    ) async {
        let candidate = request.input
        guard !candidate.isEmpty else { return }

        do {
            try await Task.sleep(for: .milliseconds(100))
        } catch {
            return
        }
        guard !Task.isCancelled, request == validationRequest else {
            return
        }

        let credential = credential
        let worker = Task.detached(
            priority: .userInitiated
        ) { () throws -> WalletImportDraft? in
            switch credential {
            case .recoveryPhrase:
                if RecoveryPhraseInputFeedback.evaluate(candidate) != nil {
                    return nil
                }
                return try WalletCoreService.importRecoveryPhrase(
                    candidate,
                    passphrase: request.recoveryPassphrase
                )
            case .privateKey:
                return try WalletCoreService.importPrivateKey(candidate)
            }
        }
        let result = await withTaskCancellationHandler {
            await worker.result
        } onCancel: {
            worker.cancel()
        }
        guard !Task.isCancelled, request == validationRequest else {
            return
        }
        completedValidationRequest = request
        importErrorMessage = nil
        switch result {
        case let .success(draft):
            validatedDraft = draft
        case let .failure(error):
            validatedDraft = nil
            // Keep the concrete cause; never include the credential itself.
            importErrorMessage = error.localizedDescription
        }
    }

    private func normalizedRecoveryPhrase(_ value: String) -> String {
        value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

private struct CredentialValidationRequest: Hashable {
    let input: String
    let rawInput: String
    let recoveryPassphrase: String
}

private enum ImportCredentialSheet: Identifiable {
    case scanner
    case unsafeCredential(UnsafeCredentialImportWarning)

    var id: String {
        switch self {
        case .scanner:
            "scanner"
        case let .unsafeCredential(warning):
            "unsafe-\(warning.id.uuidString)"
        }
    }
}

private struct ImportUtilityButton: View {
    let title: LocalizedStringKey
    var hapticPolicy: UniHapticControlPolicy = .automatic
    let action: () -> Void

    var body: some View {
        MutedWalletActionButton(
            title: title,
            prominence: .secondary,
            hapticPolicy: hapticPolicy,
            action: action
        )
    }
}

#Preview("Recovery Phrase") {
    NavigationStack {
        ImportWalletCredentialView(
            credential: .recoveryPhrase,
            onImport: { _ in }
        )
    }
}

#Preview("Private Key") {
    NavigationStack {
        ImportWalletCredentialView(
            credential: .privateKey,
            onImport: { _ in }
        )
    }
}
