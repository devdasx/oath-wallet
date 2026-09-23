import Foundation

/// Display-only projection of the Amount screen's exact entry state. Never
/// feeds a formatted/rounded display value back into the transaction draft.
struct SendAmountInputPresentation: Equatable {
    let unit: String
    let currencyPrefix: String
    let counterpart: String?

    init(entry: SendAmountEntryState, asset: SendAssetChoice, currency: WalletCurrencyContext, unitUSDPrice: Decimal? = nil) {
        unit = entry.mode == .asset ? asset.symbol : currency.code
        currencyPrefix = entry.mode == .localCurrency
            ? Self.currencyPrefix(for: currency) : ""
        counterpart = Self.counterpart(entry: entry, asset: asset, currency: currency, unitUSDPrice: unitUSDPrice)
    }

    private static func currencyPrefix(for currency: WalletCurrencyContext) -> String {
        // Reuse the app's cached POSIX formatter: $ / € / £ where available,
        // otherwise a currency code with the formatter's native spacing (AED).
        // This never reformats the user's unfinished decimal or trailing zeros.
        String(EnglishNumbers.currency(0, currencyCode: currency.code).prefix {
            !($0 >= "0" && $0 <= "9")
        })
    }

    private static func counterpart(
        entry: SendAmountEntryState, asset: SendAssetChoice, currency: WalletCurrencyContext, unitUSDPrice: Decimal? = nil
    ) -> String? {
        guard SendAmountEntryConverter.pricing(asset: asset, currency: currency, unitUSDPrice: unitUSDPrice) != nil else {
            return nil
        }
        // An empty editor is visually zero. A partial "1." is still exactly 1;
        // local-currency input uses the same precision/rounding and Max intent
        // as Review, not a separate approximation of the quantity being sent.
        guard let amount = entry.input.isEmpty ? "0" : entry.assetAmount(asset: asset, currency: currency, unitUSDPrice: unitUSDPrice)
        else { return nil }
        switch entry.mode {
        case .localCurrency:
            return EnglishNumbers.localized("wallet.format.asset_amount", amount, asset.symbol)
        case .asset:
            guard let converted = try? SendAmountEntryConverter.convertedInput(
                amount, from: .asset, to: .localCurrency, asset: asset, currency: currency, unitUSDPrice: unitUSDPrice
            ), let value = Decimal(string: converted, locale: Locale(identifier: "en_US_POSIX"))
            else { return nil }
            return EnglishNumbers.currency(value, currencyCode: currency.code)
        }
    }
}
