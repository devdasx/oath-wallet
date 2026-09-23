import SwiftUI

struct WalletHomeQuickActionsRootScreen: View {
    @Environment(\.locale) private var locale
    @Environment(WalletSettingsStore.self) private var applicationSettings

    let onSelect: (WalletHomeQuickAction) -> Void
    var onContentHeightChanged: (CGFloat) -> Void = { _ in }

    var body: some View {
        List {
            Group {
                Section {
                    Button(action: UniHaptic.action(nil) {
                        onSelect(.currency)
                    }) {
                        HStack {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(WalletHomeQuickAction.currency.titleKey)
                                        .accessibilityIdentifier("wallet-home-currency-menu-title")
                                    Text(
                                        verbatim: localizedCurrencyName
                                    )
                                    .font(.caption)
                                    .foregroundStyle(WalletTheme.secondaryLabel)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            } icon: {
                                Image(
                                    systemName:
                                        WalletHomeQuickAction.currency.systemImage
                                )
                                .accessibilityIdentifier("wallet-home-currency-menu-icon")
                            }
                            Image(systemName: "chevron.forward")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(WalletTheme.secondaryLabel)
                        }
                    }
                    .foregroundStyle(WalletTheme.primaryLabel)
                    .accessibilityValue(
                        Text(verbatim: localizedCurrencyName)
                    )
                    .accessibilityIdentifier("wallet-home-quick-action-currency")

                    ForEach(nonCurrencyActions) { action in
                        Button(action: UniHaptic.action(nil) {
                            onSelect(action)
                        }) {
                            Label(
                                action.titleKey,
                                systemImage: action.systemImage
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .foregroundStyle(WalletTheme.primaryLabel)
                        .accessibilityIdentifier(
                            "wallet-home-quick-action-\(action.rawValue)"
                        )
                    }
                }
                .listRowBackground(Color.clear)
                .listSectionSeparator(.hidden, edges: .bottom)
            }
            .walletListRowSurface()
        }
        .walletListAppearance()
        .listStyle(.plain)
        .contentMargins(.vertical, 0, for: .scrollContent)
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentSize.height
        } action: { _, height in
            guard height > 0 else { return }
            onContentHeightChanged(height)
        }
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .accessibilityIdentifier("wallet-home-quick-actions-root")
    }

    private var nonCurrencyActions: [WalletHomeQuickAction] {
        WalletHomeQuickAction.allCases.filter { $0 != .currency }
    }

    private var localizedCurrencyName: String {
        SettingsCurrencyCatalog.localizedName(
            for: applicationSettings.currencyCode,
            locale: locale
        )
    }
}
