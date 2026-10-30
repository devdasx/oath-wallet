import OathDiagnostics
import Foundation
import OathAnkr

public actor SuiSynchronizer {
    private let database:OathDatabase
    private let client:SuiClient
    private let markets:SuiMarkets
    private var flights:[String:(UUID,Task<Void,Error>)] = [:]
    private var histories:[String:Task<Void,Never>] = [:]
    private var epoch = UUID()
    public init(database:OathDatabase, apiKey:String) throws {
        self.database = database; client = try SuiClient(apiKey:apiKey); markets = SuiMarkets()
    }
    public init(database:OathDatabase, client:SuiClient, markets:SuiMarkets = SuiMarkets()) {
        self.database = database; self.client = client; self.markets = markets
    }
    private func catalog() async -> SuiCatalog {
        let saved = await OathDiagnostics.attemptOptional("marketCache", body: { try await database.marketCache(key:"sui.catalog") })
        let cached = saved.flatMap{try? JSONDecoder().decode(SuiCatalog.self,from:$0.payload)}
        if let saved, let cached, Date().timeIntervalSince1970-saved.fetchedAt < 86_400 { return cached }
        do {
            let value = try await markets.catalog(); try Task.checkCancellation()
            try await database.saveMarketCache(.init(key:"sui.catalog",source:"CoinGecko",payload:try JSONEncoder().encode(value),fetchedAt:Date().timeIntervalSince1970))
            return value
        } catch { OathDiagnostics.record(error); return cached ?? .empty }
    }
    public func refresh(accountID:String) async throws {
        let generation = epoch
        guard let account = try await database.account(accountID), account.networkID == "sui" else { throw StoreError.missingRecord }
        guard epoch == generation, !Task.isCancelled else { throw CancellationError() }
        if let flight = flights[accountID] { return try await flight.1.value }
        histories[accountID]?.cancel(); histories[accountID] = nil
        let id = UUID()
        let task = Task { [database,client,markets] in
            let ticket = try await database.beginSuiSync(accountID:accountID)
            self.startHistory(ticket)
            do {
                async let inventory: SuiInventory = {
                    let saved = try await database.suiInventoryCheckpoint(ticket)
                    let head = try await client.checkpoint()
                    // Replicas can advertise a head behind the already saved
                    // inventory. Keep the snapshot monotonic and let the client
                    // recover this exact checkpoint through its existing fallback.
                    return try await client.inventory(owner:account.address, atCheckpoint:max(saved,head))
                }()
                async let native = await OathDiagnostics.attempt("native_price") { try await markets.nativePrice() }
                let catalog = await self.catalog()
                let value = try await inventory; try Task.checkCancellation()
                try await database.commitSuiInventory(value,ticket:ticket,catalog:catalog)
                let quote = await native
                if let quote { try Task.checkCancellation(); try await Self.save([quote],database:database) }
                let refs = value.holdings.filter{$0.amount != "0" && ($0.reference != "native" || quote == nil)}.map(\.reference).sorted()
                // Up to two independent 30-token quote batches; pagination
                // itself stays sequential because the next cursor is required.
                await withTaskGroup(of:Void.self) { group in
                    var next = 0
                    func enqueue() {
                        guard next < refs.count, !Task.isCancelled else { return }
                        let chunk = Array(refs[next..<min(next+30,refs.count)]); next += chunk.count
                        group.addTask {
                            do {
                                var prices = (await OathDiagnostics.attempt("prices", body: { try await markets.prices(references:chunk,catalog:catalog) })) ?? []
                                try Task.checkCancellation()
                                let missing = chunk.filter{ref in !prices.contains{$0.reference == ref}}
                                if !missing.isEmpty { prices += (await OathDiagnostics.attempt("dexPrices", body: { try await markets.dexPrices(references:missing) })) ?? [] }
                                try Task.checkCancellation(); try await Self.save(prices,database:database)
                            } catch { OathDiagnostics.record(error);}
                        }
                    }
                    enqueue(); enqueue(); for await _ in group { enqueue() }
                }
                try Task.checkCancellation()
            } catch { OathDiagnostics.record(error); await OathDiagnostics.attempt("failSuiSync", body: { try await database.failSuiSync(ticket,history:false,code:Self.code(error)) }); throw error }
        }
        flights[accountID] = (id,task)
        do { try await task.value; if flights[accountID]?.0 == id { flights[accountID] = nil } }
        catch { OathDiagnostics.record(error); if flights[accountID]?.0 == id { flights[accountID] = nil }; throw error }
    }
    private static func save(_ prices:[SuiPrice], database:OathDatabase) async throws {
        for quote in prices {
            try Task.checkCancellation()
            guard let asset = try await database.asset(networkID:"sui",reference:quote.reference), (try? Validation.price(quote.usd)) != nil else { continue }
            try await database.saveMarketCache(.init(key:"sui.price."+quote.reference,source:quote.source,payload:try JSONEncoder().encode(quote),fetchedAt:quote.fetchedAt.timeIntervalSince1970),price:.init(assetID:asset.id,currency:"USD",value:quote.usd,observedAt:quote.fetchedAt.timeIntervalSince1970,source:quote.source))
        }
    }
    private func startHistory(_ ticket:SuiSyncTicket) {
        histories[ticket.account.id]?.cancel()
        let database = database, client = client
        histories[ticket.account.id] = Task {
            do {
                var visited:Set<String> = [], restarted = false
                while !Task.isCancelled {
                    guard let cursor = try await database.suiHistoryWork(ticket).first else { return }
                    let key = cursor.lane+":"+(cursor.beforeCursor ?? "first:\(cursor.upperCheckpoint ?? 0)")
                    guard visited.insert(key).inserted else { throw SuiError.paginationLoop }
                    do {
                        let page = try await client.history(owner:ticket.account.address,before:cursor.beforeCursor,beforeCheckpoint:cursor.upperCheckpoint)
                        try Task.checkCancellation()
                        try await database.commitSuiPage(page,cursor:cursor,ticket:ticket)
                    } catch SuiError.cursorExpired {
                        guard !restarted, cursor.beforeCursor != nil else { throw SuiError.cursorExpired }
                        restarted = true; try await database.restartSuiHistory(cursor,ticket:ticket)
                    }
                }
            } catch { OathDiagnostics.record(error); await OathDiagnostics.attempt("failSuiSync", body: { try await database.failSuiSync(ticket,history:true,code:Self.code(error)) }) }
        }
    }
    public func waitForHistory(accountID:String) async { await histories[accountID]?.value }
    private static func code(_ error:Error) -> String {
        if error is CancellationError { return "cancelled" }; if let e = error as? SuiError { return String(describing:e) }; return "storage"
    }
    public func cancel() async {
        epoch = UUID(); let tasks = flights.values.map(\.1), history = Array(histories.values)
        flights.removeAll(); histories.removeAll()
        for task in tasks { task.cancel() }; for task in history { task.cancel() }
        for task in tasks { _ = try? await task.value }; for task in history { await task.value }
    }
}
