import SwiftUI

struct WalletPrivateKeyExportSelectionScreen: View {
    let items: [WalletPrivateKeyExportItem]
    let onSelect: (WalletPrivateKeyExportItem) -> Void

    var body: some View {
        List {
            Group {
                Section {
                    ForEach(items) { item in
                        Button(action: UniHaptic.action(nil) {
                            onSelect(item)
                        }) {
                            WalletPrivateKeyExportSelectionRow(item: item)
                        }
                        .buttonStyle(.automatic)
                        .accessibilityHint(
                            Text(
                                "settings.wallets.private_key.export.selection.accessibility_hint"
                            )
                        )
                    }
                } header: {
                    Text(
                        "import.private_key.network.section"
                    )
                } footer: {
                    Text(
                        "settings.wallets.private_key.export.selection.footer"
                    )
                }
            }
            .walletListRowSurface()
        }
        .walletListAppearance()
        .listStyle(.insetGrouped)
        .navigationTitle(
            "import.private_key.network.navigation.title"
        )
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct WalletPrivateKeyExportSelectionRow: View {
    let item: WalletPrivateKeyExportItem

    var body: some View {
        HStack(spacing: 12) {
            AssetLogoView(
                source: item.logoSource,
                size: 40,
                animatesChanges: false
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: item.localizedTitle)
                    .foregroundStyle(WalletTheme.primaryLabel)

                Text(verbatim: item.localizedDetail)
                    .font(.subheadline)
                    .foregroundStyle(WalletTheme.secondaryLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "chevron.forward")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(WalletTheme.tertiaryLabel)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
