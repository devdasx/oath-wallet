import OathDiagnostics
import Foundation
import Observation
import OathDatabase
import OathMarketData

actor OathMarketEnvironment {
    static let shared = OathMarketEnvironment()
    private var setup: Task<MarketDataService, Error>?
    func service() async throws -> MarketDataService {
        if setup == nil {
            setup = Task { MarketDataService(database: try await OathDataEnvironment.shared.database()) }
        }
        do { return try await setup!.value }
        catch { OathDiagnostics.record(error); setup = nil; throw error }
    }
}

@MainActor @Observable final class OathAssetDetailModel {
    var quote: CachedMarketValue<MarketQuote>?
    var information: CachedMarketValue<AssetInformation>?
    var chart: CachedMarketValue<MarketChart>?
    var quoteFailed = false
    var informationFailed = false
    var chartFailed = false
    var loading = true
    var quoteLoading = true
    var history: [ChainHistoryItem] = []
    var historyFailed = false
    var loadingHistory = false
    private(set) var hasMoreHistory = false
    let historyLimit = 5
    private var requestID = UUID()
    private var historyRequestID = UUID()
    private var historyScope: String?

    func open(asset: MarketAsset, walletID: String, accountID: String) async {
        let request = UUID(); requestID = request
        loading = true; quoteLoading = true
        do {
            let service = try await OathMarketEnvironment.shared.service()
            async let savedQuote = service.cachedQuote(for: asset)
            async let savedInfo = service.cachedInformation(for: asset)
            async let savedChart = service.cachedChart(for: asset)
            let cached = try await (savedQuote, savedInfo, savedChart)
            guard !Task.isCancelled, requestID == request else { return }
            quote = cached.0; information = cached.1; chart = cached.2
            await refresh(asset: asset, walletID: walletID, accountID: accountID)
        } catch { OathDiagnostics.record(error, component: "asset_details", context: ["chain": asset.networkID, "asset_kind": asset.isNative ? "native" : "token"]);
            guard !Task.isCancelled, requestID == request else { return }
            quoteFailed = true; informationFailed = true; chartFailed = true
            loading = false; quoteLoading = false
        }
    }

    func refresh(asset: MarketAsset, walletID: String, accountID: String, force: Bool = false) async {
        loading = true
        await OathDiagnostics.$chain.withValue(asset.networkID) {
            await OathDiagnostics.$operationID.withValue(UUID()) {
                async let quoteWork: () = updateQuote(asset, force: force)
                async let infoWork: () = updateInformation(asset, force: force)
                async let chartWork: () = updateChart(asset, force: force)
                async let rates = await OathDiagnostics.attempt("exchange_rates") { try await OathExchangeRateEnvironment.shared.refresh() }
                _ = await (quoteWork, infoWork, chartWork, rates)
            }
        }
        if !Task.isCancelled { loading = false }
    }
    func updateQuote(_ asset: MarketAsset, force: Bool = false) async {
        quoteLoading = true
        defer { quoteLoading = false }
        do {
            let service = try await OathMarketEnvironment.shared.service()
            let result = try await service.quote(for: asset, force: force)
            guard !Task.isCancelled else { return }
            quote = result; quoteFailed = false
        } catch {
            // A provider may have no listing for an otherwise valid token. Keep
            // the existing unavailable/saved-data presentation without logging
            // expected coverage gaps. Invalid data and outages remain failures.
            if error as? MarketDataError != .notListed {
                OathDiagnostics.record(error, component: "asset_details", context: ["chain": asset.networkID, "asset_kind": asset.isNative ? "native" : "token"])
            }
            if !Task.isCancelled { quoteFailed = true } }
    }
    private func updateInformation(_ asset: MarketAsset, force: Bool) async {
        do {
            let service = try await OathMarketEnvironment.shared.service()
            // Information includes market cap and supply; refresh those with
            // the user's pull while retaining shared coalescing and backoff.
            let result = try await service.information(for: asset, force: force)
            guard !Task.isCancelled else { return }
            information = result; informationFailed = false
        } catch {
            // A provider may have no listing for an otherwise valid token. Keep
            // the existing unavailable/saved-data presentation without logging
            // expected coverage gaps. Invalid data and outages remain failures.
            if error as? MarketDataError != .notListed {
                OathDiagnostics.record(error, component: "asset_details", context: ["chain": asset.networkID, "asset_kind": asset.isNative ? "native" : "token"])
            }
            if !Task.isCancelled { informationFailed = true } }
    }
    private func updateChart(_ asset: MarketAsset, force: Bool) async {
        do {
            let service = try await OathMarketEnvironment.shared.service()
            let result = try await service.chart(for: asset, force: force)
            guard !Task.isCancelled else { return }
            chart = result; chartFailed = false
        } catch {
            // A provider may have no listing for an otherwise valid token. Keep
            // the existing unavailable/saved-data presentation without logging
            // expected coverage gaps. Invalid data and outages remain failures.
            if error as? MarketDataError != .notListed {
                OathDiagnostics.record(error, component: "asset_details", context: ["chain": asset.networkID, "asset_kind": asset.isNative ? "native" : "token"])
            }
            if !Task.isCancelled { chartFailed = true } }
    }
    func observeHistory(walletID: String, accountID: String, assetID: String, currency: String) async {
        let request = UUID()
        historyRequestID = request
        let scope = "\(walletID):\(accountID):\(assetID)"
        if historyScope != scope {
            history = []; hasMoreHistory = false; historyFailed = false; historyScope = scope
        }
        loadingHistory = true
        defer { if historyRequestID == request { loadingHistory = false } }
        do {
            let db = try await OathDataEnvironment.shared.database()
            async let _: Void = OathSwapHistoryEnrichment.shared.observe(walletID: walletID)
            let limit = historyLimit
            // One lookahead row determines whether this asset needs View All.
            for try await page in db.observeChainHistory(walletID: walletID, accountID: accountID, assetID: assetID, currency: currency, limit: limit + 1) {
                guard !Task.isCancelled, historyRequestID == request else { return }
                history = Array(page.prefix(limit))
                hasMoreHistory = page.count > limit
                historyFailed = false; loadingHistory = false
            }
        } catch { OathDiagnostics.record(error); if !Task.isCancelled, historyRequestID == request { historyFailed = true } }
    }
}

struct OathAssetRoute: Hashable {
    let walletID: String
    let holding: Holding
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.walletID == rhs.walletID && lhs.holding.id == rhs.holding.id }
    func hash(into hasher: inout Hasher) { hasher.combine(walletID); hasher.combine(holding.id) }
}

@MainActor @Observable final class OathChainActivityModel {
    private(set) var items: [ChainHistoryItem] = []
    private(set) var displayCurrency = "USD"
    private(set) var loading = true
    private(set) var failed = false
    private(set) var hasMore = false
    private(set) var limit = 50
    private(set) var attempt = 0
    private var requestID = UUID()
    private var scope: String?
    private var contentScope: String?
    private var filterScope: HistoryFilter?

    init(seed: OathHomeHistorySnapshot? = nil) {
        guard let seed else { return }
        items = Array(seed.items.prefix(limit)); hasMore = seed.items.count > limit
        displayCurrency = seed.currency; loading = false
        contentScope = "\(seed.walletID):all:all:all"
        scope = "\(seed.walletID):all:all:all:\(seed.currency)::\(seed.localeIdentifier)"
        filterScope = .init()
    }

    func loadMoreOrRetry() {
        guard !loading, failed || hasMore else { return }
        loading = true
        if failed { attempt += 1 }
        else if hasMore { limit += 50 }
    }

    func observe(walletID: String, networkID: String?, accountID: String?, assetID: String?,
                 currency: String, query: String, filter: HistoryFilter, localeIdentifier: String) async {
        let request = UUID()
        requestID = request
        let nextContentScope = "\(walletID):\(networkID ?? "all"):\(accountID ?? "all"):\(assetID ?? "all")"
        let nextScope = "\(walletID):\(networkID ?? "all"):\(accountID ?? "all"):\(assetID ?? "all"):\(currency):\(query):\(localeIdentifier)"
        // A filter/search refresh keeps its last complete page until the local
        // index delivers the replacement. Clearing here destroys row identity
        // and makes a native List animate two unrelated lists through empty.
        // Never carry rows across wallet/account/asset boundaries.
        if contentScope != nextContentScope {
            items = []; contentScope = nextContentScope
        }
        if scope != nextScope || filterScope != filter {
            hasMore = false; failed = false; limit = 50; scope = nextScope
            filterScope = filter
        }
        loading = true
        defer { if requestID == request { loading = false } }
        do {
            let db = try await OathDataEnvironment.shared.database()
            if !query.isEmpty { try await Task.sleep(for: .milliseconds(180)) }
            try Task.checkCancellation()
            async let _: Void = OathSwapHistoryEnrichment.shared.observe(walletID: walletID)
            let visibleLimit = limit
            for try await page in db.observeChainHistory(walletID: walletID, networkID: networkID,
                                                         accountID: accountID, assetID: assetID,
                                                         currency: currency, limit: visibleLimit + 1,
                                                         search: query, filter: filter, localeIdentifier: localeIdentifier) {
                guard !Task.isCancelled, requestID == request else { return }
                items = Array(page.prefix(visibleLimit))
                displayCurrency = currency
                hasMore = page.count > visibleLimit
                failed = false; loading = false
            }
        } catch { OathDiagnostics.record(error, component: "history", operation: "observe");
            if !Task.isCancelled, requestID == request { failed = true }
        }
    }
}
