import SwiftUI

struct DuplicateWalletImportWarning: Identifiable, Sendable {
    var id: String { wallet.id }

    let wallet: ManagedWallet
}

struct DuplicateWalletImportWarningSheet: View {
    let warning: DuplicateWalletImportWarning
    let isProcessing: Bool
    let errorMessage: String?
    let onOpenOrActivate: () -> Void
    let onChooseDifferent: () -> Void

    var body: some View {
        List {
            Group {
                Section {
                    LabeledContent {
                        Text(verbatim: warning.wallet.name)
                            .multilineTextAlignment(.trailing)
                            .walletPrivacySensitive()
                    } label: {
                        Text("import.duplicate.existing_wallet")
                    }

                    LabeledContent {
                        Text(statusKey)
                            .foregroundStyle(.secondary)
                    } label: {
                        Text("import.duplicate.status")
                    }
                } header: {
                    Text("import.duplicate.title")
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("import.duplicate.message")

                        if let errorMessage {
                            Text(verbatim: errorMessage)
                                .foregroundStyle(WalletTheme.danger)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .walletListRowSurface()
        }
        .walletListAppearance()
        .navigationTitle("import.duplicate.title")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .walletSafeAreaBar(edge: .bottom, spacing: 0) {
            VStack(spacing: 12) {
                PrimaryWalletButton(
                    title: primaryActionKey,
                    hapticPolicy: .silent,
                    action: onOpenOrActivate
                )
                .disabled(isProcessing)

                SecondaryWalletButton(
                    title: "import.duplicate.action.choose_different",
                    action: onChooseDifferent
                )
                .disabled(isProcessing)
            }
            .walletActionScreenMargins()
            .padding(.top, 12)
            .padding(.bottom, 8)
        }
    }

    private var statusKey: LocalizedStringKey {
        warning.wallet.isSelected
            ? "import.duplicate.status.current"
            : "import.duplicate.status.inactive"
    }

    private var primaryActionKey: LocalizedStringKey {
        warning.wallet.isSelected
            ? "import.duplicate.action.open"
            : "import.duplicate.action.activate"
    }
}
