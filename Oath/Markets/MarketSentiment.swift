import Foundation
import Observation

struct MarketSentiment: Codable, Equatable, Sendable {
    enum Classification: String, Codable, CaseIterable, Sendable {
        case extremeFear = "Extreme Fear"
        case fear = "Fear"
        case neutral = "Neutral"
        case greed = "Greed"
        case extremeGreed = "Extreme Greed"

        var localizationKey: String {
            switch self {
            case .extremeFear: "markets.sentiment.extreme_fear"
            case .fear: "markets.sentiment.fear"
            case .neutral: "markets.sentiment.neutral"
            case .greed: "markets.sentiment.greed"
            case .extremeGreed: "markets.sentiment.extreme_greed"
            }
        }
    }

    let value: Int
    let classification: Classification
    let date: Date
    let refreshAfter: Date

    static let refreshInterval: TimeInterval = 15 * 60
    static let maximumAge: TimeInterval = 6 * 3600

    func isCurrent(at now: Date) -> Bool {
        (0...100).contains(value)
            && date.timeIntervalSince1970.isFinite
            && date.timeIntervalSince(now) <= 300
            && now.timeIntervalSince(date) < Self.maximumAge
    }

    static func decode(_ data: Data, now: Date) throws -> Self {
        struct Response: Decodable {
            struct Entry: Decodable {
                let value: Int
                let value_classification: String
                let update_time: String
            }
            struct Status: Decodable {
                let errorCode: Int
                enum CodingKeys: String, CodingKey { case errorCode = "error_code" }
                init(from decoder: Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    // CMC's public API returns either 0 or "0" for success.
                    if let code = try? container.decode(Int.self, forKey: .errorCode) {
                        errorCode = code
                    } else {
                        let text = try container.decode(String.self, forKey: .errorCode)
                        guard let code = Int(text) else {
                            throw DecodingError.dataCorruptedError(forKey: .errorCode, in: container,
                                debugDescription: "Invalid provider status")
                        }
                        errorCode = code
                    }
                }
            }
            let data: Entry
            let status: Status
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        let entry = response.data
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard response.status.errorCode == 0,
              (0...100).contains(entry.value),
              let classification = Classification(rawValue: entry.value_classification),
              let date = formatter.date(from: entry.update_time)
                ?? ISO8601DateFormatter().date(from: entry.update_time)
        else { throw URLError(.cannotParseResponse) }
        let result = Self(value: entry.value, classification: classification,
                          date: date, refreshAfter: now.addingTimeInterval(refreshInterval))
        guard result.isCurrent(at: now) else { throw URLError(.cannotParseResponse) }
        return result
    }
}

@MainActor @Observable
final class MarketSentimentStore {
    static let shared = MarketSentimentStore()
    static let endpoint = URL(string: "https://pro-api.coinmarketcap.com/public-api/v3/fear-and-greed/latest")!
    private(set) var reading: MarketSentiment?
    private(set) var isLoading = false
    private let transport: any MarketTransport
    private let defaults: UserDefaults
    private let cacheKey = "markets.sentiment.coinmarketcap.v1"
    private var retryAfter = Date.distantPast
    private var consecutiveFailures = 0

    init(transport: any MarketTransport = MarketHTTPTransport(), defaults: UserDefaults = .standard) {
        self.transport = transport
        self.defaults = defaults
        // Bitcoin-only readings must never appear under the market-wide source.
        defaults.removeObject(forKey: "markets.sentiment.alternative.v1")
        if let data = defaults.data(forKey: cacheKey),
           let saved = try? JSONDecoder().decode(MarketSentiment.self, from: data),
           saved.isCurrent(at: Date()) {
            reading = saved
        }
    }

    func refresh(now: Date = Date()) async {
        if let reading, !reading.isCurrent(at: now) { self.reading = nil }
        guard !isLoading, now >= retryAfter,
              reading == nil || now >= reading!.refreshAfter else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let data = try await transport.data(from: Self.endpoint)
            try Task.checkCancellation()
            let result = try MarketSentiment.decode(data, now: now)
            reading = result
            defaults.set(try JSONEncoder().encode(result), forKey: cacheKey)
            consecutiveFailures = 0
            retryAfter = .distantPast
        } catch {
            guard !Task.isCancelled else { return }
            // Keep only a recent CMC reading on transient errors. A different
            // provider's index is not interchangeable with this methodology.
            consecutiveFailures = min(consecutiveFailures + 1, 5)
            var delay = min(900, 60 * pow(2, Double(consecutiveFailures - 1)))
            if let failure = error as? MarketHTTPFailure, failure.retryAfter.isFinite {
                delay = max(delay, min(3600, max(0, failure.retryAfter)))
            }
            retryAfter = now.addingTimeInterval(delay)
        }
    }
}
