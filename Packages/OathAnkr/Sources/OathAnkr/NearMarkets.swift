import OathDiagnostics
import Foundation

/// CoinGecko-listed identities are eligible for automatic portfolio visibility.
/// A ticker match is never used to identify a token.
public struct NearCatalog: Codable, Sendable {
    public let ids: [String:String]
    public static let empty = NearCatalog(ids:[:])
    public func contains(_ reference:String) -> Bool { reference == "native" || ids[reference] != nil }
}
public struct NearMarkets: Sendable {
    private let transport:any AnkrTransport
    public init(transport:any AnkrTransport = AnkrHTTPTransport()) { self.transport = transport }
    private func read(_ url:URL) async throws -> Data {
        var request = URLRequest(url:url); request.timeoutInterval = 25
        request.setValue("OathWallet/1.0",forHTTPHeaderField:"User-Agent")
        return try await OathDiagnostics.withChain("near") {
            do {
                for attempt in 0..<2 {
                    let (data,status) = try await transport.send(request)
                    if attempt == 0, [502,503,504].contains(status) {
                        try await Task.sleep(for:.milliseconds(400)); continue
                    }
                    guard status == 200 else { throw NearError.http(status) }
                    try Task.checkCancellation(); return data
                }
                throw NearError.transport
            } catch {
                if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                OathDiagnostics.record(error, context: DiagnosticHTTP.context(request))
                if error is DiagnosticDeferral { throw error }
                throw (error as? NearError) ?? .transport
            }
        }
    }
    public func catalog() async throws -> NearCatalog {
        try Self.decodeCatalog(await read(URL(string:"https://api.coingecko.com/api/v3/coins/list?include_platform=true")!))
    }
    public static func decodeCatalog(_ data:Data) throws -> NearCatalog {
        guard let rows = try JSONDecoder().decode(NearJSON.self,from:data).array else { throw NearError.malformed }
        var ids:[String:String] = [:]
        for row in rows {
            guard let type = row["platforms"]["near-protocol"].string, let ref = try? NearIdentity.reference(type),
                  let id = row["id"].string, !id.isEmpty else { continue }
            // Ambiguous catalogue identities cannot select an arbitrary quote.
            if let old = ids[ref], old != id { throw NearError.malformed }
            ids[ref] = id
        }
        guard !ids.isEmpty else { throw NearError.malformed }
        ids["native"] = "near"; return .init(ids:ids)
    }
    public func nativePrice() async throws -> NearPrice {
        try await OathDiagnostics.withChain("near") {
            do {
                let data = try await read(URL(string:"https://api.coinbase.com/v2/prices/NEAR-USD/spot")!)
                let row = try JSONDecoder().decode(NearJSON.self,from:data)["data"]
                guard row["base"].string == "NEAR", row["currency"].string == "USD", let usd = TonMarkets.positive(row["amount"]) else { throw NearError.malformed }
                return .init(reference:"native",usd:usd,source:"Coinbase",fetchedAt:.now)
            } catch {
                try Task.checkCancellation()
                // Availability failover only. Cancellation, wrong asset/currency,
                // invalid prices and authorization failures must not turn into success.
                switch error {
                case NearError.transport, is DiagnosticDeferral: break
                case NearError.http(let status) where status == 408 || status == 429 || (500...599).contains(status): break
                default: throw error
                }
                OathDiagnostics.record(error, component:"prices", operation:"near_native_fallback", context:["stage":"quote"])
                // The existing contract/decimal-checked NEAR source maps native
                // NEAR to wrap.near. Share its bulk response with token quotes.
                guard let quote = try await ecosystemPrices(tokens:[.native]).first else { throw NearError.malformed }
                return quote
            }
        }
    }
    public func prices(references:[String], catalog:NearCatalog) async throws -> [NearPrice] {
        guard !references.isEmpty, references.count <= 30 else { throw NearError.malformed }
        let refs = try Set(references.map{try NearIdentity.reference($0)})
        let ids = Set(refs.compactMap{catalog.ids[$0]})
        guard !ids.isEmpty else { return [] }
        var url = URLComponents(string:"https://api.coingecko.com/api/v3/simple/price")!
        url.queryItems = [.init(name:"ids",value:ids.sorted().joined(separator:",")),.init(name:"vs_currencies",value:"usd"),.init(name:"include_last_updated_at",value:"true")]
        return try Self.decodePrices(await read(url.url!),references:refs,catalog:catalog)
    }
    public static func decodePrices(_ data:Data, references:Set<String>, catalog:NearCatalog, now:Date = .now) throws -> [NearPrice] {
        let json = try JSONDecoder().decode(NearJSON.self,from:data)
        var output:[NearPrice] = []
        for ref in references {
            guard let id = catalog.ids[ref], let usd = TonMarkets.positive(json[id]["usd"]),
                  let timestamp = json[id]["last_updated_at"].text.flatMap(Double.init),
                  timestamp <= now.timeIntervalSince1970+60, now.timeIntervalSince1970-timestamp < 3600 else { continue }
            output.append(.init(reference:ref,usd:usd,source:"CoinGecko",fetchedAt:Date(timeIntervalSince1970:timestamp)))
        }
        return output
    }
    /// One bulk public quote response, matched by contract and on-chain decimals.
    public func ecosystemPrices(tokens:[NearToken]) async throws -> [NearPrice] {
        try Task.checkCancellation()
        guard !tokens.isEmpty else { return [] }
        let data = try await read(URL(string:"https://prices.intear.tech/list-token-price")!)
        return try Self.decodeEcosystemPrices(data,tokens:tokens)
    }
    public static func decodeEcosystemPrices(_ data:Data, tokens:[NearToken]) throws -> [NearPrice] {
        let json = try JSONDecoder().decode(NearJSON.self,from:data)
        guard case .object = json else { throw NearError.malformed }
        return tokens.compactMap { token in
            let row = json[token.reference == "native" ? "wrap.near":token.reference]
            guard row["decimal"].integer == UInt64(token.decimals), let usd = TonMarkets.positive(row["price"]) else { return nil }
            return .init(reference:token.reference,usd:usd,source:"Intear",fetchedAt:.now)
        }
    }
}
