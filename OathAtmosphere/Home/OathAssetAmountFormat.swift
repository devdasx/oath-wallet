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
        nativeSummary(amount, ticker: ticker)
    }

    /// Display only. Signing and editable send amounts use exact atomic units.
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
        return fiatValue(amount)
    }

    /// A single localized policy for balances, history, prices and fees.
    /// Keep Foundation's currency/digit attributes and native symbol placement.
    func fiatValue(_ amount: Decimal, signed: Bool = false) -> AttributedString {
        let value = displayAmount(amount)
        let minimum = Decimal(string: "0.01")!
        let style = Decimal.FormatStyle.Currency(code: currencyCode).locale(locale)
            .precision(.fractionLength(2))
        let signedStyle = style.sign(strategy: .always(showZero: false))
        if value != 0 && abs(value) < minimum {
            let bound = value < 0 ? -minimum : minimum
            return AttributedString(value < 0 ? "> " : "< ") +
                (signed ? bound.formatted(signedStyle.attributed) : bound.formatted(style.attributed))
        }
        return signed ? value.formatted(signedStyle.attributed) : value.formatted(style.attributed)
    }

    func money(_ amount: Decimal, signed: Bool = false) -> String {
        String(fiatValue(amount, signed: signed).characters)
    }

    func fee(_ amount: Decimal?) -> String? {
        guard let amount, !amount.isNaN, amount >= 0 else { return nil }
        return money(amount)
    }

    /// Canonical decimal strings may exceed Decimal's precision. Trim only the
    /// fractional display, preserving all integer digits and never rounding up.
    static func boundedUnits(_ units: String) -> String {
        let parts = units.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return units }
        let fraction = parts[1].prefix(8).reversed().drop(while: { $0 == "0" }).reversed()
        let integer = String(parts[0])
        if fraction.isEmpty, ["0", "-0"].contains(integer), parts[1].contains(where: { $0 != "0" }) {
            return integer.hasPrefix("-") ? "> -0.00000001" : "< 0.00000001"
        }
        return integer + (fraction.isEmpty ? "" : "." + String(fraction))
    }

    private func displayAmount(_ amount: Decimal?) -> Decimal {
        guard let amount, !amount.isNaN else { return .zero }
        return amount
    }
}
