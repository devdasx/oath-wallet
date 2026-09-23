import SwiftUI
import UniformTypeIdentifiers

struct WalletSwitcherMuunEmergencyKitImportScreen: View {
    let onImport: (WalletImportDraft) -> Void

    @State private var recoveryCode = ""
    @State private var emergencyKit: MuunEmergencyKitPayload?
    @State private var isChoosingFile = false
    @State private var isWorking = false
    @State private var errorKey: String?
    @State private var operationTask: Task<Void, Never>?

    var body: some View {
        List {
            Group {
                Section {
                    Button(action: UniHaptic.action(nil) {
                        errorKey = nil
                        isChoosingFile = true
                    }) {
                        Text(LocalizedStringKey(
                            emergencyKit == nil
                                ? "muun.recovery.choose_pdf"
                                : "muun.recovery.kit_selected"
                        ))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .disabled(isWorking)
                } header: {
                    Text("muun.recovery.method.emergency.title")
                } footer: {
                    Text("muun.recovery.emergency.instructions")
                }

                Section {
                    MuunRecoveryCodeField(value: $recoveryCode)
                        .disabled(isWorking)
                } footer: {
                    Text("muun.recovery.code.instructions")
                }

                if let errorKey {
                    Section {
                        Text(LocalizedStringKey(errorKey))
                            .foregroundStyle(WalletTheme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .walletListRowSurface()
        }
        .walletListAppearance()
        .listStyle(.insetGrouped)
        .navigationTitle("muun.recovery.method.emergency.title")
        .navigationBarTitleDisplayMode(.inline)
        .walletKeyboardUsesScreenAction()
        .walletSafeAreaBar(edge: .bottom, spacing: 0) {
            PrimaryWalletButton(title: "muun.recovery.action") {
                recoverWallet()
            }
            .disabled(!canRecover || isWorking)
            .walletActionScreenMargins()
            .padding(.top, 12)
            .padding(.bottom, 8)
        }
        .fileImporter(
            isPresented: $isChoosingFile,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: false,
            onCompletion: handleFileSelection
        )
        .onChange(of: recoveryCode) {
            errorKey = nil
        }
        .onDisappear(perform: cancelPendingOperation)
    }

    private var canRecover: Bool {
        emergencyKit != nil
            && MuunRecoveryImportInput.isValidRecoveryCode(recoveryCode)
    }

    private func handleFileSelection(_ result: Result<[URL], Error>) {
        switch result {
        case let .success(urls):
            guard urls.count == 1, let url = urls.first else {
                errorKey = "muun.recovery.error.invalid_kit"
                return
            }
            readEmergencyKit(at: url)
        case let .failure(error):
            let cocoaError = error as NSError
            guard cocoaError.code != NSUserCancelledError else { return }
            errorKey = "muun.recovery.error.invalid_kit"
        }
    }

    private func readEmergencyKit(at url: URL) {
        operationTask?.cancel()
        emergencyKit = nil
        errorKey = nil
        isWorking = true
        operationTask = Task { @MainActor in
            defer { isWorking = false }
            do {
                let payload = try await MuunRecoveryImportProcessor
                    .readEmergencyKit(at: url)
                try Task.checkCancellation()
                emergencyKit = payload
            } catch is CancellationError {
                return
            } catch {
                errorKey = MuunRecoveryImportPresentation.errorKey(for: error)
            }
        }
    }

    private func recoverWallet() {
        guard let emergencyKit, canRecover, !isWorking else { return }
        operationTask?.cancel()
        errorKey = nil
        isWorking = true
        let canonicalCode = recoveryCode
        operationTask = Task { @MainActor in
            defer { isWorking = false }
            do {
                let draft = try await MuunRecoveryImportProcessor
                    .emergencyKitDraft(
                        payload: emergencyKit,
                        recoveryCode: canonicalCode
                    )
                try Task.checkCancellation()
                onImport(draft)
            } catch is CancellationError {
                return
            } catch {
                errorKey = MuunRecoveryImportPresentation.errorKey(for: error)
            }
        }
    }

    // Screen-owned input survives forward navigation. Popping this screen
    // or dismissing its owning flow disposes of the draft.
    private func cancelPendingOperation() {
        operationTask?.cancel()
        operationTask = nil
        isWorking = false
    }
}
