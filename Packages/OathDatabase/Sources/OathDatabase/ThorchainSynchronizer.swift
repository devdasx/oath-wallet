import Foundation
import OathAnkr
import OathDiagnostics

public actor ThorchainSynchronizer {
    private let database:OathDatabase
    private let client:ThorchainClient
    private var flights:[String:(UUID,Task<Void,Error>)] = [:]
    private var histories:[String:Task<Void,Never>] = [:]
    private var epoch=UUID()
    public init(database:OathDatabase, client:ThorchainClient = ThorchainClient()) { self.database=database; self.client=client }
    public func refresh(accountID:String) async throws {
        if let flight=flights[accountID] { return try await flight.1.value }
        let id=UUID(), generation=epoch
        let task=Task { [database,client] in
            try await OathDiagnostics.$chain.withValue("thorchain") {
                try await OathDiagnostics.$operationID.withValue(UUID()) {
                    do {
                        let ticket=try await database.beginThorchainSync(accountID:accountID)
                        guard self.epoch == generation else { throw CancellationError() }
                        async let market=client.catalog()
                        let height=try await client.latestHeight(atLeast:ticket.minimumHeight)
                        async let inventory=client.inventory(owner:ticket.account.address,height:height)
                        self.startHistory(ticket, height: height)
                        let cached=await OathDiagnostics.attemptOptional("thorchain_cached_catalog") { try await database.marketCache(key:"thorchain.catalog") }
                        // An undecodable optional cache is a cache miss; live reads continue.
                        let catalog=cached.flatMap { saved in OathDiagnostics.attempt("decode_cached_catalog", body: { try JSONDecoder().decode(ThorchainCatalog.self, from: saved.payload) }) } ?? ThorchainCatalog()
                        let holdings=try await inventory
                        try Task.checkCancellation()
                        try await database.commitThorchainInventory(holdings,ticket:ticket,catalog:catalog)
                        let fresh=try await market
                        try Task.checkCancellation()
                        try await database.commitThorchainCatalog(fresh,ticket:ticket)
                    } catch { OathDiagnostics.record(error,component:"ThorchainSynchronizer",operation:"refresh"); throw error }
                }
            }
        }
        flights[accountID]=(id,task)
        do { try await task.value; if flights[accountID]?.0 == id { flights[accountID]=nil } }
        catch { OathDiagnostics.record(error,component:"ThorchainSynchronizer",operation:"refresh_result"); if flights[accountID]?.0 == id { flights[accountID]=nil }; throw error }
    }
    private func startHistory(_ ticket:ThorchainSyncTicket, height:Int64) {
        histories[ticket.account.id]?.cancel()
        let database=database, client=client
        histories[ticket.account.id]=Task {
            do {
                // Reuse this refresh's validated block for new history windows.
                // A second latest-block read can hit an older replica and abort
                // history despite already having a valid inventory pin. Existing
                // incomplete cursors retain their own pinned height in the store.
                let cached=await OathDiagnostics.attemptOptional("thorchain_history_catalog") { try await database.marketCache(key:"thorchain.catalog") }
                let catalog=cached.flatMap { saved in OathDiagnostics.attempt("decode_cached_catalog", body: { try JSONDecoder().decode(ThorchainCatalog.self, from: saved.payload) }) } ?? ThorchainCatalog()
                // Sender/recipient/failed-message indexes are independent. Each
                // page commits atomically and resumes after relaunch. Historical
                // work is capped per refresh, never an unbounded hot-phone loop.
                try await withThrowingTaskGroup(of:Void.self) { group in
                    for stream in ["transfer.sender","transfer.recipient","message.sender"] {
                        group.addTask {
                            for lane in ["recent","backfill"] {
                                var cursor=try await database.thorchainCursor(ticket:ticket,stream:stream,lane:lane,height:height)
                                for _ in 0..<10 where !cursor.complete {
                                    try Task.checkCancellation()
                                    let page=try await client.history(owner:ticket.account.address,stream:stream,height:cursor.height,lowerHeight:cursor.lowerHeight,page:cursor.page)
                                    try Task.checkCancellation()
                                    try await database.commitThorchainHistory(page,cursor:cursor,ticket:ticket,catalog:catalog)
                                    if page.next == nil { break }
                                    cursor=try await database.thorchainCursor(ticket:ticket,stream:stream,lane:lane,height:height)
                                }
                            }
                        }
                    }
                    try await group.waitForAll()
                }
            } catch {
                // Reset/navigation cancellation can race a generation rejection.
                // This is already-observed task teardown, not a provider failure.
                if !Task.isCancelled { OathDiagnostics.record(error,component:"ThorchainSynchronizer",operation:"history") }
            }
        }
    }
    public func waitForHistory(accountID:String) async { await histories[accountID]?.value }
    public func cancel() async {
        epoch=UUID()
        let tasks=flights.values.map(\.1), history=Array(histories.values)
        flights.removeAll(); histories.removeAll()
        tasks.forEach{$0.cancel()}; history.forEach{$0.cancel()}
        for task in tasks { _ = try? await task.value }; for task in history { await task.value }
    }
}
