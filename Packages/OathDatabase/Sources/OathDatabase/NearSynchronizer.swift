import OathDiagnostics
import Foundation
import OathAnkr

public actor NearSynchronizer {
    private let database:OathDatabase
    private let client:NearClient
    private let markets:NearMarkets
    private var flights:[String:(UUID,Task<Void,Error>)] = [:]
    private var histories:[String:Task<Void,Never>] = [:]
    private var epoch = UUID()
    public init(database:OathDatabase, apiKey:String) throws {
        self.database = database; client = try NearClient(apiKey:apiKey); markets = NearMarkets()
    }
    public init(database:OathDatabase, client:NearClient, markets:NearMarkets = NearMarkets()) {
        self.database = database; self.client = client; self.markets = markets
    }
    private func catalog() async -> NearCatalog {
        let saved = await OathDiagnostics.attemptOptional("marketCache", body: { try await database.marketCache(key:"near.catalog") })
        let cached = saved.flatMap{try? JSONDecoder().decode(NearCatalog.self,from:$0.payload)}
        if let saved, let cached, Date().timeIntervalSince1970-saved.fetchedAt < 86_400 { return cached }
        do {
            let value = try await markets.catalog(); try Task.checkCancellation()
            try await database.saveMarketCache(.init(key:"near.catalog",source:"CoinGecko",payload:try JSONEncoder().encode(value),fetchedAt:Date().timeIntervalSince1970))
            return value
        } catch { OathDiagnostics.record(error); return cached ?? .empty }
    }
    public func refresh(accountID:String) async throws {
        let generation = epoch
        guard let account = try await database.account(accountID), account.networkID == "near" else { throw StoreError.missingRecord }
        guard epoch == generation, !Task.isCancelled else { throw CancellationError() }
        if let flight = flights[accountID] { return try await flight.1.value }
        histories[accountID]?.cancel(); histories[accountID] = nil
        let id = UUID()
        let task = Task { [database,client,markets] in
            try await OathDiagnostics.withChain("near") {
                let ticket = try await database.beginNearSync(accountID:accountID)
                self.startHistory(ticket)
                do {
                    let known = try await database.nearKnownReferences(accountID:accountID)
                    async let inventory = client.inventory(owner:account.address,knownReferences:known)
                    async let native = await OathDiagnostics.attempt("native_price") { try await markets.nativePrice() }
                    let catalog = await self.catalog()
                    let value = try await inventory; try Task.checkCancellation()
                    try await database.commitNearInventory(value,ticket:ticket,catalog:catalog)
                    let quote = await native
                    if let quote { try Task.checkCancellation(); try await Self.save([quote],database:database) }
                    let refs = value.holdings.filter{$0.amount != nil && $0.amount != "0" && ($0.reference != "native" || quote == nil)}.map(\.reference).sorted()
                    // Up to two independent 30-token quote batches; pagination
                    // itself stays sequential because the next cursor is required.
                    let covered = await withTaskGroup(of:[String].self) { group in
                        var next = 0
                        func enqueue() {
                            guard next < refs.count, !Task.isCancelled else { return }
                            let chunk = Array(refs[next..<min(next+30,refs.count)]); next += chunk.count
                            group.addTask {
                                let prices = (await OathDiagnostics.attempt("prices", body: { try await markets.prices(references:chunk,catalog:catalog) })) ?? []
                                do {
                                    try Task.checkCancellation()
                                    try await Self.save(prices,database:database)
                                } catch { OathDiagnostics.record(error);}
                                // A storage failure does not make a valid provider
                                // quote missing or justify substituting another price.
                                return prices.map(\.reference)
                            }
                        }
                        var covered:Set<String> = []
                        enqueue(); enqueue(); for await refs in group { covered.formUnion(refs); enqueue() }
                        return covered
                    }
                    try Task.checkCancellation()
                    // The bulk ecosystem source is a fallback, not a prerequisite
                    // for already available quotes. Native-only/zero wallets and
                    // complete primary coverage must not wait for an unused API.
                    let missing = Set(refs).subtracting(covered)
                    let tokens = value.holdings.filter{missing.contains($0.reference)}.compactMap(\.token)
                    if !tokens.isEmpty {
                        let ecosystem:[NearPrice]
                        do { ecosystem = try await markets.ecosystemPrices(tokens:tokens) }
                        catch {
                            OathDiagnostics.record(error, operation:"ecosystemPrices", context:["stage":"missing_prices", "count":String(tokens.count)])
                            ecosystem = []
                        }
                        try Task.checkCancellation()
                        await OathDiagnostics.attempt("save_ecosystem_prices", body: { try await Self.save(ecosystem,database:database) })
                    }
                    try Task.checkCancellation()
                } catch { OathDiagnostics.record(error); await OathDiagnostics.attempt("failNearSync", body: { try await database.failNearSync(ticket,history:false,code:Self.code(error)) }); throw error }
            }
        }
        flights[accountID] = (id,task)
        do { try await task.value; if flights[accountID]?.0 == id { flights[accountID] = nil } }
        catch { OathDiagnostics.record(error); if flights[accountID]?.0 == id { flights[accountID] = nil }; throw error }
    }
    private static func save(_ prices:[NearPrice], database:OathDatabase) async throws {
        for quote in prices {
            try Task.checkCancellation()
            guard let asset = try await database.asset(networkID:"near",reference:quote.reference), (try? Validation.price(quote.usd)) != nil else { continue }
            try await database.saveMarketCache(.init(key:"near.price."+quote.reference,source:quote.source,payload:try JSONEncoder().encode(quote),fetchedAt:quote.fetchedAt.timeIntervalSince1970),price:.init(assetID:asset.id,currency:"USD",value:quote.usd,observedAt:quote.fetchedAt.timeIntervalSince1970,source:quote.source))
        }
    }
    private func startHistory(_ ticket:NearSyncTicket) {
        histories[ticket.account.id]?.cancel()
        let database = database, client = client
        histories[ticket.account.id] = Task {
            await withTaskGroup(of:Void.self) { group in
                for stream in ["transfers","transactions"] {
                    group.addTask {
                        do {
                            var visited:Set<String> = []
                            while !Task.isCancelled {
                                guard let cursor = try await database.nearHistoryWork(ticket,stream:stream) else { return }
                                let key = cursor.lane+":"+(cursor.beforeCursor ?? "first")
                                guard visited.insert(key).inserted else { throw NearError.paginationLoop }
                                let page = try await client.history(owner:ticket.account.address,stream:stream,before:cursor.beforeCursor)
                                try Task.checkCancellation()
                                try await database.commitNearPage(page,cursor:cursor,ticket:ticket)
                            }
                        } catch { OathDiagnostics.record(error); await OathDiagnostics.attempt("failNearSync", body: { try await database.failNearSync(ticket,history:true,code:Self.code(error)) }) }
                    }
                }
            }
        }
    }
    public func waitForHistory(accountID:String) async { await histories[accountID]?.value }
    private static func code(_ error:Error) -> String {
        if error is CancellationError { return "cancelled" }; if let e = error as? NearError { return String(describing:e) }; return "storage"
    }
    public func cancel() async {
        epoch = UUID(); let tasks = flights.values.map(\.1), history = Array(histories.values)
        flights.removeAll(); histories.removeAll()
        for task in tasks { task.cancel() }; for task in history { task.cancel() }
        for task in tasks { _ = try? await task.value }; for task in history { await task.value }
    }
}
