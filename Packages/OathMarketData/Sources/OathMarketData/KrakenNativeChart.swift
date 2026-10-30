import Foundation

/// Exact native BTC/USD, DOGE/USD, OKB/USD and TRX/USD markets, never a ticker search or wrapped token.
/// https://docs.kraken.com/api-reference/market-data/get-ohlc-data
/// The final row is explicitly uncommitted. Display only 24 complete hours.
enum KrakenNativeChart {
    enum Market: CaseIterable {
        case bitcoin, dogecoin, okb, tron
        var pair: String {
            switch self { case .bitcoin: "XBTUSD"; case .dogecoin: "XDGUSD"; case .okb: "OKBUSD"; case .tron: "TRXUSD" }
        }
        var responseKey: String {
            switch self { case .bitcoin: "XXBTZUSD"; case .dogecoin: "XDGUSD"; case .okb: "OKBUSD"; case .tron: "TRXUSD" }
        }
    }
    static func market(for asset: MarketAsset) -> Market? {
        guard asset.isNative else { return nil }
        switch (asset.networkID, asset.decimals) {
        case ("bitcoin", 8): return .bitcoin
        case ("dogecoin", 8): return .dogecoin
        case ("xlayer", 18): return .okb
        case ("tron", 6): return .tron
        default: return nil
        }
    }
    static func url(for market: Market) -> URL {
        URL(string: "https://api.kraken.com/0/public/OHLC?pair=\(market.pair)&interval=60")!
    }
    static func supports(_ asset: MarketAsset) -> Bool {
        market(for: asset) != nil
    }
    static func accepts(_ value: URL) -> Bool {
        Market.allCases.contains { value == url(for: $0) }
    }

    private struct Envelope: Decodable {
        let error: [String]
        let result: Result?
    }
    private struct Result: Decodable {
        let pair: String
        let rows: [Candle]
        let last: Int64
        private struct Key: CodingKey {
            let stringValue: String
            var intValue: Int? { nil }
            init(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { return nil }
        }
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            let pairs = container.allKeys.filter { $0.stringValue != "last" }
            guard pairs.count == 1, let key = pairs.first else { throw MarketDataError.invalidResponse }
            pair = key.stringValue
            rows = try container.decode([Candle].self, forKey: key)
            last = try container.decode(Int64.self, forKey: Key(stringValue: "last"))
        }
    }
    private struct Candle: Decodable {
        let time: Int64
        let open: Double
        let close: Double
        init(from decoder: any Decoder) throws {
            var fields = try decoder.unkeyedContainer()
            guard fields.count == 8 else { throw MarketDataError.invalidResponse }
            time = try fields.decode(Int64.self)
            func number(_ text: String, permitsZero: Bool = false) throws -> Double {
                guard text.count <= 64, text.range(of: #"^(?:0|[1-9][0-9]*)(?:\.[0-9]+)?$"#, options: .regularExpression) != nil,
                      let value = Double(text), value.isFinite, permitsZero ? value >= 0 : value > 0 else { throw MarketDataError.invalidResponse }
                return value
            }
            open = try number(fields.decode(String.self))
            let high = try number(fields.decode(String.self)), low = try number(fields.decode(String.self))
            close = try number(fields.decode(String.self))
            _ = try number(fields.decode(String.self), permitsZero: true) // VWAP may be zero in an empty interval.
            _ = try number(fields.decode(String.self), permitsZero: true)
            let trades = try fields.decode(Int64.self)
            guard time > 0, time % 3600 == 0, high >= max(open, close), low <= min(open, close), high >= low, trades >= 0 else {
                throw MarketDataError.invalidResponse
            }
        }
    }
    static func decode(_ data: Data, market: Market, at now: Date) throws -> MarketChart {
        guard data.count <= 200_000 else { throw MarketDataError.invalidResponse }
        let response = try JSONDecoder().decode(Envelope.self, from: data)
        guard response.error.isEmpty else {
            if response.error.contains("EAPI:Rate limit exceeded") || response.error.contains("EGeneral:Too many requests") { throw MarketDataError.rateLimited }
            throw MarketDataError.unavailable
        }
        guard let result = response.result, result.pair == market.responseKey,
              (25...721).contains(result.rows.count) else { throw MarketDataError.invalidResponse }
        let rows = result.rows
        for (previous, next) in zip(rows, rows.dropFirst()) {
            guard next.time - previous.time == 3600 else { throw MarketDataError.invalidResponse }
        }
        // The provider's polling cursor identifies the last committed candle.
        // A stale server/cache response must not become a fresh chart.
        guard let current = rows.last, let last = rows.dropLast().last,
              result.last == last.time,
              Double(current.time) <= now.timeIntervalSince1970,
              now.timeIntervalSince1970 - Double(current.time) < 3600 else { throw MarketDataError.invalidResponse }
        let closed = Array(rows.dropLast().suffix(24))
        let points = closed.map { MarketCandle(time: Double($0.time) + 3600, close: $0.close) }
        let change = (closed.last!.close / closed.first!.open - 1) * 100
        guard change.isFinite else { throw MarketDataError.invalidResponse }
        return .init(points: points, changePercent: change)
    }
}
