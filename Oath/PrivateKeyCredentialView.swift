import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor
struct PrivateKeyCredentialView: View {
    let network: PrivateKeyImportNetwork
    let onImport: (WalletImportDraft) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @FocusState private var isFieldFocused: Bool
    @State private var input: String
    @State private var presentedSheet: PrivateKeyCredentialSheet?
    @State private var importErrorMessage: String?
    @State private var validatedDraft: WalletImportDraft?
    @State private var showsPasswordPrompt = false
    @State private var encryptionPassword = ""
    @State private var promptedEncryptedInput: String?
    @State private var isDecrypting = false
    @State private var decryptionID = UUID()
    @State private var decryptionTask: Task<Void, Never>?
    @State private var showsFileImporter = false
    @State private var selectedFileURL: URL?
    @State private var selectedFileSize: Int?

    init(
        network: PrivateKeyImportNetwork,
        initialInput: String = "",
        onImport: @escaping (WalletImportDraft) -> Void
    ) {
        self.network = network
        self.onImport = onImport
        _input = State(initialValue: initialInput)
    }

    @State private var backgroundExpiry = WalletSensitiveContentLifecycleState()

    var body: some View {
        ZStack {
            WalletBackground()

            ScrollView {
                VStack(spacing: 0) {
                    if let url = selectedFileURL {
                        BitcoinImportFileAttachment(fileName: url.lastPathComponent, byteCount: selectedFileSize, onClear: clearSelectedFile)
                            .transition(.opacity.combined(with: .scale(scale: 0.97)))
                    } else {
                        VStack(spacing: 0) {
                            Text("import.credential.private_key.title")
                                .font(WalletTypography.title(.title))
                                .multilineTextAlignment(.center)
                                .accessibilityAddTraits(.isHeader)
                                .accessibilityIdentifier("bitcoinPrivateKeyHeadline")
                            Text(
                                String(
                                    format: WalletLocalization.string(
                                        "import.private_key.network.message"
                                    ),
                                    locale: Locale.current,
                                    network.localizedTitle
                                )
                            )
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 12)
                            .padding(.horizontal, 20)

                            privateKeyField
                                .padding(.top, 34)
                            utilityActions
                                .padding(.top, 16)
                        }
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                    }

                    if network == .bitcoin {
                        MutedWalletActionButton(title: selectedFileURL == nil ? "import.bitcoin.file.choose" : "import.bitcoin.file.replace", prominence: .secondary, hapticPolicy: .silent) {
                            isFieldFocused = false
                            showsFileImporter = true
                        }
                        .disabled(isDecrypting)
                        .padding(.top, 12)
                        .accessibilityIdentifier("bitcoinImportFile")
                    }

                    validationMessage
                        .padding(.top, 18)
                }
                .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: selectedFileURL != nil)
                .walletActionScreenMargins()
                .padding(.top, 44)
                .padding(.bottom, 36)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
        }
        .walletSecretScreenExpiry(lifecycle: $backgroundExpiry)
        .navigationTitle("import.private_key.title")
        .navigationBarTitleDisplayMode(.inline)
        .walletFocusOnPresentation { isFieldFocused = true }
        .walletKeyboardUsesScreenAction()
        .walletSafeAreaBar(edge: .bottom, spacing: 0) {
            PrimaryWalletButton(
                title: isDecrypting ? "import.bip38.decrypting" : "import.private_key.action.import"
            ) {
                importWallet()
            }
            .disabled(!isValid)
            .accessibilityIdentifier("importCredentialContinue")
            .walletActionScreenMargins()
            .padding(.top, 12)
            .padding(.bottom, 8)
        }
        .sheet(item: $presentedSheet, onDismiss: { promptForEncryptedKeyIfNeeded() }) { sheet in
            switch sheet {
            case .scanner:
                ImportWalletCredentialScannerScreen(
                    mode: .privateKey(network),
                    onRecognized: { recognizedText in
                        replaceInput(with: recognizedText)
                        presentedSheet = nil
                    }
                )
                .walletScannerPresentation()
            case let .unsafeCredential(warning):
                UnsafeCredentialImportWarningSheet(
                    warning: warning,
                    onChooseDifferent: {
                        clearSelectedFile()
                        presentedSheet = nil
                    }
                )
            }
        }
        .fileImporter(isPresented: $showsFileImporter, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
            switch result {
            case let .success(urls):
                guard let url = urls.first else { return }
                selectedFileSize = nil
                selectedFileURL = url
                importFile(url)
            case .failure:
                importErrorMessage = WalletLocalization.string("import.bitcoin.file.read_error")
            }
        }
        .alert(LocalizedStringKey(selectedFileURL == nil ? "import.bip38.title" : "settings.wallets.backup.password.section"), isPresented: $showsPasswordPrompt) {
            SecureField("import.bip38.password", text: $encryptionPassword)
                .walletTextInputDirection()
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("bip38Password")
            Button("common.cancel", role: .cancel) { encryptionPassword = "" }
            Button("import.bip38.decrypt") {
                if let url = selectedFileURL {
                    let password = encryptionPassword
                    encryptionPassword = ""
                    importFile(url, password: password)
                } else { decryptEnteredKey() }
            }
                .accessibilityIdentifier("bip38Decrypt")
        } message: {
            Text(importErrorMessage ?? WalletLocalization.string(selectedFileURL == nil ? "import.bip38.message" : "import.bitcoin.file.password_message"))
        }
        .onDisappear {
            selectedFileURL = nil
            decryptionTask?.cancel()
            decryptionID = UUID()
            encryptionPassword = ""
            isDecrypting = false
            validatedDraft = nil
        }
        .onChange(of: input) { _, _ in
            selectedFileURL = nil
            decryptionTask?.cancel()
            decryptionID = UUID()
            isDecrypting = false
            promptedEncryptedInput = nil
            encryptionPassword = ""
            showsPasswordPrompt = false
            importErrorMessage = nil
            validatedDraft = nil
        }
        .task(id: preparedInput) {
            await validatePreparedInput()
        }
    }

    private var privateKeyField: some View {
        HStack(spacing: 8) {
            TextField(
                "",
                text: $input,
                prompt: Text("import.credential.private_key.placeholder"),
                axis: .vertical
            )
            .walletTextInputDirection()
            .walletNonHyphenatingInput()
            .font(.body)
            .lineLimit(2, reservesSpace: true)
            .walletSensitiveValue()
            .writingToolsBehavior(.disabled)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused($isFieldFocused)
            .padding(.leading, 18)
            .padding(.vertical, 10)
            .accessibilityLabel(
                Text("import.credential.private_key.title")
            )
            .accessibilityHint(Text(WalletLocalization.string(network.requirementKey)))

            if !input.isEmpty {
                Button("common.clear", action: UniHaptic.action {
                    input = ""
                })
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(WalletTheme.accent)
                .buttonStyle(.plain)
                .frame(minWidth: 44, minHeight: 44)
                .padding(.trailing, 10)
            }
        }
        .frame(minHeight: 62)
        .background(
            WalletConcentricRectangle(minimumCornerRadius: 22)
            .fill(WalletTheme.textFieldSecretsSurface)
        )
        .animation(
            reduceMotion ? nil : .smooth(duration: 0.22),
            value: input.isEmpty
        )
    }

    @ViewBuilder
    private var utilityActions: some View {
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

    private var scanButton: some View {
        utilityButton(title: "common.scan") {
            isFieldFocused = false
            presentedSheet = .scanner
        }
    }

    private var pasteButton: some View {
        utilityButton(title: "common.paste") {
            guard let clipboardText = UIPasteboard.general.string else {
                return
            }
            replaceInput(with: clipboardText)
        }
    }

    private func utilityButton(
        title: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        MutedWalletActionButton(
            title: title,
            prominence: .secondary,
            action: action
        )
    }

    private var validationMessage: some View {
        ZStack {
            if let importErrorMessage {
                Text(importErrorMessage)
                    .foregroundStyle(WalletTheme.danger)
            } else if isDecrypting {
                Text("import.bip38.decrypting")
                    .foregroundStyle(.secondary)
            } else if selectedFileURL == nil, !isValid {
                Text(WalletLocalization.string(network.requirementKey))
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

    private var preparedInput: String {
        input.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isValid: Bool {
        !isDecrypting && (validatedDraft != nil || selectedFileURL == nil && isEncryptedKey)
    }

    private func replaceInput(with value: String) {
        input = value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func importWallet() {
        if selectedFileURL == nil, validatedDraft == nil, isEncryptedKey {
            promptForEncryptedKeyIfNeeded(force: true)
            return
        }
        guard let draft = validatedDraft else { return }
        isFieldFocused = false
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

    private var isEncryptedKey: Bool {
        BitcoinBIP38.recognizes(preparedInput, network: network)
    }

    private func promptForEncryptedKeyIfNeeded(force: Bool = false) {
        guard isEncryptedKey, !isDecrypting, validatedDraft == nil,
              presentedSheet == nil,
              force || promptedEncryptedInput != preparedInput else { return }
        promptedEncryptedInput = preparedInput
        encryptionPassword = ""
        isFieldFocused = false
        showsPasswordPrompt = true
    }

    private func clearSelectedFile() {
        decryptionTask?.cancel()
        decryptionTask = nil
        decryptionID = UUID()
        selectedFileURL = nil
        selectedFileSize = nil
        validatedDraft = nil
        importErrorMessage = nil
        encryptionPassword = ""
        showsPasswordPrompt = false
        promptedEncryptedInput = nil
        isDecrypting = false
        input = ""
        isFieldFocused = true
    }

    private func importFile(_ url: URL, password: String? = nil) {
        decryptionTask?.cancel()
        let attempt = UUID()
        decryptionID = attempt
        validatedDraft = nil
        importErrorMessage = nil
        isDecrypting = true
        decryptionTask = Task {
            do {
                let size = await BitcoinImportFileParser.shared.byteCount(url: url)
                guard !Task.isCancelled, decryptionID == attempt, selectedFileURL == url else { return }
                selectedFileSize = size
                let draft = try await BitcoinImportFileParser.shared.read(url: url, password: password)
                guard !Task.isCancelled, decryptionID == attempt, selectedFileURL == url else { return }
                validatedDraft = draft
                isDecrypting = false
                if password != nil { importWallet() }
            } catch {
                guard !Task.isCancelled, decryptionID == attempt, selectedFileURL == url else { return }
                isDecrypting = false
                if error as? BitcoinImportError == .passwordRequired {
                    encryptionPassword = ""
                    showsPasswordPrompt = true
                } else if error as? BitcoinImportError == .incorrectPassword {
                    importErrorMessage = WalletLocalization.string("import.bip38.wrong_password")
                    showsPasswordPrompt = true
                } else {
                    importErrorMessage = BitcoinImportErrorPresentation.message(error)
                }
            }
            decryptionTask = nil
        }
    }

    private func decryptEnteredKey() {
        guard isEncryptedKey, !isDecrypting else { return }
        let candidate = preparedInput
        let password = encryptionPassword
        encryptionPassword = ""
        isDecrypting = true
        let attempt = UUID()
        decryptionID = attempt
        decryptionTask = Task {
            do {
                let draft = try await BitcoinBIP38Decryptor.shared.decrypt(candidate, password: password)
                guard !Task.isCancelled, decryptionID == attempt, preparedInput == candidate else { return }
                guard !Task.isCancelled, decryptionID == attempt, preparedInput == candidate else { return }
                validatedDraft = draft
                importErrorMessage = nil
                isDecrypting = false
                importWallet()
            } catch {
                guard !Task.isCancelled, decryptionID == attempt, preparedInput == candidate else { return }
                validatedDraft = nil
                isDecrypting = false
                importErrorMessage = WalletLocalization.string(
                    (error as? BitcoinBIP38Error) == .incorrectPassword
                        ? "import.bip38.wrong_password" : "import.bip38.failed"
                )
                showsPasswordPrompt = true
            }
            decryptionTask = nil
        }
    }

    @MainActor
    private func validatePreparedInput() async {
        guard selectedFileURL == nil else { return }
        validatedDraft = nil
        let candidate = preparedInput
        guard !candidate.isEmpty else { return }

        do {
            try await Task.sleep(for: .milliseconds(100))
        } catch {
            return
        }
        guard !Task.isCancelled, selectedFileURL == nil, candidate == preparedInput else {
            return
        }

        if isEncryptedKey {
            promptForEncryptedKeyIfNeeded()
            return
        }
        let network = network
        let worker = Task.detached(priority: .userInitiated) {
            try? PrivateKeyImportService.importKey(
                candidate,
                network: network
            )
        }
        let draft = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        guard !Task.isCancelled, selectedFileURL == nil, candidate == preparedInput else {
            return
        }
        validatedDraft = draft
    }
}

private enum PrivateKeyCredentialSheet: Identifiable {
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
