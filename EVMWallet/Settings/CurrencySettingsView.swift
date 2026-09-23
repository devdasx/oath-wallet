import Foundation
import SwiftUI

struct SettingsCurrency: Identifiable, Hashable {
    let rate: FXCurrencyRate
    let flag: String
    let localizedName: String
    let localizedSymbol: String

    var id: String { rate.code }

    init(
        rate: FXCurrencyRate,
        locale: Locale,
        formatter: NumberFormatter
    ) {
        self.rate = rate
        flag = CurrencyFlagResolver.flag(for: rate.code)
        localizedName = locale.localizedString(
            forCurrencyCode: rate.code
        ) ?? rate.englishName
        formatter.currencyCode = rate.code
        localizedSymbol = formatter.currencySymbol ?? rate.symbol
    }

    var localizedShortNameAndCode: String {
        let symbol = localizedSymbol.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !symbol.isEmpty,
              symbol.caseInsensitiveCompare(id) != .orderedSame else {
            return id
        }
        return "\(symbol) · \(id)"
    }

    func matchesSearch(_ query: String) -> Bool {
        localizedName.localizedStandardContains(query)
            || id.localizedStandardContains(query)
            || rate.englishName.localizedStandardContains(query)
            || localizedSymbol.localizedStandardContains(query)
    }
}

enum SettingsCurrencyCatalog {
    static func localizedName(for code: String, locale: Locale) -> String {
        let normalizedCode = code.uppercased()
        return locale.localizedString(forCurrencyCode: normalizedCode)
            ?? normalizedCode
    }

    static func currencies(
        from snapshot: FXRatesSnapshot,
        locale: Locale
    ) -> [SettingsCurrency] {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .currency
        return snapshot.currencies.map {
            SettingsCurrency(
                rate: $0,
                locale: locale,
                formatter: formatter
            )
        }
    }

    static func baseCurrencyFallback(
        locale: Locale
    ) -> [SettingsCurrency] {
        currencies(
            from: .baseCurrencyFallback,
            locale: locale
        )
    }
}

struct CurrencySettingsSections {
    static let commonlyUsedCodes = ["USD", "EUR", "CAD", "JPY"]

    let mostUsed: [SettingsCurrency]
    let allCurrencies: [SettingsCurrency]

    init(
        currencies: [SettingsCurrency],
        regionalCurrencyCode: String,
        selectedCurrencyCode: String
    ) {
        var featuredCodes = Self.commonlyUsedCodes
        let normalizedRegionalCode = regionalCurrencyCode.uppercased()
        if !featuredCodes.contains(normalizedRegionalCode) {
            featuredCodes.append(normalizedRegionalCode)
        }

        let currenciesByCode = Dictionary(
            uniqueKeysWithValues: currencies.map { ($0.id, $0) }
        )
        mostUsed = featuredCodes.compactMap { currenciesByCode[$0] }

        let featuredCodeSet = Set(mostUsed.map(\.id))
        var remaining = currencies.filter {
            !featuredCodeSet.contains($0.id)
        }
        if let selectedIndex = remaining.firstIndex(where: {
            $0.id == selectedCurrencyCode
        }), selectedIndex != remaining.startIndex {
            let selected = remaining.remove(at: selectedIndex)
            remaining.insert(selected, at: remaining.startIndex)
        }
        allCurrencies = remaining
    }

    var isEmpty: Bool {
        mostUsed.isEmpty && allCurrencies.isEmpty
    }
}

enum CurrencyFlagResolver {
    static func flag(for currencyCode: String) -> String {
        guard let regionCode = regionByCurrencyCode[
            currencyCode.uppercased()
        ] else {
            return ""
        }
        return flagEmoji(for: regionCode)
    }

    private static let regionByCurrencyCode: [String: String] = {
        var result: [String: String] = [:]

        for region in Locale.Region.isoRegions.sorted(by: {
            $0.identifier < $1.identifier
        }) {
            let regionCode = region.identifier.uppercased()
            guard isFlagRegionCode(regionCode) else { continue }

            let locale = Locale(identifier: "en_\(regionCode)")
            guard let currencyCode = locale.currency?.identifier.uppercased(),
                  result[currencyCode] == nil else {
                continue
            }
            result[currencyCode] = regionCode
        }

        for (currencyCode, regionCode) in preferredRegions {
            result[currencyCode] = regionCode
        }
        return result
    }()

    private static let preferredRegions: [String: String] = [
        "ANG": "CW",
        "AUD": "AU",
        "BGN": "BG",
        "CAD": "CA",
        "CHF": "CH",
        "CLF": "CL",
        "CNH": "CN",
        "CNY": "CN",
        "DKK": "DK",
        "EUR": "EU",
        "FOK": "FO",
        "GBP": "GB",
        "GGP": "GG",
        "HRK": "HR",
        "ILS": "IL",
        "IMP": "IM",
        "INR": "IN",
        "JEP": "JE",
        "JPY": "JP",
        "KID": "KI",
        "LSL": "LS",
        "MAD": "MA",
        "NOK": "NO",
        "NZD": "NZ",
        "SLE": "SL",
        "SLL": "SL",
        "SSP": "SS",
        "TVD": "TV",
        "USD": "US",
        "VES": "VE",
        "XAF": "CM",
        "XCD": "AG",
        "XCG": "CW",
        "XDR": "UN",
        "XOF": "SN",
        "XPF": "PF",
        "ZWG": "ZW",
        "ZWL": "ZW"
    ]

    private static func isFlagRegionCode(_ value: String) -> Bool {
        value.count == 2 && value.unicodeScalars.allSatisfy {
            (65...90).contains(Int($0.value))
        }
    }

    private static func flagEmoji(for regionCode: String) -> String {
        let regionalIndicatorOffset: UInt32 = 127_397
        let scalars = regionCode.unicodeScalars.compactMap {
            UnicodeScalar(regionalIndicatorOffset + $0.value)
        }
        return String(String.UnicodeScalarView(scalars))
    }
}

struct CurrencySettingsView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale
    @Environment(WalletSettingsStore.self) private var applicationSettings
    @State private var searchText = ""
    @State private var currencies =
        SettingsCurrencyCatalog.baseCurrencyFallback(
            locale: .autoupdatingCurrent
        )
    @State private var hasFailed = false

    var body: some View {
        let sections = visibleSections

        List {
            Group {
                if hasFailed {
                    Section {
                        CurrencyRatesFailureView {
                            Task {
                                await loadCurrencies(forceRefresh: true)
                            }
                        }
                    }
                }

                if sections.isEmpty {
                    Section {
                        WalletSearchEmptyStateView()
                    }
                } else {
                    if !sections.mostUsed.isEmpty {
                        Section {
                            currencyPicker(currencies: sections.mostUsed)
                        } header: {
                            Text("settings.currency.most_used.section")
                                .foregroundStyle(WalletTheme.secondaryLabel)
                        }
                    }

                    if !sections.allCurrencies.isEmpty {
                        Section {
                            currencyPicker(currencies: sections.allCurrencies)
                        } header: {
                            Text("settings.currency.all.section")
                                .foregroundStyle(WalletTheme.secondaryLabel)
                        }
                    }
                }
            }
            .walletListRowSurface()
        }
        .walletListAppearance()
        .listStyle(.insetGrouped)
        .navigationTitle("settings.currency.title")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(
            text: $searchText,
            placement: .toolbar,
            prompt: Text("settings.currency.search")
        )
        .walletTextInputDirection()
        .walletAutomaticSearchToolbarBehavior()
        .animation(
            reduceMotion ? nil : .smooth(duration: 0.2),
            value: applicationSettings.currencyCode
        )
        .task(id: locale.identifier) {
            await loadCurrencies()
        }
    }

    private func currencyPicker(
        currencies: [SettingsCurrency]
    ) -> some View {
        Picker(
            "settings.currency.title",
            selection: currencySelection
        ) {
            ForEach(currencies) { currency in
                CurrencyRateRow(currency: currency)
                    .tag(currency.id)
            }
        }
        .pickerStyle(.inline)
        .labelsHidden()
    }

    private var visibleSections: CurrencySettingsSections {
        let query = searchText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let matches: [SettingsCurrency] = if query.isEmpty {
            currencies
        } else {
            currencies.filter { currency in
                currency.matchesSearch(query)
            }
        }
        return CurrencySettingsSections(
            currencies: matches,
            regionalCurrencyCode:
                WalletFirstRunSettings.regionalCurrencyCode(
                    locale: .autoupdatingCurrent
                ),
            selectedCurrencyCode: applicationSettings.currencyCode
        )
    }

    private func select(_ currency: SettingsCurrency) {
        applicationSettings.selectCurrency(
            code: currency.id,
            ratePerUSD: currency.rate.ratePerUSD
        )
    }

    private var currencySelection: Binding<String> {
        Binding(
            get: { applicationSettings.currencyCode },
            set: { code in
                guard code != applicationSettings.currencyCode,
                      let currency = currencies.first(
                    where: { $0.id == code }
                ) else {
                    return
                }
                select(currency)
                UniHaptic.play(.selection)
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
        currencies = SettingsCurrencyCatalog.currencies(
            from: snapshot,
            locale: locale
        )

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

        applicationSettings.updateSelectedCurrencyRate(selected.ratePerUSD)
    }
}

private struct CurrencyRateRow: View {
    let currency: SettingsCurrency

    var body: some View {
        CurrencyRateRowLayout {
            Text(verbatim: currency.flag)
                .font(.title2)
                .accessibilityHidden(true)
        } primary: {
            Text(verbatim: currency.localizedName)
                .foregroundStyle(WalletTheme.primaryLabel)
                .fixedSize(horizontal: false, vertical: true)
        } secondary: {
            Text(verbatim: currency.localizedShortNameAndCode)
                .font(.subheadline)
                .foregroundStyle(WalletTheme.secondaryLabel)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct CurrencyRateRowLayout<
    FlagContent: View,
    PrimaryContent: View,
    SecondaryContent: View
>: View {
    private let flagContent: FlagContent
    private let primaryContent: PrimaryContent
    private let secondaryContent: SecondaryContent

    init(
        @ViewBuilder flag: () -> FlagContent,
        @ViewBuilder primary: () -> PrimaryContent,
        @ViewBuilder secondary: () -> SecondaryContent
    ) {
        flagContent = flag()
        primaryContent = primary()
        secondaryContent = secondary()
    }

    var body: some View {
        HStack(spacing: 12) {
            flagContent
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                primaryContent
                secondaryContent
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct CurrencyRatesFailureView: View {
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Text("settings.currency.error.title")
                .font(.headline)
        } description: {
            Text("settings.currency.error.message")
        } actions: {
            Button("settings.currency.error.retry", action: UniHaptic.action(retry))
                .walletPrimaryActionButtonStyle()
                .buttonBorderShape(.capsule)
                .controlSize(.large)
        }
    }
}
