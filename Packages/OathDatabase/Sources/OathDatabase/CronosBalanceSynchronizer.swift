import Foundation
import OathAnkr
import OathDiagnostics

/// Uses the shared generation-checked balance ledger and existing send journal.
/// A failed token read preserves its last observation rather than writing zero.
public actor CronosBalanceSynchronizer {
    private let database: OathDatabase
    private let client: EVMSendClient
    private var flights: [String: (UUID, Task<Void, Error>)] = [:]

    public init(database: OathDatabase, client: EVMSendClient) throws {
        guard client.network == .cronos else { throw EVMSendError.wrongNetwork }
        self.database = database; self.client = client
    }

    public func refresh(walletID: String) async throws {
        if let flight = flights[walletID] { return try await flight.1.value }
        let id = UUID(), task = Task {
            try await OathDiagnostics.$chain.withValue("cronos") {
                try await OathDiagnostics.$operationID.withValue(UUID()) {
                    do {
                        let accounts = try await database.accounts(walletID: walletID).filter { $0.networkID == "cronos" }
                        guard !accounts.isEmpty else { return }
                        let native = try await database.asset(networkID: "cronos", reference: "native")
                        guard let native else { throw StoreError.missingRecord }
                        let tracked = try await database.trackedAssets(walletID: walletID).filter { $0.networkID == "cronos" && $0.reference != "native" }
                        let assets = [native] + tracked
                        let tokens = Dictionary(tracked.map { ($0.reference, $0.decimals) }, uniquingKeysWith: { first, _ in first })
                        for account in accounts {
                            try Task.checkCancellation()
                            let previous = try await database.checkpoint(accountID: account.id, stream: "cronos_balances")
                            let snapshot = try await client.cronosAccountBalances(owner: account.address, tokens: tokens)
                            guard previous.cursor?.blockHeight.map({ $0 <= snapshot.height }) ?? true else { throw StoreError.staleSync }
                            let cursor = SyncCursor(accountID: account.id, stream: "cronos_balances", cursor: UUID().uuidString,
                                blockHeight: snapshot.height, blockHash: snapshot.blockHash, updatedAt: snapshot.observedAt.timeIntervalSince1970)
                            var batch = SyncBatch(cursor: cursor, expectedCursor: previous.cursor?.cursor, expectedGeneration: previous.generation)
                            batch.balances = assets.compactMap { asset in
                                snapshot.amounts[asset.reference].map { amount in
                                    BalanceRecord(accountID: account.id, assetID: asset.id, networkID: "cronos", amountAtomic: amount,
                                        observedAt: snapshot.observedAt.timeIntervalSince1970, blockHeight: snapshot.height, source: "cronos_rpc")
                                }
                            }
                            try Task.checkCancellation()
                            try await database.apply(batch)
                        }
                    } catch {
                        OathDiagnostics.record(error, component: "wallet", operation: "cronos_balance_refresh")
                        throw error
                    }
                }
            }
        }
        flights[walletID] = (id, task)
        defer { if flights[walletID]?.0 == id { flights[walletID] = nil } }
        // The shared flight owns reporting; followers preserve the same error.
        return try await task.value
    }

    public func cancel() async {
        let tasks = flights.values.map(\.1); flights.removeAll()
        for task in tasks { task.cancel() }
        for task in tasks { _ = try? await task.value }
    }
}
