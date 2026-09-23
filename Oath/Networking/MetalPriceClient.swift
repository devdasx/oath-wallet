import Foundation

enum MetalPriceError: Error, Equatable, Sendable {
    case invalidURL
    case transport(Int)
    case invalidResponse
    case httpFailure(Int)
    case identityMismatch
    case unavailable
}

private enum MetalPriceFetchResult: Sendable {
    case success(CurrencyConverterMarketPrice)
    case failure(MetalPriceError)
}

actor MetalPriceClient {
    static let shared = MetalPriceClient(
        databaseProvider: WalletDatabaseRuntime.require
    )

    static let supportedSymbols = ["XAU", "XAG"]
    private static let provider = "gold-api"
    private static let freshLifetime: TimeInterval = 5 * 60
    private static let defaultBaseURL = URL(
        string: "https://api.gold-api.com"
    )!

    private let session: URLSession
    private let baseURL: URL
    private let databaseProvider:
        @Sendable () throws -> WalletDatabase
    private var memory: [String: CurrencyConverterMarketPrice] = [:]
    private var refreshTask:
        Task<[String: CurrencyConverterMarketPrice], Error>?

    init(
        session: URLSession? = nil,
        database: WalletDatabase,
        baseURL: URL? = nil
    ) {
        databaseProvider = { database }
        self.baseURL = baseURL ?? Self.defaultBaseURL
        self.session = session ?? Self.makeSession()
    }

    private init(
        session: URLSession? = nil,
        databaseProvider:
            @escaping @Sendable () throws -> WalletDatabase
    ) {
        self.databaseProvider = databaseProvider
        baseURL = Self.defaultBaseURL
        self.session = session ?? Self.makeSession()
    }

    private var database: WalletDatabase {
        get throws { try databaseProvider() }
    }

    func cachedPrices(
        maximumAge: TimeInterval? = nil
    ) async -> [String: CurrencyConverterMarketPrice] {
        let now = Date()
        let inMemory = memory.filter { _, quote in
            maximumAge.map {
                now.timeIntervalSince(quote.observedAt) <= $0
            } ?? true
        }
        if !inMemory.isEmpty {
            return inMemory
        }

        let cached = (
            try? await database.cachedCurrencyConverterMarketPrices(
                maximumAge: maximumAge
            )
        ) ?? [:]
        memory.merge(cached, uniquingKeysWith: { _, new in new })
        return cached
    }

    func latestPrices() async throws
        -> [String: CurrencyConverterMarketPrice] {
        let fresh = await cachedPrices(
            maximumAge: Self.freshLifetime
        )
        if Set(fresh.keys).isSuperset(of: Self.supportedSymbols.map {
            "metal:\($0)"
        }) {
            return fresh
        }

        do {
            return try await refresh()
        } catch {
            let stale = await cachedPrices()
            if !stale.isEmpty { return stale }
            throw error
        }
    }

    func removeCachedData() {
        refreshTask?.cancel()
        refreshTask = nil
        memory.removeAll(keepingCapacity: false)
    }

    func refresh() async throws
        -> [String: CurrencyConverterMarketPrice] {
        if let refreshTask {
            return try await refreshTask.value
        }

        let task = Task {
            try await Self.fetchPrices(
                symbols: Self.supportedSymbols,
                baseURL: baseURL,
                session: session
            )
        }
        refreshTask = task

        do {
            let fetched = try await task.value
            refreshTask = nil
            memory.merge(fetched, uniquingKeysWith: { _, new in new })
            try? await database.saveCurrencyConverterMarketPrices(
                Array(fetched.values)
            )
            return memory
        } catch {
            refreshTask = nil
            throw error
        }
    }

    private static func fetchPrices(
        symbols: [String],
        baseURL: URL,
        session: URLSession
    ) async throws -> [String: CurrencyConverterMarketPrice] {
        let results = await withTaskGroup(
            of: MetalPriceFetchResult.self,
            returning: [MetalPriceFetchResult].self
        ) { group in
            for symbol in symbols {
                group.addTask {
                    do {
                        return .success(
                            try await fetchPrice(
                                symbol: symbol,
                                baseURL: baseURL,
                                session: session
                            )
                        )
                    } catch let error as MetalPriceError {
                        return .failure(error)
                    } catch {
                        return .failure(.invalidResponse)
                    }
                }
            }

            var responses: [MetalPriceFetchResult] = []
            for await result in group {
                responses.append(result)
            }
            return responses
        }

        var prices: [String: CurrencyConverterMarketPrice] = [:]
        var firstFailure: MetalPriceError?
        for result in results {
            switch result {
            case let .success(quote):
                prices[quote.unitID] = quote
            case let .failure(error):
                firstFailure = firstFailure ?? error
            }
        }
        guard !prices.isEmpty else {
            throw firstFailure ?? MetalPriceError.unavailable
        }
        return prices
    }

    private static func fetchPrice(
        symbol: String,
        baseURL: URL,
        session: URLSession
    ) async throws -> CurrencyConverterMarketPrice {
        let normalizedSymbol = symbol.uppercased()
        guard supportedSymbols.contains(normalizedSymbol) else {
            throw MetalPriceError.identityMismatch
        }
        let url = baseURL
            .appendingPathComponent("price", isDirectory: true)
            .appendingPathComponent(normalizedSymbol)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Accept"
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw MetalPriceError.transport(error.code.rawValue)
        } catch {
            throw MetalPriceError.invalidResponse
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw MetalPriceError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw MetalPriceError.httpFailure(httpResponse.statusCode)
        }

        let payload: GoldAPIPriceResponse
        do {
            payload = try JSONDecoder().decode(
                GoldAPIPriceResponse.self,
                from: data
            )
        } catch {
            throw MetalPriceError.invalidResponse
        }
        guard payload.symbol.uppercased() == normalizedSymbol,
              payload.currency.uppercased() == "USD",
              payload.price.value > 0 else {
            throw MetalPriceError.identityMismatch
        }

        guard ISO8601DateFormatter().date(
            from: payload.updatedAt
        ) != nil else {
            throw MetalPriceError.invalidResponse
        }
        let observedAt = Date()
        return CurrencyConverterMarketPrice(
            unitID: "metal:\(normalizedSymbol)",
            priceUSD: payload.price.value,
            provider: provider,
            observedAt: observedAt,
            expiresAt: observedAt.addingTimeInterval(freshLifetime)
        )
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }
}

private struct GoldAPIPriceResponse: Decodable {
    let currency: String
    let price: AssetPriceJSONDecimal
    let symbol: String
    let updatedAt: String
}
