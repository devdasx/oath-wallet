import Foundation

/// Independent project information for explicitly verified native assets.
/// Provider contract fields never identify or configure an on-chain asset.
/// A native mapping never applies to wrapped coins or other tokens.
/// https://docs.coinpaprika.com/api-reference/coins/get-coin-by-id
/// https://docs.coinpaprika.com/api-reference/tickers/get-ticker-for-a-specific-coin
enum NativeInformation {
    struct Identity: Sendable {
        let id: String, name: String, symbol: String
        var coinURL: URL { URL(string: "https://api.coinpaprika.com/v1/coins/" + id)! }
        var tickerURL: URL { URL(string: "https://api.coinpaprika.com/v1/tickers/" + id)! }
    }
    static let rune = Identity(id: "rune-thorchain", name: "THORChain", symbol: "RUNE")
    static let doge = Identity(id: "doge-dogecoin", name: "Dogecoin", symbol: "DOGE")
    static let bitcoin = Identity(id: "btc-bitcoin", name: "Bitcoin", symbol: "BTC")
    static let bitcoinCash = Identity(id: "bch-bitcoin-cash", name: "Bitcoin Cash", symbol: "BCH")
    static let sui = Identity(id: "sui-sui", name: "Sui", symbol: "SUI")
    static let aptos = Identity(id: "apt-aptos", name: "Aptos", symbol: "APT")
    // X Layer's native gas asset is OKB. This mapping does not identify an
    // arbitrary ERC-20 named OKB, or supply a token contract to the wallet.
    static let okb = Identity(id: "okb-okb", name: "OKB", symbol: "OKB")

    static func identity(for asset: MarketAsset) -> Identity? {
        guard asset.isNative else { return nil }
        switch (asset.networkID, asset.decimals) {
        case ("thorchain", 8): return rune
        case ("dogecoin", 8): return doge
        case ("bitcoin", 8): return bitcoin
        case ("bitcoincash", 8): return bitcoinCash
        case ("sui", 9): return sui
        case ("aptos", 8): return aptos
        case ("xlayer", 18): return okb
        default: return nil
        }
    }

    static func supports(_ asset: MarketAsset) -> Bool { identity(for: asset) != nil }

    static func accepts(_ url: URL) -> Bool {
        [rune, doge, bitcoin, bitcoinCash, sui, aptos, okb].contains { url == $0.coinURL || url == $0.tickerURL }
    }

    private struct Coin: Decodable {
        struct Links: Decodable { let website: [String]? }
        let id: String
        let name: String
        let symbol: String
        let is_active: Bool
        let description: String?
        let logo: String?
        let links: Links?
    }
    private struct Ticker: Decodable {
        struct Quote: Decodable { let market_cap: Statistic? }
        let id: String
        let name: String
        let symbol: String
        let last_updated: String
        let total_supply: Statistic?
        let circulating_supply: Statistic?
        let quotes: [String: Quote]?
    }
    private struct Statistic: Decodable {
        let value: Decimal?
        init(from decoder: any Decoder) throws {
            let field = try decoder.singleValueContainer()
            // diagnostics: alternative-decoding. The documented absent value
            // is an empty string; null/missing fields are also optional metadata.
            if let string = try? field.decode(String.self) {
                guard string.isEmpty else { throw MarketDataError.invalidResponse }
                value = nil
            } else {
                let number = try field.decode(Decimal.self)
                guard !number.isNaN, number >= 0,
                      NSDecimalNumber(decimal: number).doubleValue.isFinite else { throw MarketDataError.invalidResponse }
                value = number
            }
        }
    }

    static func decode(coin: Data, ticker: Data, for asset: MarketAsset, at now: Date) throws -> CachedMarketValue<AssetInformation> {
        guard let identity = identity(for: asset), coin.count <= 100_000, ticker.count <= 100_000 else { throw MarketDataError.invalidResponse }
        let coin = try JSONDecoder().decode(Coin.self, from: coin)
        let ticker = try JSONDecoder().decode(Ticker.self, from: ticker)
        guard coin.id == identity.id, ticker.id == coin.id,
              coin.name == identity.name, ticker.name == coin.name,
              coin.symbol == identity.symbol, ticker.symbol == coin.symbol, coin.is_active else { throw MarketDataError.invalidResponse }
        let formatter = ISO8601DateFormatter()
        guard ticker.last_updated.count <= 40, let observed = formatter.date(from: ticker.last_updated) else {
            throw MarketDataError.invalidResponse
        }
        let age = now.timeIntervalSince(observed)
        guard age.isFinite, age >= -60, age <= 900 else { throw MarketDataError.invalidResponse }
        // Only this provider's exact project artwork is admitted. Optional missing or
        // unsafe links do not invalidate otherwise verified project information.
        let logo = coin.logo == "https://static.coinpaprika.com/coin/\(identity.id)/logo.png" ? coin.logo : nil
        let cap = ticker.quotes?["USD"]?.market_cap?.value
        return .init(value: .init(providerID: "coinpaprika:" + identity.id, name: coin.name, symbol: coin.symbol,
            description: MarketDecoding.plainDescription(coin.description ?? ""), imageURL: logo,
            website: coin.links?.website?.first { MarketDecoding.safeURL($0) != nil },
            providerURL: "https://coinpaprika.com/coin/\(identity.id)/",
            marketCaps: cap.map { ["usd": $0] }, totalSupply: ticker.total_supply?.value,
            circulatingSupply: ticker.circulating_supply?.value), fetchedAt: observed)
    }
}
