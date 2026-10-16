import OathDiagnostics
import Foundation

/// CoinGecko-listed identities are eligible for automatic portfolio visibility.
/// A ticker match is never used to identify a token.
public struct XrplCatalog: Codable, Sendable {
    public let ids: [String:String]
    public let tokens: [String:XrplToken]
    public init(ids:[String:String],tokens:[String:XrplToken] = [:]) { self.ids = ids; self.tokens = tokens }
    public static let empty = XrplCatalog(ids:[:])
    public func contains(_ reference:String) -> Bool { reference == "native" || ids[reference] != nil }
}
public struct XrplMarkets: Sendable {
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
                guard status == 200 else { throw XrplError.http(status) }
                try Task.checkCancellation(); return data
            }
            throw XrplError.transport
        } catch { OathDiagnostics.record(error);
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            throw (error as? XrplError) ?? .transport
        }
    }
    public func catalog() async throws -> XrplCatalog {
        try Self.decodeCatalog(await read(URL(string:"https://api.coingecko.com/api/v3/coins/list?include_platform=true")!))
    }
    private static func catalogReference(_ text:String) throws -> String {
        if let ref = try? XrplIdentity.reference(text) { return ref }
        guard let dot = text.lastIndex(of:".") else { throw XrplError.malformed }
        let code = String(text[..<dot]), bytes = Array(code.utf8)
        guard (4...20).contains(bytes.count) else { throw XrplError.malformed }
        let hex = (bytes+Array(repeating:0,count:20-bytes.count)).map{String(format:"%02X",$0)}.joined()
        return try XrplIdentity.reference(hex+String(text[dot...]))
    }
    public static func decodeCatalog(_ data:Data) throws -> XrplCatalog {
        guard let rows = try JSONDecoder().decode(XrplJSON.self,from:data).array else { throw XrplError.malformed }
        var ids:[String:String] = [:], tokens:[String:XrplToken] = [:]
        for row in rows {
            guard let type = row["platforms"]["xrp"].string, let ref = try? catalogReference(type),
                  let id = row["id"].string, !id.isEmpty else { continue }
            // Ambiguous catalogue identities cannot select an arbitrary quote.
            if let old = ids[ref], old != id { throw XrplError.malformed }
            ids[ref] = id
            if let base = try? XrplToken.issued(ref), let name = row["name"].string.flatMap({try? TronIdentity.clean($0)}) {
                tokens[ref] = .init(reference:ref,name:name,symbol:base.symbol,decimals:base.decimals,logo:nil)
            }
        }
        guard !ids.isEmpty else { throw XrplError.malformed }
        ids["native"] = "ripple"; return .init(ids:ids,tokens:tokens)
    }
    public func nativePrice() async throws -> XrplPrice {
        let data = try await read(URL(string:"https://api.coinbase.com/v2/prices/XRP-USD/spot")!)
        let row = try JSONDecoder().decode(XrplJSON.self,from:data)["data"]
        guard row["base"].string == "XRP", row["currency"].string == "USD", let usd = TonMarkets.positive(row["amount"]) else { throw XrplError.malformed }
        return .init(reference:"native",usd:usd,source:"Coinbase",fetchedAt:.now)
    }
    public func prices(references:[String], catalog:XrplCatalog) async throws -> [XrplPrice] {
        guard !references.isEmpty, references.count <= 30 else { throw XrplError.malformed }
        let refs = try Set(references.map{try XrplIdentity.reference($0)})
        let ids = Set(refs.compactMap{catalog.ids[$0]})
        guard !ids.isEmpty else { return [] }
        var url = URLComponents(string:"https://api.coingecko.com/api/v3/simple/price")!
        url.queryItems = [.init(name:"ids",value:ids.sorted().joined(separator:",")),.init(name:"vs_currencies",value:"usd"),.init(name:"include_last_updated_at",value:"true")]
        return try Self.decodePrices(await read(url.url!),references:refs,catalog:catalog)
    }
    public static func decodePrices(_ data:Data, references:Set<String>, catalog:XrplCatalog, now:Date = .now) throws -> [XrplPrice] {
        let json = try JSONDecoder().decode(XrplJSON.self,from:data)
        var output:[XrplPrice] = []
        for ref in references {
            guard let id = catalog.ids[ref], let usd = TonMarkets.positive(json[id]["usd"]),
                  let timestamp = json[id]["last_updated_at"].text.flatMap(Double.init),
                  timestamp <= now.timeIntervalSince1970+60, now.timeIntervalSince1970-timestamp < 3600 else { continue }
            output.append(.init(reference:ref,usd:usd,source:"CoinGecko",fetchedAt:Date(timeIntervalSince1970:timestamp)))
        }
        return output
    }
    /// Exact currency+issuer matching; never use ticker-only market lookups.
    public func dexPrice(reference:String) async throws -> XrplPrice? {
        let ref = try XrplIdentity.reference(reference)
        guard ref != "native" else { return nil }
        let url = URL(string:"https://api.dexscreener.com/token-pairs/v1/xrpl")!.appendingPathComponent(ref)
        return try Self.decodeDexPrice(await read(url),reference:ref)
    }
    public static func decodeDexPrice(_ data:Data, reference:String) throws -> XrplPrice? {
        guard let rows = try JSONDecoder().decode(XrplJSON.self,from:data).array else { throw XrplError.malformed }
        var best:(Decimal,String)?
        for row in rows {
            guard row["chainId"].string == "xrpl", let address = row["baseToken"]["address"].string,
                  (try? XrplIdentity.reference(address)) == reference, let usd = TonMarkets.positive(row["priceUsd"]),
                  let liquidity = row["liquidity"]["usd"].text.flatMap({Decimal(string:$0,locale:Locale(identifier:"en_US_POSIX"))}), liquidity >= 1000 else { continue }
            if best == nil || liquidity > best!.0 { best = (liquidity,usd) }
        }
        return best.map{.init(reference:reference,usd:$0.1,source:"DEX Screener",fetchedAt:.now)}
    }
}
