import OathDiagnostics
import SwiftUI

/// Both onboarding and additional-wallet navigation use this same editor.
/// Its callback receives a validated key in memory, never in a navigation path.
struct OathPrivateKeyImportScreen: View {
    let choice: OathPrivateKeyChoice
    var isAllowed = true
    var scannedKey: String? = nil
    @State private var didSeedScan = false
    let onImport: (OathImportedPrivateKey, UUID) async throws -> Void
    @Environment(\.oathLocalizer) private var strings
    @Environment(\.scenePhase) private var scenePhase
    @State private var text = ""
    @State private var focused = false
    @State private var pendingAction: PendingAction?
    @State private var showsScanner = false
    @State private var scanError: OathRecoveryScanError?
    @State private var pendingScanError: OathRecoveryScanError?
    @State private var work: Task<Void, Never>?
    @State private var failure: OathStringKey?
    @State private var requestID = UUID()
    @State private var generation = UUID()

    private enum PendingAction { case importKey, scan }
    private var busy: Bool { pendingAction != nil || work != nil }
    private var ready: Bool { isAllowed && !busy && !showsScanner }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                OathSettingsRow(title: choice.isEVM ? strings.text(.evmTitle) : strings.invariant(choice.title),
                    icon: "network", accessory: .none,
                    networkLogo: choice.networks.first?.logoAsset)
                    .padding(.horizontal, -20)
                Text(strings.text(.privateKeyImportDetail))
                    .oathFont(.body).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 12) {
                    OathPasteInput(hasText: !text.isEmpty, identifier: "privateKeyImport.paste",
                                   clearIdentifier: "privateKeyImport.clear", onPaste: {
                        guard ready else { return }
                        // Clipboard is accessed only for this explicit tap.
                        guard let value = OathClipboard.paste() else { return }
                        receiveInput(value)
                        focused = true
                    }, onClear: {
                        guard ready else { return }
                        text = ""
                        failure = nil
                        focused = true
                    }) {
                        OathTextInput(text: $text, focused: $focused, title: strings.text(.privateKeyInput),
                            identifier: "privateKeyImport.field", secret: true,
                            showsSecretVisibility: false, onSubmit: submit)
                    }
                    Text(strings.text(choice.networks == [.bitcoin] ? .bitcoinKeyFormat : choice.inputFormat))
                        .oathFont(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let failure {
                        Text(strings.text(failure)).oathFont(.footnote).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("privateKeyImport.error")
                    }
                }
                importButton
                    .oathActionArea(existingInset: 24)
            }
            .padding(24).frame(maxWidth: 650).frame(maxWidth: .infinity)
            .disabled(busy || !isAllowed)
        }
        .background(Color(uiColor: OathSurfaceColors.canvas).ignoresSafeArea())
        .navigationTitle(strings.text(.importPrivateKey))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(busy)
        .scrollDismissesKeyboard(.interactively)
        .interactiveDismissDisabled(busy || showsScanner)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                OathButton(strings.text(.scan), systemImage: "viewfinder", feedback: .scan) {
                    guard ready else { return }
                    focused = false
                    pendingAction = .scan
                }
                .labelStyle(.iconOnly)
                .oathNeutralControl()
                .disabled(!ready)
                .accessibilityIdentifier("privateKeyImport.scan")
            }
        }
        .oathNativeLocalization()
        .background {
            OathKeyboardDismissal(requested: pendingAction != nil, onDismiss: performPendingAction)
                .frame(width: 0, height: 0)
        }
        .oathAutofocus(when: ready && scanError == nil) { focused = true }
        .oathScannerCover(isPresented: $showsScanner, onDismiss: {
            scanError = pendingScanError
            pendingScanError = nil
        }) {
            OathScanner(strings: strings, onPayload: { payload in
                guard showsScanner, isAllowed, scenePhase != .background else { return }
                // Populate the concealed field only. Import still requires the
                // user's confirmation and the existing chain-specific validation.
                receiveInput(payload)
                showsScanner = false
            }, onFailure: { error in
                guard showsScanner, isAllowed else { return }
                pendingScanError = error
                showsScanner = false
            }, onClose: { showsScanner = false }, title: .scan, identifier: "privateKeyImport.scanner", context: .privateKey)
                .oathLanguage(strings.language)
                .ignoresSafeArea()
                .statusBarHidden(false)
        }
        .alert(strings.text(.scan), isPresented: Binding(
            get: { scanError != nil }, set: { if !$0 { scanError = nil } }
        ), presenting: scanError) { error in
            if error == .denied {
                OathButton(strings.text(.openSettings)) {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            }
            OathButton(strings.text(.close), role: .cancel) {}
        } message: { error in
            Text(strings.text(error == .invalidPhrase ? .privateKeyInvalid : error.message))
        }
        .oathErrorFeedback(failure)
        .oathErrorFeedback(scanError)
        .onAppear { if !didSeedScan { didSeedScan = true; if let scannedKey { receiveInput(scannedKey) } } }
        .onChange(of: text) { _, _ in failure = nil; requestID = UUID() }
        .onChange(of: isAllowed) { _, allowed in if !allowed { cancel() } }
        .onChange(of: scenePhase) { _, phase in if phase == .background { cancel() } }
        .onDisappear {
            // A scanner cover temporarily hides the editor. Canceling the
            // camera must preserve the draft; leaving the flow still clears it.
            if !showsScanner { cancel() }
        }
    }

    private var importButton: some View {
        OathActionButton(title: strings.text(.importAction), isWorking: busy, action: submit)
        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .accessibilityIdentifier("privateKeyImport.import")
    }

    private func submit() {
        guard ready, !text.isEmpty else { return }
        failure = nil
        focused = false
        pendingAction = .importKey
    }

    private func receiveInput(_ value: String) {
        guard isAllowed, !busy else { return }
        guard value.utf8.count <= 2_048,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            failure = .privateKeyInvalid
            return
        }
        text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        failure = nil
    }

    private func performPendingAction() {
        guard let action = pendingAction, work == nil, isAllowed else { return }
        pendingAction = nil
        switch action {
        case .scan: showsScanner = true
        case .importKey: startImport()
        }
    }

    private func startImport() {
        guard work == nil, isAllowed else { return }
        let input = text, choice = choice, id = requestID
        let token = UUID()
        generation = token
        work = Task {
            defer { if generation == token { work = nil } }
            let decoding = Task.detached(priority: .userInitiated) {
                try OathWalletEngine.importedPrivateKey(input, choice: choice)
            }
            do {
                let key = try await withTaskCancellationHandler {
                    try await decoding.value
                } onCancel: { decoding.cancel() }
                try Task.checkCancellation()
                guard isAllowed, generation == token else { return }
                try await onImport(key, id)
                text = ""
            } catch is CancellationError { }
            catch { OathDiagnostics.record(error);
                guard !Task.isCancelled, isAllowed, generation == token else { return }
                failure = (error as? OathWalletError) == .invalidPrivateKey ? .privateKeyInvalid : .walletChangeFailedDetail
            }
        }
    }

    private func cancel() {
        generation = UUID()
        work?.cancel(); work = nil
        pendingAction = nil
        showsScanner = false
        scanError = nil
        pendingScanError = nil
        focused = false
        text = ""
    }
}

extension OathPrivateKeyChoice {
    var inputFormat: OathStringKey {
        switch networks.first {
        case .dogecoin: .privateKeyFormatDogecoin
        case .litecoin: .privateKeyFormatLitecoin
        case .bitcoincash: .privateKeyFormatBitcoinCash
        case .bitcoin: .privateKeyFormatWIF
        case .solana: .privateKeyFormatSolana
        case .near: .privateKeyFormatNear
        case .stellar: .privateKeyFormatStellar
        case .sui: .privateKeyFormatSui
        case .aptos: .privateKeyFormatAptos
        case .xrpl: .privateKeyFormatXRP
        default: .privateKeyFormatHex
        }
    }
}
