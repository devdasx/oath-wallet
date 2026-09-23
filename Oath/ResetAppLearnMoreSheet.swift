import SwiftUI

/// Reset-flow education shown before authentication or destructive work begins.
struct ResetAppLearnMoreSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                List {
                    Group {
                        explanationSection(
                            title: WalletLocalization.string(
                                "settings.reset.learn_more.next.section"
                            ),
                            message: WalletLocalization.string(
                                "settings.reset.learn_more.next.message"
                            ),
                            identifier: "resetAppLearnMoreNext"
                        )
                        explanationSection(
                            title: WalletLocalization.string(
                                "settings.reset.learn_more.no_backup.section"
                            ),
                            message: WalletLocalization.string(
                                "settings.reset.learn_more.no_backup.message"
                            ),
                            identifier: "resetAppLearnMoreNoBackup"
                        )
                        explanationSection(
                            title: WalletLocalization.string(
                                "settings.reset.learn_more.backup.section"
                            ),
                            message: WalletLocalization.string(
                                "settings.reset.learn_more.backup.message"
                            ),
                            identifier: "resetAppLearnMoreBackupAdvice"
                        )
                    }
                    .walletListRowSurface()
                }
                .walletListAppearance()
                .listStyle(.insetGrouped)
                .accessibilityIdentifier("resetAppLearnMoreSheet")
                .navigationTitle(
                    Text(
                        verbatim: WalletLocalization.string(
                            "settings.reset.learn_more.navigation"
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
