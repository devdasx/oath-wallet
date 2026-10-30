import Foundation

/// Midgard's documented RUNE/USD series, scoped to native THORChain only.
/// https://gitlab.com/thorchain/midgard/-/raw/develop/openapi/openapi.yaml
enum ThorchainChart {
    private static let endpoint = "https://gateway.liquify.com/chain/thorchain_midgard/v2/history/rune"

    static func url(at date: Date) throws -> URL {
        let time = date.timeIntervalSince1970
        guard time.isFinite, time >= 90_000, time <= 253_402_300_799 else { throw MarketDataError.invalidResponse }
        var url = URLComponents(string: endpoint)!
        // Exclude the open hour. Its advertised end is in the future and its
        // price is still changing; never present that point as a closing price.
        url.queryItems = [.init(name: "interval", value: "hour"), .init(name: "count", value: "25"),
                          .init(name: "to", value: String(Int64(time) / 3600 * 3600))]
        return url.url!
    }

    static func accepts(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.host == "gateway.liquify.com", parts.port == nil,
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              parts.percentEncodedPath == "/chain/thorchain_midgard/v2/history/rune",
              let query = parts.queryItems, query.count == 3,
              query.filter({ $0.name == "interval" && $0.value == "hour" }).count == 1,
              query.filter({ $0.name == "count" && $0.value == "25" }).count == 1,
              let end = query.first(where: { $0.name == "to" })?.value,
              let time = timestamp(end), time >= 90_000, time % 3600 == 0 else { return false }
        return true
    }

    private static func timestamp(_ text: String) -> Int64? {
        guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }),
              let value = Int64(text), value > 0, value <= 253_402_300_799 else { return nil }
        return value
    }

    static func decode(_ data: Data, at date: Date) throws -> MarketChart {
        struct Interval: Decodable { let startTime: String; let endTime: String; let runePriceUSD: String }
        struct Meta: Decodable { let startTime: String; let endTime: String }
        struct History: Decodable { let intervals: [Interval]; let meta: Meta }
        _ = try url(at: date)
        guard data.count <= 100_000 else { throw MarketDataError.invalidResponse }
        let history = try JSONDecoder().decode(History.self, from: data)
        guard history.intervals.count == 25 else { throw MarketDataError.invalidResponse }
        let end = Int64(date.timeIntervalSince1970) / 3600 * 3600
        guard timestamp(history.meta.endTime) == end,
              timestamp(history.meta.startTime) == end - 25 * 3600 else { throw MarketDataError.invalidResponse }
        var points: [MarketCandle] = []
        for (index, interval) in history.intervals.enumerated() {
            guard timestamp(interval.startTime) == end - Int64(25 - index) * 3600,
                  timestamp(interval.endTime) == end - Int64(24 - index) * 3600,
                  MarketDecoding.validPrice(interval.runePriceUSD), let price = Double(interval.runePriceUSD) else {
                throw MarketDataError.invalidResponse
            }
            points.append(.init(time: Double(end - Int64(24 - index) * 3600), close: price))
        }
        let change = (points[24].close / points[0].close - 1) * 100
        guard change.isFinite else { throw MarketDataError.invalidResponse }
        return .init(points: points, changePercent: change)
    }
}
