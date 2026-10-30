import OathDiagnostics
import Foundation
import OathAnkr

/// Independent balance, market and historical work. Inventory publication never
/// waits for the archive to walk a wallet's lifetime of transactions.
public actor SolanaSynchronizer {
    private let database: OathDatabase
    private let client: SolanaClient
    private let markets: SolanaMarkets
    private var flights: [String: (id: UUID, owner: String, task: Task<Void, Error>)] = [:]
    private var history: [String: Task<Void, Never>] = [:]
    private var epoch = UUID()
    public init(database: OathDatabase, apiKey: String) throws {
        self.database = database; client = try SolanaClient(apiKey: apiKey); markets = SolanaMarkets()
    }
    public init(database: OathDatabase, client: SolanaClient, markets: SolanaMarkets = SolanaMarkets()) {
        self.database = database; self.client = client; self.markets = markets
    }
    public func refresh(accountID: String) async throws {
        let generation = epoch
        let account = try await database.account(accountID)
        guard let account, account.networkID == "solana" else { throw StoreError.missingRecord }
        let owner = try await database.solanaReceiveState(accountID: accountID)?.selected.address ?? account.address
        guard generation == epoch, !Task.isCancelled else { throw CancellationError() }
        if let flight = flights[accountID] {
            if flight.owner == owner { return try await flight.task.value }
            flight.task.cancel()
        }
        history[accountID]?.cancel(); history[accountID] = nil
        let id = UUID()
        let work = Task { [database,client,markets] in
            let ticket = try await database.beginSolanaSync(accountID: accountID)
            do {
                async let inventory = client.inventory(owner: ticket.owner)
                async let directory = Self.catalog(database: database, markets: markets)
                async let nativePrice = await OathDiagnostics.attempt("native_price") { try await markets.nativePrice() }
                let (values, catalog) = try await (inventory, directory)
                try Task.checkCancellation()
                try await database.commitSolanaInventory(values, ticket: ticket, catalog: catalog)
                // Launch resumable history only after the public addresses are registered.
                self.startHistory(ticket, catalog: catalog)
                if let price = await nativePrice { try await Self.save([price], database: database) }
                let tracked = try await database.trackedAssets(walletID: account.walletID)
                let explicit = Set(tracked.filter { $0.networkID == "solana" }.map(\.reference))
                let mints = Set(values.accounts.filter { $0.amount != "0" && (catalog[$0.mint] != nil || explicit.contains($0.mint)) }.map(\.mint)).sorted()
                // Two requests at a time, thirty mints per request. A failed
                // market chunk retains its previous quotes and other chunks finish.
                await withTaskGroup(of: Void.self) { group in
                    var start = 0
                    func enqueue() {
                        guard start < mints.count, !Task.isCancelled else { return }
                        let chunk = Array(mints[start..<min(start + 30,mints.count)]); start += chunk.count
                        group.addTask {
                            do { let prices = try await markets.prices(mints: chunk); try Task.checkCancellation(); try await Self.save(prices, database: database) }
                            catch { OathDiagnostics.record(error); /* A missing market is unknown, never an invented zero. */ }
                        }
                    }
                    enqueue(); enqueue()
                    for await _ in group { enqueue() }
                }
            } catch { OathDiagnostics.record(error);
                await OathDiagnostics.attempt("failSolanaSync", body: { try await database.failSolanaSync(ticket, history: false, code: Self.failureCode(error)) })
                throw error
            }
        }
        flights[accountID] = (id, owner, work)
        do { try await work.value; if flights[accountID]?.id == id { flights[accountID] = nil } }
        catch { OathDiagnostics.record(error); if flights[accountID]?.id == id { flights[accountID] = nil }; throw error }
    }
    private static func catalog(database: OathDatabase, markets: SolanaMarkets) async throws -> [String: SolanaTokenInfo] {
        let key = "solana.coingecko.catalog.v1"
        let saved = try await database.marketCache(key: key)
        if let saved, Date().timeIntervalSince1970 - saved.fetchedAt < 86_400,
           let value = try? SolanaMarkets.decodeCatalog(saved.payload) { return value }
        do {
            let data = try await markets.catalog()
            try Task.checkCancellation()
            try await database.saveMarketCache(.init(key: key, source: "CoinGecko", payload: data, fetchedAt: Date().timeIntervalSince1970))
            return try SolanaMarkets.decodeCatalog(data)
        } catch { OathDiagnostics.record(error);
            try Task.checkCancellation()
            // Existing verification survives temporary directory outages.
            if let saved { return (try? SolanaMarkets.decodeCatalog(saved.payload)) ?? [:] }
            return [:]
        }
    }
    private static func save(_ prices: [SolanaPrice], database: OathDatabase) async throws {
        for price in prices {
            guard let asset = try await database.asset(networkID: "solana", reference: price.mint),
                  let decimal = Decimal(string: price.usd, locale: Locale(identifier: "en_US_POSIX")),
                  !decimal.isNaN, decimal > 0 else { continue }
            let valueString = NSDecimalNumber(decimal: decimal).stringValue
            guard (try? Validation.price(valueString)) != nil else { continue }
            // The public mint's record was committed with the inventory first.
            let value = PriceRecord(assetID: asset.id, currency: "USD", value: valueString,
                                    observedAt: price.fetchedAt.timeIntervalSince1970, source: price.source)
            try await database.saveMarketCache(.init(key: "solana.price." + price.mint, source: price.source,
                payload: try JSONEncoder().encode(price), fetchedAt: price.fetchedAt.timeIntervalSince1970), price: value)
        }
    }
    private func startHistory(_ ticket: SolanaSyncTicket, catalog: [String: SolanaTokenInfo]) {
        history[ticket.account.id]?.cancel()
        let database = database, client = client
        history[ticket.account.id] = Task {
            let started = Date().timeIntervalSince1970
            do {
                while !Task.isCancelled {
                    let work = try await database.solanaHistoryWork(ticket, since: started, limit: 3)
                    if work.isEmpty { return }
                    // Bounded parallelism avoids thousands of tasks on wallets
                    // with spam accounts, while all durable cursors get a turn.
                    let failure = await withTaskGroup(of: String?.self) { group in
                        for cursor in work { group.addTask {
                            do { try await Self.historyPage(cursor, ticket: ticket, started: started, catalog: catalog,
                                                            database: database, client: client); return nil }
                            catch { OathDiagnostics.record(error); return Self.failureCode(error) }
                        } }
                        var failure: String?
                        for await result in group { if failure == nil { failure = result } }
                        return failure
                    }
                    if let failure {
                        try await database.failSolanaSync(ticket, history: true, code: failure)
                        return
                    }
                }
            } catch { OathDiagnostics.record(error); await OathDiagnostics.attempt("failSolanaSync", body: { try await database.failSolanaSync(ticket, history: true, code: Self.failureCode(error)) }) }
        }
    }
    private static func failureCode(_ error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        if let code = error as? SolanaError { return String(describing: code) }
        return "storage"
    }
    private static func historyPage(_ cursor: SolanaHistoryCursor, ticket: SolanaSyncTicket, started: Double,
        catalog: [String: SolanaTokenInfo], database: OathDatabase, client: SolanaClient) async throws {
        let backfill = cursor.head != nil && cursor.lastChecked >= started && cursor.pendingBefore == nil
        // Commit small visible pages promptly, instead of waiting for hundreds
        // of archival transactions before showing the first history entry.
        let pageSize = 20
        let page = try await client.signatures(address: cursor.address,
            before: backfill ? cursor.before : cursor.pendingBefore, until: backfill ? nil : cursor.head, limit: pageSize)
        try Task.checkCancellation()
        var values = try await database.cachedSolanaTransactions(ticket, signatures: page.signatures.map(\.signature))
        let known = Set(values.map(\.signature))
        let missing = page.signatures.map(\.signature).filter { !known.contains($0) }
        let fetched = try await withThrowingTaskGroup(of: [SolanaTransaction].self) { group in
            for start in stride(from: 0, to: missing.count, by: 20) {
                let chunk = Array(missing[start..<min(start+20,missing.count)])
                group.addTask { try await client.transactions(signatures: chunk, owner: ticket.owner) }
            }
            var result: [SolanaTransaction] = []
            for try await batch in group { result += batch }
            return result
        }
        values += fetched
        try Task.checkCancellation()
        try await database.commitSolanaHistory(values, page: page, cursor: cursor, ticket: ticket, backfill: backfill,
                                              pageSize: pageSize, catalog: catalog)
    }
    public func cancel() async {
        epoch = UUID()
        let tasks = flights.values.map(\.task), histories = Array(history.values)
        flights.removeAll(); history.removeAll()
        for task in tasks { task.cancel() }
        for task in histories { task.cancel() }
        for task in tasks { _ = try? await task.value }
        for task in histories { await task.value }
    }
}
