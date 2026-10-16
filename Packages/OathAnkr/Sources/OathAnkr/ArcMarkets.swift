import OathDiagnostics
import Foundation

public struct ArcMarkets: Sendable {
    private let transport: any AnkrTransport
    public init(transport: any AnkrTransport = AnkrHTTPTransport()) { self.transport = transport }
    public func quotes(references:[String],catalog:ArcCatalog) async throws -> [ArcPrice] {
        guard !references.isEmpty, references.count <= 30 else { throw AnkrError.invalidResponse }
        let refs = try Set(references.map(ArcIdentity.address)).sorted()
        var quotes = (await OathDiagnostics.attempt("prices", body: { try await prices(references:refs,catalog:catalog) })) ?? []
        try Task.checkCancellation()
        var missing = refs.filter { ref in !quotes.contains { $0.reference == ref } }
        if !missing.isEmpty { quotes += (await OathDiagnostics.attempt("fallbackPrices", body: { try await fallbackPrices(references:missing) })) ?? [] }
        try Task.checkCancellation()
        missing = refs.filter { ref in !quotes.contains { $0.reference == ref } }
        if !missing.isEmpty { quotes += (await OathDiagnostics.attempt("poolPrices", body: { try await poolPrices(references:missing) })) ?? [] }
        try Task.checkCancellation()
        missing = refs.filter { ref in !quotes.contains { $0.reference == ref } }
        if !missing.isEmpty { quotes += (await OathDiagnostics.attempt("dexPrices", body: { try await dexPrices(references:missing) })) ?? [] }
        try Task.checkCancellation()
        return quotes
    }
    private func read(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url); request.timeoutInterval = 25
        let (data, status) = try await transport.send(request)
        guard status == 200 else { throw AnkrError.http(status) }
        guard data.count <= 32 * 1024 * 1024 else { throw AnkrError.responseTooLarge }
        try Task.checkCancellation(); return data
    }
    public func catalog() async throws -> ArcCatalog {
        try Self.decodeCatalog(await read(URL(string: "https://api.coingecko.com/api/v3/coins/list?include_platform=true")!))
    }
    public static func decodeCatalog(_ data: Data) throws -> ArcCatalog {
        guard let rows = try JSONDecoder().decode(SolanaJSON.self, from: data).array else { throw AnkrError.invalidResponse }
        var ids: [String: String] = [:], ambiguous: Set<String> = []
        for row in rows {
            guard let contract = row["platforms"]["arc"].string,
                  let reference = try? ArcIdentity.address(contract), let id = row["id"].string, !id.isEmpty else { continue }
            if let old = ids[reference], old != id { ambiguous.insert(reference) }
            if reference != ArcIdentity.usdc && reference != ArcIdentity.systemEmitter { ids[reference] = id }
        }
        for reference in ambiguous { ids[reference] = nil }
        guard !ids.isEmpty else { throw AnkrError.invalidResponse }
        return .init(ids: ids)
    }
    public func nativePrice() async throws -> ArcPrice {
        let data = try await read(URL(string: "https://api.coinbase.com/v2/prices/USDC-USD/spot")!)
        let value = try JSONDecoder().decode(SolanaJSON.self, from: data)["data"]
        guard value["base"].string == "USDC", value["currency"].string == "USD",
              let usd = TonMarkets.positive(value["amount"]) else { throw AnkrError.invalidResponse }
        return .init(reference: "native", usd: usd, source: "Coinbase", fetchedAt: .now)
    }
    public func prices(references: [String], catalog: ArcCatalog) async throws -> [ArcPrice] {
        guard references.count <= 30 else { throw AnkrError.invalidResponse }
        let refs = try Set(references.map { try ArcIdentity.address($0) })
        let ids = Set(refs.compactMap { catalog.ids[$0] })
        guard !ids.isEmpty else { return [] }
        var url = URLComponents(string: "https://api.coingecko.com/api/v3/simple/price")!
        url.queryItems = [.init(name: "ids", value: ids.sorted().joined(separator: ",")), .init(name: "vs_currencies", value: "usd"),
                          .init(name: "include_last_updated_at", value: "true")]
        return try Self.decodePrices(await read(url.url!), references: refs, catalog: catalog)
    }
    public static func decodePrices(_ data: Data, references: Set<String>, catalog: ArcCatalog,
                                    now: Date = .now) throws -> [ArcPrice] {
        let json = try JSONDecoder().decode(SolanaJSON.self, from: data)
        return references.compactMap { reference in
            guard let id = catalog.ids[reference], let usd = TonMarkets.positive(json[id]["usd"]),
                  let timestamp = json[id]["last_updated_at"].text.flatMap(Double.init), timestamp.isFinite,
                  timestamp <= now.timeIntervalSince1970 + 60, now.timeIntervalSince1970 - timestamp < 3600 else { return nil }
            return .init(reference: reference, usd: usd, source: "CoinGecko", fetchedAt: Date(timeIntervalSince1970: timestamp))
        }
    }
    public func fallbackPrices(references:[String]) async throws -> [ArcPrice] {
        guard !references.isEmpty, references.count <= 30 else { throw AnkrError.invalidResponse }
        let refs = try Set(references.map(ArcIdentity.address))
        let url = URL(string:"https://coins.llama.fi/prices/current/" + refs.sorted().map { "arc:" + $0 }.joined(separator:","))!
        return try Self.decodeFallback(await read(url),references:refs)
    }
    public static func decodeFallback(_ data:Data,references:Set<String>,now:Date = .now) throws -> [ArcPrice] {
        let coins = try JSONDecoder().decode(SolanaJSON.self,from:data)["coins"]
        guard case .object = coins else { throw AnkrError.invalidResponse }
        return references.compactMap { ref in
            let row = coins["arc:" + ref]
            guard let usd = TonMarkets.positive(row["price"]),
                  let confidence = row["confidence"].text.flatMap(Double.init), (0.9...1).contains(confidence),
                  let time = row["timestamp"].text.flatMap(Double.init), time.isFinite,
                  time <= now.timeIntervalSince1970 + 60, now.timeIntervalSince1970 - time < 3600 else { return nil }
            return .init(reference:ref,usd:usd,source:"DefiLlama",fetchedAt:Date(timeIntervalSince1970:time))
        }
    }
    public func poolPrices(references:[String]) async throws -> [ArcPrice] {
        guard !references.isEmpty, references.count <= 30 else { throw AnkrError.invalidResponse }
        let refs = try Set(references.map(ArcIdentity.address))
        let url = URL(string:"https://api.geckoterminal.com/api/v2/simple/networks/arc/token_price/" + refs.sorted().joined(separator:","))!
        return try Self.decodePoolPrices(await read(url),references:refs)
    }
    public static func decodePoolPrices(_ data:Data,references:Set<String>,now:Date = .now) throws -> [ArcPrice] {
        let json = try JSONDecoder().decode(SolanaJSON.self,from:data)
        guard json["data"]["type"].string == "simple_token_price",
              case .object(let prices) = json["data"]["attributes"]["token_prices"] else { throw AnkrError.invalidResponse }
        // The provider's current quote is keyed by the exact contract on Arc.
        // An absent quote remains absent; no stablecoin peg or ticker guess.
        return prices.compactMap { key,value in
            guard let ref = try? ArcIdentity.address(key), references.contains(ref), let usd = TonMarkets.positive(value) else { return nil }
            return .init(reference:ref,usd:usd,source:"GeckoTerminal",fetchedAt:now)
        }
    }
    public func dexPrices(references: [String]) async throws -> [ArcPrice] {
        guard !references.isEmpty, references.count <= 30 else { throw AnkrError.invalidResponse }
        let refs = try Set(references.map { try ArcIdentity.address($0) })
        let url = URL(string: "https://api.dexscreener.com/tokens/v1/arc/" + refs.sorted().joined(separator: ","))!
        return try Self.decodeDEX(await read(url), references: refs)
    }
    public static func decodeDEX(_ data: Data, references: Set<String>, now: Date = .now) throws -> [ArcPrice] {
        guard let pairs = try JSONDecoder().decode(SolanaJSON.self, from: data).array else { throw AnkrError.invalidResponse }
        var selected: [String: (Decimal, String)] = [:]
        for pair in pairs {
            guard pair["chainId"].string == "arc", let address = pair["baseToken"]["address"].string,
                  let reference = try? ArcIdentity.address(address), references.contains(reference),
                  let price = TonMarkets.positive(pair["priceUsd"]), let liquidity = TonMarkets.positive(pair["liquidity"]["usd"]),
                  let amount = Decimal(string: liquidity, locale: Locale(identifier: "en_US_POSIX")), amount >= 10_000 else { continue }
            if selected[reference].map({ $0.0 < amount }) ?? true { selected[reference] = (amount, price) }
        }
        return selected.map { .init(reference: $0.key, usd: $0.value.1, source: "DEX Screener", fetchedAt: now) }
    }
}
