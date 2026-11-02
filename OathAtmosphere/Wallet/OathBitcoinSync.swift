import OathDiagnostics
import Foundation
import OathBitcoin
import OathDatabase

/// One flight per account, including foreground and pull-to-refresh callers.
/// Bitcoin, Dogecoin, Litecoin and Bitcoin Cash have independent concurrent pools.
/// Keys stay in the vault; prices stay in their own
/// existing cache. A failed/partial discovery leaves the last ledger intact.
actor OathBitcoinSync {
    static let shared = OathBitcoinSync()
    private let pools = Dictionary(uniqueKeysWithValues: UTXONetwork.allCases.map { ($0, ElectrumPool(network: $0)) })
    private let historyPools = Dictionary(uniqueKeysWithValues: UTXONetwork.allCases.map { ($0, ElectrumPool(network: $0)) })
    private var historyPending: Set<String> = []
    private var flights: [String: (id: UUID, task: Task<Void, Error>)] = [:]
    private var histories: [String: (id: UUID, task: Task<Void, Never>)] = [:]
    private var epoch = UUID()
    private var isCancelling = false

    func refresh(accountID: String, vault: OathWalletVault, includeHistory: Bool = true) async throws {
        let generation = epoch
        try await refreshSpendable(accountID: accountID, vault: vault)
        guard generation == epoch, !Task.isCancelled else { throw CancellationError() }
        guard includeHistory else { return }
        refreshHistory(accountID: accountID, vault: vault)
    }

    /// Background activity hydration has separate sockets and never holds up
    /// balance refresh or send preparation. Repeated scans coalesce to one rerun.
    func refreshHistory(accountID: String, vault: OathWalletVault) {
        guard !isCancelling else { return }
        historyPending.insert(accountID)
        guard histories[accountID] == nil else { return }
        let id = UUID(), generation = epoch
        let task = Task {
            defer {
                if histories[accountID]?.id == id { histories[accountID] = nil }
            }
            while generation == epoch, !Task.isCancelled,
                  historyPending.remove(accountID) != nil {
                await OathDiagnostics.$operationID.withValue(UUID()) {
                    do {
                        let db = try await vault.database()
                        guard let state = try await db.bitcoinState(accountID: accountID),
                              let pool = historyPools[state.descriptor.network] else { throw OathWalletError.unavailable }
                        try await OathDiagnostics.$chain.withValue(state.descriptor.network.rawValue) {
                            try await BitcoinActivitySynchronizer(database: db, client: pool).refresh(accountID: accountID)
                        }
                    } catch StoreError.staleSync {
                        // A newer verified scan owns this account's history.
                    } catch is CancellationError {
                        // Wallet teardown cancels background hydration.
                    } catch { OathDiagnostics.record(error, component: "sync", operation: "utxo_history") }
                }
            }
        }
        histories[accountID] = (id, task)
    }

    /// Quotes need a fresh verified UTXO snapshot and funding transactions,
    /// not the ancestors/block timestamps used only to render old activity.
    func prepareForSend(accountID: String, vault: OathWalletVault, forceRefresh: Bool = false) async throws {
        // A just-completed foreground/review scan already contains verified
        // funding data. Reuse it briefly, never extend its timestamp, and keep
        // queue/sign-time freshness and reservation validation in the ledger.
        try await refreshSpendable(accountID: accountID, vault: vault, reuseRecentSnapshot: !forceRefresh)
        try Task.checkCancellation()
    }

    private func refreshSpendable(accountID: String, vault: OathWalletVault, reuseRecentSnapshot: Bool = false) async throws {
        guard !isCancelling else { throw CancellationError() }
        if let flight = flights[accountID] { return try await flight.task.value }
        let id = UUID()
        let task = Task { [pools] in
            try await OathDiagnostics.$operationID.withValue(OathDiagnostics.operationID ?? id) {
                try Task.checkCancellation()
                try await vault.prepareBitcoin(accountID: accountID)
                let db = try await vault.database()
                if reuseRecentSnapshot, try await db.bitcoinSnapshotIsRecentForSend(accountID: accountID) { return }
                guard let state = try await db.bitcoinState(accountID: accountID) else { throw OathWalletError.unavailable }
                guard let pool = pools[state.descriptor.network] else { throw OathWalletError.unavailable }
                let scanID = try await db.beginBitcoinScan(accountID: accountID)
                do {
                    let snapshot = try await pool.withStableSnapshot { peer in
                        let scan = try await BitcoinDiscovery(query: peer).scan(state.descriptor, requiredThrough: state.requiredThrough)
                        try scan.validate(wallet: state.descriptor, requiredThrough: state.requiredThrough)
                        let txids = Set(scan.addresses.flatMap { $0.state.unspent.map(\.txid) })
                        let missing = try await db.bitcoinMissingTransactions(accountID: accountID, txids: txids)
                        // Parsed funding transactions anchor each output's exact
                        // value and script; only public txids go to the peers.
                        let transactions = try await peer.transactions(txids: missing)
                        return (scan: scan, transactions: transactions)
                    }
                    try Task.checkCancellation()
                    try await db.commitBitcoinScan(accountID: accountID, scanID: scanID, scan: snapshot.value.scan,
                        transactions: snapshot.value.transactions, tipHeight: snapshot.tip.height)
                } catch { OathDiagnostics.record(error, component: "sync", operation: "utxo_spendable", context: ["chain": state.descriptor.network.rawValue]);
                    let code: String
                    if error is CancellationError { code = "cancelled" }
                    else if let error = error as? BitcoinError { code = String(describing: error) }
                    else { code = "storage" }
                    await OathDiagnostics.attempt("failBitcoinScan", body: { try await db.failBitcoinScan(accountID: accountID, scanID: scanID, code: code) })
                    throw error
                }
            }
        }
        flights[accountID] = (id, task)
        defer { if flights[accountID]?.id == id { flights[accountID] = nil } }
        try await task.value
    }

    func cancel() async {
        guard !isCancelling else { return }
        isCancelling = true
        defer { isCancelling = false }
        epoch = UUID()
        historyPending.removeAll()
        let tasks = flights.values.map(\.task)
        let historyTasks = histories.values.map(\.task)
        for task in tasks { task.cancel() }
        for task in historyTasks { task.cancel() }
        for pool in pools.values { await pool.close() }
        for pool in historyPools.values { await pool.close() }
        for task in tasks { _ = await task.result }
        for task in historyTasks { await task.value }
    }
}
