import OathDiagnostics
import OathArtworkSource
import Foundation

public struct TronMarketTokenInfo: Codable, Sendable, Equatable {
    public let address: String
    public let name: String
    public let symbol: String
    public let decimals: Int
    public let logo: String?
}
public struct TronPrice: Codable, Sendable, Equatable {
    public let mint: String
    public let usd: String
    public let source: String
    public let fetchedAt: Date
}

/// Keyless market data is matched by the exact TRON contract, never ticker.
/// The CoinGecko listing supplies verification independently of DEX price existence.
public struct TronMarkets: Sendable {
    private let transport: any AnkrTransport
    private let permits = AnkrPermits(count: 2)
    private let fallbackPacer = TronMarketPacer()
    public init(transport: any AnkrTransport = AnkrHTTPTransport()) { self.transport = transport }
    private func get(_ url: URL) async throws -> Data {
        try await permits.acquire()
        do {
            var request = URLRequest(url: url)
            request.setValue("OathWallet/1.0", forHTTPHeaderField: "User-Agent")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            for attempt in 0..<3 {
                try Task.checkCancellation()
                if url.host == "api.geckoterminal.com" || url.host == "api.coingecko.com" { try await fallbackPacer.wait() }
                let (data, status) = try await transport.send(request)
                if status == 200 { await permits.release(); return data }
                if (status == 429 || status >= 500) && attempt < 2 { try await Task.sleep(for: .seconds(1 << attempt)); continue }
                throw TronError.http(status)
            }
            throw TronError.transport
        } catch { OathDiagnostics.record(error); await permits.release(); throw error }
    }
    public func catalog() async throws -> Data {
        let data = try await get(URL(string: "https://tokens.coingecko.com/tron/all.json")!)
        _ = try Self.decodeCatalog(data)
        return data
    }
    public static func decodeCatalog(_ data: Data) throws -> [String: TronMarketTokenInfo] {
        let root = try JSONDecoder().decode(TronJSON.self, from: data)
        guard let tokens = root["tokens"].array, !tokens.isEmpty, tokens.count <= 100_000 else { throw TronError.malformed }
        var result: [String: TronMarketTokenInfo] = [:]
        for token in tokens {
            // The chain-specific directory uses null chainId; explicit TRON mainnet is also accepted.
            guard token["chainId"].isNull || token["chainId"].integer == 728126428 else { continue }
            guard let address = token["address"].string, TronIdentity.isToken(address),
                  let decimals = token["decimals"].integer, decimals <= 255,
                  let name = token["name"].string, !name.isEmpty, name.count <= 256,
                  let symbol = token["symbol"].string, !symbol.isEmpty, symbol.count <= 64 else { continue }
            let logo = ArtworkSource.normalized(token["logoURI"].string)
            let info = TronMarketTokenInfo(address: address, name: name, symbol: symbol, decimals: Int(decimals), logo: logo)
            if let old = result[address], old != info { throw TronError.malformed }
            result[address] = info
        }
        guard !result.isEmpty else { throw TronError.malformed }
        return result
    }
    public func nativePrice() async throws -> TronPrice {
        do {
            let data = try await get(URL(string: "https://api.coinbase.com/v2/prices/TRX-USD/spot")!)
            let value = try JSONDecoder().decode(TronJSON.self, from: data)["data"]
            guard value["base"].string == "TRX", value["currency"].string == "USD",
                  let price = value["amount"].string, Self.positive(price) != nil else { throw TronError.malformed }
            return .init(mint: "native", usd: price, source: "Coinbase", fetchedAt: .now)
        } catch { OathDiagnostics.record(error);
            try Task.checkCancellation()
            guard let quote = try await prices(mints: ["TNUC9Qb1rRpS5CbWLmNMxXBjyFoydXjWFR"]).first else { throw TronError.malformed }
            return .init(mint: "native", usd: quote.usd, source: quote.source, fetchedAt: quote.fetchedAt)
        }
    }
    /// Up to 30 token references per group, the documented DEX Screener limit.
    /// Missing pairs remain unknown; failed or unpriced tokens never become $0.
    public func prices(mints: [String]) async throws -> [TronPrice] {
        guard !mints.isEmpty, mints.count <= 30, mints.allSatisfy(TronIdentity.isToken), Set(mints).count == mints.count else { throw TronError.invalidAddress }
        let contracts = mints.filter(TronIdentity.isAddress)
        if contracts.isEmpty { return try await coinGeckoPrices(mints) }
        let url = URL(string: "https://api.dexscreener.com/tokens/v1/tron/" + contracts.joined(separator: ","))!
        var quotes: [TronPrice] = []
        do { quotes = try Self.decodePrices(await get(url), mints: Set(mints)) }
        catch { OathDiagnostics.record(error); try Task.checkCancellation() }
        let found = Set(quotes.map(\.mint))
        let missing = contracts.filter { !found.contains($0) }
        if !missing.isEmpty {
            let fallback = URL(string: "https://api.geckoterminal.com/api/v2/simple/networks/tron/token_price/" + missing.joined(separator: ","))!
            do { quotes += try Self.decodeFallbackPrices(await get(fallback), mints: Set(missing)) }
            catch { OathDiagnostics.record(error);
                try Task.checkCancellation()
                // Try the independent contract-price source below.
            }
        }
        let absent = mints.filter { ref in !quotes.contains { $0.mint == ref } }
        if !absent.isEmpty { quotes += (await OathDiagnostics.attempt("coinGeckoPrices", body: { try await coinGeckoPrices(absent) })) ?? [] }
        return quotes
    }
    /// The anonymous CoinGecko tier accepts one TRON identifier per request,
    /// including legacy TRC-10 IDs that have no DEX contract address.
    private func coinGeckoPrices(_ references: [String]) async throws -> [TronPrice] {
        var quotes: [TronPrice] = []
        for ref in references {
            try Task.checkCancellation()
            let url = URL(string: "https://api.coingecko.com/api/v3/simple/token_price/tron?contract_addresses=" + ref + "&vs_currencies=usd")!
            do {
                let json = try JSONDecoder().decode(TronJSON.self, from: await get(url))
                if let usd = json[ref]["usd"].text, Self.positive(usd) != nil {
                    quotes.append(.init(mint: ref, usd: usd, source: "CoinGecko", fetchedAt: .now))
                }
            } catch { OathDiagnostics.record(error); try Task.checkCancellation() } // Retain healthy quotes in a partial response.
        }
        return quotes
    }
    public static func decodeFallbackPrices(_ data: Data, mints: Set<String>, now: Date = .now) throws -> [TronPrice] {
        let value = try JSONDecoder().decode(TronJSON.self, from: data)["data"]
        guard value["type"].string == "simple_token_price",
              case .object(let prices) = value["attributes"]["token_prices"] else { throw TronError.malformed }
        return prices.keys.sorted().compactMap { mint in
            guard mints.contains(mint), let usd = prices[mint]?.string, positive(usd) != nil else { return nil }
            return .init(mint: mint, usd: usd, source: "GeckoTerminal", fetchedAt: now)
        }
    }
    public static func decodePrices(_ data: Data, mints: Set<String>, now: Date = .now) throws -> [TronPrice] {
        guard let pairs = try JSONDecoder().decode(TronJSON.self, from: data).array else { throw TronError.malformed }
        var best: [String: (Decimal, String)] = [:]
        for pair in pairs {
            guard pair["chainId"].string == "tron", let mint = pair["baseToken"]["address"].string, mints.contains(mint),
                  let usd = pair["priceUsd"].string, positive(usd) != nil,
                  case .number(let liquidity) = pair["liquidity"]["usd"], let depth = positive(liquidity) else { continue }
            if best[mint] == nil || depth > best[mint]!.0 { best[mint] = (depth, usd) }
        }
        return best.keys.sorted().map { .init(mint: $0, usd: best[$0]!.1, source: "DEX Screener", fetchedAt: now) }
    }
    private static func positive(_ value: String) -> Decimal? {
        guard value.count <= 100,
              value.range(of: "^[0-9]+(?:\\.[0-9]+)?(?:[eE][+-]?[0-9]+)?$", options: .regularExpression) != nil,
              let result = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")),
              !result.isNaN, result > 0 else { return nil }
        return result
    }
}

/// GeckoTerminal's public tier allows 30 calls/minute. Reserve slots before
/// suspension so concurrent price chunks cannot burst past that allowance.
private actor TronMarketPacer {
    private var next = ContinuousClock.now
    func wait() async throws {
        let start = max(next, .now)
        next = start.advanced(by: .milliseconds(2100))
        if start > .now { try await Task.sleep(until: start, clock: .continuous) }
        try Task.checkCancellation()
    }
}
