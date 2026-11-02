import OathDiagnostics
import Foundation
import OathAnkr

public actor RobinhoodSynchronizer {
    private let database: OathDatabase
    private let client: RobinhoodClient
    private let markets: RobinhoodMarkets
    private var flights: [String: (UUID, Task<Void, Error>)] = [:]
    private var histories: [String: Task<Void, Never>] = [:]
    private var catalogFlight: (UUID, Task<RobinhoodCatalog, Never>)?
    private var epoch = UUID()
    public init(database: OathDatabase, apiKey: String, blockscoutKey: String? = nil, alchemyAPIKey: String? = nil) throws {
        self.database = database; client = try RobinhoodClient(apiKey: apiKey, blockscoutKey: blockscoutKey, alchemyAPIKey: alchemyAPIKey); markets = RobinhoodMarkets()
    }
    public init(database: OathDatabase, client: RobinhoodClient, markets: RobinhoodMarkets = RobinhoodMarkets()) {
        self.database = database; self.client = client; self.markets = markets
    }
    private func catalog() async -> RobinhoodCatalog {
        if let catalogFlight { return await catalogFlight.1.value }
        let id = UUID(), task = Task { await self.fetchCatalog() }
        catalogFlight = (id,task)
        let result = await task.value
        if catalogFlight?.0 == id { catalogFlight = nil }
        return result
    }
    private func fetchCatalog() async -> RobinhoodCatalog {
        let saved = await OathDiagnostics.attemptOptional("marketCache", body: { try await database.marketCache(key: "robinhood.catalog") })
        let cached = saved.flatMap { saved in OathDiagnostics.attempt("decode_cached_catalog", body: { try JSONDecoder().decode(RobinhoodCatalog.self, from: saved.payload) }) }
        if let saved, let cached, Date().timeIntervalSince1970 - saved.fetchedAt < 86_400 { return cached }
        do {
            let value = try await markets.catalog(); try Task.checkCancellation()
            try await database.saveMarketCache(.init(key: "robinhood.catalog", source: "CoinGecko", payload: try JSONEncoder().encode(value), fetchedAt: Date().timeIntervalSince1970))
            return value
        } catch { OathDiagnostics.record(error); return cached ?? .empty }
    }
    public func refresh(accountID: String) async throws {
        let generation = epoch
        guard !Task.isCancelled else { throw CancellationError() }
        if let flight = flights[accountID] { return try await flight.1.value }
        let id = UUID()
        let task = Task { [database,client,markets] in
            let ticket = try await database.beginRobinhoodSync(accountID: accountID)
            guard generation == self.epoch, !Task.isCancelled else { throw CancellationError() }
            self.startHistory(ticket)
            do {
                let tracked = try await database.knownRobinhoodTokens(accountID: accountID)
                async let inventory = client.inventory(owner: ticket.account.address, tracked: tracked)
                async let native = await OathDiagnostics.attempt("native_price") { try await markets.nativePrice() }
                let catalog = await self.catalog()
                let value = try await inventory; try Task.checkCancellation()
                try await database.commitRobinhoodInventory(value, ticket: ticket, catalog: catalog)
                if let price = await native { try await Self.save([price], database: database) }
                let trackedRefs = Set(try await database.trackedAssets(walletID: ticket.account.walletID).filter { $0.networkID == "robinhood" }.map(\.reference))
                let refs = value.holdings.filter { $0.token.reference != "native" && $0.amount != "0" &&
                    (catalog.contains($0.token.reference) || trackedRefs.contains($0.token.reference)) }.map { $0.token.reference }.sorted()
                await withTaskGroup(of: Void.self) { group in
                    var next = 0
                    func enqueue() {
                        guard next < refs.count, !Task.isCancelled else { return }
                        let chunk = Array(refs[next..<min(next+30, refs.count)]); next += chunk.count
                        group.addTask {
                            do {
                                var prices = (await OathDiagnostics.attempt("prices", body: { try await markets.prices(references: chunk, catalog: catalog) })) ?? []
                                try Task.checkCancellation()
                                let missing = chunk.filter { ref in !prices.contains { $0.reference == ref } }
                                if !missing.isEmpty { prices += (await OathDiagnostics.attempt("dexPrices", body: { try await markets.dexPrices(references: missing) })) ?? [] }
                                try Task.checkCancellation(); try await Self.save(prices, database: database)
                            } catch { OathDiagnostics.record(error);}
                        }
                    }
                    enqueue(); enqueue(); for await _ in group { enqueue() }
                }
                try Task.checkCancellation()
            } catch { OathDiagnostics.record(error); await OathDiagnostics.attempt("failRobinhoodSync", body: { try await database.failRobinhoodSync(ticket, code: Self.code(error)) }); throw error }
        }
        flights[accountID] = (id,task)
        do { try await task.value; if flights[accountID]?.0 == id { flights[accountID] = nil } }
        catch { OathDiagnostics.record(error); if flights[accountID]?.0 == id { flights[accountID] = nil }; throw error }
    }
    private static func save(_ prices: [RobinhoodPrice], database: OathDatabase) async throws {
        for quote in prices {
            try Task.checkCancellation()
            guard let asset = try await database.asset(networkID: "robinhood", reference: quote.reference),
                  (try? Validation.price(quote.usd)) != nil else { continue }
            do {
                try await database.saveMarketCache(.init(key: "robinhood.price." + quote.reference, source: quote.source,
                    payload: try JSONEncoder().encode(quote), fetchedAt: quote.fetchedAt.timeIntervalSince1970),
                    price: .init(assetID: asset.id, currency: "USD", value: quote.usd, observedAt: quote.fetchedAt.timeIntervalSince1970, source: quote.source))
            } catch StoreError.staleSync { continue }
        }
    }
    private func startHistory(_ ticket: RobinhoodSyncTicket) {
        histories[ticket.account.id]?.cancel()
        let database = database, client = client
        histories[ticket.account.id] = Task {
            await withTaskGroup(of: Void.self) { group in
                for stream in client.historyStreams {
                    group.addTask {
                        // Each stream's recent page wins over old backfill.
                        // The three independent streams overlap, while the
                        // indexer's shared limiter respects its free-tier rate.
                        for lane in ["recent", "backfill"] {
                            var current: RobinhoodHistoryCursor?
                            do {
                                var visited: Set<String> = []
                                var restarted = false
                                while !Task.isCancelled {
                                    guard let cursor = try await database.robinhoodHistoryWork(ticket).first(where: { $0.stream == stream.rawValue && $0.lane == lane }) else { break }
                                    current = cursor
                                    guard visited.insert(cursor.cursor ?? "first").inserted else { throw AnkrError.paginationLoop }
                                    do {
                                        let page = try await client.history(owner: ticket.account.address, stream: stream, cursor: cursor.cursor,
                                                                            from: cursor.startTime, through: cursor.endTime)
                                        try Task.checkCancellation(); try await database.commitRobinhoodPage(page, cursor: cursor, ticket: ticket)
                                    } catch AnkrError.http(let code) where [400,422].contains(code) && cursor.cursor != nil && !restarted {
                                        try await database.restartRobinhoodHistory(cursor, ticket: ticket)
                                        restarted = true; visited.removeAll()
                                    }
                                }
                            } catch { OathDiagnostics.record(error);
                                if let current { await OathDiagnostics.attempt("failRobinhoodSync", body: { try await database.failRobinhoodSync(ticket, cursor: current, code: Self.code(error)) }) }
                                break
                            }
                        }
                    }
                }
            }
        }
    }
    public func waitForHistory(accountID: String) async { await histories[accountID]?.value }
    private static func code(_ error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        if let error = error as? AnkrError { return String(describing: error) }; return "storage"
    }
    public func cancel() async {
        epoch = UUID(); let tasks = flights.values.map(\.1), history = Array(histories.values)
        let catalog = catalogFlight?.1; catalogFlight = nil; catalog?.cancel()
        flights.removeAll(); histories.removeAll()
        for task in tasks { task.cancel() }; for task in history { task.cancel() }
        for task in tasks { _ = try? await task.value }; for task in history { await task.value }
        _ = await catalog?.value
    }
}
