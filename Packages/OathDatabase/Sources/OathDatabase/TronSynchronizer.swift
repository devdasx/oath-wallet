import OathDiagnostics
import Foundation
import OathAnkr

/// Refreshes the active public address. Quotes, inventory and three historical
/// streams overlap; each opaque pagination cursor advances only after commit.
public actor TronSynchronizer {
    private let database: OathDatabase
    private let client: TronClient
    private let markets: TronMarkets
    private var flights: [String: (UUID, Task<Void, Error>)] = [:]
    private var histories: [String: Task<Void, Never>] = [:]
    private var epoch = UUID()
    public init(database: OathDatabase, apiKey: String) throws {
        self.database = database; client = try TronClient(apiKey: apiKey); markets = TronMarkets()
    }
    public init(database: OathDatabase, client: TronClient, markets: TronMarkets = TronMarkets()) {
        self.database = database; self.client = client; self.markets = markets
    }
    public func refresh(accountID: String) async throws {
        let generation = epoch
        guard let account = try await database.account(accountID), account.networkID == "tron" else { throw StoreError.missingRecord }
        guard epoch == generation, !Task.isCancelled else { throw CancellationError() }
        if let flight = flights[accountID] { return try await flight.1.value }
        histories[accountID]?.cancel(); histories[accountID] = nil
        let id = UUID()
        let task = Task { [database,client,markets] in
            let ticket = try await database.beginTronSync(accountID: accountID)
            do {
                let tracked = try await database.trackedAssets(walletID: account.walletID).filter { $0.networkID == "tron" }.map(\.reference)
                let previous = try await database.tronInventory(accountID: accountID)?.holdings.map { $0.token.reference } ?? []
                async let values = client.inventory(owner: account.address, additionalTokens: Array(Set(tracked + previous)))
                async let directory = Self.catalog(database, markets)
                async let quote = await OathDiagnostics.attempt("native_price") { try await markets.nativePrice() }
                let catalog = await directory
                self.startHistory(ticket, catalog: catalog)
                let inventory = try await values
                try Task.checkCancellation()
                try await database.commitTronInventory(inventory, ticket: ticket, catalog: catalog)
                if let quote = await quote { try await Self.save([quote], database: database) }
                let refs = inventory.holdings.filter { $0.amount != "0" && TronIdentity.isToken($0.token.reference) && (catalog[$0.token.reference] != nil || tracked.contains($0.token.reference)) }.map { $0.token.reference }.sorted()
                await withTaskGroup(of: Void.self) { group in
                    var next = 0
                    func enqueue() {
                        guard next < refs.count, !Task.isCancelled else { return }
                        let chunk = Array(refs[next..<min(next+30,refs.count)]); next += chunk.count
                        group.addTask {
                            do { let prices = try await markets.prices(mints: chunk); try Task.checkCancellation(); try await Self.save(prices, database: database) }
                            catch { OathDiagnostics.record(error); /* Preserve cached quotes on provider failure or an unpriced market. */ }
                        }
                    }
                    enqueue(); enqueue(); for await _ in group { enqueue() }
                }
                if !inventory.failedReferences.isEmpty || !inventory.discoveryComplete { throw TronError.incomplete }
            } catch { OathDiagnostics.record(error);
                await OathDiagnostics.attempt("failTronSync", body: { try await database.failTronSync(ticket, history: false, code: Self.code(error)) }); throw error
            }
        }
        flights[accountID] = (id,task)
        do { try await task.value; if flights[accountID]?.0 == id { flights[accountID] = nil } }
        catch { OathDiagnostics.record(error); if flights[accountID]?.0 == id { flights[accountID] = nil }; throw error }
    }
    private static func catalog(_ database: OathDatabase, _ markets: TronMarkets) async -> [String: TronMarketTokenInfo] {
        let key = "tron.coingecko.catalog.v1"
        let cached = await OathDiagnostics.attemptOptional("marketCache", body: { try await database.marketCache(key: key) })
        if let cached, Date().timeIntervalSince1970-cached.fetchedAt < 86_400,
           let value = OathDiagnostics.attempt("decode_cached_catalog", body: { try TronMarkets.decodeCatalog(cached.payload) }) { return value }
        do {
            let raw = try await markets.catalog(); try Task.checkCancellation()
            try await database.saveMarketCache(.init(key: key, source: "CoinGecko", payload: raw, fetchedAt: Date().timeIntervalSince1970))
            return try TronMarkets.decodeCatalog(raw)
        } catch { OathDiagnostics.record(error); return cached.flatMap { saved in OathDiagnostics.attempt("decode_cached_catalog", body: { try TronMarkets.decodeCatalog(saved.payload) }) } ?? [:] }
    }
    private static func save(_ quotes: [TronPrice], database: OathDatabase) async throws {
        for quote in quotes {
            guard let asset = try await database.asset(networkID: "tron", reference: quote.mint),
                  let price = Decimal(string: quote.usd, locale: Locale(identifier: "en_US_POSIX")), price > 0, !price.isNaN else { continue }
            let amount = NSDecimalNumber(decimal: price).stringValue
            guard (try? Validation.price(amount)) != nil else { continue }
            try await database.saveMarketCache(.init(key: "tron.price."+quote.mint, source: quote.source, payload: try JSONEncoder().encode(quote), fetchedAt: quote.fetchedAt.timeIntervalSince1970), price: .init(assetID: asset.id, currency: "USD", value: amount, observedAt: quote.fetchedAt.timeIntervalSince1970, source: quote.source))
        }
    }
    private func startHistory(_ ticket: TronSyncTicket, catalog: [String: TronMarketTokenInfo]) {
        histories[ticket.account.id]?.cancel()
        let database = database, client = client
        histories[ticket.account.id] = Task {
            var restarted: Set<String> = []
            var stopped: Set<String> = []
            do {
                while !Task.isCancelled {
                    let work = try await database.tronHistoryWork(ticket).filter { !stopped.contains($0.stream) }
                    if work.isEmpty { return }
                    let outcomes = try await withThrowingTaskGroup(of: (TronHistoryCursor, String?).self) { group in
                        for cursor in work { group.addTask {
                            do { try await Self.page(cursor, ticket: ticket, catalog: catalog, database: database, client: client); return (cursor,nil) }
                            catch {
                                // Check ownership before reducing an error to a
                                // stored failure code. A newer refresh/reset owns
                                // the database after it invalidates this ticket.
                                try Task.checkCancellation()
                                try await database.requireCurrentTronSync(ticket)
                                if OathDiagnostics.isExpectedCancellation(error) { throw CancellationError() }
                                OathDiagnostics.record(error); return (cursor,Self.code(error))
                            }
                        } }
                        var results: [(TronHistoryCursor,String?)] = []
                        for try await result in group { results.append(result) }; return results
                    }
                    try Task.checkCancellation()
                    try await database.requireCurrentTronSync(ticket)
                    for (cursor,error) in outcomes {
                        guard let error else { continue }
                        let key = cursor.stream + cursor.lane
                        if error == "http(400)", cursor.cursor != nil, restarted.insert(key).inserted {
                            _ = try await database.restartTronCursor(cursor, ticket: ticket)
                        } else {
                            stopped.insert(cursor.stream)
                            try await database.failTronSync(ticket, history: true, code: error)
                        }
                    }
                }
            } catch is CancellationError {
                // diagnostics: tron-history-teardown. Replaced/cancelled work
                // cannot mark the new refresh failed or advance old cursors.
            } catch {
                do {
                    try Task.checkCancellation()
                    try await database.requireCurrentTronSync(ticket)
                    OathDiagnostics.record(error)
                    try await database.failTronSync(ticket, history: true, code: Self.code(error))
                } catch is CancellationError {
                    // diagnostics: tron-history-failure-teardown. Ownership was
                    // revoked after the failing read; there is nothing to save.
                } catch StoreError.staleSync {
                    // failTronSync validates only ticket ownership; losing it
                    // between the read and writer transaction is normal teardown.
                } catch { OathDiagnostics.record(error, operation: "failTronSync") }
            }
        }
    }
    private static func page(_ cursor: TronHistoryCursor, ticket: TronSyncTicket, catalog: [String: TronMarketTokenInfo], database: OathDatabase, client: TronClient) async throws {
        guard let stream = TronStream(rawValue: cursor.stream) else { throw TronError.malformed }
        let page = try await client.history(owner: ticket.account.address, stream: stream, start: cursor.start, end: cursor.end, cursor: cursor.cursor, limit: 20, confirmedOnly: cursor.lane == "backfill")
        let transactions = try await withThrowingTaskGroup(of: TronTransaction.self) { group in
            var next = 0
            func enqueue() {
                guard next < page.hashes.count, !Task.isCancelled else { return }
                let hash = page.hashes[next]; next += 1
                group.addTask {
                    if let saved = try await database.tronTransaction(accountID: ticket.account.id, hash: hash), saved.confirmed { return saved }
                    return try await client.transaction(hash)
                }
            }
            for _ in 0..<4 { enqueue() }
            var values: [TronTransaction] = []
            for try await value in group { values.append(value); enqueue() }; return values
        }
        let refs = Set(transactions.flatMap(\.events).filter { $0.from == ticket.account.address || $0.to == ticket.account.address }.map(\.reference))
        // Metadata is memoized by the client and obtained from ANKR, including
        // historical tokens whose present balance is zero.
        let tokens = try await withThrowingTaskGroup(of: TronToken.self) { group in
            let references = refs.sorted(); var next = 0
            func enqueue() {
                guard next < references.count, !Task.isCancelled else { return }
                let reference = references[next]; next += 1
                group.addTask { try await client.token(reference) }
            }
            for _ in 0..<4 { enqueue() }
            var result: [String:TronToken] = [:]
            for try await token in group { result[token.reference] = token; enqueue() }
            return result
        }
        try Task.checkCancellation()
        try await database.commitTronPage(page, transactions: transactions, tokens: tokens, catalog: catalog, cursor: cursor, ticket: ticket)
    }
    public func waitForHistory(accountID: String) async { await histories[accountID]?.value }
    private static func code(_ error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        if let error = error as? TronError { return String(describing: error) }
        return "storage"
    }
    public func cancel() async {
        epoch = UUID()
        let tasks = flights.values.map(\.1), history = Array(histories.values)
        flights.removeAll(); histories.removeAll()
        for task in tasks { task.cancel() }; for task in history { task.cancel() }
        for task in tasks { _ = try? await task.value }; for task in history { await task.value }
    }
}
