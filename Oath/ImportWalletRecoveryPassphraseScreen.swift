import SwiftUI

struct ImportWalletRecoveryPassphraseScreen: View {
    let onSave: (String) -> Void
    private let initialPassphrase: String

    @Environment(\.dismiss) private var dismiss
    @State private var passphrase: String
    @State private var confirmation: String
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case passphrase
        case confirmation
    }

    init(
        initialPassphrase: String,
        onSave: @escaping (String) -> Void
    ) {
        self.onSave = onSave
        self.initialPassphrase = initialPassphrase.decomposedStringWithCompatibilityMapping
        _passphrase = State(initialValue: initialPassphrase)
        _confirmation = State(initialValue: initialPassphrase)
    }

    @State private var backgroundExpiry = WalletSensitiveContentLifecycleState()

    var body: some View {
        List {
            Group {
                Section {
                    SecureField(
                        "import.recovery.passphrase.field",
                        text: $passphrase
                    )
                    .walletTextInputSubmitAction(identifier: "importRecoveryPassphrase", returnKeyType: .next) {
                        focusedField = .confirmation
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .walletSensitiveValue()
                    .focused($focusedField, equals: .passphrase)

                    SecureField(
                        "import.recovery.passphrase.confirm_field",
                        text: $confirmation
                    )
                    .walletTextInputSubmitAction(identifier: "importRecoveryConfirmation", returnKeyType: .done) {
                        focusedField = nil
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .walletSensitiveValue()
                    .focused($focusedField, equals: .confirmation)
                } header: {
                    Text("import.recovery.passphrase.section")
                } footer: {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("import.recovery.passphrase.footer")

                        if let validationMessageKey {
                            Text(LocalizedStringKey(validationMessageKey))
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
        .navigationTitle("import.recovery.passphrase.navigation")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                WalletConfirmationButton {
                    saveIfValid()
                }
                .accessibilityLabel(Text("common.save"))
                .disabled(!canSave)
                .accessibilityIdentifier("importRecoveryPassphraseSave")
            }
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
            return "import.recovery.passphrase.too_long"
        }
        if normalizedPassphrase != normalizedConfirmation {
            return "import.recovery.passphrase.mismatch"
        }
        return nil
    }

    private var canSave: Bool {
        validationMessageKey == nil && normalizedPassphrase != initialPassphrase
    }

    private func saveIfValid() {
        guard canSave else { return }
        onSave(normalizedPassphrase)
        dismiss()
    }
}
