import OathDiagnostics
import Foundation
import OathAnkr

public actor TonSynchronizer {
    private let database: OathDatabase
    private let client: TonClient
    private let markets: TonMarkets
    private var flights: [String:(UUID,Task<Void,Error>)] = [:]
    private var histories: [String:Task<Void,Never>] = [:]
    private var epoch = UUID()
    public init(database: OathDatabase, apiKey: String) throws {
        self.database = database; client = try TonClient(apiKey:apiKey); markets = TonMarkets()
    }
    public init(database: OathDatabase, client: TonClient, markets: TonMarkets = TonMarkets()) {
        self.database = database; self.client = client; self.markets = markets
    }
    public func refresh(accountID: String) async throws {
        let generation = epoch
        guard let account = try await database.account(accountID), account.networkID == "ton" else { throw StoreError.missingRecord }
        guard epoch == generation, !Task.isCancelled else { throw CancellationError() }
        if let task = flights[accountID] { return try await task.1.value }
        histories[accountID]?.cancel(); histories[accountID] = nil
        let id = UUID()
        let task = Task { [database,client,markets] in
            let ticket = try await database.beginTonSync(accountID:accountID)
            do {
                // Inventory, history and USD quotes run independently. The
                // shared index client respects the anonymous rate allowance.
                async let inventory = client.inventory(owner:account.address)
                async let native = await OathDiagnostics.attempt("native_price") { try await markets.nativePrice() }
                try Task.checkCancellation()
                self.startHistory(ticket)
                let value = try await inventory
                try Task.checkCancellation()
                try await database.commitTonInventory(value,ticket:ticket)
                try Task.checkCancellation()
                var quotes = value.prices
                if let native = await native { quotes.append(native) }
                else { quotes += (await OathDiagnostics.attempt("prices", body: { try await client.prices(references:["native"]) })) ?? [] }
                try await Self.save(quotes,database:database)
                let priced = Set(quotes.map(\.reference))
                let tracked = try await database.trackedAssets(walletID:account.walletID).filter{$0.networkID == "ton"}.map(\.reference)
                let missing = value.holdings.filter { $0.token.reference != "native" && $0.amount != "0" && ($0.token.verified || tracked.contains($0.token.reference)) && !priced.contains($0.token.reference) }.map{$0.token.reference}
                // Thirty contracts per quote request, at most two in flight.
                await withTaskGroup(of:Void.self) { group in
                    var next = 0
                    func enqueue() {
                        guard next < missing.count, !Task.isCancelled else { return }
                        let chunk = Array(missing[next..<min(next+30,missing.count)]); next += chunk.count
                        group.addTask {
                            do { let prices = try await markets.prices(references:chunk); try Task.checkCancellation(); try await Self.save(prices,database:database) }
                            catch { OathDiagnostics.record(error); /* Cached USD quotes survive outages and absent markets. */ }
                        }
                    }
                    enqueue(); enqueue(); for await _ in group { enqueue() }
                }
                if !value.discoveryComplete || !value.failedReferences.isEmpty { throw TonError.incomplete }
            } catch { OathDiagnostics.record(error); await OathDiagnostics.attempt("failTonSync", body: { try await database.failTonSync(ticket,history:false,code:Self.code(error)) }); throw error }
        }
        flights[accountID] = (id,task)
        do { try await task.value; if flights[accountID]?.0 == id { flights[accountID] = nil } }
        catch { OathDiagnostics.record(error); if flights[accountID]?.0 == id { flights[accountID] = nil }; throw error }
    }
    private static func save(_ quotes: [TonPrice], database: OathDatabase) async throws {
        for quote in quotes {
            guard let asset = try await database.asset(networkID:"ton",reference:quote.reference),
                  (try? Validation.price(quote.usd)) != nil else { continue }
            try await database.saveMarketCache(.init(key:"ton.price."+quote.reference,source:quote.source,payload:try JSONEncoder().encode(quote),fetchedAt:quote.fetchedAt.timeIntervalSince1970),price:.init(assetID:asset.id,currency:"USD",value:quote.usd,observedAt:quote.fetchedAt.timeIntervalSince1970,source:quote.source))
        }
    }
    private func startHistory(_ ticket: TonSyncTicket) {
        histories[ticket.account.id]?.cancel()
        let database = database, client = client
        histories[ticket.account.id] = Task {
            var stopped: Set<String> = []
            do {
                while !Task.isCancelled {
                    let work = try await database.tonHistoryWork(ticket).filter{!stopped.contains($0.stream)}
                    if work.isEmpty { return }
                    let results = await withTaskGroup(of:(String,String?).self) { group in
                        for cursor in work { group.addTask {
                            do {
                                guard let stream = TonStream(rawValue:cursor.stream) else { throw TonError.malformed }
                                let page = try await client.history(owner:ticket.account.address,stream:stream,before:cursor.beforeLT,limit:stream == .native ? 100 : 1000)
                                try Task.checkCancellation()
                                try await database.commitTonPage(page,cursor:cursor,ticket:ticket)
                                return (cursor.stream,nil)
                            } catch { OathDiagnostics.record(error); return (cursor.stream,Self.code(error)) }
                        } }
                        var values: [(String,String?)] = []; for await value in group { values.append(value) }; return values
                    }
                    for (stream,error) in results { if let error { stopped.insert(stream); try await database.failTonSync(ticket,history:true,code:error) } }
                }
            } catch { OathDiagnostics.record(error); await OathDiagnostics.attempt("failTonSync", body: { try await database.failTonSync(ticket,history:true,code:Self.code(error)) }) }
        }
    }
    public func waitForHistory(accountID: String) async { await histories[accountID]?.value }
    private static func code(_ error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        if let e = error as? TonError { return String(describing:e) }; return "storage"
    }
    public func cancel() async {
        epoch = UUID()
        let tasks = flights.values.map(\.1), history = Array(histories.values)
        flights.removeAll(); histories.removeAll()
        for task in tasks { task.cancel() }; for task in history { task.cancel() }
        for task in tasks { _ = try? await task.value }; for task in history { await task.value }
    }
}
