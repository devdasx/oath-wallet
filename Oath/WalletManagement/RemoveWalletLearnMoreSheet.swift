import SwiftUI

/// Wallet-removal education shown before authentication or deletion begins.
struct RemoveWalletLearnMoreSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                List {
                    Group {
                        explanationSection(
                            title: WalletLocalization.string(
                                "settings.wallets.remove.learn_more.next.section"
                            ),
                            message: WalletLocalization.string(
                                "settings.wallets.remove.learn_more.next.message"
                            ),
                            identifier: "removeWalletLearnMoreNext"
                        )
                        explanationSection(
                            title: WalletLocalization.string(
                                "settings.wallets.remove.learn_more.no_backup.section"
                            ),
                            message: WalletLocalization.string(
                                "settings.wallets.remove.learn_more.no_backup.message"
                            ),
                            identifier: "removeWalletLearnMoreNoBackup"
                        )
                        explanationSection(
                            title: WalletLocalization.string(
                                "settings.wallets.remove.learn_more.backup.section"
                            ),
                            message: WalletLocalization.string(
                                "settings.wallets.remove.learn_more.backup.message"
                            ),
                            identifier: "removeWalletLearnMoreBackupAdvice"
                        )
                    }
                    .walletListRowSurface()
                }
                .walletListAppearance()
                .listStyle(.insetGrouped)
                .accessibilityIdentifier("removeWalletLearnMoreSheet")
                .navigationTitle(
                    Text(
                        verbatim: WalletLocalization.string(
                            "settings.wallets.remove.learn_more.navigation"
                        )
                    )
                )
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        WalletCloseButton {
                            dismiss()
                        }
                    }
                }
            }

        }
        .walletSheetPresentation()
    }

    private func explanationSection(
        title: String,
        message: String,
        identifier: String
    ) -> some View {
        Section {
            Text(verbatim: message)
                .foregroundStyle(WalletTheme.primaryLabel)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(identifier)
        } header: {
            Text(verbatim: title)
        }
    }
}
