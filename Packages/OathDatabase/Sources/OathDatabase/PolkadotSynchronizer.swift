import Foundation
import OathAnkr
import OathDiagnostics

protocol PolkadotSyncProviding: Sendable {
    func inventory(owner: String) async throws -> PolkadotInventory
    func prices(for tokens: [PolkadotToken]) async throws -> [PolkadotPrice]
    func history(owner: String, stream: String, page: Int, finalizedHeight: Int64) async throws -> PolkadotHistoryPage
    func relayFinalizedHeight() async throws -> Int64
}

extension PolkadotClient: PolkadotSyncProviding {}

public actor PolkadotSynchronizer {
    private let database: OathDatabase
    private let client: any PolkadotSyncProviding
    private var flights: [String: (id: UUID, task: Task<Void, Error>)] = [:]
    private var background: [String: Task<Void, Never>] = [:]
    public init(database: OathDatabase, client: PolkadotClient) { self.database = database; self.client = client }
    init(database: OathDatabase, provider: any PolkadotSyncProviding) { self.database = database; self.client = provider }
    public func refresh(accountID: String) async throws {
        if let flight = flights[accountID] { return try await flight.task.value }
        // Invalidate the old work before beginPolkadotSync replaces its ticket.
        // Waiting for a new inventory response first lets old history/price
        // requests finish against the newly invalidated database generation.
        background[accountID]?.cancel()
        let id = UUID()
        let task = Task {
            try await OathDiagnostics.$chain.withValue("polkadot") {
                try await OathDiagnostics.$operationID.withValue(UUID()) {
                    do {
                        let ticket = try await database.beginPolkadotSync(accountID: accountID)
                        let inventory = try await client.inventory(owner: ticket.account.address)
                        try Task.checkCancellation()
                        try await database.commitPolkadotInventory(inventory, ticket: ticket)
                        try Task.checkCancellation()
                        startBackground(ticket, inventory: inventory)
                    } catch { OathDiagnostics.record(error, component: "polkadot", operation: "refresh"); throw error }
                }
            }
        }
        flights[accountID] = (id, task)
        defer { if flights[accountID]?.id == id { flights[accountID] = nil } }
        try await task.value
    }
    private func startBackground(_ ticket: PolkadotSyncTicket, inventory: PolkadotInventory) {
        background[ticket.account.id]?.cancel()
        let database = database, client = client
        background[ticket.account.id] = Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await Self.attemptBackground("polkadot_prices") {
                        let prices = try await client.prices(for: inventory.holdings.map(\.token))
                        try Task.checkCancellation(); try await database.commitPolkadotPrices(prices, ticket: ticket)
                    }
                }
                for stream in ["native", "assets", "foreign", "extrinsics", "relay-native", "relay-extrinsics"] {
                    group.addTask {
                        await Self.attemptBackground("polkadot_history_" + stream) {
                            let latestHeight = try await (stream.hasPrefix("relay-") ? client.relayFinalizedHeight() : inventory.height)
                            // Recent pages are re-read to catch new incoming transfers.
                            // Backfill has a durable cursor and a bounded work budget.
                            for page in 0..<1 {
                                try Task.checkCancellation()
                                let result = try await client.history(owner: ticket.account.address, stream: stream, page: page, finalizedHeight: latestHeight)
                                try Task.checkCancellation()
                                try await database.commitPolkadotHistory(result, ticket: ticket, stream: stream, currentPage: page, advance: false)
                                if result.next == nil { break }
                            }
                            for _ in 0..<5 {
                                let cursor = try await database.polkadotHistoryCursor(ticket, stream: stream, latestHeight: latestHeight)
                                let page = cursor.page
                                guard page >= 0 else { break }
                                try Task.checkCancellation()
                                let result = try await client.history(owner: ticket.account.address, stream: stream, page: page, finalizedHeight: cursor.upperHeight)
                                try Task.checkCancellation()
                                try await database.commitPolkadotHistory(result, ticket: ticket, stream: stream, currentPage: page, advance: true)
                                if result.next == nil { break }
                            }
                        }
                    }
                }
            }
        }
    }
    private nonisolated static func attemptBackground(_ operation: String, body: @Sendable () async throws -> Void) async {
        await OathDiagnostics.attempt(operation) {
            try await runBackgroundOperation(body)
        }
    }
    nonisolated static func runBackgroundOperation(_ body: @Sendable () async throws -> Void) async throws {
        do {
            try Task.checkCancellation()
            try await body()
        } catch StoreError.staleSync where Task.isCancelled {
            // Cancellation can arrive between the caller's check and an awaited
            // database operation. A superseded worker is expected teardown;
            // staleSync from active work must still reach shared diagnostics.
            throw CancellationError()
        }
    }
    public func waitForBackground(accountID: String) async { await background[accountID]?.value }
    public func cancel() async {
        let work = flights.values.map(\.task), tasks = Array(background.values)
        flights.removeAll(); background.removeAll()
        work.forEach { $0.cancel() }; tasks.forEach { $0.cancel() }
        for task in work { _ = try? await task.value }; for task in tasks { await task.value }
    }
}
