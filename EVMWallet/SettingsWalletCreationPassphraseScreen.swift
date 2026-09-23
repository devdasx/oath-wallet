import SwiftUI

struct SettingsWalletCreationPassphraseScreen: View {
    let onSave: (String) -> Void

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
                    .walletTextInputSubmitAction(identifier: "settingsCreationPassphrase", returnKeyType: .next) {
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
                    .walletTextInputSubmitAction(identifier: "settingsCreationConfirmation", returnKeyType: .done) {
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
        .navigationTitle("wallet.creation.passphrase.navigation")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                WalletConfirmationButton {
                    saveIfValid()
                }
                .disabled(!isValid)
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
            return "wallet.creation.passphrase.too_long"
        }
        if normalizedPassphrase != normalizedConfirmation {
            return "wallet.creation.passphrase.mismatch"
        }
        return nil
    }

    private var isValid: Bool {
        validationMessageKey == nil
    }

    private func saveIfValid() {
        guard isValid else { return }
        onSave(normalizedPassphrase)
    }
}
