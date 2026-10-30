import Foundation
import GRDB

/// Display-amount search never converts the on-chain quantity to floating point.
/// Fiat matching uses the same current price, FX and currency rounding as the UI.
enum HistorySearch {
    static let function = DatabaseFunction("oath_history_matches", argumentCount: 8, pure: true) { values in
        guard let text = String.fromDatabaseValue(values[0]),
              let atomic = String.fromDatabaseValue(values[1]),
              let decimals = Int.fromDatabaseValue(values[2]),
              let currency = String.fromDatabaseValue(values[5]),
              let localeID = String.fromDatabaseValue(values[6]),
              let query = String.fromDatabaseValue(values[7]) else { return false }
        return matches(text: text, atomic: atomic, decimals: decimals,
            price: String.fromDatabaseValue(values[3]), rate: String.fromDatabaseValue(values[4]),
            currency: currency, locale: Locale(identifier: localeID), query: query)
    }

    static func matches(text: String, atomic: String, decimals: Int, price: String?, rate: String?,
                        currency: String, locale: Locale, query: String) -> Bool {
        let words = normalize(query).split(whereSeparator: \.isWhitespace).map(String.init)
        var searchable = normalize(text)
        if searchable.contains("incoming") { searchable += " received" }
        if searchable.contains("outgoing") { searchable += " sent" }
        if searchable.contains("canceled") { searchable += " cancelled" }
        if words.allSatisfy({ searchable.contains($0) }) { return true }
        // Hashes, addresses and names do not need price formatting at all.
        if words.contains(where: { !searchable.contains($0) && !$0.contains(where: \.isNumber) && $0 != currency.lowercased() }) { return false }
        let units = (try? AtomicAmount(atomic).units(decimals: decimals)) ?? ""
        var fiatAmounts: [String] = []
        var currencySymbol = currency.lowercased()
        if let quantity = Decimal(string: units), let price, let rate,
           let quote = Decimal(string: price), let fx = Decimal(string: rate) {
            let value = quantity * quote * fx
            if !value.isNaN {
                fiatAmounts.append(NSDecimalNumber(decimal: value).stringValue)
                let formatter = NumberFormatter()
                formatter.locale = locale; formatter.numberStyle = .currency; formatter.currencyCode = currency
                currencySymbol = normalize(formatter.currencySymbol)
                if let formatted = formatter.string(from: NSDecimalNumber(decimal: value)) {
                    fiatAmounts.append(normalize(formatted))
                    let fractionDigits = formatter.maximumFractionDigits
                    formatter.numberStyle = .decimal
                    // Keep the currency's precision, including zero-decimal currencies.
                    formatter.minimumFractionDigits = 0
                    formatter.maximumFractionDigits = fractionDigits
                    if let plain = formatter.string(from: NSDecimalNumber(decimal: value)) { fiatAmounts.append(normalize(plain)) }
                }
            }
        }
        return words.allSatisfy { word in
            if searchable.contains(word) { return true }
            guard word.contains(where: \.isNumber) else { return word == currency.lowercased() }
            let hasCurrency = word.contains(currency.lowercased()) || word.contains(currencySymbol) ||
                word.unicodeScalars.contains { $0.properties.generalCategory == .currencySymbol }
            let numberWord = word.replacingOccurrences(of: currency.lowercased(), with: "")
                .replacingOccurrences(of: currencySymbol, with: "")
                .replacingOccurrences(of: currency == "USD" ? "us$" : currency.lowercased(), with: "")
            guard !numberWord.contains(where: \.isLetter) else { return false }
            let normalized = numeric(numberWord, locale: locale)
            let amounts = hasCurrency ? fiatAmounts : [units] + fiatAmounts
            return !normalized.isEmpty && amounts.contains {
                $0.contains(word) || numeric($0, locale: locale).contains(normalized)
            }
        }
    }

    private static func normalize(_ text: String) -> String {
        String(text.compactMap { character -> Character? in
            if character.unicodeScalars.allSatisfy({ $0.properties.generalCategory == .format }) { return nil }
            if let digit = character.wholeNumberValue, (0...9).contains(digit) { return Character(String(digit)) }
            return character
        }).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func numeric(_ text: String, locale: Locale) -> String {
        var text = text.replacingOccurrences(of: "٬", with: "").replacingOccurrences(of: "٫", with: ".")
        if let grouping = locale.groupingSeparator, grouping != "." { text = text.replacingOccurrences(of: grouping, with: "") }
        if let separator = locale.decimalSeparator, separator != "." { text = text.replacingOccurrences(of: separator, with: ".") }
        // Currency symbols, direction signs and spaces do not affect an amount.
        return String(text.filter { $0.isNumber || $0 == "." })
    }
}
