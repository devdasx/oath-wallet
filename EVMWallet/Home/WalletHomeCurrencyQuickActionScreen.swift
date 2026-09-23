import Foundation
import SwiftUI

struct WalletHomeCurrencyQuickActionScreen: View {
    @Environment(\.locale) private var locale
    @Environment(WalletSettingsStore.self) private var applicationSettings

    let onCurrencySelected: () -> Void
    let onBack: () -> Void

    @State private var searchText = ""
    @State private var currencies: [SettingsCurrency]
    @State private var hasFailed = false

    init(
        initialCurrencies: [SettingsCurrency],
        onBack: @escaping () -> Void,
        onCurrencySelected: @escaping () -> Void
    ) {
        _currencies = State(initialValue: initialCurrencies)
        self.onCurrencySelected = onCurrencySelected
        self.onBack = onBack
    }

    var body: some View {
        let sections = visibleSections

        WalletHomeCurrencyNavigationContainer(searchText: $searchText, onBack: onBack) {
            currencyList(sections: sections)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .walletTextInputDirection()
        .task(id: locale.identifier) {
            await loadCurrencies()
        }
    }

    private func currencyList(sections: CurrencySettingsSections) -> some View {
        List {
            Group {
                if hasFailed {
                    Section {
                        ContentUnavailableView {
                            Text("settings.currency.error.title")
                                .font(.headline)
                        } description: {
                            Text("settings.currency.error.message")
                        } actions: {
                            Button("settings.currency.error.retry", action: UniHaptic.action {
                                Task {
                                    await loadCurrencies(
                                        forceRefresh: true
                                    )
                                }
                            })
                            .walletPrimaryActionButtonStyle()
                            .buttonBorderShape(.capsule)
                            .controlSize(.large)
                        }
                    }
                    .listRowBackground(Color.clear)
                }

                if sections.isEmpty {
                    Section {
                        WalletSearchEmptyStateView()
                    }
                    .listRowBackground(Color.clear)
                } else {
                    if !sections.mostUsed.isEmpty {
                        Section {
                            currencyPicker(sections.mostUsed)
                        } header: {
                            Text("settings.currency.most_used.section")
                        }
                        .listRowBackground(Color.clear)
                    }

                    if !sections.allCurrencies.isEmpty {
                        Section {
                            currencyPicker(sections.allCurrencies)
                        } header: {
                            Text("settings.currency.all.section")
                        }
                        .listRowBackground(Color.clear)
                    }
                }
            }
            .walletListRowSurface()
        }
        .walletListAppearance()
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
    }

    private func currencyPicker(
        _ currencies: [SettingsCurrency]
    ) -> some View {
        Picker(
            "settings.currency.title",
            selection: currencySelection
        ) {
            ForEach(currencies) { currency in
                currencyRow(currency)
                    .tag(currency.id)
            }
        }
        .pickerStyle(.inline)
        .labelsHidden()
    }

    private func currencyRow(
        _ currency: SettingsCurrency
    ) -> some View {
        HStack(spacing: 12) {
            Text(verbatim: currency.flag)
                .font(.title3)
                .frame(width: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: currency.localizedName)
                Text(verbatim: currency.localizedShortNameAndCode)
                    .font(.caption)
                    .foregroundStyle(WalletTheme.secondaryLabel)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("wallet-home-currency-\(currency.id)")
    }

    private var visibleSections: CurrencySettingsSections {
        let query = searchText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let matches = query.isEmpty
            ? currencies
            : currencies.filter { $0.matchesSearch(query) }
        return CurrencySettingsSections(
            currencies: matches,
            regionalCurrencyCode:
                WalletFirstRunSettings.regionalCurrencyCode(
                    locale: .autoupdatingCurrent
                ),
            selectedCurrencyCode: applicationSettings.currencyCode
        )
    }

    private var currencySelection: Binding<String> {
        Binding(
            get: { applicationSettings.currencyCode },
            set: { code in
                guard code != applicationSettings.currencyCode,
                      let currency = currencies.first(where: {
                          $0.id == code
                      })
                else {
                    return
                }
                applicationSettings.selectCurrency(
                    code: currency.id,
                    ratePerUSD: currency.rate.ratePerUSD
                )
                UniHaptic.play(.selection)
                onCurrencySelected()
            }
        )
    }

    @MainActor
    private func loadCurrencies(forceRefresh: Bool = false) async {
        var hasStoredSnapshot = false
        if let cached = await FXRatesClient.shared.cachedSnapshot() {
            apply(cached)
            hasStoredSnapshot = true
        } else {
            apply(
                .baseCurrencyFallback,
                repairsMissingSelection: false
            )
        }
        hasFailed = false

        do {
            let snapshot = if forceRefresh {
                try await FXRatesClient.shared.refresh()
            } else {
                try await FXRatesClient.shared.latestSnapshot()
            }
            try Task.checkCancellation()
            apply(snapshot)
        } catch is CancellationError {
            return
        } catch {
            hasFailed = !hasStoredSnapshot
        }
    }

    @MainActor
    private func apply(
        _ snapshot: FXRatesSnapshot,
        repairsMissingSelection: Bool = true
    ) {
        let updatedCurrencies = SettingsCurrencyCatalog.currencies(
            from: snapshot,
            locale: locale
        )
        if currencies != updatedCurrencies {
            currencies = updatedCurrencies
        }

        guard let selected = snapshot.currency(
            for: applicationSettings.currencyCode
        ) else {
            guard repairsMissingSelection else { return }
            applicationSettings.selectCurrency(
                code: WalletCurrencyPreference.defaultCode,
                ratePerUSD: 1
            )
            return
        }
        applicationSettings.updateSelectedCurrencyRate(
            selected.ratePerUSD
        )
    }
}
