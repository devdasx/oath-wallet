import Foundation
import CoreFoundation
import OathAnkr
import OathDiagnostics

/// Public network + token identity only. No symbol search, account address,
/// wallet identifier, authenticated endpoint, or inferred stablecoin peg.
struct ContractPriceRequest: Sendable {
    enum Provider: String, Sendable { case gecko = "CoinGecko", terminal = "GeckoTerminal", dex = "DEX Screener", llama = "DefiLlama" }
    let provider: Provider
    let url: URL
    let key: String
    let network: String

    static let terminalNetworks = [
        "ethereum":"eth", "arbitrum":"arbitrum", "arc":"arc", "avalanche":"avax", "base":"base",
        "bnb":"bsc", "fantom":"ftm", "flare":"flare", "gnosis":"xdai", "linea":"linea",
        "optimism":"optimism", "polygon":"polygon_pos", "monad":"monad", "unichain":"unichain",
        "hyperevm":"hyperevm", "robinhood":"robinhood", "scroll":"scroll", "somnia":"somnia",
        "story":"story", "taiko":"taiko", "telos":"tlos", "xlayer":"x-layer", "solana":"solana",
        "tron":"tron", "ton":"ton", "aptos":"aptos", "sui":"sui-network", "near":"near",
        "xrpl":"xrpl", "stellar":"stellar", "thorchain":"thorchain"
    ]
    static let dexNetworks = ["bnb":"bsc", "avalanche":"avalanche", "gnosis":"gnosischain", "xlayer":"xlayer"]
    static let llamaNetworks = ["bnb":"bsc", "avalanche":"avax", "gnosis":"xdai", "polygon":"polygon", "near":"near"]

    static func requests(for asset: MarketAsset) -> [Self] {
        guard (0...255).contains(asset.decimals), !asset.reference.isEmpty, asset.reference.utf8.count <= 512 else { return [] }
        func endpoint(_ base: String, _ path: String, query: [URLQueryItem] = []) -> URL {
            var parts = URLComponents(string: base)!
            // Encode a reference as one component: slashes in bank denominations
            // and punctuation in Move types must never alter the endpoint path.
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~:"))
            parts.percentEncodedPath += "/" + path.addingPercentEncoding(withAllowedCharacters: allowed)!
            parts.queryItems = query.isEmpty ? nil : query
            return parts.url!
        }
        let bankProject = asset.networkID == "thorchain" ? MarketIdentity.thorchainProjects[asset.reference] : nil
        if asset.isNative || bankProject != nil {
            guard let coin = asset.isNative ? MarketIdentity.native[asset.networkID]?.gecko : bankProject else { return [] }
            var url = URLComponents(string: "https://api.coingecko.com/api/v3/simple/price")!
            url.queryItems = [.init(name:"ids",value:coin), .init(name:"vs_currencies",value:"usd"), .init(name:"include_last_updated_at",value:"true")]
            return [.init(provider:.gecko,url:url.url!,key:coin,network:asset.networkID),
                .init(provider:.llama,url:endpoint("https://coins.llama.fi/prices/current", "coingecko:"+coin),key:"coingecko:"+coin,network:asset.networkID)]
        }
        guard let terminal = terminalNetworks[asset.networkID] else { return [] }
        let ref = asset.networkID == "ton" ? (try? TonIdentity.friendly(asset.reference)) ?? asset.reference : asset.reference
        var result: [Self] = [
            .init(provider:.terminal,url:endpoint("https://api.geckoterminal.com/api/v2/networks/\(terminal)/tokens",ref),key:ref,network:terminal),
            // This documented endpoint includes chainId on every returned pair.
            // Exact base token AND chain are checked before interpreting priceUsd.
            .init(provider:.dex,url:endpoint("https://api.dexscreener.com/latest/dex/tokens",ref),key:ref,network:dexNetworks[asset.networkID] ?? asset.networkID)
        ]
        if let platform = MarketIdentity.geckoPlatforms[asset.networkID], asset.networkID != "thorchain" {
            var url = URLComponents(string:"https://api.coingecko.com/api/v3/simple/token_price/\(platform)")!
            url.queryItems = [.init(name:"contract_addresses",value:ref), .init(name:"vs_currencies",value:"usd"), .init(name:"include_last_updated_at",value:"true")]
            result.append(.init(provider:.gecko,url:url.url!,key:ref,network:platform))
        }
        let llamaKey = (llamaNetworks[asset.networkID] ?? asset.networkID) + ":" + asset.reference
        result.append(.init(provider:.llama,url:endpoint("https://coins.llama.fi/prices/current",llamaKey),key:llamaKey,network:asset.networkID))
        return result
    }
}

struct ResolvedMarketPrice: Sendable {
    let quote: MarketQuote
    let date: Date
    let source: String
}

enum ContractPriceDecoding {
    static func matches(_ value: String, asset: MarketAsset) -> Bool {
        // Canonicalize only chain-defined address representations. Move module
        // names, NEAR accounts, base58 mints and issuer identities retain case.
        switch asset.networkID {
        case "ton": return (try? TonIdentity.raw(value)) == (try? TonIdentity.raw(asset.reference)) && (try? TonIdentity.raw(value)) != nil
        case "aptos": return (try? AptosIdentity.reference(value)) == asset.reference
        case "sui": return (try? SuiIdentity.reference(value)) == asset.reference
        case "xrpl": return (try? XrplIdentity.reference(value)) == asset.reference
        default: return asset.matches(value)
        }
    }
    static func positive(_ value: Any?) -> Decimal? {
        let string: String
        if let value = value as? String { string = value }
        else if let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() { string = value.stringValue }
        else { return nil }
        guard string.count <= 256, string.range(of: "^(?:0|[1-9][0-9]*)(?:\\.[0-9]+)?(?:[eE][+-]?[0-9]+)?$", options:.regularExpression) != nil,
              let number = Decimal(string:string,locale:Locale(identifier:"en_US_POSIX")), !number.isNaN, number > 0 else { return nil }
        return number
    }
    static func decode(_ data: Data, request: ContractPriceRequest, asset: MarketAsset, now: Date) throws -> ResolvedMarketPrice {
        guard data.count <= 2_000_000,
              let root = try JSONSerialization.jsonObject(with:data) as? [String:Any] else { throw MarketDataError.invalidResponse }
        var price: Decimal?, date = now
        switch request.provider {
        case .gecko:
            let projectLookup = asset.isNative || (asset.networkID == "thorchain" && MarketIdentity.thorchainProjects[asset.reference] == request.key)
            let rows = root.filter { projectLookup ? $0.key == request.key : matches($0.key,asset:asset) }
            guard rows.count <= 1 else { throw MarketDataError.invalidResponse }
            guard let row = rows.first?.value as? [String:Any] else { throw MarketDataError.notListed }
            price = positive(row["usd"])
            guard let timestamp = positive(row["last_updated_at"]) else { throw MarketDataError.invalidResponse }
            date = Date(timeIntervalSince1970:NSDecimalNumber(decimal:timestamp).doubleValue)
        case .llama:
            guard let coins = root["coins"] as? [String:Any] else { throw MarketDataError.invalidResponse }
            let rows = coins.filter {
                guard let colon = $0.key.firstIndex(of:":") else { return false }
                let prefix = String($0.key[..<colon]), ref = String($0.key[$0.key.index(after:colon)...])
                return request.key.hasPrefix("coingecko:") ? $0.key == request.key : prefix == String(request.key.prefix(while:{$0 != ":"})) && matches(ref,asset:asset)
            }
            guard rows.count <= 1 else { throw MarketDataError.invalidResponse }
            guard let row = rows.first?.value as? [String:Any] else { throw MarketDataError.notListed }
            guard let confidence = positive(row["confidence"]), confidence >= Decimal(string:"0.9")!, confidence <= 1 else { throw MarketDataError.notListed }
            if !asset.isNative, asset.networkID != "xrpl", let decimals = row["decimals"] as? Int, decimals != asset.decimals { throw MarketDataError.invalidResponse }
            price = positive(row["price"])
            guard let timestamp = positive(row["timestamp"]) else { throw MarketDataError.invalidResponse }
            date = Date(timeIntervalSince1970:NSDecimalNumber(decimal:timestamp).doubleValue)
        case .terminal:
            guard let token = root["data"] as? [String:Any], let row = token["attributes"] as? [String:Any],
                  let address = row["address"] as? String, matches(address,asset:asset),
                  let id = token["id"] as? String, id == request.network + "_" + address else { throw MarketDataError.invalidResponse }
            if asset.networkID != "xrpl", let decimals = row["decimals"] as? Int, decimals != asset.decimals { throw MarketDataError.invalidResponse }
            // A dust pool is not an adequate portfolio valuation source.
            guard let depth = positive(row["total_reserve_in_usd"]), depth >= 1000 else { throw MarketDataError.notListed }
            price = positive(row["price_usd"])
        case .dex:
            // The API's priceUsd is the BASE asset's price, never the quote token.
            guard let pairs = root["pairs"] as? [[String:Any]] else {
                if root["pairs"] is NSNull { throw MarketDataError.notListed }
                throw MarketDataError.invalidResponse
            }
            guard pairs.count <= 1000 else { throw MarketDataError.invalidResponse }
            var best: (Decimal, Decimal)?
            for row in pairs where row["chainId"] as? String == request.network {
                guard let base = row["baseToken"] as? [String:Any], let address = base["address"] as? String,
                      matches(address,asset:asset), let usd = positive(row["priceUsd"]),
                      let liquidity = row["liquidity"] as? [String:Any], let depth = positive(liquidity["usd"]), depth >= 1000 else { continue }
                if depth > (best?.0 ?? 0) { best = (depth,usd) }
            }
            price = best?.1
        }
        guard let price else { throw MarketDataError.notListed }
        let age = now.timeIntervalSince(date)
        guard age.isFinite, age >= -120, age <= 900 else { throw MarketDataError.notListed }
        return .init(quote:.init(code:asset.isNative ? MarketIdentity.native[asset.networkID]?.coinbase ?? asset.reference : asset.reference,
                               usd:NSDecimalNumber(decimal:price).stringValue),date:date,source:request.provider.rawValue)
    }
}

/// A bounded first-valid-result race. Shared provider work may finish for other
/// callers; it never delays publishing another provider's already valid quote.
/// Late/cancelled losers cannot write the quote or overwrite its timestamp.
struct ParallelMarketPrice {
    struct Candidate: Sendable { let source: String; let fetch: @Sendable () async throws -> ResolvedMarketPrice }
    private enum Outcome: Sendable { case price(ResolvedMarketPrice), failure(MarketDataError), timeout }
    static func first(_ candidates: [Candidate], network: String, timeout: Duration = .seconds(12)) async throws -> ResolvedMarketPrice {
        guard !candidates.isEmpty else { throw MarketDataError.notListed }
        let (stream, sink) = AsyncStream<Outcome>.makeStream(bufferingPolicy:.bufferingNewest(candidates.count+1))
        let tasks = candidates.map { candidate in Task {
            do {
                let price = try await candidate.fetch()
                try Task.checkCancellation()
                sink.yield(.price(price))
            } catch {
                // Cancellation and an absent optional listing are expected.
                if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { return }
                if error as? MarketDataError != .notListed {
                    OathDiagnostics.record(error,component:"market_price",operation:"provider_quote",
                        context:["chain":network,"stage":candidate.source])
                }
                sink.yield(.failure(error as? MarketDataError ?? .unavailable))
            }
        } }
        let timer = Task { do { try await Task.sleep(for:timeout); sink.yield(.timeout) } catch { /* expected race teardown */ } }
        defer { tasks.forEach { $0.cancel() }; timer.cancel(); sink.finish() }
        var failures = 0, reason = MarketDataError.notListed
        for await outcome in stream {
            try Task.checkCancellation()
            switch outcome {
            case .price(let result): return result
            case .timeout: throw MarketDataError.unavailable
            case .failure(let error):
                failures += 1
                if error != .notListed { reason = error }
                if failures == candidates.count { throw reason }
            }
        }
        throw CancellationError()
    }
}
