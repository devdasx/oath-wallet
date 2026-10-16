import Foundation

public enum CurrencyCatalog {
    /// Foundation supplies localized fiat names. Include new ISO codes on older
    /// supported iOS versions; never offer the feed's crypto or metal tickers.
    public static let codes = Set(Locale.commonISOCurrencyCodes).union(["XCG", "ZWG"])

    /// Common global currencies, ordered by the BIS 2025 FX turnover survey.
    /// https://www.bis.org/publications/202509-commentary-otc-derivatives
    public static let mostUsedCodes = ["USD", "EUR", "JPY", "GBP", "CNY", "CHF", "AUD", "CAD", "HKD", "SGD"]

    public struct Sections: Equatable, Sendable {
        public let mostUsed: [String]
        public let others: [String]
        public var isEmpty: Bool { mostUsed.isEmpty && others.isEmpty }
    }

    public static func sections(availableCodes: [String], selectedCode: String,
                                deviceLocale: Locale = .autoupdatingCurrent,
                                query: String, displayLocale: Locale) -> Sections {
        // Device Region is an on-device preference, not the person's location.
        // Keep it separate from the app's display language: Arabic must not
        // imply a Saudi currency, for example. Never send this value to a server.
        let regionalCode = deviceLocale.currency?.identifier
        let preferred = [selectedCode] + [regionalCode].compactMap { $0 } + mostUsedCodes
        var featured = Set<String>()
        let mostUsed = preferred.filter { codes.contains($0) && featured.insert($0).inserted }

        // Keep the selected and regional currencies visible even before rates
        // load or while offline. The UI enables selection only with a real rate.
        let available = Set(availableCodes).intersection(codes).union(featured)
        let matches = matching(Array(available), query: query, locale: displayLocale)
        let matchingCodes = Set(matches)
        return Sections(mostUsed: mostUsed.filter { matchingCodes.contains($0) },
                        others: matches.filter { !featured.contains($0) })
    }

    public static func name(_ code: String, locale: Locale) -> String {
        locale.localizedString(forCurrencyCode: code) ?? code
    }

    public static func matching(_ codes: [String], query: String, locale: Locale) -> [String] {
        let words = query.split(whereSeparator: \.isWhitespace)
        return codes.filter { code in
            let fields = [code, name(code, locale: locale), name(code, locale: Locale(identifier: "en"))]
            return words.allSatisfy { word in fields.contains {
                $0.range(of: String(word), options: [.caseInsensitive, .diacriticInsensitive], locale: locale) != nil
            } }
        }.sorted {
            let order = name($0, locale: locale).compare(name($1, locale: locale), options: [.caseInsensitive], locale: locale)
            return order == .orderedSame ? $0 < $1 : order == .orderedAscending
        }
    }
}
