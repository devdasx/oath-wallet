import Foundation
import OathDiagnostics

extension ThorchainClient {
    public func metadata() async throws -> [String:ThorchainToken] {
        var result:[String:ThorchainToken] = [:], key:String?, visited:Set<String> = []
        for _ in 0..<50 {
            var q:[URLQueryItem] = [.init(name:"pagination.limit",value:"100")]
            if let key { q.append(.init(name:"pagination.key",value:key)) }
            let json = try await read(Self.node,path:"cosmos/bank/v1beta1/denoms_metadata",query:q)
            guard let rows = json["metadatas"].array else { throw ThorchainError.malformed }
            for row in rows {
                guard let base=row["base"].string, let name=row["name"].string, let symbol=row["symbol"].string,
                      let units=row["denom_units"].array else { throw ThorchainError.malformed }
                let ref=try ThorchainIdentity.reference(base)
                guard units.contains(where:{$0["denom"].string == base && $0["exponent"].integer == 0}) else { throw ThorchainError.malformed }
                // Several TokenFactory LP issuers set display=base even though
                // they register an 8-decimal human unit. Use the registered unit.
                let powers=Set(units.compactMap{$0["exponent"].integer}.filter{$0 > 0})
                let power = powers.first ?? 0
                guard powers.count <= 1, power <= 255 else { throw ThorchainError.malformed }
                result[ref] = .init(reference:ref,name:try TronIdentity.clean(name),symbol:try TronIdentity.clean(symbol,limit:64),decimals:Int(power))
            }
            key=json["pagination"]["next_key"].string.flatMap{$0.isEmpty ? nil:$0}
            if key == nil { return result }
            guard visited.insert(key!).inserted else { throw ThorchainError.paginationLoop }
        }
        throw ThorchainError.incomplete
    }
    public func catalog() async throws -> ThorchainCatalog {
        try await catalogRequests.value { try await loadCatalog() }
    }
    private func loadCatalog() async throws -> ThorchainCatalog {
        // Independent endpoints overlap; unavailable quotes do not erase holdings.
        async let tokenResult = OathDiagnostics.attempt("thorchain_metadata") { try await metadata() }
        async let poolsResult = OathDiagnostics.attempt("thorchain_pools") { try await read(Self.midgard,path:"v2/pools") }
        // Midgard publishes runePriceUSD in /v2/stats. /v2/network only
        // describes nodes/bonds and cannot supply a native price.
        async let statsResult = OathDiagnostics.attempt("thorchain_native_price") { try await read(Self.midgard,path:"v2/stats") }
        async let securedResult = OathDiagnostics.attempt("thorchain_secured_assets") { try await read(Self.node,path:"thorchain/securedassets") }
        async let vaultResult = OathDiagnostics.attempt("thorchain_vault_prices") { try await recoverVaultMarkets() }
        let (tokens,pools,stats,secured) = await (tokenResult,poolsResult,statsResult,securedResult)
        let pricedPools = Set((pools?.array ?? []).filter { $0["status"].string == "available" && TonMarkets.positive($0["assetPriceUSD"]) != nil }.compactMap { $0["asset"].string })
        var identities = Set(["THOR.RUNE", "THOR.TCY", "X/RUJI"] + (pools?.array ?? []).filter { $0["status"].string == "available" }.compactMap { $0["asset"].string }).subtracting(pricedPools)
        if let stats, TonMarkets.positive(stats["runePriceUSD"]) != nil { identities.remove("THOR.RUNE") }
        let oracle=await OathDiagnostics.attempt("thorchain_oracle_prices") { try await oraclePrices(assets:Array(identities).sorted()) } ?? [:]
        var result = try Self.decodeCatalog(pools:pools ?? .array([]), stats:stats ?? .null, secured:secured ?? .array([]),oracle:oracle)
        result.tokens=tokens ?? [:]
        // CoinGecko is a fallback, not an unconditional extra request on every
        // refresh. Keep its shared quota for exact identities still unpriced by
        // Midgard/the fresh oracle; never use an untrusted token's ticker.
        let missing = [("native","thorchain"),("x/ruji","rujira"),("tcy","tcy")].filter { result.prices[$0.0] == nil }
        if !missing.isEmpty {
            async let geckoResult = OathDiagnostics.attempt("thorchain_ecosystem_prices") {
                try await read(URL(string:"https://api.coingecko.com")!,path:"api/v3/simple/price",query:[.init(name:"ids",value:missing.map(\.1).joined(separator:",")),.init(name:"vs_currencies",value:"usd"),.init(name:"include_last_updated_at",value:"true")])
            }
            // Independent API budget: a CoinGecko client/IP throttle does not
            // prevent reading DefiLlama's published observations. It can itself
            // source CoinGecko, so timestamp/confidence checks remain mandatory.
            async let llamaResult = OathDiagnostics.attempt("thorchain_ecosystem_fallback") {
                try await read(URL(string: "https://coins.llama.fi")!, path: "prices/current/" + missing.map { "coingecko:" + $0.1 }.joined(separator: ","))
            }
            let (gecko, llama) = await (geckoResult, llamaResult)
            for (ref, id) in missing {
                if let gecko, let value = TonMarkets.positive(gecko[id]["usd"]),
                   let time = gecko[id]["last_updated_at"].text.flatMap(Double.init), time.isFinite,
                   Date().timeIntervalSince1970 - time < 3600, time <= Date().timeIntervalSince1970 + 60 {
                    result.prices[ref] = value
                } else if let llama {
                    // Missing optional market coverage is not a failed wallet.
                    if !llama["coins"]["coingecko:" + id].isNull {
                        if let quote = OathDiagnostics.attempt("thorchain_decode_fallback", body: {
                            try NativePriceFallback.decodeLlama(llama, key: "coingecko:" + id, maxAge: 3600)
                        }) { result.prices[ref] = quote.usd }
                    }
                }
            }
        }
        if let vaults = await vaultResult { try Self.applyVaultMarkets(vaults,to:&result) }
        return result
    }
    private func oraclePrices(assets:[String]) async throws -> [String:String] {
        guard assets.count <= 500 else { throw ThorchainError.incomplete }
        var result:[String:String] = [:]
        // One batched read covers the current directory. If it grows, keep
        // requests bounded; never perform one request for every wallet token.
        for start in stride(from:0,to:assets.count,by:10) {
            let batch=Array(assets[start..<min(start+10,assets.count)])
            let ids=batch.map{Data(("Asset:"+$0).utf8).base64EncodedString()}
            let literal=String(decoding:try JSONEncoder().encode(ids),as:UTF8.self)
            let j=try await readMarketGraphQL("{nodes(ids:\(literal)){... on Asset {asset price {current timestamp}}}}", stage: "oracle")
            guard let rows=j["data"]["nodes"].array, rows.count == batch.count else { throw ThorchainError.malformed }
            result.merge(try Self.decodeOracle(rows,expected:Set(batch)),uniquingKeysWith:{$1})
        }
        return result
    }
    public static func decodeOracle(_ rows:[SolanaJSON],expected:Set<String>,now:Date = .now) throws -> [String:String] {
        let parser=ISO8601DateFormatter(); parser.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
        var result:[String:String] = [:]
        for row in rows {
            if row.isNull { continue } // Not every issued token has a market.
            guard let asset=row["asset"].string, expected.contains(asset) else { throw ThorchainError.malformed }
            guard let text=row["price"]["current"].text, let n=Decimal(string:text), n>0,
                  let time=row["price"]["timestamp"].string.flatMap(parser.date(from:)),
                  now.timeIntervalSince(time)<900, time.timeIntervalSince(now)<=60 else { continue }
            result[asset]=NSDecimalNumber(decimal:n/1_000_000_000_000).stringValue
        }
        return result
    }
    func vaultMarkets() async throws -> [SolanaJSON] {
        var cursor:String?, visited:Set<String> = [], rows:[SolanaJSON] = []
        for _ in 0..<50 {
            // GraphQL literal escaping comes from the JSON encoder, never from
            // interpolating a remote cursor directly into query syntax.
            let after = try cursor.map { ",after:" + String(decoding:try JSONEncoder().encode($0),as:UTF8.self) } ?? ""
            let query = "{rujira {strategies(first:10,typenames:[\"GhostVault\"]\(after)) {pageInfo {hasNextPage endCursor} edges {node {... on GhostVault {asset {asset variants {native {denom}}} status {depositPool {ratio shares} lastUpdated}}}}}}}"
            let j = try await readMarketGraphQL(query, stage: "vault")
            guard let edges = j["data"]["rujira"]["strategies"]["edges"].array,
                  case let .bool(more) = j["data"]["rujira"]["strategies"]["pageInfo"]["hasNextPage"] else { throw ThorchainError.malformed }
            rows += edges.map { $0["node"] }
            if !more { return rows }
            guard let next = j["data"]["rujira"]["strategies"]["pageInfo"]["endCursor"].string,
                  visited.insert(next).inserted else { throw ThorchainError.paginationLoop }
            cursor=next
        }
        throw ThorchainError.incomplete
    }
    func readMarketGraphQL(_ query: String, stage: String) async throws -> SolanaJSON {
        let json = try await catalogRequests.graphQL(stage: stage) {
            try await read(URL(string: "https://api.rujira.network")!, path: "api/graphql",
                           query: [.init(name: "query", value: query)])
        }
        try Task.checkCancellation()
        if let errors = json["errors"].array {
            guard errors.isEmpty else { throw ThorchainError.graphql }
        } else if !json["errors"].isNull { throw ThorchainError.malformed }
        return json
    }
    static func isMarketRateLimit(_ json: SolanaJSON) -> Bool {
        guard let errors = json["errors"].array, !errors.isEmpty else { return false }
        // Do not retry arbitrary GraphQL/schema errors, mixed errors, or a
        // message merely containing the rate-limit phrase.
        return errors.allSatisfy {
            $0["message"].string?.split(separator: "\n", omittingEmptySubsequences: false).first ==
                "rate bucket full (5000). bucket drains 500/s."
        }
    }
    public static func applyVaultMarkets(_ rows:[SolanaJSON],to catalog:inout ThorchainCatalog, now:Date = .now) throws {
        let parser=ISO8601DateFormatter(); parser.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
        for row in rows {
            guard let denom=row["asset"]["variants"]["native"]["denom"].string else { continue }
            let underlying=try ThorchainIdentity.reference(denom)
            // Rujira's vault source defines the receipt as x/ghost-vault/<denom>.
            // Its GraphQL Bigint schema explicitly scales decimal ratios by 1e12.
            let receipt="x/ghost-vault/"+denom
            guard catalog.tokens[receipt]?.decimals == 8,
                  let base=catalog.prices[underlying].flatMap({Decimal(string:$0)}),
                  let ratioText=row["status"]["depositPool"]["ratio"].text,
                  let ratio=Decimal(string:ratioText), ratio>0,
                  let sharesText=row["status"]["depositPool"]["shares"].text,
                  let shares=Decimal(string:sharesText), shares>0,
                  let time=row["status"]["lastUpdated"].string.flatMap(parser.date(from:)),
                  now.timeIntervalSince(time) < 3600, time.timeIntervalSince(now) <= 60 else { continue }
            let price=base*ratio/1_000_000_000_000
            guard !price.isNaN, price>0 else { continue }
            catalog.prices[receipt]=NSDecimalNumber(decimal:price).stringValue
        }
    }
    public static func decodeCatalog(pools:SolanaJSON, stats:SolanaJSON, secured:SolanaJSON,oracle:[String:String] = [:]) throws -> ThorchainCatalog {
        guard let rows=pools.array, let shares=secured.array else { throw ThorchainError.malformed }
        var result=ThorchainCatalog()
        if let p=oracle["THOR.RUNE"] ?? TonMarkets.positive(stats["runePriceUSD"]) { result.prices["native"]=p }
        result.prices["x/ruji"]=oracle["X/RUJI"]
        result.prices["tcy"]=oracle["THOR.TCY"]
        var spot:[String:Decimal] = [:]
        for row in rows {
            guard let asset=row["asset"].string, let p=oracle[asset] ?? TonMarkets.positive(row["assetPriceUSD"]), let value=Decimal(string:p,locale:Locale(identifier:"en_US_POSIX")) else { continue }
            // A suspended pool is not a current redeemable market quote.
            guard row["status"].string == "available" else { continue }
            spot[asset.lowercased()] = value
            if asset == "THOR.TCY" { result.prices["tcy"]=p }
            if let dot=asset.firstIndex(of:"."), !asset.hasPrefix("THOR.") {
                let synth=(asset[..<dot]+"/"+asset[asset.index(after:dot)...]).lowercased()
                result.prices[synth]=p
            }
        }
        for row in shares {
            guard let asset=row["asset"].string, let dash=asset.firstIndex(of:"-"),
                  let supplyText=row["supply"].text, let depthText=row["depth"].text,
                  let supply=Decimal(string:supplyText), supply>0, let depth=Decimal(string:depthText), depth>=0 else { continue }
            let underlying=(asset[..<dash]+"."+asset[asset.index(after:dash)...]).lowercased()
            guard let price=spot[underlying] else { continue }
            let value=price*depth/supply
            guard !value.isNaN, value > 0 else { continue }
            result.prices[asset.lowercased()]=NSDecimalNumber(decimal:value).stringValue
        }
        return result
    }
}
