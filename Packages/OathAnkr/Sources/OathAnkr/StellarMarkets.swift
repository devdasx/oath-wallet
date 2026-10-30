import OathDiagnostics
import Foundation

/// CoinGecko-listed identities are eligible for automatic portfolio visibility.
/// A ticker match is never used to identify a token.
public struct StellarCatalog: Codable, Sendable {
    public let ids: [String:String]
    public let tokens: [String:StellarToken]
    public init(ids:[String:String],tokens:[String:StellarToken] = [:]) { self.ids = ids; self.tokens = tokens }
    public static let empty = StellarCatalog(ids:[:])
    public func contains(_ reference:String) -> Bool { reference == "native" || ids[reference] != nil || tokens[reference] != nil }
    /// Independent ANKR whitelist identities remain usable when the global
    /// CoinGecko catalogue is unavailable. Never trust a symbol-only match.
    public func includingVerified(_ inventory:StellarInventory) -> StellarCatalog {
        var tokens=tokens
        for holding in inventory.holdings where inventory.verified.contains(holding.reference) {
            guard holding.token.reference == holding.reference,
                  (try? StellarIdentity.reference(holding.reference)) == holding.reference else { continue }
            tokens[holding.reference]=holding.token
        }
        return .init(ids:ids,tokens:tokens)
    }
}
public actor StellarMarkets {
    private let transport:any AnkrTransport
    private var catalogFlight:Task<StellarCatalog,Error>?
    private var cachedCatalog:(value:StellarCatalog,date:Date)?
    public var catalogUpdatedAt:Date? { cachedCatalog?.date }
    private var catalogRetryAt=Date.distantPast
    private var coingeckoRetryAt=Date.distantPast
    public init(transport:any AnkrTransport = AnkrHTTPTransport()) { self.transport = transport }
    private func read(_ url:URL) async throws -> Data {
        var request = URLRequest(url:url); request.timeoutInterval = 25
        request.setValue("OathWallet/1.0",forHTTPHeaderField:"User-Agent")
        do {
            for attempt in 0..<2 {
                try Task.checkCancellation()
                let (data,status) = try await transport.send(request)
                // Discard cancelled responses before mutating provider cooldowns.
                try Task.checkCancellation()
                if status == 429, url.host == "api.coingecko.com" {
                    coingeckoRetryAt=Date().addingTimeInterval(300)
                }
                if attempt == 0, [502,503,504].contains(status) {
                    try await Task.sleep(for:.milliseconds(400)); continue
                }
                guard status == 200 else { throw StellarError.http(status) }
                try Task.checkCancellation(); return data
            }
            throw StellarError.transport
        } catch {
            // An independently cancelled URL request is expected control flow,
            // not a transport failure that should start fallbacks or backoff.
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            OathDiagnostics.record(error)
            if error is DiagnosticDeferral { throw error }
            throw (error as? StellarError) ?? .transport
        }
    }
    public func catalog(fallback:StellarCatalog = .empty) async throws -> StellarCatalog {
        try Task.checkCancellation()
        if let cachedCatalog,Date().timeIntervalSince(cachedCatalog.date)<86_400 { return cachedCatalog.value }
        if Date()<max(catalogRetryAt,coingeckoRetryAt) { return cachedCatalog?.value ?? fallback }
        let task:Task<StellarCatalog,Error>
        if let catalogFlight { task=catalogFlight }
        else {
            task=Task { try Self.decodeCatalog(await self.read(URL(string:"https://api.coingecko.com/api/v3/coins/list?include_platform=true")!)) }
            catalogFlight=task
        }
        do {
            let value=try await task.value
            cachedCatalog=(value,.now);catalogFlight=nil
            try Task.checkCancellation();return value
        } catch { OathDiagnostics.record(error,component:"prices",operation:"stellar_catalog_fallback");
            catalogFlight=nil
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            catalogRetryAt=Date().addingTimeInterval(300)
            // Do not persist this as a fresh successful catalogue. The next
            // refresh can retry after cooldown; balances use the ANKR whitelist.
            return cachedCatalog?.value ?? fallback
        }
    }
    private static func catalogReference(_ text:String) throws -> String {
        if let ref = try? StellarIdentity.reference(text) { return ref }
        let parts = text.replacingOccurrences(of:":",with:"-").split(separator:"-")
        guard parts.count == 2 else { throw StellarError.malformed }
        return try StellarIdentity.contract(code:String(parts[0]),issuer:String(parts[1]))
    }
    public static func decodeCatalog(_ data:Data) throws -> StellarCatalog {
        guard let rows = try JSONDecoder().decode(StellarJSON.self,from:data).array else { throw StellarError.malformed }
        var ids:[String:String] = [:]
        var tokens:[String:StellarToken] = [:]
        for row in rows {
            guard let type = row["platforms"]["stellar"].string, let ref = try? catalogReference(type),
                  let id = row["id"].string, !id.isEmpty else { continue }
            // Ambiguous catalogue identities cannot select an arbitrary quote.
            if let old = ids[ref], old != id { throw StellarError.malformed }
            ids[ref] = id
            let parts = type.replacingOccurrences(of:":",with:"-").split(separator:"-")
            if parts.count == 2, let name = row["name"].string.flatMap({try? TronIdentity.clean($0)}) {
                tokens[ref] = .init(reference:ref,name:name,symbol:String(parts[0]),decimals:7,logo:nil,assetCode:String(parts[0]),issuer:String(parts[1]))
            }

        }
        guard !ids.isEmpty else { throw StellarError.malformed }
        ids["native"] = "stellar"; return .init(ids:ids,tokens:tokens)
    }
    public func nativePrice(fallback: @Sendable () async throws -> StellarPrice? = { nil }) async throws -> StellarPrice {
        do {
            let data = try await read(URL(string:"https://api.coinbase.com/v2/prices/XLM-USD/spot")!)
            let row = try JSONDecoder().decode(StellarJSON.self,from:data)["data"]
            guard row["base"].string == "XLM", row["currency"].string == "USD", let usd = TonMarkets.positive(row["amount"]) else { throw StellarError.malformed }
            return .init(reference:"native",usd:usd,source:"Coinbase",fetchedAt:.now)
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            OathDiagnostics.record(error,component:"prices",operation:"stellar_native_fallback")
            let alternative:StellarPrice?
            do {
                let result=try await fallback()
                try Task.checkCancellation()
                alternative=result
            } catch {
                if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                OathDiagnostics.record(error,component:"prices",operation:"stellar_ankr_price");alternative=nil
            }
            if let quote=alternative {
                guard quote.reference == "native",TonMarkets.positive(.string(quote.usd)) != nil,
                      quote.fetchedAt <= Date().addingTimeInterval(60),Date().timeIntervalSince(quote.fetchedAt)<3600 else { throw StellarError.malformed }
                return quote
            }
            try Task.checkCancellation()
            if let quote=try await prices(references:["native"],catalog:.init(ids:["native":"stellar"])).first { return quote }
            throw error
        }
    }
    public func prices(references:[String], catalog:StellarCatalog) async throws -> [StellarPrice] {
        try Task.checkCancellation()
        guard !references.isEmpty, references.count <= 30 else { throw StellarError.malformed }
        let refs = try Set(references.map{try StellarIdentity.reference($0)})
        // A known rate limit is normal cooldown, not a new failed request.
        // The synchronizer tries ANKR and then the on-chain DEX for missing quotes.
        if Date()<coingeckoRetryAt { return [] }
        let ids = Set(refs.compactMap{catalog.ids[$0]})
        guard !ids.isEmpty else { return [] }
        var url = URLComponents(string:"https://api.coingecko.com/api/v3/simple/price")!
        url.queryItems = [.init(name:"ids",value:ids.sorted().joined(separator:",")),.init(name:"vs_currencies",value:"usd"),.init(name:"include_last_updated_at",value:"true")]
        return try Self.decodePrices(await read(url.url!),references:refs,catalog:catalog)
    }
    public static func decodePrices(_ data:Data, references:Set<String>, catalog:StellarCatalog, now:Date = .now) throws -> [StellarPrice] {
        let json = try JSONDecoder().decode(StellarJSON.self,from:data)
        var output:[StellarPrice] = []
        for ref in references {
            guard let id = catalog.ids[ref], let usd = TonMarkets.positive(json[id]["usd"]),
                  let timestamp = json[id]["last_updated_at"].text.flatMap(Double.init),
                  timestamp <= now.timeIntervalSince1970+60, now.timeIntervalSince1970-timestamp < 3600 else { continue }
            output.append(.init(reference:ref,usd:usd,source:"CoinGecko",fetchedAt:Date(timeIntervalSince1970:timestamp)))
        }
        return output
    }
    /// A recent volume-weighted on-chain quote for classic assets that have
    /// no aggregator price. Thin/empty markets retain the previous quote.
    public func tradePrice(token:StellarToken,native:StellarPrice) async throws -> StellarPrice? {
        guard let code = token.assetCode, let issuer = token.issuer, native.reference == "native",
              try StellarIdentity.contract(code:code,issuer:issuer) == token.reference else { return nil }
        let now = Date(), start = Int64(now.addingTimeInterval(-86_400).timeIntervalSince1970*1000)
        var url = URLComponents(string:"https://horizon.stellar.org/trade_aggregations")!
        url.queryItems = [.init(name:"base_asset_type",value:code.utf8.count <= 4 ? "credit_alphanum4":"credit_alphanum12"),
            .init(name:"base_asset_code",value:code),.init(name:"base_asset_issuer",value:issuer),.init(name:"counter_asset_type",value:"native"),
            .init(name:"resolution",value:"3600000"),.init(name:"order",value:"desc"),.init(name:"limit",value:"24"),.init(name:"start_time",value:String(start))]
        return try Self.decodeTradePrice(await read(url.url!),reference:token.reference,native:native,now:now)
    }
    public static func decodeTradePrice(_ data:Data,reference:String,native:StellarPrice,now:Date = .now) throws -> StellarPrice? {
        guard let rows = try JSONDecoder().decode(StellarJSON.self,from:data)["_embedded"]["records"].array,
              native.reference == "native", native.fetchedAt <= now.addingTimeInterval(60), now.timeIntervalSince(native.fetchedAt) < 3600,
              let xlm = Decimal(string:native.usd,locale:Locale(identifier:"en_US_POSIX")), xlm > 0 else { throw StellarError.malformed }
        var base = Decimal(0), counter = Decimal(0), count:Int64 = 0, latest:Double = 0
        for row in rows {
            let time = Double(try StellarIdentity.number(row["timestamp"]))/1000
            guard time <= now.timeIntervalSince1970, now.timeIntervalSince1970-time < 86_400,
                  let b = TonMarkets.positive(row["base_volume"]).flatMap({Decimal(string:$0,locale:Locale(identifier:"en_US_POSIX"))}),
                  let c = TonMarkets.positive(row["counter_volume"]).flatMap({Decimal(string:$0,locale:Locale(identifier:"en_US_POSIX"))}) else { continue }
            base += b; counter += c; count = min(3,count+min(3,try StellarIdentity.number(row["trade_count"]))); latest = max(latest,time)
        }
        guard base > 0, counter >= 100, count >= 3, now.timeIntervalSince1970-latest < 7200 else { return nil }
        let usd = counter/base*xlm
        guard !usd.isNaN, usd > 0 else { return nil }
        return .init(reference:reference,usd:NSDecimalNumber(decimal:usd).stringValue,source:"Stellar DEX 24h VWAP",fetchedAt:Date(timeIntervalSince1970:latest))
    }
}
