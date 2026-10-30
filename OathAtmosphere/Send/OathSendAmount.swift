import Foundation

/// Exact input arithmetic. Decimal is used only for optional fiat conversion;
/// native amounts and balance comparisons retain every atomic digit.
enum OathSendAmount {
    enum Failure: Error, Equatable { case invalid, precision, zero, balanceUnknown, insufficient }

    static func normalized(_ input: String, locale: Locale) -> String? {
        guard input.count <= 450, !input.unicodeScalars.contains(where: { $0.properties.generalCategory == .format }) else { return nil }
        let separator = locale.decimalSeparator ?? "."
        var output = ""
        for character in input.trimmingCharacters(in: .whitespacesAndNewlines) {
            if character == "." || String(character) == separator || character == "٫" {
                output.append(".")
            } else if let digit = character.wholeNumberValue, (0...9).contains(digit),
                      character.unicodeScalars.allSatisfy({ CharacterSet.decimalDigits.contains($0) }) {
                output.append(String(digit))
            } else { return nil }
        }
        guard !output.isEmpty, output != ".", output.filter({ $0 == "." }).count <= 1 else { return nil }
        return output
    }

    static func atomic(_ input: String, decimals: Int, locale: Locale) throws -> String {
        guard (0...255).contains(decimals), let value = normalized(input, locale: locale) else { throw Failure.invalid }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        let fraction = parts.count == 2 ? String(parts[1]) : ""
        // Extra zeroes are harmless, but never round a entered native amount.
        guard fraction.dropFirst(decimals).allSatisfy({ $0 == "0" }) else { throw Failure.precision }
        let raw = String(parts[0]) + String(fraction.prefix(decimals)) + String(repeating: "0", count: max(0, decimals - fraction.count))
        let result = canonical(raw)
        guard result.count <= 193 else { throw Failure.invalid }
        guard result != "0" else { throw Failure.zero }
        return result
    }

    static func validate(_ atomic: String, balance: String?) -> Failure? {
        guard let balance, !balance.isEmpty, balance.utf8.allSatisfy({ (48...57).contains($0) }), balance.count <= 193 else { return .balanceUnknown }
        let limit = canonical(balance)
        return atomic.count > limit.count || (atomic.count == limit.count && atomic > limit) ? .insufficient : nil
    }

    static func units(_ atomic: String, decimals: Int) -> String? {
        guard !atomic.isEmpty, atomic.count <= 193, atomic.utf8.allSatisfy({ (48...57).contains($0) }), (0...255).contains(decimals) else { return nil }
        guard decimals > 0 else { return canonical(atomic) }
        let padded = String(repeating: "0", count: max(0, decimals + 1 - atomic.count)) + atomic
        let split = padded.index(padded.endIndex, offsetBy: -decimals)
        let fraction = padded[split...].reversed().drop(while: { $0 == "0" }).reversed()
        return canonical(String(padded[..<split])) + (fraction.isEmpty ? "" : "." + String(fraction))
    }

    /// Editable fiat amounts are capped at cents in every currency. Round down
    /// so switching units cannot increase the amount the user selected.
    static func fiatInput(_ value: Decimal) -> String? {
        guard !value.isNaN, value >= 0 else { return nil }
        var value = value, rounded = Decimal()
        NSDecimalRound(&rounded, &value, 2, .down)
        return NSDecimalNumber(decimal: rounded).stringValue
    }

    static func fromFiat(_ input: String, price: Decimal, decimals: Int, locale: Locale) throws -> String {
        guard let normalized = normalized(input, locale: locale), normalized.filter({ $0 != "." }).count <= 38,
              var value = Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX")),
              !value.isNaN, value > 0, !price.isNaN, price > 0, ((0...38).contains(decimals) || decimals == 96) else { throw Failure.invalid }
        var divisor = price, result = Decimal(), rounded = Decimal()
        let error = NSDecimalDivide(&result, &value, &divisor, .down)
        guard error == .noError || error == .lossOfPrecision, !result.isNaN else { throw Failure.invalid }
        NSDecimalRound(&rounded, &result, min(decimals,38), .down)
        return try atomic(NSDecimalNumber(decimal: rounded).stringValue, decimals: decimals, locale: Locale(identifier: "en_US_POSIX"))
    }

    /// Display conversion is separate from send validation: an empty/zero
    /// entry has a zero equivalent, not a missing market price. Sub-atomic
    /// fiat values also display zero; atomic() still prevents sending them.
    static func displayUnits(_ input: String, fiat: Bool, price: Decimal?, decimals: Int, locale: Locale) -> String? {
        let price = price ?? 0
        if fiat && (price.isNaN || price <= 0 || !((0...38).contains(decimals) || decimals == 96)) { return nil }
        let value = input.isEmpty ? "0" : input
        guard let normalized = normalized(value, locale: locale) else { return nil }
        if normalized.allSatisfy({ $0 == "0" || $0 == "." }) { return "0" }
        // Expected editable amount validation; never report entered values.
        let raw = fiat
            ? try? fromFiat(value, price: price, decimals: decimals, locale: locale)
            : try? atomic(value, decimals: decimals, locale: locale)
        if let raw { return units(raw, decimals: decimals) }
        if fiat, let value = Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX")),
           value > 0, value / price < pow(10 as Decimal, -decimals) { return "0" }
        return nil
    }

    private static func canonical(_ value: String) -> String {
        let stripped = value.drop(while: { $0 == "0" })
        return stripped.isEmpty ? "0" : String(stripped)
    }
}

/// Max freezes the selected atomic balance independently of its displayed
/// currency. Never convert a rounded fiat label back into a send quantity.
struct OathSendMaximumAmount {
    let atomic: String
    let units: String

    init?(balance: String?, decimals: Int) {
        guard let balance, let units = OathSendAmount.units(balance, decimals: decimals) else { return nil }
        let canonical = balance.drop(while: { $0 == "0" })
        atomic = canonical.isEmpty ? "0" : String(canonical)
        self.units = units
    }

    func input(fiat: Bool, price: Decimal?, currency: String) -> String? {
        guard fiat else { return units }
        guard var price, !price.isNaN, price > 0,
              var quantity = Decimal(string: units, locale: Locale(identifier: "en_US_POSIX")),
              !quantity.isNaN else { return nil }
        var total = Decimal()
        let status = NSDecimalMultiply(&total, &quantity, &price, .plain)
        guard status == .noError || status == .lossOfPrecision, !total.isNaN else { return nil }
        // The rounded label never replaces Max's exact atomic quantity.
        return OathSendAmount.fiatInput(total)
    }

    /// Leaving Max restores the explicit unit preference before applying the
    /// key. Never reinterpret native digits as fiat, or retain Max's exact-send
    /// override after an edit. A no-op key leaves the selection untouched.
    func edited(by key: OathSendKeypadInput.Key, preferredFiat: Bool, price: Decimal?,
                currency: String, decimals: Int, locale: Locale) -> (fiat: Bool, amount: String)? {
        // Missing/unrepresentable prices are expected optional data, not an app
        // failure. Keep native entry without logging amounts or keypad actions.
        let fiatInput = preferredFiat && OathSendUnitPreference.allowsFiat(price: price, decimals: decimals)
            ? input(fiat: true, price: price, currency: currency) : nil
        let fiat = fiatInput != nil
        let before = fiatInput ?? units
        let after = OathSendKeypadInput.applying(key, to: before, fiat: fiat, decimals: decimals, locale: locale)
        guard before != after else { return nil }
        return (fiat, after)
    }
}

/// Only the explicit unit choice is persisted; never the amount or recipient.
enum OathSendUnitPreference {
    static let key = "send.fiatEntry"
    static func isFiat(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }
    static func save(fiat: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(fiat, forKey: key)
    }

    static func allowsFiat(price: Decimal?, decimals: Int) -> Bool {
        guard let price, !price.isNaN, price > 0 else { return false }
        return (0...38).contains(decimals) || decimals == 96
    }

    /// Price availability is temporary and must not overwrite the saved choice.
    /// If a quote disappears mid-entry, never relabel a fiat amount as coins.
    static func availableEntry(fiat: Bool, amount: String, price: Decimal?, decimals: Int) -> (fiat: Bool, amount: String) {
        guard fiat, !allowsFiat(price: price, decimals: decimals) else { return (fiat, amount) }
        return (false, "")
    }
}

/// String-based keypad editing preserves trailing decimal places and never
/// routes native amounts through floating point. No UIKit keyboard is needed.
enum OathSendKeypadInput {
    enum Key: Hashable { case digit(Int), decimal, delete, clear }

    static func applying(_ key: Key, to input: String, fiat: Bool, decimals: Int, locale: Locale) -> String {
        var value = input.isEmpty ? "" : OathSendAmount.normalized(input, locale: locale) ?? ""
        switch key {
        case .clear:
            return ""
        case .delete:
            if !value.isEmpty { value.removeLast() }
        case .decimal:
            guard (fiat || decimals > 0), !value.contains(".") else { return value }
            value = value.isEmpty ? "0." : value + "."
        case .digit(let digit):
            guard (0...9).contains(digit) else { return value }
            if value == "0" { value = String(digit) }
            else {
                if let point = value.firstIndex(of: "."),
                   value.distance(from: point, to: value.endIndex) - 1 >= (fiat ? 2 : decimals) { return value }
                guard value.filter({ $0 != "." }).count < (fiat ? 38 : 450) else { return value }
                value += String(digit)
            }
        }
        return value
    }
}

/// Built once per locale/currency change, not once per key or animation frame.
struct OathSendAmountFormat {
    let decimalSeparator: String
    let digits: [String]
    let prefix: String
    let suffix: String

    init(locale: Locale, currency: String) {
        let number = NumberFormatter()
        number.locale = locale; number.numberStyle = .decimal
        number.usesGroupingSeparator = false; number.maximumFractionDigits = 0
        digits = (0...9).map { number.string(from: NSNumber(value: $0)) ?? String($0) }
        decimalSeparator = locale.decimalSeparator ?? "."
        let money = NumberFormatter()
        money.locale = locale; money.numberStyle = .currency; money.currencyCode = currency
        prefix = money.positivePrefix ?? ""
        suffix = money.positiveSuffix ?? ""
    }

    func number(_ canonical: String) -> String {
        canonical.map { character in
            if character == "." { return decimalSeparator }
            if let digit = character.wholeNumberValue, (0...9).contains(digit) { return digits[digit] }
            return String(character)
        }.joined()
    }

    func amount(_ input: String, fiat: Bool, symbol: String, decimals: Int, belowFiatMinimum: Bool = false) -> String {
        let parts = amountParts(input, fiat: fiat, symbol: symbol, decimals: decimals, belowFiatMinimum: belowFiatMinimum)
        return parts.prefix + parts.number + parts.suffix
    }

    func amountParts(_ input: String, fiat: Bool, symbol: String, decimals: Int, belowFiatMinimum: Bool = false) -> (prefix: String, number: String, suffix: String) {
        if fiat && belowFiatMinimum { return ("< " + prefix, number("0.01"), suffix) }
        let placeholder = fiat || decimals == 0 ? "0" : "0." + String(repeating: "0", count: min(3, decimals))
        let value = number(input.isEmpty ? placeholder : input)
        return fiat ? (prefix, value, suffix) : ("", value, " " + symbol)
    }
}
