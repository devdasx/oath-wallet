import Foundation

enum FXRatesError: Error, Equatable, Sendable {
    case invalidResponse
    case httpFailure(Int)
    case emptyRates
}

struct FXCurrencyRate: Codable, Hashable, Identifiable, Sendable {
    let code: String
    let englishName: String
    let symbol: String
    let ratePerUSD: Decimal
    let rateDate: String

    var id: String { code }
}

struct FXRatesSnapshot: Codable, Sendable {
    static let baseCurrencyFallback = FXRatesSnapshot(
        fetchedAt: Date(timeIntervalSince1970: 0),
        currencies: []
    )

    let fetchedAt: Date
    let currencies: [FXCurrencyRate]

    init(fetchedAt: Date, currencies: [FXCurrencyRate]) {
        self.fetchedAt = fetchedAt

        let baseCode = "USD"
        let suppliedBase = currencies.first {
            $0.code.caseInsensitiveCompare(baseCode) == .orderedSame
        }
        let nonBaseCurrencies = currencies.filter {
            $0.code.caseInsensitiveCompare(baseCode) != .orderedSame
        }
        let rateDate = suppliedBase?.rateDate
            ?? nonBaseCurrencies.first?.rateDate
            ?? Self.rateDate(for: fetchedAt)
        let englishLocale = Locale(identifier: "en_US")
        let symbolFormatter = NumberFormatter()
        symbolFormatter.locale = englishLocale
        symbolFormatter.numberStyle = .currency
        symbolFormatter.currencyCode = baseCode
        let baseCurrency = FXCurrencyRate(
            code: baseCode,
            englishName: suppliedBase?.englishName
                ?? englishLocale.localizedString(forCurrencyCode: baseCode)
                ?? baseCode,
            symbol: suppliedBase?.symbol
                ?? symbolFormatter.currencySymbol
                ?? baseCode,
            ratePerUSD: 1,
            rateDate: rateDate
        )

        self.currencies = (nonBaseCurrencies + [baseCurrency]).sorted {
            $0.code < $1.code
        }
    }

    func currency(for code: String) -> FXCurrencyRate? {
        currencies.first {
            $0.code.caseInsensitiveCompare(code) == .orderedSame
        }
    }

    private static func rateDate(for date: Date) -> String {
        String(ISO8601DateFormatter().string(from: date).prefix(10))
    }
}


// Deterministic in-memory fixture; production UI never reaches a provider here.
actor FXRatesClient {
    static let shared = FXRatesClient()
    static let snapshot = FXRatesSnapshot(
        fetchedAt: Date(),
        currencies: Locale.commonISOCurrencyCodes.map {
            FXCurrencyRate(code: $0, englishName: $0, symbol: $0,
                           ratePerUSD: 1, rateDate: "2026-09-05")
        }
    )

    func cachedSnapshot() async -> FXRatesSnapshot? { Self.snapshot }
    func latestSnapshot() async throws -> FXRatesSnapshot { Self.snapshot }
    func refresh() async throws -> FXRatesSnapshot { Self.snapshot }
}
