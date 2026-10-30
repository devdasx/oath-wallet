import OathDiagnostics
import Foundation
import OathAnkr

public actor ArcSynchronizer {
    private let database: OathDatabase
    private let client: ArcClient
    private let markets: ArcMarkets
    private var flights: [String: (UUID, Task<Void, Error>)] = [:]
    private var histories: [String: Task<Void, Never>] = [:]
    private var catalogFlight: (UUID, Task<ArcCatalog, Never>)?
    private var epoch = UUID()
    public init(database: OathDatabase, indexKey: String? = nil, alchemyAPIKey: String? = nil) throws {
        self.database = database; client = try ArcClient(indexKey: indexKey, alchemyAPIKey: alchemyAPIKey); markets = ArcMarkets()
    }
    public init(database: OathDatabase, client: ArcClient, markets: ArcMarkets = ArcMarkets()) {
        self.database = database; self.client = client; self.markets = markets
    }
    private func catalog() async -> ArcCatalog {
        if let catalogFlight { return await catalogFlight.1.value }
        let id = UUID(), task = Task { await self.fetchCatalog() }
        catalogFlight = (id,task)
        let result = await task.value
        if catalogFlight?.0 == id { catalogFlight = nil }
        return result
    }
    private func fetchCatalog() async -> ArcCatalog {
        let saved = await OathDiagnostics.attemptOptional("marketCache", body: { try await database.marketCache(key: "arc.catalog") })
        let cached = saved.flatMap { try? JSONDecoder().decode(ArcCatalog.self, from: $0.payload) }
        if let saved, let cached, Date().timeIntervalSince1970 - saved.fetchedAt < 86_400 { return cached }
        do {
            let value = try await markets.catalog(); try Task.checkCancellation()
            try await database.saveMarketCache(.init(key: "arc.catalog", source: "CoinGecko", payload: try JSONEncoder().encode(value), fetchedAt: Date().timeIntervalSince1970))
            return value
        } catch { OathDiagnostics.record(error); return cached ?? .bootstrap }
    }
    public func refresh(accountID: String) async throws {
        let generation = epoch
        guard !Task.isCancelled else { throw CancellationError() }
        if let flight = flights[accountID] { return try await flight.1.value }
        let id = UUID()
        let task = Task { [database,client,markets] in
            // Drain the previous history before beginArcSync revokes its ticket.
            // Otherwise its final commit/failure write races the new refresh.
            await self.stopHistory(accountID: accountID)
            guard generation == self.epoch, !Task.isCancelled else { throw CancellationError() }
            let ticket = try await database.beginArcSync(accountID: accountID)
            guard generation == self.epoch, !Task.isCancelled else { throw CancellationError() }
            do {
                async let catalogWork = self.catalog()
                async let native = await OathDiagnostics.attempt("native_price") { try await markets.nativePrice() }
                let tracked = try await database.knownArcTokens(accountID: accountID)
                let catalog = await catalogWork
                let value = try await client.inventory(owner:ticket.account.address,references:Array(catalog.ids.keys),tracked:tracked)
                try Task.checkCancellation(); try await database.commitArcInventory(value,ticket:ticket,catalog:catalog)
                if let price = await native { try await Self.save([price],database:database) }
                await self.startHistory(ticket,through:value.block + 1,catalog:catalog)
                await self.updatePrices(value,ticket:ticket,catalog:catalog)
                try Task.checkCancellation()
            } catch { OathDiagnostics.record(error); await OathDiagnostics.attempt("failArcSync", body: { try await database.failArcSync(ticket,code:Self.code(error)) }); throw error }
        }
        flights[accountID] = (id,task)
        do { try await task.value; if flights[accountID]?.0 == id { flights[accountID] = nil } }
        catch { OathDiagnostics.record(error); if flights[accountID]?.0 == id { flights[accountID] = nil }; throw error }
    }
    private static func save(_ prices: [ArcPrice], database: OathDatabase) async throws {
        for quote in prices {
            try Task.checkCancellation()
            guard let asset = try await database.asset(networkID: "arc", reference: quote.reference),
                  (try? Validation.price(quote.usd)) != nil else { continue }
            do {
                try await database.saveMarketCache(.init(key: "arc.price." + quote.reference, source: quote.source,
                    payload: try JSONEncoder().encode(quote), fetchedAt: quote.fetchedAt.timeIntervalSince1970),
                    price: .init(assetID: asset.id, currency: "USD", value: quote.usd, observedAt: quote.fetchedAt.timeIntervalSince1970, source: quote.source))
            } catch StoreError.staleSync { continue }
        }
    }
    private func updatePrices(_ inventory:ArcInventory,ticket:ArcSyncTicket,catalog:ArcCatalog) async {
        let tracked = Set((await OathDiagnostics.attempt("trackedAssets", body: { try await database.trackedAssets(walletID:ticket.account.walletID) }))?.filter { $0.networkID == "arc" }.map(\.reference) ?? [])
        let refs = inventory.holdings.filter { $0.token.reference != "native" && $0.amount != nil && $0.amount != "0" &&
            (catalog.contains($0.token.reference) || tracked.contains($0.token.reference)) }.map { $0.token.reference }.sorted()
        let markets = markets, database = database
        await withTaskGroup(of:Void.self) { group in
            var next = 0
            func enqueue() {
                guard next < refs.count, !Task.isCancelled else { return }
                let chunk = Array(refs[next..<min(next+30,refs.count)]); next += chunk.count
                group.addTask {
                    do {
                        let prices = try await markets.quotes(references:chunk,catalog:catalog)
                        try Task.checkCancellation(); try await Self.save(prices,database:database)
                    } catch { OathDiagnostics.record(error);}
                }
            }
            enqueue(); enqueue(); for await _ in group { enqueue() }
        }
    }
    private func startHistory(_ ticket: ArcSyncTicket, through:Int64, catalog:ArcCatalog) async {
        let generation = epoch
        let previous = histories.removeValue(forKey:ticket.account.id)
        previous?.cancel(); await previous?.value
        guard generation == epoch, !Task.isCancelled else { return }
        let database = database, client = client
        histories[ticket.account.id] = Task {
            do { try await database.prepareArcHistory(ticket,through:through) }
            catch { await self.historyFailed(error, ticket: ticket); return }
            await withTaskGroup(of:Void.self) { group in
                // Independent recent and genesis lanes. Each page/cursor commits
                // atomically, so interruption never skips undiscovered tokens.
                for lane in ["recent","backfill"] {
                    group.addTask {
                        do {
                            while !Task.isCancelled {
                                guard let cursor = try await database.arcHistoryWork(ticket).first(where: { $0.lane == lane }) else { break }
                                let known = try await database.knownArcTokens(accountID:ticket.account.id)
                                let page = try await client.history(owner:ticket.account.address,from:cursor.nextBlock,through:cursor.endBlock,known:known)
                                try Task.checkCancellation()
                                try await database.commitArcPage(page,cursor:cursor,ticket:ticket)
                                let discovered = Dictionary(page.events.map { ($0.token.reference,$0.token) },uniquingKeysWith:{ first,_ in first }).values.filter { $0.reference != "native" }
                                if !discovered.isEmpty {
                                    let inventory = try await client.inventory(owner:ticket.account.address,references:[],tracked:Array(discovered))
                                    try Task.checkCancellation()
                                    do { try await database.commitArcInventory(inventory,ticket:ticket,catalog:catalog) }
                                    catch StoreError.staleSync { continue }
                                    await self.updatePrices(inventory,ticket:ticket,catalog:catalog)
                                }
                            }
                        } catch { await self.historyFailed(error, ticket: ticket, lane: lane) }
                    }
                }
            }
        }
    }
    private func stopHistory(accountID: String) async {
        let previous = histories.removeValue(forKey: accountID)
        previous?.cancel()
        await previous?.value
    }
    private func historyFailed(_ error: any Error, ticket: ArcSyncTicket, lane: String? = nil) async {
        do {
            try Task.checkCancellation()
            try await database.requireCurrentArcSync(ticket)
            if OathDiagnostics.isExpectedCancellation(error) { throw CancellationError() }
            OathDiagnostics.record(error, operation: "arc_history", context: ["chain": "arc", "stage": lane ?? "prepare"])
            try await database.failArcSync(ticket, lane: lane, code: Self.code(error))
        } catch is CancellationError {
            // diagnostics: arc-history-teardown. Cancelled work must not write a failure.
        } catch StoreError.staleSync {
            // diagnostics: arc-history-ownership. The ticket was superseded or
            // removed, possibly between the read and failure-write transaction.
            // Current-run cursor conflicts are still reported above.
        } catch {
            OathDiagnostics.record(error, operation: "failArcSync", context: ["chain": "arc", "stage": lane ?? "prepare"])
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
