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

actor FXRatesClient {
    static let shared = FXRatesClient(
        databaseProvider: WalletDatabaseRuntime.require
    )

    private static let baseCode = "USD"
    private static let cacheLifetime: TimeInterval = 6 * 60 * 60
    private static let frankfurterRatesURL = URL(
        string: "https://api.frankfurter.dev/v2/rates?base=USD"
    )!
    private static let openExchangeRatesURL = URL(
        string: "https://open.er-api.com/v6/latest/USD"
    )!

    private let session: URLSession
    private let router: AdaptiveProviderRouter
    private let serviceID: String
    private let timeoutSeconds: Double
    private let frankfurterURL: URL
    private let openExchangeURL: URL
    private let databaseProvider:
        @Sendable () throws -> WalletDatabase
    private var memorySnapshot: FXRatesSnapshot?
    private var refreshTask: Task<FXRatesSnapshot, Error>?

    init(
        session: URLSession? = nil,
        database: WalletDatabase,
        router: AdaptiveProviderRouter = .shared,
        serviceID: String = "fiat_fx_rates_usd",
        timeoutSeconds: Double = 7,
        frankfurterURL: URL? = nil,
        openExchangeURL: URL? = nil
    ) {
        databaseProvider = { database }
        self.router = router
        self.serviceID = serviceID
        self.timeoutSeconds = timeoutSeconds
        self.frankfurterURL = frankfurterURL ?? Self.frankfurterRatesURL
        self.openExchangeURL = openExchangeURL
            ?? Self.openExchangeRatesURL
        if let session {
            self.session = session
        } else {
            self.session = Self.makeDefaultSession()
        }
    }

    private init(
        session: URLSession? = nil,
        databaseProvider:
            @escaping @Sendable () throws -> WalletDatabase
    ) {
        self.databaseProvider = databaseProvider
        router = .shared
        serviceID = "fiat_fx_rates_usd"
        timeoutSeconds = 7
        frankfurterURL = Self.frankfurterRatesURL
        openExchangeURL = Self.openExchangeRatesURL
        if let session {
            self.session = session
        } else {
            self.session = Self.makeDefaultSession()
        }
    }

    private var database: WalletDatabase {
        get throws {
            try databaseProvider()
        }
    }

    func cachedSnapshot() async -> FXRatesSnapshot? {
        if let memorySnapshot {
            return memorySnapshot
        }

        guard let snapshot = try? await database.cachedFXRates() else {
            return nil
        }

        memorySnapshot = snapshot
        return snapshot
    }

    /// Warms the durable, process-wide rates cache without making any view
    /// wait for the network. A fresh cache is returned immediately; a missing
    /// or stale cache is refreshed through the normal deduplicated request.
    func prewarm() async -> FXRatesSnapshot? {
        do {
            return try await latestSnapshot()
        } catch {
            return await cachedSnapshot()
        }
    }

    func latestSnapshot() async throws -> FXRatesSnapshot {
        if let snapshot = await cachedSnapshot(),
           Date().timeIntervalSince(snapshot.fetchedAt)
            < Self.cacheLifetime {
            return snapshot
        }

        return try await refresh()
    }

    func refresh() async throws -> FXRatesSnapshot {
        if let refreshTask {
            return try await refreshTask.value
        }

        let task = Task {
            try await fetchRemoteSnapshot()
        }
        refreshTask = task

        do {
            let snapshot = try await task.value
            memorySnapshot = snapshot
            try? await database.saveFXRates(snapshot)
            refreshTask = nil
            return snapshot
        } catch {
            refreshTask = nil
            throw error
        }
    }

    private func fetchRemoteSnapshot() async throws -> FXRatesSnapshot {
        let session = session
        let serviceID = serviceID
        let frankfurterURL = frankfurterURL
        let openExchangeURL = openExchangeURL
        let attempts = [
            AdaptiveProviderAttempt<[NormalizedRate]>(
                endpoint: AdaptiveProviderEndpoint(
                    serviceID: serviceID,
                    endpointURL: frankfurterURL,
                    identityURL: AdaptiveProviderIdentity.originURL(
                        for: frankfurterURL
                    ),
                    baselinePriority: 0
                ),
                operation: {
                    try await Self.fetchFrankfurterRates(
                        session: session,
                        url: frankfurterURL
                    )
                }
            ),
            AdaptiveProviderAttempt<[NormalizedRate]>(
                endpoint: AdaptiveProviderEndpoint(
                    serviceID: serviceID,
                    endpointURL: openExchangeURL,
                    identityURL: AdaptiveProviderIdentity.originURL(
                        for: openExchangeURL
                    ),
                    baselinePriority: 1
                ),
                operation: {
                    try await Self.fetchOpenExchangeRates(
                        session: session,
                        url: openExchangeURL
                    )
                }
            )
        ]
        let rates = try await router.executeRead(
            serviceID: serviceID,
            attempts: attempts,
            timeoutSeconds: timeoutSeconds,
            shouldFallback: Self.shouldFallback
        )

        let currencies = rates.compactMap { rate -> FXCurrencyRate? in
            let code = rate.code.uppercased()
            guard
                code.count == 3,
                code != Self.baseCode,
                rate.ratePerUSD > 0
            else {
                return nil
            }

            return FXCurrencyRate(
                code: code,
                englishName: Self.englishName(for: code),
                symbol: Self.symbol(for: code),
                ratePerUSD: rate.ratePerUSD,
                rateDate: rate.rateDate
            )
        }
        .sorted { $0.code < $1.code }

        guard !currencies.isEmpty else {
            throw FXRatesError.emptyRates
        }

        let snapshot = FXRatesSnapshot(
            fetchedAt: Date(),
            currencies: currencies
        )
        return snapshot
    }

    private static func requestData(
        from url: URL,
        session: URLSession
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FXRatesError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw FXRatesError.httpFailure(httpResponse.statusCode)
        }

        return data
    }

    private static func fetchFrankfurterRates(
        session: URLSession,
        url: URL
    ) async throws -> [NormalizedRate] {
        let data = try await requestData(from: url, session: session)
        guard let responses = try JSONSerialization.jsonObject(with: data)
            as? [[String: Any]]
        else {
            throw FXRatesError.invalidResponse
        }
        let rates = responses.compactMap { response -> NormalizedRate? in
            guard
                let base = response["base"] as? String,
                base.uppercased() == baseCode,
                let code = response["quote"] as? String,
                let date = response["date"] as? String,
                let rate = decimalValue(response["rate"])
            else {
                return nil
            }
            return NormalizedRate(
                code: code,
                ratePerUSD: rate,
                rateDate: date
            )
        }
        guard !rates.isEmpty else { throw FXRatesError.emptyRates }
        return rates
    }

    private static func fetchOpenExchangeRates(
        session: URLSession,
        url: URL
    ) async throws -> [NormalizedRate] {
        let data = try await requestData(from: url, session: session)
        guard let response = try JSONSerialization.jsonObject(with: data)
            as? [String: Any]
        else {
            throw FXRatesError.invalidResponse
        }
        guard
            let result = response["result"] as? String,
            result.caseInsensitiveCompare("success") == .orderedSame,
            let base = response["base_code"] as? String,
            base.uppercased() == baseCode,
            let updatedAt = int64Value(
                response["time_last_update_unix"]
            ),
            let responseRates = response["rates"] as? [String: Any]
        else {
            throw FXRatesError.invalidResponse
        }
        let date = String(
            ISO8601DateFormatter()
                .string(
                    from: Date(
                        timeIntervalSince1970:
                            TimeInterval(updatedAt)
                    )
                )
                .prefix(10)
        )
        let rates = responseRates.compactMap { code, value in
            decimalValue(value).map {
                NormalizedRate(
                    code: code,
                    ratePerUSD: $0,
                    rateDate: date
                )
            }
        }
        guard !rates.isEmpty else { throw FXRatesError.emptyRates }
        return rates
    }

    private static func shouldFallback(_ error: Error) -> Bool {
        if ProviderReliabilityClassification.isRetryableTransport(error) {
            return true
        }
        if let ratesError = error as? FXRatesError {
            switch ratesError {
            case .invalidResponse, .emptyRates:
                return true
            case let .httpFailure(status):
                return ProviderReliabilityClassification
                    .isRetryableHTTPStatus(status)
            }
        }
        return error is DecodingError
    }

    private static func englishName(for currencyCode: String) -> String {
        Locale(identifier: "en_US")
            .localizedString(forCurrencyCode: currencyCode)
            ?? currencyCode
    }

    private static func symbol(for currencyCode: String) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .currency
        formatter.currencyCode = currencyCode
        return formatter.currencySymbol ?? currencyCode
    }

    private static func decimalValue(_ value: Any?) -> Decimal? {
        if let number = value as? NSNumber {
            return number.decimalValue
        }
        if let string = value as? String {
            return Decimal(
                string: string,
                locale: Locale(identifier: "en_US_POSIX")
            )
        }
        return nil
    }

    private static func int64Value(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber {
            return number.int64Value
        }
        if let string = value as? String {
            return Int64(string)
        }
        return nil
    }

    private static func makeDefaultSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 10
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }

}

private extension FXRatesClient {
    struct NormalizedRate: Sendable {
        let code: String
        let ratePerUSD: Decimal
        let rateDate: String
    }

}
