import OathDiagnostics
import Foundation
import OathAnkr

public actor AptosSynchronizer {
    private let database:OathDatabase
    private let client:AptosClient
    private let markets:AptosMarkets
    private var flights:[String:(UUID,Task<Void,Error>)]=[:]
    private var histories:[String:Task<Void,Never>]=[:]
    private var epoch=UUID()
    public init(database:OathDatabase,apiKey:String,indexerKey:String?=nil) throws {
        self.database=database;client=try AptosClient(apiKey:apiKey,indexerKey:indexerKey);markets=AptosMarkets()
    }
    public init(database:OathDatabase,client:AptosClient,markets:AptosMarkets=AptosMarkets()) {
        self.database=database;self.client=client;self.markets=markets
    }
    private func catalog() async -> AptosCatalog {
        let saved=await OathDiagnostics.attemptOptional("marketCache", body: { try await database.marketCache(key:"aptos.catalog") })
        let cached=saved.flatMap{try? JSONDecoder().decode(AptosCatalog.self,from:$0.payload)}
        if let saved,let cached,Date().timeIntervalSince1970-saved.fetchedAt<86_400 {return cached}
        do {
            let value=try await markets.catalog();try Task.checkCancellation()
            try await database.saveMarketCache(.init(key:"aptos.catalog",source:"Powered by Panora",payload:try JSONEncoder().encode(value),fetchedAt:Date().timeIntervalSince1970))
            return value
        } catch { OathDiagnostics.record(error);return cached ?? .empty}
    }
    public func refresh(accountID:String) async throws {
        try await OathDiagnostics.$chain.withValue("aptos") {
            try await OathDiagnostics.$operationID.withValue(UUID()) { try await refreshAccount(accountID:accountID) }
        }
    }
    private func refreshAccount(accountID:String) async throws {
        let generation=epoch
        guard let account=try await database.account(accountID),account.networkID=="aptos" else {throw StoreError.missingRecord}
        guard epoch==generation,!Task.isCancelled else {throw CancellationError()}
        if let flight=flights[accountID] {return try await flight.1.value}
        histories[accountID]?.cancel();histories[accountID]=nil
        let id=UUID()
        let task=Task { [database,client,markets] in
            let ticket=try await database.beginAptosSync(accountID:accountID)
            do {
                async let inventory=client.inventory(owner:account.address)
                async let native = await OathDiagnostics.attempt("native_price") { try await markets.nativePrice() }
                let catalog=await self.catalog()
                try Task.checkCancellation()
                let value=try await inventory;try Task.checkCancellation()
                try await database.commitAptosInventory(value,ticket:ticket,catalog:catalog)
                // Inventory and history share the indexer's compute quota.
                // Persist balances before history can consume that quota.
                self.startHistory(ticket,catalog:catalog)
                let quote=await native
                if let quote {try await Self.save([quote],database:database)}
                let refs=Array(Set(value.holdings.filter{$0.amount != "0" && ($0.token.reference != "native" || quote==nil)}.map{catalog.canonical($0.token.reference)})).sorted()
                // At most two quote batches in flight, thirty exact identities
                // each. A missing quote is unknown, never an invented zero.
                await withTaskGroup(of:Void.self) {group in
                    var next=0
                    func enqueue() {guard next<refs.count,!Task.isCancelled else{return};let chunk=Array(refs[next..<min(next+30,refs.count)]);next+=chunk.count
                        group.addTask {
                            do {
                                var prices=(await OathDiagnostics.attempt("prices", body: { try await markets.prices(references:chunk) })) ?? []
                                try Task.checkCancellation()
                                let missing=chunk.filter { ref in !prices.contains{$0.reference==ref} }
                                if !missing.isEmpty {prices += (await OathDiagnostics.attempt("dexPrices", body: { try await markets.dexPrices(references:missing) })) ?? []}
                                try Task.checkCancellation();try await Self.save(prices,database:database)
                            } catch { OathDiagnostics.record(error);}
                        }
                    }
                    enqueue();enqueue();for await _ in group {enqueue()}
                }
                if !value.discoveryComplete || !value.failedReferences.isEmpty {throw AptosError.incomplete}
            } catch { OathDiagnostics.record(error);await OathDiagnostics.attempt("failAptosSync", body: { try await database.failAptosSync(ticket,history:false,code:Self.code(error)) });throw error}
        }
        flights[accountID]=(id,task)
        do {try await task.value;if flights[accountID]?.0==id {flights[accountID]=nil}}
        catch { OathDiagnostics.record(error);if flights[accountID]?.0==id {flights[accountID]=nil};throw error}
    }
    private static func save(_ quotes:[AptosPrice],database:OathDatabase) async throws {
        for quote in quotes {
            let alias=try await database.marketCache(key:"aptos.alias."+quote.reference)
            let reference=alias.flatMap{String(data:$0.payload,encoding:.utf8)} ?? quote.reference
            guard let asset=try await database.asset(networkID:"aptos",reference:reference),(try? Validation.price(quote.usd)) != nil else {continue}
            try await database.saveMarketCache(.init(key:"aptos.price."+reference,source:quote.source,payload:try JSONEncoder().encode(quote),fetchedAt:quote.fetchedAt.timeIntervalSince1970),price:.init(assetID:asset.id,currency:"USD",value:quote.usd,observedAt:quote.fetchedAt.timeIntervalSince1970,source:quote.source))
        }
    }
    private func startHistory(_ ticket:AptosSyncTicket,catalog:AptosCatalog) {
        histories[ticket.account.id]?.cancel()
        let database=database,client=client
        histories[ticket.account.id]=Task {
            do {
                while !Task.isCancelled {
                    guard let cursor=try await database.aptosHistoryWork(ticket).first else{return}
                    let page=try await client.history(owner:ticket.account.address,before:cursor.beforeVersion,limit:5)
                    try Task.checkCancellation()
                    try await database.commitAptosPage(page,cursor:cursor,ticket:ticket,catalog:catalog)
                }
            } catch { OathDiagnostics.record(error);await OathDiagnostics.attempt("failAptosSync", body: { try await database.failAptosSync(ticket,history:true,code:Self.code(error)) })}
        }
    }
    public func waitForHistory(accountID:String) async {await histories[accountID]?.value}
    private static func code(_ error:Error) -> String {
        if error is CancellationError {return "cancelled"};if let e=error as? AptosError {return String(describing:e)};return "storage"
    }
    public func cancel() async {
        epoch=UUID();let tasks=flights.values.map(\.1),history=Array(histories.values)
        flights.removeAll();histories.removeAll()
        for task in tasks {task.cancel()};for task in history {task.cancel()}
        for task in tasks {_ = try? await task.value};for task in history {await task.value}
    }
}
