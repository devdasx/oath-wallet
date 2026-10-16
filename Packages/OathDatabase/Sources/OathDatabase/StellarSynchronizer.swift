import OathDiagnostics
import Foundation
import OathAnkr

public actor StellarSynchronizer {
    private let database:OathDatabase
    private let client:StellarClient
    private let markets:StellarMarkets
    private var flights:[String:(UUID,Task<Void,Error>)] = [:]
    private var histories:[String:Task<Void,Never>] = [:]
    private var epoch = UUID()
    public init(database:OathDatabase, apiKey:String) throws {
        self.database = database; client = try StellarClient(apiKey:apiKey); markets = StellarMarkets()
    }
    public init(database:OathDatabase, client:StellarClient, markets:StellarMarkets = StellarMarkets()) {
        self.database = database; self.client = client; self.markets = markets
    }
    private func catalog() async -> StellarCatalog {
        let saved = await OathDiagnostics.attemptOptional("marketCache", body: { try await database.marketCache(key:"stellar.catalog") })
        let cached = saved.flatMap{try? JSONDecoder().decode(StellarCatalog.self,from:$0.payload)}
        if let saved, let cached, Date().timeIntervalSince1970-saved.fetchedAt < 86_400 { return cached }
        do {
            let value = try await markets.catalog(fallback:cached ?? .empty); try Task.checkCancellation()
            if let updated=await markets.catalogUpdatedAt {
                try await database.saveMarketCache(.init(key:"stellar.catalog",source:"CoinGecko",payload:try JSONEncoder().encode(value),fetchedAt:updated.timeIntervalSince1970))
            }
            return value
        } catch { OathDiagnostics.record(error); return cached ?? .empty }
    }
    public func refresh(accountID:String) async throws {
        try await OathDiagnostics.$chain.withValue("stellar") {
            try await OathDiagnostics.$operationID.withValue(UUID()) { try await refreshAccount(accountID:accountID) }
        }
    }
    private func refreshAccount(accountID:String) async throws {
        let generation = epoch
        guard let account = try await database.account(accountID), account.networkID == "stellar" else { throw StoreError.missingRecord }
        guard epoch == generation, !Task.isCancelled else { throw CancellationError() }
        if let flight = flights[accountID] { return try await flight.1.value }
        histories[accountID]?.cancel(); histories[accountID] = nil
        let id = UUID()
        let task = Task { [database,client,markets] in
            let latest = try await client.latestLedger()
            let ticket = try await database.beginStellarSync(accountID:accountID,latestLedger:latest)
            try Task.checkCancellation()
            guard self.epoch == generation else { throw CancellationError() }
            self.startHistory(ticket)
            do {
                async let inventory = client.inventory(owner:account.address)
                async let native = await OathDiagnostics.attempt("native_price") { try await markets.nativePrice { try await client.price(reference:"native") } }
                let savedCatalog = await self.catalog()
                let value = try await inventory; try Task.checkCancellation()
                let catalog = savedCatalog.includingVerified(value)
                try await database.commitStellarInventory(value,ticket:ticket,catalog:catalog)
                try await Self.save(value.prices,database:database)
                let quote = await native
                if let quote { try Task.checkCancellation(); try await Self.save([quote],database:database) }
                let tracked = Set(try await database.trackedAssets(walletID:account.walletID).filter{$0.networkID == "stellar"}.map(\.reference))
                let refs = value.holdings.filter{$0.amount != "0" && (catalog.contains($0.reference) || value.verified.contains($0.reference) || tracked.contains($0.reference)) && ($0.reference != "native" || quote == nil)}.map(\.reference).sorted()
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
                                    await withTaskGroup(of:StellarPrice?.self) { quotes in
                                        for ref in missing[offset..<min(offset+2,missing.count)] {
                                            quotes.addTask {
                                                if let price = await OathDiagnostics.attemptOptional("price", body: { try await client.price(reference:ref) }) { return price }
                                                guard let holding = value.holdings.first(where:{$0.reference == ref}), let quote else { return nil }
                                                return await OathDiagnostics.attemptOptional("tradePrice", body: { try await markets.tradePrice(token:holding.token,native:quote) })
                                            }
                                        }
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
            } catch { OathDiagnostics.record(error); await OathDiagnostics.attempt("failStellarSync", body: { try await database.failStellarSync(ticket,history:false,code:Self.code(error)) }); throw error }
        }
        flights[accountID] = (id,task)
        do { try await task.value; if flights[accountID]?.0 == id { flights[accountID] = nil } }
        catch { OathDiagnostics.record(error); if flights[accountID]?.0 == id { flights[accountID] = nil }; throw error }
    }
    static func save(_ prices:[StellarPrice], database:OathDatabase) async throws {
        for quote in prices {
            try Task.checkCancellation()
            guard let asset = try await database.asset(networkID:"stellar",reference:quote.reference), (try? Validation.price(quote.usd)) != nil else { continue }
            do {
                try await database.saveMarketCache(.init(key:"stellar.price."+quote.reference,source:quote.source,payload:try JSONEncoder().encode(quote),fetchedAt:quote.fetchedAt.timeIntervalSince1970),price:.init(assetID:asset.id,currency:"USD",value:quote.usd,observedAt:quote.fetchedAt.timeIntervalSince1970,source:quote.source))
            } catch StoreError.staleSync {
                // Another wallet/provider already saved a newer public quote.
                // Retain it without treating a successful balance read as failed.
                continue
            }
        }
    }
    private func startHistory(_ ticket:StellarSyncTicket) {
        histories[ticket.account.id]?.cancel()
        let database = database, client = client
        histories[ticket.account.id] = Task {
            await withTaskGroup(of:Void.self) { group in
                for lane in ["recent","backfill"] {
                    group.addTask {
                        do {
                            var visited:Set<String> = []
                            while !Task.isCancelled {
                                guard let cursor = try await database.stellarHistoryWork(ticket).first(where:{$0.lane == lane}) else { return }
                                let key = cursor.cursor ?? "first"
                                guard visited.insert(key).inserted else { throw StellarError.paginationLoop }
                                let page = try await client.events(owner:ticket.account.address,startLedger:cursor.startLedger,endLedger:cursor.endLedger,cursor:cursor.cursor)
                                let missing = Set(page.events.filter{$0.token == nil}.map(\.reference))
                                for reference in missing {
                                    try Task.checkCancellation()
                                    if try await database.marketCache(key:"stellar.token."+reference) == nil,
                                       let metadata = await OathDiagnostics.attempt("metadata", body: { try await client.metadata(reference:reference,owner:ticket.account.address) }) {
                                        try await database.saveStellarMetadata([metadata],ticket:ticket)
                                    }
                                }
                                try Task.checkCancellation()
                                try await database.commitStellarPage(page,cursor:cursor,ticket:ticket)
                            }
                        } catch { OathDiagnostics.record(error); await OathDiagnostics.attempt("failStellarSync", body: { try await database.failStellarSync(ticket,history:true,code:Self.code(error)) }) }
                    }
                }
                await group.waitForAll()
            }
        }
    }
    public func waitForHistory(accountID:String) async { await histories[accountID]?.value }
    private static func code(_ error:Error) -> String {
        if error is CancellationError { return "cancelled" }; if let e = error as? StellarError { return String(describing:e) }; return "storage"
    }
    public func cancel() async {
        epoch = UUID(); let tasks = flights.values.map(\.1), history = Array(histories.values)
        flights.removeAll(); histories.removeAll()
        for task in tasks { task.cancel() }; for task in history { task.cancel() }
        for task in tasks { _ = try? await task.value }; for task in history { await task.value }
    }
}
