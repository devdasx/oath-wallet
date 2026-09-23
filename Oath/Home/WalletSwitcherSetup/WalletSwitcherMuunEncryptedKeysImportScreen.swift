import SwiftUI

struct WalletSwitcherMuunEncryptedKeysImportScreen: View {
    let onImport: (WalletImportDraft) -> Void

    @State private var firstEncryptedKey = ""
    @State private var secondEncryptedKey = ""
    @State private var recoveryCode = ""
    @State private var isWorking = false
    @State private var errorKey: String?
    @State private var recoveryTask: Task<Void, Never>?

    var body: some View {
        List {
            Group {
                Section {
                    MuunEncryptedKeyField(
                        title: "muun.recovery.first_key",
                        value: $firstEncryptedKey
                    )
                    .disabled(isWorking)

                    MuunEncryptedKeyField(
                        title: "muun.recovery.second_key",
                        value: $secondEncryptedKey
                    )
                    .disabled(isWorking)
                } header: {
                    Text("muun.recovery.method.keys.title")
                } footer: {
                    Text("muun.recovery.manual.instructions")
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
        .navigationTitle("muun.recovery.method.keys.title")
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
        .onChange(of: firstEncryptedKey, clearError)
        .onChange(of: secondEncryptedKey, clearError)
        .onChange(of: recoveryCode, clearError)
        .onDisappear(perform: cancelPendingOperation)
    }

    private var canRecover: Bool {
        MuunRecoveryImportInput.manualInputsAreValid(
            firstEncryptedKey: firstEncryptedKey,
            secondEncryptedKey: secondEncryptedKey,
            recoveryCode: recoveryCode
        )
    }

    private func recoverWallet() {
        guard canRecover, !isWorking else { return }
        recoveryTask?.cancel()
        errorKey = nil
        isWorking = true
        let first = firstEncryptedKey
        let second = secondEncryptedKey
        let code = recoveryCode
        recoveryTask = Task { @MainActor in
            defer { isWorking = false }
            do {
                let draft = try await MuunRecoveryImportProcessor
                    .encryptedKeysDraft(
                        firstEncryptedKey: first,
                        secondEncryptedKey: second,
                        recoveryCode: code
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

    private func clearError() {
        errorKey = nil
    }

    // Screen-owned input survives forward navigation. Popping this screen
    // or dismissing its owning flow disposes of the draft.
    private func cancelPendingOperation() {
        recoveryTask?.cancel()
        recoveryTask = nil
        isWorking = false
    }
}
