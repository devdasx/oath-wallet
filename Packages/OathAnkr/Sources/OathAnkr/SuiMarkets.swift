import OathDiagnostics
import Foundation

/// Same CoinGecko-listed criterion used by ANKR's Advanced API whitelist.
/// A ticker match is never used to identify a token.
public struct SuiCatalog: Codable, Sendable {
    public let ids: [String:String]
    public static let empty = SuiCatalog(ids:[:])
    public func contains(_ reference:String) -> Bool { reference == "native" || ids[reference] != nil }
}
public struct SuiMarkets: Sendable {
    private let transport:any AnkrTransport
    public init(transport:any AnkrTransport = AnkrHTTPTransport()) { self.transport = transport }
    private func read(_ url:URL) async throws -> Data {
        var request = URLRequest(url:url); request.timeoutInterval = 25
        request.setValue("OathWallet/1.0",forHTTPHeaderField:"User-Agent")
        do {
            for attempt in 0..<2 {
                let (data,status) = try await transport.send(request)
                if attempt == 0, [502,503,504].contains(status) {
                    try await Task.sleep(for:.milliseconds(400)); continue
                }
                guard status == 200 else { throw SuiError.http(status) }
                try Task.checkCancellation(); return data
            }
            throw SuiError.transport
        } catch { OathDiagnostics.record(error);
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            throw (error as? SuiError) ?? .transport
        }
    }
    public func catalog() async throws -> SuiCatalog {
        try Self.decodeCatalog(await read(URL(string:"https://api.coingecko.com/api/v3/coins/list?include_platform=true")!))
    }
    public static func decodeCatalog(_ data:Data) throws -> SuiCatalog {
        guard let rows = try JSONDecoder().decode(SuiJSON.self,from:data).array else { throw SuiError.malformed }
        var ids:[String:String] = [:]
        for row in rows {
            guard let type = row["platforms"]["sui"].string, let ref = try? SuiIdentity.reference(type),
                  let id = row["id"].string, !id.isEmpty else { continue }
            // Ambiguous catalogue identities cannot select an arbitrary quote.
            if let old = ids[ref], old != id { throw SuiError.malformed }
            ids[ref] = id
        }
        guard !ids.isEmpty else { throw SuiError.malformed }
        ids["native"] = "sui"; return .init(ids:ids)
    }
    public func nativePrice() async throws -> SuiPrice {
        let data = try await read(URL(string:"https://api.coinbase.com/v2/prices/SUI-USD/spot")!)
        let row = try JSONDecoder().decode(SuiJSON.self,from:data)["data"]
        guard row["base"].string == "SUI", row["currency"].string == "USD", let usd = TonMarkets.positive(row["amount"]) else { throw SuiError.malformed }
        return .init(reference:"native",usd:usd,source:"Coinbase",fetchedAt:.now)
    }
    public func prices(references:[String], catalog:SuiCatalog) async throws -> [SuiPrice] {
        guard !references.isEmpty, references.count <= 30 else { throw SuiError.malformed }
        let refs = try Set(references.map{try SuiIdentity.reference($0)})
        let ids = Set(refs.compactMap{catalog.ids[$0]})
        guard !ids.isEmpty else { return [] }
        var url = URLComponents(string:"https://api.coingecko.com/api/v3/simple/price")!
        url.queryItems = [.init(name:"ids",value:ids.sorted().joined(separator:",")),.init(name:"vs_currencies",value:"usd"),.init(name:"include_last_updated_at",value:"true")]
        return try Self.decodePrices(await read(url.url!),references:refs,catalog:catalog)
    }
    public static func decodePrices(_ data:Data, references:Set<String>, catalog:SuiCatalog, now:Date = .now) throws -> [SuiPrice] {
        let json = try JSONDecoder().decode(SuiJSON.self,from:data)
        var output:[SuiPrice] = []
        for ref in references {
            guard let id = catalog.ids[ref], let usd = TonMarkets.positive(json[id]["usd"]),
                  let timestamp = json[id]["last_updated_at"].text.flatMap(Double.init),
                  timestamp <= now.timeIntervalSince1970+60, now.timeIntervalSince1970-timestamp < 3600 else { continue }
            output.append(.init(reference:ref,usd:usd,source:"CoinGecko",fetchedAt:Date(timeIntervalSince1970:timestamp)))
        }
        return output
    }
    public func dexPrices(references:[String]) async throws -> [SuiPrice] {
        guard !references.isEmpty, references.count <= 30 else { throw SuiError.malformed }
        let refs = try Set(references.map{try SuiIdentity.reference($0)})
        let addresses = try refs.sorted().map{try SuiIdentity.coinType($0)}.joined(separator:",")
        // Percent-encode Move separators too: unescaped :: trips the provider's
        // edge firewall. Tested against multi-token mainnet queries.
        let encoded = addresses.addingPercentEncoding(withAllowedCharacters:.alphanumerics)!
        let url = URL(string:"https://api.dexscreener.com/tokens/v1/sui/"+encoded)!
        return try Self.decodeDexPrices(await read(url),references:refs)
    }
    public static func decodeDexPrices(_ data:Data, references:Set<String>) throws -> [SuiPrice] {
        guard let rows = try JSONDecoder().decode(SuiJSON.self,from:data).array else { throw SuiError.malformed }
        var best:[String:(Decimal,String)] = [:]
        for row in rows {
            guard row["chainId"].string == "sui", let raw = row["baseToken"]["address"].string,
                  let ref = try? SuiIdentity.reference(raw), references.contains(ref),
                  let usd = TonMarkets.positive(row["priceUsd"]), let depth = TonMarkets.positive(row["liquidity"]["usd"]),
                  let liquidity = Decimal(string:depth), liquidity >= 1000 else { continue }
            if liquidity > (best[ref]?.0 ?? 0) { best[ref] = (liquidity,usd) }
        }
        return best.map{.init(reference:$0.key,usd:$0.value.1,source:"DEX Screener",fetchedAt:.now)}
    }
}
