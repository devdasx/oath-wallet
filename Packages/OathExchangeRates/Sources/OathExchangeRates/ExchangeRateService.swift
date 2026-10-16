import OathDiagnostics
import Foundation
import OathDatabase

public enum ExchangeRateError: Error, Sendable { case invalidResponse, unavailable }

public protocol ExchangeRateTransport: Sendable {
    func data(from url: URL) async throws -> Data
}

public struct URLSessionRateTransport: ExchangeRateTransport {
    private let session: URLSession

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
        let (data, response) = try await DiagnosticHTTP.data(for: request, session: session)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              data.count <= 131_072 else { throw ExchangeRateError.invalidResponse }
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
            guard CurrencyCatalog.codes.contains(currency) else { continue }
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
    private var retryDeadline: ContinuousClock.Instant?

    public init(database: OathDatabase, transport: any ExchangeRateTransport = URLSessionRateTransport(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.database = database; self.transport = transport; self.now = now
    }

    @discardableResult public func refreshIfNeeded(retryNow: Bool = false) async throws -> USDExchangeRates {
        if let inFlight { return try await inFlight.value }
        if !retryNow, let retryDeadline, ContinuousClock.now < retryDeadline { throw ExchangeRateError.unavailable }
        let database = database, transport = transport, now = now
        let task = Task<USDExchangeRates, Error> {
            let date = now()
            if let cached = try await database.exchangeRates(), cached.isFresh(at: date) { return cached }
            for endpoint in ExchangeRateFeed.endpoints {
                do {
                    let data = try await transport.data(from: endpoint)
                    try Task.checkCancellation()
                    let rates = try ExchangeRateFeed.decode(data, fetchedAt: now())
                    try await database.saveExchangeRates(rates)
                    return rates
                } catch is CancellationError { throw CancellationError() }
                catch { OathDiagnostics.record(error); continue }
            }
            throw ExchangeRateError.unavailable
        }
        // Install the task before the first suspension, including the SQL read.
        inFlight = task
        do {
            let result = try await task.value
            inFlight = nil
            retryDeadline = nil
            return result
        } catch { OathDiagnostics.record(error);
            inFlight = nil
            retryDeadline = ContinuousClock.now.advanced(by: .seconds(60))
            throw error
        }
    }
}
