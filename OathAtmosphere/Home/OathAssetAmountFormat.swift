import Foundation

/// Amounts stay optional until supplied by a balance service. Zero is a display
/// fallback only; it does not turn missing balances or quotes into stored values.
struct OathAssetAmounts: Equatable, Sendable {
    let native: Decimal?
    let fiat: Decimal?
    let currencyCode: String?

    static let unavailable = Self(native: nil, fiat: nil, currencyCode: nil)
}

struct OathAssetAmountFormat {
    let locale: Locale
    var selectedCurrencyCode: String? = nil
    var currencyCode: String { selectedCurrencyCode ?? locale.currency?.identifier ?? "USD" }

    func native(_ amount: Decimal?, ticker: String) -> String {
        let amount = displayAmount(amount)
        // Preserve small native units instead of rounding positive dust to 0.
        let number = amount.formatted(.number.locale(locale).grouping(.never)
            .precision(.fractionLength(7...24)))
        return "\(number) \(ticker)"
    }

    /// List presentation is bounded; stored values and accessibility keep full
    /// precision through `native`. Never display a positive dust balance as zero.
    func nativeSummary(_ amount: Decimal?, ticker: String) -> String {
        let amount = displayAmount(amount)
        let minimum = Decimal(string: "0.00000001", locale: Locale(identifier: "en_US_POSIX"))!
        let format = Decimal.FormatStyle.number.locale(locale).grouping(.never)
            .precision(.fractionLength(0...8)).rounded(rule: .towardZero)
        if amount > 0 && amount < minimum { return "< \(minimum.formatted(format)) \(ticker)" }
        if amount < 0 && amount > -minimum { return "> \((-minimum).formatted(format)) \(ticker)" }
        return "\(amount.formatted(format)) \(ticker)"
    }

    func fiat(_ amounts: OathAssetAmounts) -> AttributedString {
        // Missing/invalid quotes use the same formatted zero as an empty wallet.
        // While changing currency, never relabel the previous currency's amount.
        let amount: Decimal = amounts.currencyCode == currencyCode ? displayAmount(amounts.fiat) : .zero
        // Foundation supplies the currency's minor units (JPY 0, USD 2, JOD 3)
        // as well as localized placement, separators and digits.
        // The localized symbol already identifies the currency (e.g. US$).
        // Keep Foundation's single currency run, including code-only symbols
        // such as JOD, rather than prepending a second currency label.
        return amount.formatted(.currency(code: currencyCode).locale(locale).attributed)
    }

    /// Fees use ISO currency precision, with extra digits only when ordinary
    /// rounding would hide a paid fee. Unknown pricing is distinct from zero.
    func fee(_ amount: Decimal?) -> String? {
        guard let amount, !amount.isNaN, amount >= 0 else { return nil }
        let style = Decimal.FormatStyle.Currency(code: currencyCode).locale(locale)
        let rounded = amount.formatted(style)
        guard amount > 0, rounded == Decimal.zero.formatted(style) else { return rounded }
        let smallest = Decimal(string: "0.00000001", locale: Locale(identifier: "en_US_POSIX"))!
        let precise = style.precision(.fractionLength(2...8))
        return amount < smallest ? "< " + smallest.formatted(precise) : amount.formatted(precise)
    }

    private func displayAmount(_ amount: Decimal?) -> Decimal {
        guard let amount, !amount.isNaN else { return .zero }
        return amount
    }
}
