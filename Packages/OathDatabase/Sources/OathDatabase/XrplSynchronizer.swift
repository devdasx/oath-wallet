import OathDiagnostics
import Foundation
import OathAnkr

public actor XrplSynchronizer {
    private let database:OathDatabase
    private let client:XrplClient
    private let markets:XrplMarkets
    private var flights:[String:(UUID,Task<Void,Error>)] = [:]
    private var histories:[String:Task<Void,Never>] = [:]
    private var epoch = UUID()
    public init(database:OathDatabase, apiKey:String) throws {
        self.database = database; client = try XrplClient(apiKey:apiKey); markets = XrplMarkets()
    }
    public init(database:OathDatabase, client:XrplClient, markets:XrplMarkets = XrplMarkets()) {
        self.database = database; self.client = client; self.markets = markets
    }
    private func catalog() async -> XrplCatalog {
        let saved = await OathDiagnostics.attemptOptional("marketCache", body: { try await database.marketCache(key:"xrpl.catalog") })
        let cached = saved.flatMap{try? JSONDecoder().decode(XrplCatalog.self,from:$0.payload)}
        if let saved, let cached, Date().timeIntervalSince1970-saved.fetchedAt < 86_400 { return cached }
        do {
            let value = try await markets.catalog(); try Task.checkCancellation()
            try await database.saveMarketCache(.init(key:"xrpl.catalog",source:"CoinGecko",payload:try JSONEncoder().encode(value),fetchedAt:Date().timeIntervalSince1970))
            return value
        } catch { OathDiagnostics.record(error); return cached ?? .empty }
    }
    public func refresh(accountID:String) async throws {
        let generation = epoch
        guard let account = try await database.account(accountID), account.networkID == "xrpl" else { throw StoreError.missingRecord }
        guard epoch == generation, !Task.isCancelled else { throw CancellationError() }
        if let flight = flights[accountID] { return try await flight.1.value }
        histories[accountID]?.cancel(); histories[accountID] = nil
        let id = UUID()
        let task = Task { [database,client,markets] in
            let ticket = try await database.beginXrplSync(accountID:accountID)
            try Task.checkCancellation()
            guard self.epoch == generation else { throw CancellationError() }
            self.startHistory(ticket)
            do {
                async let inventory = client.inventory(owner:account.address)
                async let native = await OathDiagnostics.attempt("native_price") { try await markets.nativePrice() }
                let catalog = await self.catalog()
                let value = try await inventory; try Task.checkCancellation()
                try await database.commitXrplInventory(value,ticket:ticket,catalog:catalog)
                let quote = await native
                if let quote { try Task.checkCancellation(); try await Self.save([quote],database:database) }
                let refs = value.holdings.filter{$0.amount != "0" && !$0.amount.hasPrefix("-") && ($0.reference != "native" || quote == nil)}.map(\.reference).sorted()
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
                                // Two batches each issue at most two concurrent DEX reads.
                                for offset in stride(from:0,to:missing.count,by:2) {
                                    await withTaskGroup(of:XrplPrice?.self) { quotes in
                                        for ref in missing[offset..<min(offset+2,missing.count)] { quotes.addTask { await OathDiagnostics.attemptOptional("dexPrice", body: { try await markets.dexPrice(reference:ref) }) } }
                                        for await price in quotes { if let price { prices.append(price) } }
                                    }
                                }
                                try Task.checkCancellation(); try await Self.save(prices,database:database)
                            } catch { OathDiagnostics.record(error);}
                        }
                    }
                    enqueue(); enqueue(); for await _ in group { enqueue() }
                }
                try Task.checkCancellation()
            } catch { OathDiagnostics.record(error); await OathDiagnostics.attempt("failXrplSync", body: { try await database.failXrplSync(ticket,history:false,code:Self.code(error)) }); throw error }
        }
        flights[accountID] = (id,task)
        do { try await task.value; if flights[accountID]?.0 == id { flights[accountID] = nil } }
        catch { OathDiagnostics.record(error); if flights[accountID]?.0 == id { flights[accountID] = nil }; throw error }
    }
    private static func save(_ prices:[XrplPrice], database:OathDatabase) async throws {
        for quote in prices {
            try Task.checkCancellation()
            guard let asset = try await database.asset(networkID:"xrpl",reference:quote.reference), (try? Validation.price(quote.usd)) != nil else { continue }
            try await database.saveMarketCache(.init(key:"xrpl.price."+quote.reference,source:quote.source,payload:try JSONEncoder().encode(quote),fetchedAt:quote.fetchedAt.timeIntervalSince1970),price:.init(assetID:asset.id,currency:"USD",value:quote.usd,observedAt:quote.fetchedAt.timeIntervalSince1970,source:quote.source))
        }
    }
    private func startHistory(_ ticket:XrplSyncTicket) {
        histories[ticket.account.id]?.cancel()
        let database = database, client = client
        histories[ticket.account.id] = Task {
            do {
                var visited:Set<String> = [], restarted = false
                while !Task.isCancelled {
                    guard let cursor = try await database.xrplHistoryWork(ticket).first else { return }
                    let key = cursor.lane+":"+(cursor.beforeCursor ?? "first:\(cursor.upperLedger ?? 0)")
                    guard visited.insert(key).inserted else { throw XrplError.paginationLoop }
                    do {
                        let page = try await client.history(owner:ticket.account.address,before:cursor.beforeCursor,upperLedger:cursor.upperLedger)
                        try Task.checkCancellation()
                        try await database.commitXrplPage(page,cursor:cursor,ticket:ticket)
                    } catch XrplError.rpc("invalidMarker") {
                        guard !restarted, cursor.beforeCursor != nil else { throw XrplError.rpc("invalidMarker") }
                        restarted = true; try await database.restartXrplHistory(cursor,ticket:ticket)
                    }
                }
            } catch { OathDiagnostics.record(error); await OathDiagnostics.attempt("failXrplSync", body: { try await database.failXrplSync(ticket,history:true,code:Self.code(error)) }) }
        }
    }
    public func waitForHistory(accountID:String) async { await histories[accountID]?.value }
    private static func code(_ error:Error) -> String {
        if error is CancellationError { return "cancelled" }; if let e = error as? XrplError { return String(describing:e) }; return "storage"
    }
    public func cancel() async {
        epoch = UUID(); let tasks = flights.values.map(\.1), history = Array(histories.values)
        flights.removeAll(); histories.removeAll()
        for task in tasks { task.cancel() }; for task in history { task.cancel() }
        for task in tasks { _ = try? await task.value }; for task in history { await task.value }
    }
}
