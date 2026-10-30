import OathDiagnostics
import Foundation
import OathDatabase
import OathAnkr
import OathTokenImages

/// Read-through public market cache. Requests coalesce before the first SQL
/// suspension; failures retain data and back off without storing fake zeroes.
public actor MarketDataService {
    private let database: OathDatabase
    private let transport: any MarketTransport
    private let now: @Sendable () -> Date
    private static let sharedArtworkCatalog = ArtworkFallbackCatalog(transport: PublicArtworkCatalogTransport())
    let artworkCatalog: ArtworkFallbackCatalog
    private struct LoadFlight {
        let id: UUID
        let task: Task<Void, Never>
        var consumers: [UUID: CheckedContinuation<MarketCacheEntry, Error>]
    }
    private var work: [String: LoadFlight] = [:]
    // Observation time is provider data, not the time we last checked it.
    // A valid 2-minute-old observation must not trigger another request on
    // every render. Never rewrite that timestamp to make the quote look new.
    private var quoteRefreshAfter: [String: ContinuousClock.Instant] = [:]
    private var retryAfter: [String: ContinuousClock.Instant] = [:]
    private var retryReason: [String: MarketDataError] = [:]

    public init(database: OathDatabase, transport: any MarketTransport = URLSessionMarketTransport(),
                now: @escaping @Sendable () -> Date = { Date() },
                artworkCatalog: ArtworkFallbackCatalog? = nil) {
        self.database = database; self.transport = transport; self.now = now
        self.artworkCatalog = artworkCatalog ?? Self.sharedArtworkCatalog
    }
    private func key(_ kind: String, _ asset: MarketAsset, version: Int = 1) -> String {
        // ETH is the same project across seven native networks. Share its
        // description cache instead of exhausting the keyless metadata quota.
        if kind == "info", asset.isNative, let identity = MarketIdentity.native[asset.networkID] {
            return "v\(version).info.native.\(identity.gecko)"
        }
        return "v\(version).\(kind).\(asset.cacheIdentity)"
    }

    public func cachedQuote(for asset: MarketAsset) async throws -> CachedMarketValue<MarketQuote>? {
        var result: CachedMarketValue<MarketQuote>? = try await cached(key("quote", asset, version: 2))
        if result == nil { result = try await cached(key("quote", asset)) }
        // All chain synchronizers publish into the same price table. Reuse that
        // quote even for newly added tokens, and never relabel its observation time.
        if let saved = try await database.asset(networkID: asset.networkID, reference: asset.reference),
           saved.id == asset.id, saved.decimals == asset.decimals,
           let price = try await database.latestPrice(assetID: asset.id, currency: "USD"),
           let value = Decimal(string: price.value), !value.isNaN, value > 0 {
            let date = Date(timeIntervalSince1970: price.observedAt)
            if result == nil || date > result!.fetchedAt {
                result = .init(value: .init(code: asset.reference, usd: price.value), fetchedAt: date)
            }
        }
        return result
    }
    public func cachedInformation(for asset: MarketAsset) async throws -> CachedMarketValue<AssetInformation>? {
        if asset.networkID == "thorchain", !asset.isNative {
            if let enriched: CachedMarketValue<AssetInformation> = try await cached(key("info", asset, version: 2)) { return enriched }
            return try await thorchainInformation(asset)
        }
        if asset.networkID == "aptos", !asset.isNative {
            return try await aptosInformation(asset)
        }
        if asset.networkID == "sui", !asset.isNative { return try await suiInformation(asset) }
        if asset.networkID == "near", !asset.isNative { return try await nearInformation(asset) }
        if asset.networkID == "xrpl", !asset.isNative { return try await xrplInformation(asset) }
        if asset.networkID == "stellar", !asset.isNative { return try await stellarInformation(asset) }
        if asset.networkID == "ton", !asset.isNative {
            return try await tonInformation(asset)
        }
        if let current: CachedMarketValue<AssetInformation> = try await cached(key("info", asset, version: 2)) {
            return current
        }
        // Keep the previous description available offline while fetching the
        // new market-data payload. A v1 entry never suppresses that fetch.
        return try await cached(key("info", asset))
    }
    private func thorchainInformation(_ asset: MarketAsset) async throws -> CachedMarketValue<AssetInformation>? {
        guard let saved=try await database.asset(networkID:"thorchain",reference:asset.reference),
              saved.id == asset.id, saved.decimals == asset.decimals else { return nil }
        let catalog=try await database.marketCache(key:"thorchain.catalog")
        return .init(value:.init(providerID:"thorchain:"+saved.reference,name:saved.name,symbol:saved.symbol,
            description:"",imageURL:saved.logo,website:nil,providerURL:"https://runescan.io"),
            fetchedAt:Date(timeIntervalSince1970:catalog?.fetchedAt ?? 0))
    }
    private func tonInformation(_ asset: MarketAsset) async throws -> CachedMarketValue<AssetInformation>? {
        guard let saved = try await database.marketCache(key:"ton.token."+asset.reference),
              let token = OathDiagnostics.attempt("decode_cached_metadata", body: { try JSONDecoder().decode(CachedTokenMetadata.self,from:saved.payload) }),
              token.reference == asset.reference, token.decimals == asset.decimals else { return nil }
        return .init(value:.init(providerID:"tonapi:"+token.reference,name:token.name,symbol:token.symbol,
            description:token.description ?? "",imageURL:token.logo,website:nil,
            providerURL:"https://tonviewer.com/"+token.reference),fetchedAt:Date(timeIntervalSince1970:saved.fetchedAt))
    }
    private func aptosInformation(_ asset: MarketAsset) async throws -> CachedMarketValue<AssetInformation>? {
        guard let saved = try await database.marketCache(key:"aptos.token."+asset.reference),
              let token = OathDiagnostics.attempt("decode_cached_metadata", body: { try JSONDecoder().decode(CachedTokenMetadata.self,from:saved.payload) }),
              token.reference == asset.reference, token.decimals == asset.decimals else { return nil }
        return .init(value:.init(providerID:"aptos:"+token.reference,name:token.name,symbol:token.symbol,
            description:token.description ?? "",imageURL:token.logo,website:nil,
            providerURL:"https://explorer.aptoslabs.com/"+(token.reference.contains("::") ? "coin/":"fungible_asset/")+token.reference+"?network=mainnet"),fetchedAt:Date(timeIntervalSince1970:saved.fetchedAt))
    }
    private func suiInformation(_ asset: MarketAsset) async throws -> CachedMarketValue<AssetInformation>? {
        guard let saved = try await database.marketCache(key:"sui.token."+asset.reference),
              let token = OathDiagnostics.attempt("decode_cached_metadata", body: { try JSONDecoder().decode(CachedTokenMetadata.self,from:saved.payload) }),
              token.reference == asset.reference, token.decimals == asset.decimals else { return nil }
        return .init(value:.init(providerID:"sui:"+token.reference,name:token.name,symbol:token.symbol,
            description:token.description ?? "",imageURL:token.logo,website:nil,
            providerURL:"https://suiscan.xyz/mainnet/coin/"+token.reference+"/overview"),fetchedAt:Date(timeIntervalSince1970:saved.fetchedAt))
    }
    private func nearInformation(_ asset: MarketAsset) async throws -> CachedMarketValue<AssetInformation>? {
        guard let saved = try await database.marketCache(key:"near.token."+asset.reference),
              let token = OathDiagnostics.attempt("decode_cached_metadata", body: { try JSONDecoder().decode(CachedTokenMetadata.self,from:saved.payload) }),
              token.reference == asset.reference, token.decimals == asset.decimals else { return nil }
        return .init(value:.init(providerID:"near:"+token.reference,name:token.name,symbol:token.symbol,
            description:token.description ?? "",imageURL:token.logo,website:nil,
            providerURL:"https://nearblocks.io/token/"+token.reference),fetchedAt:Date(timeIntervalSince1970:saved.fetchedAt))
    }
    public func cachedChart(for asset: MarketAsset) async throws -> CachedMarketValue<MarketChart>? {
        try await cached(key("chart", asset))
    }
    private func xrplInformation(_ asset: MarketAsset) async throws -> CachedMarketValue<AssetInformation>? {
        guard let saved = try await database.marketCache(key:"xrpl.token."+asset.reference),
              let token = OathDiagnostics.attempt("decode_cached_metadata", body: { try JSONDecoder().decode(CachedTokenMetadata.self,from:saved.payload) }),
              token.reference == asset.reference, token.decimals == asset.decimals else { return nil }
        return .init(value:.init(providerID:"xrpl:"+token.reference,name:token.name,symbol:token.symbol,
            description:token.description ?? "",imageURL:token.logo,website:nil,
            providerURL:"https://xrpscan.com/"+(token.reference.contains(".") ? "token/":"mpt/")+token.reference),fetchedAt:Date(timeIntervalSince1970:saved.fetchedAt))
    }
    private func stellarInformation(_ asset: MarketAsset) async throws -> CachedMarketValue<AssetInformation>? {
        guard let saved = try await database.marketCache(key:"stellar.token."+asset.reference),
              let token = OathDiagnostics.attempt("decode_cached_metadata", body: { try JSONDecoder().decode(CachedTokenMetadata.self,from:saved.payload) }),
              token.reference == asset.reference, token.decimals == asset.decimals else { return nil }
        return .init(value:.init(providerID:"stellar:"+token.reference,name:token.name,symbol:token.symbol,
            description:token.description ?? "",imageURL:token.logo,website:nil,
            providerURL:"https://stellar.expert/explorer/public/contract/"+token.reference),fetchedAt:Date(timeIntervalSince1970:saved.fetchedAt))
    }
    private func cached<T: Decodable & Sendable>(_ key: String) async throws -> CachedMarketValue<T>? {
        guard let entry = try await database.marketCache(key: key),
              let value = OathDiagnostics.attempt("decode_cached_metadata", body: { try JSONDecoder().decode(T.self, from: entry.payload) }) else { return nil }
        return CachedMarketValue(value: value, fetchedAt: Date(timeIntervalSince1970: entry.fetchedAt))
    }
    private func decoded<T: Decodable & Sendable>(_ entry: MarketCacheEntry) throws -> CachedMarketValue<T> {
        CachedMarketValue(value: try JSONDecoder().decode(T.self, from: entry.payload),
                          fetchedAt: Date(timeIntervalSince1970: entry.fetchedAt))
    }

    public func quote(for asset: MarketAsset, force: Bool = false) async throws -> CachedMarketValue<MarketQuote> {
        let previous = try await cachedQuote(for: asset)
        if !force, let previous,
           previous.isFresh(at: now(), lifetime: 60) || (quoteRefreshAfter[asset.cacheIdentity].map { $0 > .now } ?? false) { return previous }
        let transport = transport, now = now
        do {
            let refreshed: CachedMarketValue<MarketQuote> = try decoded(await load(key: key("quote", asset, version: 2), source: "Market providers", lifetime: 60, force: force) {
                try await OathDiagnostics.$chain.withValue(asset.networkID) {
                    try await OathDiagnostics.$operationID.withValue(UUID()) {
                        var candidates = ContractPriceRequest.requests(for: asset).map { request in
                            ParallelMarketPrice.Candidate(source: request.provider.rawValue) {
                                let bytes = try await transport.data(from: request.url)
                                return try ContractPriceDecoding.decode(bytes, request: request, asset: asset, now: now())
                            }
                        }
                        candidates.append(.init(source: "Coinbase") {
                            let code = try await self.coinbaseCode(for: asset)
                            let data = try await transport.data(from: URL(string: "https://api.coinbase.com/v2/prices/\(code)-USD/spot")!)
                            return .init(quote: try MarketDecoding.quote(data, code: code), date: now(), source: "Coinbase")
                        })
                        let result = try await ParallelMarketPrice.first(candidates, network: asset.networkID)
                        return (try JSONEncoder().encode(result.quote), result.date.timeIntervalSince1970,
                            PriceRecord(assetID: asset.id, currency: "USD", value: result.quote.usd,
                                observedAt: result.date.timeIntervalSince1970, source: result.source))
                    }
                }
            })
            quoteRefreshAfter = quoteRefreshAfter.filter { $0.value > .now }
            if quoteRefreshAfter.count >= 512 { quoteRefreshAfter.removeAll(keepingCapacity: true) }
            quoteRefreshAfter[asset.cacheIdentity] = .now.advanced(by: .seconds(60))
            // Providers refresh on different schedules. A successful but older
            // observation must not move the displayed price backwards in time.
            if let previous, previous.fetchedAt > refreshed.fetchedAt { return previous }
            return refreshed
        } catch {
            // load records original non-coverage failures. Offline/outage never
            // replaces a saved quote with zero or invents a new freshness date.
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if error as? MarketDataError != .notListed {
                OathDiagnostics.record(error, component: "market_price", operation: "quote_cache_fallback",
                    context: ["chain": asset.networkID])
            }
            if let previous { return previous }
            throw error
        }
    }
    public func information(for asset: MarketAsset, force: Bool = false) async throws -> CachedMarketValue<AssetInformation> {
        try await OathDiagnostics.withChain(asset.networkID) {
            try await informationValue(for: asset, force: force)
        }
    }
    private func informationValue(for asset: MarketAsset, force: Bool) async throws -> CachedMarketValue<AssetInformation> {
        if asset.networkID == "thorchain", !asset.isNative {
            guard let info=try await cachedInformation(for: asset) else { throw MarketDataError.notListed }; return info
        }
        if asset.networkID == "sui", !asset.isNative {
            guard let info = try await suiInformation(asset) else { throw MarketDataError.notListed }; return info
        }
        if asset.networkID == "xrpl", !asset.isNative {
            guard let info = try await xrplInformation(asset) else { throw MarketDataError.notListed }; return info
        }
        if asset.networkID == "stellar", !asset.isNative {
            guard let info = try await stellarInformation(asset) else { throw MarketDataError.notListed }; return info
        }
        if asset.networkID == "near", !asset.isNative {
            guard let info = try await nearInformation(asset) else { throw MarketDataError.notListed }; return info
        }
        if asset.networkID == "aptos", !asset.isNative {
            guard let info = try await aptosInformation(asset) else { throw MarketDataError.notListed }; return info
        }
        if asset.networkID == "ton", !asset.isNative {
            // The account synchronizer already fetched the complete Jetton
            // identity. Reuse it offline without a duplicate index request.
            guard let info = try await tonInformation(asset) else { throw MarketDataError.notListed }
            return info
        }
        return try await enrichedInformation(for: asset, force: force)
    }

    // Artwork can enrich a known denomination without making the native
    // bank-token detail/quote path depend on an external catalog being online.
    func enrichedInformation(for asset: MarketAsset, force: Bool = false) async throws -> CachedMarketValue<AssetInformation> {
        let transport = transport, now = now
        do {
            return try decoded(await load(key: key("info", asset, version: 2), source: "CoinGecko", lifetime: 300, force: force) {
                let data = try await transport.data(from: MarketIdentity.informationURL(for: asset))
                let info = try MarketDecoding.information(data, for: asset)
                return (try JSONEncoder().encode(info), now().timeIntervalSince1970, nil)
            })
        } catch {
            if error is CancellationError || Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            guard let identity = NativeInformation.identity(for: asset),
                  [.rateLimited, .unavailable, .notListed].contains(error as? MarketDataError) || error is URLError || error is DiagnosticDeferral else { throw error }
            if error as? MarketDataError != .notListed {
                OathDiagnostics.record(error, component: "prices", operation: "information_fallback",
                    context: ["chain": asset.networkID, "source": "CoinGecko"])
            }
            // Separate request/backoff key lets the independent source recover
            // even while CoinGecko is throttled. Reuse only verified timestamps.
            let entry = try await load(key: key("paprikaInfo", asset), source: "CoinPaprika", lifetime: 300, force: force) {
                try Task.checkCancellation()
                async let coin = transport.data(from: identity.coinURL)
                async let ticker = transport.data(from: identity.tickerURL)
                let info = try await NativeInformation.decode(coin: coin, ticker: ticker, for: asset, at: now())
                return (try JSONEncoder().encode(info.value), info.fetchedAt.timeIntervalSince1970, nil)
            }
            try Task.checkCancellation()
            let committed = try await database.saveMarketCache(.init(key: key("info", asset, version: 2), source: entry.source,
                payload: entry.payload, fetchedAt: entry.fetchedAt))
            return try decoded(committed)
        }
    }
    public func chart(for asset: MarketAsset, force: Bool = false) async throws -> CachedMarketValue<MarketChart> {
        try await OathDiagnostics.$chain.withValue(asset.networkID) {
            try await OathDiagnostics.$operationID.withValue(OathDiagnostics.operationID ?? UUID()) {
                try await chartValue(for: asset, force: force)
            }
        }
    }
    private func chartValue(for asset: MarketAsset, force: Bool) async throws -> CachedMarketValue<MarketChart> {
        let transport = transport, now = now
        // Coinbase's price API and Exchange listings are different catalogs.
        // TRX has a spot price but no TRX-USD Exchange candles.
        if asset.isNative, asset.networkID == "thorchain", asset.decimals == 8 {
            do { return try await geckoChart(for: asset, force: force) }
            catch {
                if error is CancellationError || Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                // Preserve schema/identity failures. Only provider absence or
                // availability failures can switch to this exact native series.
                guard [.rateLimited, .unavailable, .notListed].contains(error as? MarketDataError) || error is URLError || error is DiagnosticDeferral else { throw error }
                if error as? MarketDataError != .notListed {
                    OathDiagnostics.record(error, component: "prices", operation: "chart_fallback",
                        context: ["chain": "thorchain", "source": "CoinGecko"])
                }
                let entry = try await load(key: key("midgardChart", asset), source: "THORChain Midgard", lifetime: 300, force: force) {
                    try Task.checkCancellation()
                    let date = now()
                    let data = try await transport.data(from: ThorchainChart.url(at: date))
                    return (try JSONEncoder().encode(ThorchainChart.decode(data, at: date)), date.timeIntervalSince1970, nil)
                }
                try Task.checkCancellation()
                let committed = try await database.saveMarketCache(.init(key: key("chart", asset), source: entry.source,
                    payload: entry.payload, fetchedAt: entry.fetchedAt))
                return try decoded(committed)
            }
        }
        if asset.isNative, asset.networkID == "tron", let market = KrakenNativeChart.market(for: asset) {
            do { return try await geckoChart(for: asset, force: force) }
            catch {
                if error is CancellationError || Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                guard [.notListed, .rateLimited, .unavailable].contains(error as? MarketDataError) || error is URLError || error is DiagnosticDeferral else { throw error }
                if error as? MarketDataError != .notListed {
                    OathDiagnostics.record(error, component: "prices", operation: "kraken_chart_fallback",
                        context: ["chain": asset.networkID, "source": "CoinGecko"])
                }
                return try await krakenChart(for: asset, market: market, force: force)
            }
        }
        if asset.isNative, ["tron","thorchain"].contains(asset.networkID) { return try await geckoChart(for: asset, force: force) }
        do { return try decoded(await load(key: key("chart", asset), source: "Coinbase", lifetime: 300, force: force) {
            let code = try await self.coinbaseCode(for: asset)
            let date = now()
            let base = "https://api.exchange.coinbase.com/products/\(code)-USD/"
            let formatter = ISO8601DateFormatter()
            var url = URLComponents(string: base + "candles")!
            url.queryItems = [.init(name: "granularity", value: "3600"),
                .init(name: "start", value: formatter.string(from: date.addingTimeInterval(-86_400))),
                .init(name: "end", value: formatter.string(from: date))]
            async let stats = self.chartStatistics(from: URL(string: base + "stats")!)
            let data = try await transport.data(from: url.url!)
            let chart = try MarketDecoding.chart(data, stats: await stats, now: date)
            return (try JSONEncoder().encode(chart), date.timeIntervalSince1970, nil)
        }) } catch {
            // diagnostics: market-chart-recovery. The shared load boundary
            // records original provider/storage failures before this recovery.
            if error is CancellationError || Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            // load already reports the original outage. An unavailable Exchange
            // chart can recover through the independently keyed exact-asset
            // series, just as a missing listing can. Never hide malformed data.
            guard [.notListed, .rateLimited, .unavailable].contains(error as? MarketDataError) || error is URLError || error is DiagnosticDeferral else { throw error }
            do { return try await geckoChart(for: asset, force: force) }
            catch {
                if error is CancellationError || Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                if TokenPoolChart.network(for: asset) != nil,
                   [.notListed, .rateLimited, .unavailable].contains(error as? MarketDataError) || error is URLError || error is DiagnosticDeferral {
                    // Missing listings are expected coverage gaps; preserve
                    // actual outages while trying the exact-contract pool.
                    if error as? MarketDataError != .notListed {
                        OathDiagnostics.record(error, component: "prices", operation: "token_chart_fallback",
                            context: ["chain": asset.networkID, "source": "CoinGecko"])
                    }
                    return try await tokenPoolChart(for: asset, force: force)
                }
                guard let market = KrakenNativeChart.market(for: asset),
                      [.notListed, .rateLimited, .unavailable].contains(error as? MarketDataError) || error is URLError || error is DiagnosticDeferral else { throw error }
                OathDiagnostics.record(error, component: "prices", operation: "kraken_chart_fallback",
                    context: ["chain": asset.networkID, "source": "CoinGecko"])
                return try await krakenChart(for: asset, market: market, force: force)
            }
        }
    }

    private func krakenChart(for asset: MarketAsset, market: KrakenNativeChart.Market, force: Bool) async throws -> CachedMarketValue<MarketChart> {
        let transport = transport, now = now
        let entry = try await load(key: key("krakenChart", asset), source: "Kraken", lifetime: 300, force: force) {
            try Task.checkCancellation()
            let date = now(), data = try await transport.data(from: KrakenNativeChart.url(for: market))
            return (try JSONEncoder().encode(KrakenNativeChart.decode(data, market: market, at: date)), date.timeIntervalSince1970, nil)
        }
        try Task.checkCancellation()
        let committed = try await database.saveMarketCache(.init(key: key("chart", asset), source: entry.source,
            payload: entry.payload, fetchedAt: entry.fetchedAt))
        return try decoded(committed)
    }

    private func tokenPoolChart(for asset: MarketAsset, force: Bool) async throws -> CachedMarketValue<MarketChart> {
        let transport = transport, now = now
        let entry = try await load(key: key("terminalChart", asset), source: "GeckoTerminal", lifetime: 300, force: force) {
            try Task.checkCancellation()
            let date = now()
            let pools = try await transport.data(from: TokenPoolChart.poolsURL(for: asset))
            try Task.checkCancellation()
            let selection = try TokenPoolChart.select(pools, for: asset)
            let candles = try await transport.data(from: TokenPoolChart.candlesURL(for: asset, selection: selection, at: date))
            try Task.checkCancellation()
            let chart = try TokenPoolChart.decode(candles, for: asset, selection: selection, at: date)
            return (try JSONEncoder().encode(chart), date.timeIntervalSince1970, nil)
        }
        try Task.checkCancellation()
        let committed = try await database.saveMarketCache(.init(key: key("chart", asset), source: entry.source,
            payload: entry.payload, fetchedAt: entry.fetchedAt))
        return try decoded(committed)
    }

    private func chartStatistics(from url: URL) async -> Data? {
        do { return try await transport.data(from: url) }
        catch {
            // A missing optional stats product is normal; outages still report.
            if error as? MarketDataError != .notListed {
                OathDiagnostics.record(error, component: "prices", operation: "chart_stats")
            }
            return nil
        }
    }

    private func geckoChart(for asset: MarketAsset, force: Bool) async throws -> CachedMarketValue<MarketChart> {
        let transport = transport, now = now
        // Use a distinct request key: a missing Exchange listing must not put
        // the independent market provider into the Exchange's one-hour backoff.
        let entry = try await load(key: key("geckoChart", asset), source: "CoinGecko", lifetime: 300, force: force) {
            let date = now(), data = try await transport.data(from: MarketIdentity.chartURL(for: asset))
            return (try JSONEncoder().encode(MarketDecoding.geckoChart(data, now: date)), date.timeIntervalSince1970, nil)
        }
        let committed = try await database.saveMarketCache(.init(key: key("chart", asset), source: "CoinGecko", payload: entry.payload, fetchedAt: entry.fetchedAt))
        return try decoded(committed)
    }

    private func coinbaseCode(for asset: MarketAsset) async throws -> String {
        if asset.isNative {
            guard let code = MarketIdentity.native[asset.networkID]?.coinbase else { throw MarketDataError.notListed }
            return code
        }
        for (code, networks) in MarketIdentity.issuerContracts {
            if let contract = networks[asset.networkID], asset.matches(contract) { return code }
        }
        let catalogKey = "v1.coinbase.currencies"
        let transport = transport, now = now
        let entry: MarketCacheEntry
        do {
            entry = try await load(key: catalogKey, source: "Coinbase", lifetime: 86_400, force: false) {
                let data = try await transport.data(from: URL(string: "https://api.exchange.coinbase.com/currencies")!)
                _ = try MarketDecoding.currencies(data)
                return (data, now().timeIntervalSince1970, nil)
            }
        } catch { OathDiagnostics.record(error);
            guard let saved = try await database.marketCache(key: catalogKey) else { throw error }
            entry = saved
        }
        return try MarketDecoding.tokenCode(for: asset, directory: entry.payload)
    }

    private func load(key: String, source: String, lifetime: TimeInterval, force: Bool,
                      fetch: @escaping @Sendable () async throws -> (Data, Double, PriceRecord?)) async throws -> MarketCacheEntry {
        try Task.checkCancellation()
        let consumer = UUID()
        let entry = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<MarketCacheEntry, Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                if var flight = work[key] {
                    flight.consumers[consumer] = continuation; work[key] = flight
                    return
                }
                let database = database, date = now(), id = UUID()
                let deadline = retryAfter[key], reason = retryReason[key] ?? .unavailable
                let operationID = OathDiagnostics.operationID ?? UUID()
                let task = Task {
                    await OathDiagnostics.$operationID.withValue(operationID) {
                        let result: Result<MarketCacheEntry, Error>
                        do {
                            try Task.checkCancellation()
                            if !force, let saved = try await database.marketCache(key: key),
                               (-300..<lifetime).contains(date.timeIntervalSince1970 - saved.fetchedAt) {
                                result = .success(saved)
                            } else {
                                try Task.checkCancellation()
                                if let deadline, deadline > .now { throw reason }
                                let (data, fetchedAt, price) = try await fetch()
                                try Task.checkCancellation()
                                let value = MarketCacheEntry(key: key, source: price?.source ?? source, payload: data, fetchedAt: fetchedAt)
                                result = .success(try await database.saveMarketCache(value, price: price))
                            }
                        } catch {
                            // Last-consumer cancellation is already-observed
                            // teardown, even if an uncooperative provider fails late.
                            // Cached backoff is also the original failure, not
                            // another provider attempt. Genuine failures report
                            // here before completion sets the retry deadline.
                            if !Task.isCancelled, !(error is CancellationError),
                               (error as? URLError)?.code != .cancelled,
                               deadline.map({ $0 > .now }) != true,
                               error as? MarketDataError != .notListed {
                                OathDiagnostics.record(error, component: "prices", operation: "market_load")
                            }
                            result = .failure(Task.isCancelled ? CancellationError() : error)
                        }
                        self.finishLoad(key: key, id: id, result: result)
                    }
                }
                work[key] = LoadFlight(id: id, task: task, consumers: [consumer: continuation])
            }
        } onCancel: {
            Task { await self.cancelLoad(key: key, consumer: consumer) }
        }
        try Task.checkCancellation()
        return entry
    }

    private func finishLoad(key: String, id: UUID, result: Result<MarketCacheEntry, Error>) {
        // A cancelled producer may finish after a replacement has started. It
        // must not remove that flight or change its error/backoff state.
        guard let flight = work[key], flight.id == id else { return }
        work[key] = nil
        var completion = result
        switch result {
        case .success:
            retryAfter[key] = nil; retryReason[key] = nil
        case .failure(let error):
            // Navigation/transport cancellation must not become an unavailable
            // provider for the next screen. No retry deadline exists for work
            // that was interrupted; genuine provider failures still back off.
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                completion = .failure(CancellationError())
            } else if error is DiagnosticDeferral {
                // The shared scheduler owns this deadline. Do not replace it
                // with an unavailable/not-listed result or extend it per asset.
            } else {
                // Repeated reads preserve the original backoff deadline.
                if retryAfter[key].map({ $0 > .now }) != true {
                    retryAfter[key] = .now.advanced(by: .seconds(error as? MarketDataError == .notListed ? 3_600 : 60))
                    retryReason[key] = error as? MarketDataError ?? .unavailable
                }
            }
        }
        for continuation in flight.consumers.values { continuation.resume(with: completion) }
    }

    private func cancelLoad(key: String, consumer: UUID) {
        guard var flight = work[key], let continuation = flight.consumers.removeValue(forKey: consumer) else { return }
        continuation.resume(throwing: CancellationError())
        if flight.consumers.isEmpty {
            work[key] = nil; flight.task.cancel()
        } else {
            // Preserve the single public read for screens that still need it.
            work[key] = flight
        }
    }
}

private struct CachedTokenMetadata: Decodable {
    let reference:String
    let name:String
    let symbol:String
    let decimals:Int
    let logo:String?
    let description:String?
}
