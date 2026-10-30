import OathDiagnostics
import OathArtworkSource
import Foundation

public struct SolanaTokenInfo: Codable, Sendable, Equatable {
    public let address: String
    public let name: String
    public let symbol: String
    public let decimals: Int
    public let logo: String?
}
public struct SolanaPrice: Codable, Sendable, Equatable {
    public let mint: String
    public let usd: String
    public let source: String
    public let fetchedAt: Date
}

/// Keyless market data is matched by the exact, case-sensitive mint, never ticker.
/// The CoinGecko listing supplies verification independently of DEX price existence.
public struct SolanaMarkets: Sendable {
    private let transport: any AnkrTransport
    private let permits = AnkrPermits(count: 2)
    private let fallbackPacer = SolanaMarketPacer()
    public init(transport: any AnkrTransport = AnkrHTTPTransport()) { self.transport = transport }
    private func get(_ url: URL) async throws -> Data {
        try await permits.acquire()
        do {
            var request = URLRequest(url: url)
            request.setValue("OathWallet/1.0", forHTTPHeaderField: "User-Agent")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            for attempt in 0..<3 {
                try Task.checkCancellation()
                if url.host == "api.geckoterminal.com" { try await fallbackPacer.wait() }
                let (data, status) = try await transport.send(request)
                try Task.checkCancellation()
                if status == 200 { await permits.release(); return data }
                if (status == 429 || status >= 500) && attempt < 2 { try await Task.sleep(for: .seconds(1 << attempt)); continue }
                throw SolanaError.http(status)
            }
            throw SolanaError.transport
        } catch {
            await permits.release()
            // A transport may cancel independently of its caller. Cancellation
            // ends this read; it must not trigger another provider or telemetry.
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            OathDiagnostics.record(error)
            throw error
        }
    }
    public func catalog() async throws -> Data {
        let data = try await get(URL(string: "https://tokens.coingecko.com/solana/all.json")!)
        _ = try Self.decodeCatalog(data)
        return data
    }
    public static func decodeCatalog(_ data: Data) throws -> [String: SolanaTokenInfo] {
        let root = try JSONDecoder().decode(SolanaJSON.self, from: data)
        guard let tokens = root["tokens"].array, !tokens.isEmpty, tokens.count <= 100_000 else { throw SolanaError.malformed }
        var result: [String: SolanaTokenInfo] = [:]
        for token in tokens {
            // CoinGecko's Solana-specific endpoint uses null chainId (Solana
            // has no EVM chain ID). Also accept the SPL token-list mainnet ID.
            guard token["chainId"].isNull || token["chainId"].integer == 101 else { continue }
            guard let address = token["address"].string, SolanaIdentity.isAddress(address),
                  let decimals = token["decimals"].integer, decimals <= 255,
                  let name = token["name"].string, !name.isEmpty, name.count <= 256,
                  let symbol = token["symbol"].string, !symbol.isEmpty, symbol.count <= 64 else { continue }
            let logo = ArtworkSource.normalized(token["logoURI"].string)
            let info = SolanaTokenInfo(address: address, name: name, symbol: symbol, decimals: Int(decimals), logo: logo)
            if let old = result[address], old != info { throw SolanaError.malformed }
            result[address] = info
        }
        guard !result.isEmpty else { throw SolanaError.malformed }
        return result
    }
    public func nativePrice() async throws -> SolanaPrice {
        do {
            let data = try await get(URL(string: "https://api.coinbase.com/v2/prices/SOL-USD/spot")!)
            let value = try JSONDecoder().decode(SolanaJSON.self, from: data)["data"]
            guard value["base"].string == "SOL", value["currency"].string == "USD",
                  let price = value["amount"].string, Self.positive(price) != nil else { throw SolanaError.malformed }
            return .init(mint: "native", usd: price, source: "Coinbase", fetchedAt: .now)
        } catch is CancellationError {
            throw CancellationError()
        } catch { OathDiagnostics.record(error);
            try Task.checkCancellation()
            guard let quote = try await prices(mints: [SolanaIdentity.wrappedSOL]).first else { throw SolanaError.malformed }
            return .init(mint: "native", usd: quote.usd, source: quote.source, fetchedAt: quote.fetchedAt)
        }
    }
    /// Up to 30 mint addresses in one request, the documented DEX Screener limit.
    /// Missing pairs remain unknown; neither a failed request nor an unpriced mint becomes $0.
    public func prices(mints: [String]) async throws -> [SolanaPrice] {
        guard !mints.isEmpty, mints.count <= 30, mints.allSatisfy(SolanaIdentity.isAddress), Set(mints).count == mints.count else { throw SolanaError.invalidAddress }
        let url = URL(string: "https://api.dexscreener.com/tokens/v1/solana/" + mints.joined(separator: ","))!
        var quotes: [SolanaPrice] = []
        var primaryFailed = false
        do { quotes = try Self.decodePrices(await get(url), mints: Set(mints)) }
        catch is CancellationError { throw CancellationError() }
        catch { OathDiagnostics.record(error); try Task.checkCancellation(); primaryFailed = true }
        let found = Set(quotes.map(\.mint))
        let missing = mints.filter { !found.contains($0) }
        if !missing.isEmpty {
            let fallback = URL(string: "https://api.geckoterminal.com/api/v2/simple/networks/solana/token_price/" + missing.joined(separator: ","))!
            do { quotes += try Self.decodeFallbackPrices(await get(fallback), mints: Set(missing)) }
            catch is CancellationError { throw CancellationError() }
            catch { OathDiagnostics.record(error);
                try Task.checkCancellation()
                if primaryFailed && quotes.isEmpty { throw error }
            }
        }
        try Task.checkCancellation()
        return quotes
    }
    public static func decodeFallbackPrices(_ data: Data, mints: Set<String>, now: Date = .now) throws -> [SolanaPrice] {
        let value = try JSONDecoder().decode(SolanaJSON.self, from: data)["data"]
        guard value["type"].string == "simple_token_price",
              case .object(let prices) = value["attributes"]["token_prices"] else { throw SolanaError.malformed }
        return prices.keys.sorted().compactMap { mint in
            guard mints.contains(mint), let usd = prices[mint]?.string, positive(usd) != nil else { return nil }
            return .init(mint: mint, usd: usd, source: "GeckoTerminal", fetchedAt: now)
        }
    }
    public static func decodePrices(_ data: Data, mints: Set<String>, now: Date = .now) throws -> [SolanaPrice] {
        guard let pairs = try JSONDecoder().decode(SolanaJSON.self, from: data).array else { throw SolanaError.malformed }
        var best: [String: (Decimal, String)] = [:]
        for pair in pairs {
            guard pair["chainId"].string == "solana", let mint = pair["baseToken"]["address"].string, mints.contains(mint),
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
private actor SolanaMarketPacer {
    private var next = ContinuousClock.now
    func wait() async throws {
        let start = max(next, .now)
        next = start.advanced(by: .milliseconds(2100))
        if start > .now { try await Task.sleep(until: start, clock: .continuous) }
        try Task.checkCancellation()
    }
}
