import Foundation
import GRDB
import Observation

/// Public market data has its own database, outside the wallet reset transaction.
actor MarketDatabase {
    private var pool: DatabasePool?
    private let directory: URL
    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.aperture.wallet")
        .appendingPathComponent("Markets", isDirectory: true)) { self.directory = directory }

    private func connection() throws -> DatabasePool {
        if let pool { return pool }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let opened = try DatabasePool(path: directory.appendingPathComponent("markets.sqlite").path)
        try opened.write { db in
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS marketRecords (id TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL)")
        }
        pool = opened
        return opened
    }
    func load() throws -> [String: MarketRecord] {
        try connection().read { db in
            var result: [String: MarketRecord] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT id, payload FROM marketRecords") {
                let data: Data = row["payload"]
                if let record = try? JSONDecoder().decode(MarketRecord.self, from: data) { result[row["id"]] = record }
            }
            return result
        }
    }
    func close() { pool = nil }

    func save(_ records: [String: MarketRecord]) throws {
        try connection().write { db in
            for (id, record) in records {
                let data = try JSONEncoder().encode(record)
                try db.execute(sql: "INSERT INTO marketRecords (id,payload) VALUES (?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload", arguments: [id, data])
            }
        }
    }
}

/// Best-effort recovery after reinstall on the same iCloud account. No wallet data.
actor MarketCloudArchive {
    func merge(_ local: [String: MarketRecord]) -> [String: MarketRecord] {
        guard let root = FileManager.default.url(forUbiquityContainerIdentifier: "iCloud.com.aperture.wallet") else { return local }
        let directory = root.appendingPathComponent("Documents/Markets", isDirectory: true)
        let url = directory.appendingPathComponent("public-market-cache-v1.json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.isUbiquitousItem(at: url) {
                let values = try url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
                if values.ubiquitousItemDownloadingStatus != .current {
                    try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                    // Never replace an archive whose bytes have not downloaded yet.
                    return local
                }
            }
            var merged = local
            var error: NSError?
            NSFileCoordinator().coordinate(writingItemAt: url, options: .forMerging, error: &error) { coordinatedURL in
                if let data = try? Data(contentsOf: coordinatedURL), data.count < 20_000_000,
                   let remote = try? JSONDecoder().decode([String: MarketRecord].self, from: data) {
                    for (id, record) in remote where !id.isEmpty && id.utf8.count < 1024 {
                        merged[id, default: MarketRecord()].merge(record)
                    }
                }
                if let encoded = try? JSONEncoder().encode(merged) { try? encoded.write(to: coordinatedURL, options: .atomic) }
            }
            return merged
        } catch { return local }
    }
}

@MainActor @Observable
final class MarketStore {
    static let shared = MarketStore()
    private(set) var records: [String: MarketRecord] = [:]
    private let database: MarketDatabase
    private let provider: MarketProvider
    private let cloud = MarketCloudArchive()
    private let cloudEnabled: Bool
    private var visibleAssets: [WalletAsset] = []
    private var discoveryCoins: [MarketCoin] = []
    private var running = false
    private var loaded = false
    private var requests = Set<String>()
    private var cloudSyncAt = Date.distantPast
    private var archiveTask: Task<Void, Never>?

    init(database: MarketDatabase = MarketDatabase(), provider: MarketProvider = MarketProvider(), cloudEnabled: Bool = true) {
        self.cloudEnabled = cloudEnabled
        self.database = database
        self.provider = provider
    }

    func loadCache() async {
        guard !loaded else { return }
        loaded = true
        if let saved = try? await database.load() {
            for (id, record) in saved { records[id, default: MarketRecord()].merge(record) }
        }
    }

    /// Owned by the app root, including onboarding. Sleeps and requests suspend;
    /// database, JSON decoding and iCloud coordination execute off the main actor.
    func run() async {
        guard !running else { return }
        running = true
        defer { running = false }
        await loadCache()
        // Cloud recovery cannot delay public API requests or first paint.
        let recovery = Task { await synchronizeCloud() }
        defer { recovery.cancel() }
        var failures = 0
        while !Task.isCancelled {
            let needed = catalog(assets: visibleAssets).filter { Date().timeIntervalSince(records[$0.id]?.quote?.updatedAt ?? .distantPast) > 180 }
            if !needed.isEmpty {
                let quotes = await refresh(coins: needed)
                failures = quotes.count < needed.count ? min(failures + 1, 5) : 0
            }
            if Date().timeIntervalSince(cloudSyncAt) > 900 { await synchronizeCloud() }
            do { try await Task.sleep(for: .seconds(failures > 0 ? min(300, 10 * pow(2, Double(failures))) : 180)) }
            catch { return }
        }
    }

    func catalog(assets: [WalletAsset]) -> [MarketCoin] {
        var coins = MarketCoin.catalog(for: assets)
        var seen = Set(coins.map(\.id))
        coins.append(contentsOf: discoveryCoins.filter { seen.insert($0.id).inserted })
        return coins
    }

    func trackDiscovery(_ discovery: MarketDiscoveryStore) async {
        let snapshot = discovery.trending
        var seen = Set<String>()
        discoveryCoins = ((snapshot?.coins ?? []) + discovery.favorites)
            .filter { seen.insert($0.id).inserted }.map(\.marketCoin)
        if let snapshot {
            var quotes: [String: MarketQuote] = [:]
            for coin in snapshot.coins {
                guard let price = coin.price else { continue }
                let quote = MarketQuote(price: price, change24h: coin.change24h,
                    marketCap: nil, volume: nil, high24h: nil, low24h: nil,
                    supply: nil, rank: nil, image: coin.image,
                    updatedAt: snapshot.date, source: "CoinGecko",
                    changeUpdatedAt: snapshot.date)
                if quote.isValid { quotes[coin.id] = quote }
            }
            if !quotes.isEmpty { await accept(quotes) }
        }
    }

    func trackVisibleAssets(_ assets: [WalletAsset]) async {
        visibleAssets = assets
        await loadCache()
        let owned = MarketCoin.catalog(for: assets).filter {
            $0.ownedAsset != nil && Date().timeIntervalSince(records[$0.id]?.quote?.updatedAt ?? .distantPast) > 180
        }
        if !owned.isEmpty { await refresh(coins: owned) }
    }

    @discardableResult
    func refresh(coins: [MarketCoin]) async -> [String: MarketQuote] {
        await loadCache()
        return await provider.quotes(for: coins) { [weak self] quotes in
            await self?.accept(quotes)
        }
    }
    private func accept(_ quotes: [String: MarketQuote]) async {
        for (id, quote) in quotes { records[id, default: MarketRecord()].merge(MarketRecord(quote: quote)) }
        await persist()
    }

    func detail(_ coin: MarketCoin, range: MarketRange) async {
        await loadCache()
        // Metadata must not wait behind historical-provider retries. This task
        // also survives a range change; the per-coin key coalesces requests.
        Task { await updateInfo(coin) }
        let key = coin.id + range.rawValue
        guard requests.insert(key).inserted else { return }
        defer { requests.remove(key) }
        let cached = records[coin.id]?.histories[range.rawValue]
        if cached == nil || Date().timeIntervalSince(cached!.updatedAt) > 900 {
            // Bounded retry; cached history is never cleared by a failed request.
            for attempt in 0..<3 {
                if let history = await provider.history(for: coin, range: range) {
                    records[coin.id, default: MarketRecord()].histories[range.rawValue] = history
                    await persist()
                    break
                }
                guard !Task.isCancelled else { return }
                if attempt < 2 { try? await Task.sleep(for: .seconds(2 * (attempt + 1))) }
            }
        }
    }

    private func updateInfo(_ coin: MarketCoin) async {
        let infoKey = coin.id + ":info"
        if Date().timeIntervalSince(records[coin.id]?.info?.updatedAt ?? .distantPast) > 604_800,
           requests.insert(infoKey).inserted {
            defer { requests.remove(infoKey) }
            if let info = await provider.info(for: coin) {
                records[coin.id, default: MarketRecord()].info = info
                await persist()
            }
        }
    }
    private func persist(archive: Bool = true) async {
        try? await database.save(records)
        guard archive, cloudEnabled, archiveTask == nil else { return }
        archiveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled else { return }
            await self.synchronizeCloud()
            self.archiveTask = nil
        }
    }
    private func synchronizeCloud() async {
        guard cloudEnabled else { return }
        cloudSyncAt = Date()
        let restored = await cloud.merge(records)
        for (id, record) in restored { records[id, default: MarketRecord()].merge(record) }
        await persist(archive: false)
    }
}
