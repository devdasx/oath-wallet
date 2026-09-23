import SwiftUI

struct WalletSwitcherTrustWalletPasswordScreen: View {
    let backup: TrustWalletBackupDescriptor
    let onRestore: (WalletImportDraft, String?) -> Void

    @State private var password = ""
    @State private var isRestoring = false
    @State private var errorKey: String?
    @State private var restoreTask: Task<Void, Never>?
    @FocusState private var isPasswordFocused: Bool

    var body: some View {
        List {
            Group {
                Section("import.icloud.backup.title") {
                    LabeledContent("import.icloud.passkey.wallet") {
                        if let displayName = backup.displayName {
                            Text(verbatim: displayName)
                        } else {
                            Text("import.icloud.backup.title")
                        }
                    }

                    LabeledContent("import.icloud.backup.type") {
                        Text(LocalizedStringKey(backup.kind.titleKey))
                    }
                }

                Section {
                    SecureField(
                        "import.icloud.password.placeholder",
                        text: $password
                    )
                    .walletTextInputDirection()
                    .textContentType(.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .walletPrivacySensitive()
                    .focused($isPasswordFocused)
                    .disabled(isRestoring)
                } header: {
                    Text("import.icloud.password.section")
                } footer: {
                    Text("import.warning")
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
        .navigationTitle("import.icloud.passkey.navigation.title")
        .navigationBarTitleDisplayMode(.inline)
        .walletKeyboardUsesScreenAction()
        .walletSafeAreaBar(edge: .bottom, spacing: 0) {
            PrimaryWalletButton(title: "import.icloud.action.restore") {
                restoreWallet()
            }
            .disabled(isRestoring)
            .walletActionScreenMargins()
            .padding(.top, 12)
            .padding(.bottom, 8)
        }
        .onChange(of: password) {
            errorKey = nil
        }
        .onDisappear(perform: cancelPendingOperation)
    }

    private func restoreWallet() {
        guard !isRestoring else { return }
        restoreTask?.cancel()
        errorKey = nil
        isRestoring = true
        let candidatePassword = password
        restoreTask = Task { @MainActor in
            defer { isRestoring = false }
            do {
                let result = try await TrustWalletBackupImporter.restore(
                    backup,
                    password: candidatePassword
                )
                try Task.checkCancellation()
                onRestore(result.draft, result.walletName)
            } catch is CancellationError {
                return
            } catch {
                errorKey = TrustWalletBackupImportPresentation
                    .restoreErrorKey(for: error)
            }
        }
    }

    // Screen-owned input survives forward navigation. Popping this screen
    // or dismissing its owning flow disposes of the draft.
    private func cancelPendingOperation() {
        restoreTask?.cancel()
        restoreTask = nil
        isPasswordFocused = false
        isRestoring = false
    }
}
