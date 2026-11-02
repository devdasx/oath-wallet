import OathDiagnostics
import Foundation
import OathDatabase

public enum ExchangeRateError: Error, Sendable { case invalidResponse, unavailable }

public protocol ExchangeRateTransport: Sendable {
    func data(from url: URL) async throws -> Data
}

public struct URLSessionRateTransport: ExchangeRateTransport {
    private let session: URLSession

    init(session: URLSession) { self.session = session }

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    public func data(from url: URL) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await DiagnosticHTTP.boundedData(for: request, session: session, maximumBytes: 131_072)
        guard let response = response as? HTTPURLResponse else { throw ExchangeRateError.invalidResponse }
        // DiagnosticHTTP records the filtered provider envelope. Preserve its
        // status for callers too, rather than turning an outage into corrupt data.
        guard response.statusCode == 200 else { throw NSError(domain: "Oath.HTTP", code: response.statusCode) }
        guard let data else { throw ExchangeRateError.invalidResponse }
        return data
    }
}

public enum ExchangeRateFeed {
    public static let endpoints = [
        URL(string: "https://cdn.jsdelivr.net/npm/@fawazahmed0/currency-api@latest/v1/currencies/usd.json")!,
        URL(string: "https://latest.currency-api.pages.dev/v1/currencies/usd.json")!
    ]
    public static let source = "https://github.com/fawazahmed0/exchange-api"

    private struct Payload: Decodable {
        let date: String
        let usd: [String: Decimal]
        private enum Keys: String, CodingKey { case date, usd }
        private struct CurrencyKey: CodingKey {
            let stringValue: String
            var intValue: Int? { nil }
            init(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { return nil }
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: Keys.self)
            date = try values.decode(String.self, forKey: .date)
            let quotes = try values.nestedContainer(keyedBy: CurrencyKey.self, forKey: .usd)
            var fiat: [String: Decimal] = [:]
            for key in quotes.allKeys where CurrencyCatalog.codes.contains(key.stringValue.uppercased()) {
                fiat[key.stringValue] = try quotes.decode(Decimal.self, forKey: key)
            }
            usd = fiat
        }
    }

    public static func decode(_ data: Data, fetchedAt: Date) throws -> USDExchangeRates {
        guard data.count <= 131_072 else { throw ExchangeRateError.invalidResponse }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: payload.date), formatter.string(from: date) == payload.date,
              date <= fetchedAt, fetchedAt.timeIntervalSince(date) < 7 * 86_400,
              payload.usd["usd"] == 1 else { throw ExchangeRateError.invalidResponse }
        var rates: [String: String] = [:]
        for (code, rate) in payload.usd {
            let currency = code.uppercased()
            guard !rate.isNaN, rate > 0, rate < Decimal(string: "1000000000000000")!,
                  rates[currency] == nil else { throw ExchangeRateError.invalidResponse }
            rates[currency] = NSDecimalNumber(decimal: rate).stringValue
        }
        // A truncated or wrong-base response must not erase a working table.
        guard rates.count >= 100, rates["USD"] == "1" else { throw ExchangeRateError.invalidResponse }
        return USDExchangeRates(rates: rates, observedAt: date.timeIntervalSince1970,
                                fetchedAt: fetchedAt.timeIntervalSince1970, source: source)
    }
}

/// One in-flight request for the app, including concurrent scenes and refreshes.
/// Selection only writes the currency preference; it never calls this service.
public actor ExchangeRateService {
    private let database: OathDatabase
    private let transport: any ExchangeRateTransport
    private let now: @Sendable () -> Date
    private var inFlight: Task<USDExchangeRates, Error>?
    private var backoff: (deadline: ContinuousClock.Instant, failure: any Error)?

    public init(database: OathDatabase, transport: any ExchangeRateTransport = URLSessionRateTransport(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.database = database; self.transport = transport; self.now = now
    }

    @discardableResult public func refreshIfNeeded(retryNow: Bool = false) async throws -> USDExchangeRates {
        if let inFlight { return try await inFlight.value }
        if !retryNow, let backoff, ContinuousClock.now < backoff.deadline {
            throw backoff.failure
        }
        let task = Task {
            try await OathDiagnostics.$operationID.withValue(UUID()) { try await loadRates() }
        }
        // Install the task before the first suspension, including the SQL read.
        inFlight = task
        let result = await task.result
        inFlight = nil
        switch result {
        case .success(let rates):
            backoff = nil
            return rates
        case .failure(let error):
            if OathDiagnostics.isExpectedCancellation(error) {
                backoff = nil
            } else {
                backoff = (ContinuousClock.now.advanced(by: .seconds(60)), error)
            }
            throw error
        }
    }

    private func loadRates() async throws -> USDExchangeRates {
        do {
            if let cached = try await database.exchangeRates(), cached.isFresh(at: now()) { return cached }
        } catch {
            OathDiagnostics.record(error, component: "prices", operation: "exchange_rates", context: ["stage": "cache_read"])
            throw error
        }
        var lastFailure: (any Error)?
        for endpoint in ExchangeRateFeed.endpoints {
            let rates: USDExchangeRates
            var stage = "feed_request"
            do {
                let data = try await transport.data(from: endpoint)
                try Task.checkCancellation()
                stage = "feed_decode"
                rates = try ExchangeRateFeed.decode(data, fetchedAt: now())
            } catch {
                if OathDiagnostics.isExpectedCancellation(error) { throw error }
                OathDiagnostics.record(error, component: "prices", operation: "exchange_rates",
                                       context: ["stage": stage, "host": endpoint.host ?? ""])
                lastFailure = error
                continue
            }
            do {
                try await database.saveExchangeRates(rates)
                return rates
            } catch {
                OathDiagnostics.record(error, component: "prices", operation: "exchange_rates",
                                       context: ["stage": "cache_write", "host": endpoint.host ?? ""])
                // A newer mirror can recover rejected data but cannot repair a failed database write.
                switch error as? StoreError {
                case .invalidValue, .staleSync: lastFailure = error
                default: throw error
                }
            }
        }
        throw lastFailure ?? ExchangeRateError.unavailable
    }
}
