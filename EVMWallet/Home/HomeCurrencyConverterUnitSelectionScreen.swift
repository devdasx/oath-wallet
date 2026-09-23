import SwiftUI

struct HomeCurrencyConverterUnitSelectionScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    let units: [CurrencyConverterUnit]
    let selectedID: String
    let excludedIDs: Set<String>
    let onSelect: (CurrencyConverterUnit) -> Void

    @State private var searchText = ""

    var body: some View {
        List {
            Group {
                if visibleUnits.isEmpty {
                    Section {
                        WalletSearchEmptyStateView()
                    }
                } else {
                    unitSection(
                        kind: .fiat,
                        title: "settings.currency.all.section"
                    )
                    unitSection(
                        kind: .metal,
                        title: "settings.converter.metals.section"
                    )
                    unitSection(
                        kind: .crypto,
                        title: "receive.assets.section"
                    )
                }
            }
            .walletListRowSurface()
        }
        .walletListAppearance()
        .listStyle(.insetGrouped)
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(
            text: $searchText,
            placement: .toolbar,
            prompt: Text("settings.converter.search")
        )
        .walletTextInputDirection()
        .walletAutomaticSearchToolbarBehavior()
    }

    private var navigationTitle: LocalizedStringKey {
        selectedID.isEmpty
            ? "settings.converter.add"
            : "settings.converter.title"
    }

    @ViewBuilder
    private func unitSection(
        kind: CurrencyConverterUnitKind,
        title: LocalizedStringKey
    ) -> some View {
        let matchingUnits = visibleUnits.filter { $0.kind == kind }
        if !matchingUnits.isEmpty {
            Section {
                ForEach(matchingUnits) { unit in
                    Button(action: UniHaptic.action {
                        onSelect(unit)
                        UniHaptic.play(.selection)
                        dismiss()
                    }) {
                        HomeCurrencyConverterUnitRow(
                            unit: unit,
                            isSelected: unit.id == selectedID,
                            locale: locale
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!unit.hasUsableRate)
                    .accessibilityAddTraits(
                        unit.id == selectedID ? .isSelected : []
                    )
                }
            } header: {
                Text(title)
                    .foregroundStyle(WalletTheme.secondaryLabel)
            }
        }
    }

    private var visibleUnits: [CurrencyConverterUnit] {
        let selectableUnits = units.filter {
            !excludedIDs.contains($0.id)
        }
        let query = searchText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !query.isEmpty else { return selectableUnits }
        return selectableUnits.filter {
            $0.matches(query, locale: locale)
        }
    }
}

private struct HomeCurrencyConverterUnitRow: View {
    let unit: CurrencyConverterUnit
    let isSelected: Bool
    let locale: Locale

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            if !unit.flag.isEmpty {
                Text(verbatim: unit.flag)
                    .font(.title2)
                    .accessibilityHidden(true)
            } else if let logoSource = unit.logoSource {
                AssetLogoView(
                    source: logoSource,
                    size: 32,
                    diagnosticAssetIdentity: unit.walletAssetID
                )
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: unit.localizedName(locale: locale))
                    .foregroundStyle(
                        !unit.hasUsableRate
                            ? WalletTheme.secondaryLabel
                            : isSelected
                                ? WalletTheme.accent
                                : WalletTheme.primaryLabel
                    )
                    .fixedSize(horizontal: false, vertical: true)

                Text(verbatim: unit.localizedDetail(locale: locale))
                    .font(.subheadline)
                    .foregroundStyle(WalletTheme.secondaryLabel)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !unit.hasUsableRate {
                Text("wallet.assets.add_token.price_unavailable")
                    .font(.caption)
                    .foregroundStyle(WalletTheme.secondaryLabel)
                    .multilineTextAlignment(.trailing)
            }
        }
        .contentShape(Rectangle())
    }
}
