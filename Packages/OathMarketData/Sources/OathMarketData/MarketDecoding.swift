import Foundation

public enum MarketDecoding {
    struct CoinbaseCurrency: Codable, Sendable {
        struct Network: Codable, Sendable {
            let id: String
            let contract_address: String?
        }
        let id: String
        let supported_networks: [Network]?
    }
    struct Spot: Decodable {
        struct Value: Decodable { let amount: String; let base: String; let currency: String }
        let data: Value
    }
    struct Coin: Decodable {
        struct Platform: Decodable { let contract_address: String; let decimal_place: Int? }
        struct Image: Decodable { let small: String?; let large: String? }
        struct Links: Decodable { let homepage: [String]? }
        struct MarketData: Decodable {
            let market_cap: [String: Decimal?]?
            let total_supply: Decimal?
            let circulating_supply: Decimal?
        }
        let id: String
        let name: String
        let symbol: String
        let description: [String: String]?
        let detail_platforms: [String: Platform]?
        let image: Image?
        let links: Links?
        let market_data: MarketData?
    }
    struct Stats: Decodable { let open: String; let last: String }

    static func currencies(_ data: Data) throws -> [CoinbaseCurrency] {
        let values = try JSONDecoder().decode([CoinbaseCurrency].self, from: data)
        guard !values.isEmpty, values.count <= 10_000,
              Set(values.map(\.id)).count == values.count else { throw MarketDataError.invalidResponse }
        return values
    }

    public static func tokenCode(for asset: MarketAsset, directory: Data) throws -> String {
        guard !asset.isNative else { throw MarketDataError.invalidResponse }
        let network = MarketIdentity.coinbaseNetworks[asset.networkID] ?? asset.networkID
        let matches = try currencies(directory).filter { currency in
            (currency.supported_networks ?? []).contains {
                $0.id == network && $0.contract_address.map { !$0.isEmpty && asset.matches($0) } == true
            }
        }
        guard !matches.isEmpty else { throw MarketDataError.notListed }
        // Absence is expected; conflicting or unsafe provider identities are not.
        guard matches.count == 1, let code = matches.first?.id, validCode(code) else {
            throw MarketDataError.invalidResponse
        }
        return code
    }

    public static func quote(_ data: Data, code: String) throws -> MarketQuote {
        let spot = try JSONDecoder().decode(Spot.self, from: data).data
        guard spot.base == code, spot.currency == "USD", validPrice(spot.amount) else { throw MarketDataError.invalidResponse }
        return MarketQuote(code: code, usd: spot.amount)
    }

    public static func information(_ data: Data, for asset: MarketAsset) throws -> AssetInformation {
        let coin = try JSONDecoder().decode(Coin.self, from: data)
        guard !coin.name.isEmpty, coin.name.count <= 200, !coin.symbol.isEmpty, coin.symbol.count <= 80,
              coin.id.count <= 200, coin.id.range(of: "^[a-z0-9-]+$", options: .regularExpression) != nil else {
            throw MarketDataError.invalidResponse
        }
        if asset.isNative {
            guard coin.id == MarketIdentity.native[asset.networkID]?.gecko else { throw MarketDataError.invalidResponse }
        } else {
            guard let platform = MarketIdentity.geckoPlatforms[asset.networkID],
                  let definition = coin.detail_platforms?[platform], asset.matches(definition.contract_address),
                  definition.decimal_place == nil || definition.decimal_place == asset.decimals else {
                throw MarketDataError.invalidResponse
            }
        }
        let image = [coin.image?.large, coin.image?.small].compactMap { $0 }.first {
            guard let url = safeURL($0) else { return false }
            return ["assets.coingecko.com", "coin-images.coingecko.com"].contains(url.host ?? "")
        }
        let caps = coin.market_data?.market_cap?.compactMapValues { $0 }
        let supply = coin.market_data?.total_supply
        let circulating = coin.market_data?.circulating_supply
        let statistics = Array(caps?.values ?? [:].values) + [supply, circulating].compactMap { $0 }
        guard statistics.allSatisfy({ !$0.isNaN && $0 >= 0 }) else { throw MarketDataError.invalidResponse }
        return AssetInformation(providerID: coin.id, name: coin.name, symbol: coin.symbol.uppercased(),
            description: plainDescription(coin.description?["en"] ?? ""), imageURL: image,
            website: coin.links?.homepage?.first { safeURL($0) != nil },
            providerURL: "https://www.coingecko.com/en/coins/" + coin.id,
            marketCaps: caps, totalSupply: supply, circulatingSupply: circulating)
    }

    public static func chart(_ data: Data, stats: Data?, now: Date) throws -> MarketChart {
        let rows = try JSONDecoder().decode([[Double]].self, from: data)
        guard rows.count <= 1_000 else { throw MarketDataError.invalidResponse }
        // Coinbase legitimately returns [] when this window has no trades,
        // including delisted products still present in its currency directory.
        guard !rows.isEmpty else { throw MarketDataError.notListed }
        var samples: [Double: MarketCandle] = [:]
        let end = now.timeIntervalSince1970
        for row in rows {
            guard row.count == 6, row.allSatisfy(\.isFinite), row[0] > 0, row[1] > 0,
                  row[2] >= row[1], row[4] > 0, row[4] >= row[1], row[4] <= row[2] else {
                throw MarketDataError.invalidResponse
            }
            if row[0] >= end - 86_400 && row[0] <= end {
                samples[row[0]] = MarketCandle(time: row[0], close: row[4])
            }
        }
        let points = samples.values.sorted { $0.time < $1.time }
        guard points.count >= 2 else { throw MarketDataError.notListed }
        var change: Double?
        if let stats, let value = try? JSONDecoder().decode(Stats.self, from: stats),
           validPrice(value.open), validPrice(value.last), let open = Double(value.open), let last = Double(value.last) {
            let percent = (last / open - 1) * 100
            if percent.isFinite { change = percent }
        }
        return MarketChart(points: points, changePercent: change)
    }

    static func validCode(_ code: String) -> Bool {
        code.count <= 30 && code.range(of: "^[A-Z0-9]+$", options: .regularExpression) != nil
    }

    static func geckoChart(_ data: Data, now: Date) throws -> MarketChart {
        struct Series: Decodable { let prices: [[Double]] }
        let rows = try JSONDecoder().decode(Series.self, from: data).prices
        guard rows.count <= 2000 else { throw MarketDataError.invalidResponse }
        guard !rows.isEmpty else { throw MarketDataError.notListed }
        var samples: [Double: MarketCandle] = [:]
        let end = now.timeIntervalSince1970
        for row in rows {
            guard row.count == 2, row.allSatisfy(\.isFinite), row[0] > 0, row[1] > 0 else { throw MarketDataError.invalidResponse }
            let time = row[0] / 1000
            if time >= end - 86400, time <= end + 60 { samples[time] = .init(time: time, close: row[1]) }
        }
        let points = samples.values.sorted { $0.time < $1.time }
        guard let first = points.first, let last = points.last, points.count >= 2 else { throw MarketDataError.notListed }
        let change = (last.close / first.close - 1) * 100
        return .init(points: points, changePercent: change.isFinite ? change : nil)
    }
    static func validPrice(_ value: String) -> Bool {
        guard value.count <= 80, value.range(of: "^[0-9]+(\\.[0-9]+)?$", options: .regularExpression) != nil,
              let decimal = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")),
              !decimal.isNaN, decimal > 0, let double = Double(value), double.isFinite else { return false }
        return true
    }
    public static func safeURL(_ value: String) -> URL? {
        guard value.count <= 2_048, let url = URL(string: value), url.scheme == "https",
              let host = url.host, host.contains("."), url.user == nil, url.password == nil,
              !host.hasSuffix(".local"), host != "localhost", host.range(of: "^[0-9.:]+$", options: .regularExpression) == nil else { return nil }
        return url
    }
    static func plainDescription(_ input: String) -> String {
        // Display provider prose as plain text. Never render remote HTML/scripts.
        String(input.prefix(20_000)).replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines).prefix(4_000).description
    }
}
