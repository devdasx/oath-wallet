import SwiftUI

struct WalletSwitcherCreationPassphraseScreen: View {
    let onSave: (String) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var passphrase: String
    @State private var confirmation: String
    @State private var isSaving = false
    @State private var saveErrorKey: String?
    @State private var saveTask: Task<Void, Never>?
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case passphrase
        case confirmation
    }

    init(
        initialPassphrase: String,
        onSave: @escaping (String) async throws -> Void
    ) {
        self.onSave = onSave
        _passphrase = State(initialValue: initialPassphrase)
        _confirmation = State(initialValue: initialPassphrase)
    }

    @State private var backgroundExpiry = WalletSensitiveContentLifecycleState()

    var body: some View {
        List {
            Group {
                Section {
                    SecureField(
                        "wallet.creation.passphrase.field",
                        text: $passphrase
                    )
                    .walletTextInputSubmitAction(identifier: "switcherCreationPassphrase", returnKeyType: .next) {
                        focusedField = .confirmation
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .walletSensitiveValue()
                    .focused($focusedField, equals: .passphrase)

                    SecureField(
                        "wallet.creation.passphrase.confirm_field",
                        text: $confirmation
                    )
                    .walletTextInputSubmitAction(identifier: "switcherCreationConfirmation", returnKeyType: .done) {
                        focusedField = nil
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .walletSensitiveValue()
                    .focused($focusedField, equals: .confirmation)
                } header: {
                    Text("wallet.creation.passphrase.section")
                } footer: {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("wallet.creation.passphrase.footer")

                        if let messageKey {
                            Text(LocalizedStringKey(messageKey))
                                .font(.body)
                                .foregroundStyle(WalletTheme.danger)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .walletListRowSurface()
        }
        .walletListAppearance()
        .listStyle(.insetGrouped)
        .walletFocusOnPresentation { focusedField = .passphrase }
        .walletSecretScreenExpiry(lifecycle: $backgroundExpiry)
        .navigationTitle("wallet.creation.passphrase.navigation")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                WalletConfirmationButton {
                    saveIfValid()
                }
                .disabled(!isValid || isSaving)
            }
        }
        .interactiveDismissDisabled(isSaving)
        .onChange(of: passphrase) {
            saveErrorKey = nil
        }
        .onChange(of: confirmation) {
            saveErrorKey = nil
        }
        .onDisappear {
            saveTask?.cancel()
            saveTask = nil
        }
    }

    private var normalizedPassphrase: String {
        passphrase.decomposedStringWithCompatibilityMapping
    }

    private var normalizedConfirmation: String {
        confirmation.decomposedStringWithCompatibilityMapping
    }

    private var validationMessageKey: String? {
        if normalizedPassphrase.utf8.count
            > WalletRecoveryCredential.maximumPassphraseUTF8Count {
            return "wallet.creation.passphrase.too_long"
        }
        if normalizedPassphrase != normalizedConfirmation {
            return "wallet.creation.passphrase.mismatch"
        }
        return nil
    }

    private var messageKey: String? {
        validationMessageKey ?? saveErrorKey
    }

    private var isValid: Bool {
        validationMessageKey == nil
    }

    private func saveIfValid() {
        guard isValid, !isSaving else { return }
        isSaving = true
        saveErrorKey = nil

        saveTask = Task { @MainActor in
            defer {
                isSaving = false
                saveTask = nil
            }

            do {
                try await onSave(normalizedPassphrase)
                try Task.checkCancellation()
                UniHaptic.play(.successQuiet)
                dismiss()
            } catch is CancellationError {
                return
            } catch {
                UniHaptic.play(.error)
                saveErrorKey = "wallet.creation.generate.error"
            }
        }
    }
}
