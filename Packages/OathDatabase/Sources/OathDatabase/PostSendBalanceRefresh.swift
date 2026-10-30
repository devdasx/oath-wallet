import Foundation
import GRDB
import OathBitcoin
import OathDiagnostics

/// Local routing identity only. Never include it in diagnostics or requests.
public struct SendBalanceRefreshTarget: Hashable, Sendable {
    public let walletID: String
    public let networkID: String
    public init(walletID: String, networkID: String) {
        self.walletID = walletID; self.networkID = networkID
    }
}

extension OathDatabase {
    func observeSendBalanceRefreshSignal() -> AsyncThrowingStream<Int64, Error> {
        stream { try Int64.fetchOne($0, sql: "SELECT revision FROM sendBalanceRefreshSignal WHERE id=1") ?? 0 }
    }
    func sendBalanceRefreshRevisions(_ target: SendBalanceRefreshTarget) async throws -> [String: Int64] {
        try await pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT r.sendID,r.revision FROM sendBalanceRefreshes r JOIN sends s ON s.id=r.sendID JOIN wallets w ON w.id=s.walletID
                WHERE r.completedAt IS NULL AND s.walletID=? AND s.networkID=?
                  AND (s.state IN ('broadcast','confirmed') OR ((s.networkID IN ('sui','xrpl','stellar','tron','near','polkadot','aptos','solana','arc','ton','thorchain') OR EXISTS(SELECT 1 FROM evmSendPlans e WHERE e.sendID=s.id)) AND s.state='failed' AND COALESCE(s.failureCode,'')<>'expired')) AND w.deletedAt IS NULL AND NOT EXISTS(SELECT 1 FROM metadata WHERE key='walletReset')
                ORDER BY s.createdAt,s.id LIMIT 100
                """, arguments: [target.walletID, target.networkID])
            return Dictionary(uniqueKeysWithValues: rows.map { ($0["sendID"] as String, $0["revision"] as Int64) })
        }
    }

    public func pendingSendBalanceRefreshTargets(after: SendBalanceRefreshTarget? = nil, limit: Int = 64) async throws -> [SendBalanceRefreshTarget] {
        try await pool.read { db in
            var sql = """
                SELECT s.walletID,s.networkID FROM sendBalanceRefreshes r JOIN sends s ON s.id=r.sendID
                JOIN wallets w ON w.id=s.walletID
                WHERE r.completedAt IS NULL AND (s.state IN ('broadcast','confirmed') OR ((s.networkID IN ('sui','xrpl','stellar','tron','near','polkadot','aptos','solana','arc','ton','thorchain') OR EXISTS(SELECT 1 FROM evmSendPlans e WHERE e.sendID=s.id)) AND s.state='failed' AND COALESCE(s.failureCode,'')<>'expired')) AND w.deletedAt IS NULL AND NOT EXISTS(SELECT 1 FROM metadata WHERE key='walletReset')
                """
            var args: StatementArguments = []
            if let after { sql += " AND (s.walletID,s.networkID)>(?,?)"; args += [after.walletID, after.networkID] }
            sql += " GROUP BY s.walletID,s.networkID ORDER BY s.walletID,s.networkID LIMIT ?"
            args += [max(1, min(64, limit))]
            return try Row.fetchAll(db, sql: sql, arguments: args)
                .map { .init(walletID: $0["walletID"], networkID: $0["networkID"]) }
        }
    }

    public func pendingSendBalanceRefreshes(_ target: SendBalanceRefreshTarget) async throws -> [SendRecord] {
        try await pool.read { db in
            try SendRecord.fetchAll(db, sql: """
                SELECT s.* FROM sendBalanceRefreshes r JOIN sends s ON s.id=r.sendID JOIN wallets w ON w.id=s.walletID
                WHERE r.completedAt IS NULL AND s.walletID=? AND s.networkID=?
                  AND (s.state IN ('broadcast','confirmed') OR ((s.networkID IN ('sui','xrpl','stellar','tron','near','polkadot','aptos','solana','arc','ton','thorchain') OR EXISTS(SELECT 1 FROM evmSendPlans e WHERE e.sendID=s.id)) AND s.state='failed' AND COALESCE(s.failureCode,'')<>'expired')) AND w.deletedAt IS NULL AND NOT EXISTS(SELECT 1 FROM metadata WHERE key='walletReset')
                ORDER BY s.createdAt,s.id LIMIT 100
                """, arguments: [target.walletID, target.networkID])
        }
    }

    func completeSendBalanceRefreshes(_ ids: Set<String>, target: SendBalanceRefreshTarget, revisions: [String: Int64]) async throws {
        try await pool.write { db in
            for id in ids {
                guard let revision = revisions[id] else { continue }
                try db.execute(sql: """
                    UPDATE sendBalanceRefreshes SET completedAt=? WHERE sendID=? AND completedAt IS NULL AND revision=?
                    AND EXISTS(SELECT 1 FROM sends s WHERE s.id=sendID AND s.walletID=? AND s.networkID=?)
                    """, arguments: [Date.now.timeIntervalSince1970, id, revision, target.walletID, target.networkID])
            }
        }
    }

    /// A successful HTTP/RPC response may still describe the pre-send mempool.
    /// Require the sending accounts to observe this exact transaction AND its
    /// consumed inputs before ending retries. Self-transfers need no balance delta.
    public func bitcoinSendBalanceIsCurrent(_ send: SendRecord) async throws -> Bool {
        try await pool.read { db in
            guard let network = UTXONetwork(rawValue: send.networkID),
                  let bytes = try Data.fetchOne(db, sql: "SELECT plan FROM bitcoinSendPlans WHERE sendID=?", arguments: [send.id]),
                  let txID = send.transactionID,
                  let tx = try TransactionRecord.fetchOne(db, key: txID) else { return false }
            let plan = try JSONDecoder().decode(BitcoinSendPlan.self, from: bytes)
            guard plan.chain == network, tx.networkID == send.networkID else { throw StoreError.conflictingIdentity }
            for accountID in Set(plan.coins.map(\.accountID)).union([send.accountID]) {
                guard try Bool.fetchOne(db, sql: """
                    SELECT EXISTS(SELECT 1 FROM bitcoinHistory h JOIN accounts a ON a.id=h.accountID
                    JOIN bitcoinWallets b ON b.accountID=a.id WHERE h.accountID=? AND h.txid=?
                    AND a.walletID=? AND a.networkID=? AND b.failure IS NULL AND b.scanID IS NULL)
                    """, arguments: [accountID, tx.hash, send.walletID, send.networkID]) == true else { return false }
            }
            for coin in plan.coins {
                guard try Bool.fetchOne(db, sql: "SELECT spent FROM utxos WHERE networkID=? AND transactionHash=? AND outputIndex=?",
                    arguments: [send.networkID, coin.txid, coin.vout]) == true else { return false }
            }
            return true
        }
    }
}

/// Chain-independent, durable send follow-up. Adapters refresh only this target
/// and return IDs whose committed balances reflect their submitted transaction.
/// The worker never signs, broadcasts, changes send status or releases inputs.
public actor PostSendBalanceRefresher {
    public typealias Refresh = @Sendable (SendBalanceRefreshTarget, [SendRecord]) async throws -> Set<String>
    private let database: OathDatabase
    private let refresh: Refresh
    private let delays: [Duration]
    private let sleep: @Sendable (Duration) async throws -> Void
    private var enabled = false
    private var observer: Task<Void, Never>?
    private var retryTimer: Task<Void, Never>?
    private var epoch = UUID()
    private var rescan = false
    private var flights: [SendBalanceRefreshTarget: (UUID, Task<Void, Never>)] = [:]
    private var queued: [SendBalanceRefreshTarget] = []
    private var rerun: Set<SendBalanceRefreshTarget> = []
    private var cursor: SendBalanceRefreshTarget?
    private var reachedEnd = false
    private var loading: UUID?

    public init(database: OathDatabase, refresh: @escaping Refresh) {
        self.database = database; self.refresh = refresh
        delays = [.zero, .seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16)]
        sleep = { try await Task.sleep(for: $0) }
    }
    init(database: OathDatabase, delays: [Duration], sleep: @escaping @Sendable (Duration) async throws -> Void,
         refresh: @escaping Refresh) {
        self.database = database; self.delays = Array(delays.prefix(10)); self.sleep = sleep; self.refresh = refresh
    }

    /// Observe journal changes independently of the presenting screen. The
    /// slow retry also covers offline/indexer delays beyond the initial burst.
    public func resume() async {
        if !enabled {
            enabled = true
            let ticket = UUID(); epoch = ticket
            observer = Task {
                while enabled, epoch == ticket, !Task.isCancelled {
                    do {
                        for try await _ in database.observeSendBalanceRefreshSignal() {
                            guard enabled, epoch == ticket, !Task.isCancelled else { return }
                            await reschedule()
                        }
                        return
                    } catch {
                        if Task.isCancelled || error is CancellationError { return }
                        OathDiagnostics.record(error, component: "send", operation: "balance_refresh_observe")
                        do { try await Task.sleep(for: .seconds(15)) } catch { return } // Lifecycle cancellation.
                    }
                }
            }
            retryTimer = Task {
                while enabled, epoch == ticket, !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(60)) } catch { return } // Lifecycle cancellation.
                    guard enabled, epoch == ticket, !Task.isCancelled else { return }
                    await reschedule()
                }
            }
        } else {
            await reschedule()
        }
        // The observation's initial value performs the first scan. Starting a
        // second scan here would duplicate the initial retry burst.
    }
    private func reschedule() async {
        cursor = nil; reachedEnd = false
        // A new confirmation must not be lost behind an older in-flight read.
        for target in flights.keys { rerun.insert(target) }
        if loading != nil { rescan = true; return }
        await fillQueue()
    }
    public func request(_ target: SendBalanceRefreshTarget) {
        guard enabled else { return } // Durable intent remains while locked.
        if flights[target] != nil { rerun.insert(target); return }
        enqueue(target); pump()
    }
    public func pause() {
        enabled = false; epoch = UUID(); observer?.cancel(); observer = nil; retryTimer?.cancel(); retryTimer = nil
        rescan = false; queued.removeAll(); rerun.removeAll(); loading = nil
        let tasks = flights.values.map(\.1)
        flights.removeAll()
        for task in tasks { task.cancel() }
    }
    private func enqueue(_ target: SendBalanceRefreshTarget) {
        guard !queued.contains(target), flights[target] == nil, queued.count < 64 else { return }
        queued.append(target)
    }
    private func fillQueue() async {
        guard enabled, !reachedEnd, loading == nil, queued.count < 64 else { return }
        let ticket = UUID(); loading = ticket
        defer {
            if loading == ticket {
                loading = nil
                if rescan, enabled {
                    rescan = false
                    Task { await self.reschedule() }
                }
            }
        }
        do {
            let targets = try await database.pendingSendBalanceRefreshTargets(after: cursor, limit: 64 - queued.count)
            guard enabled, loading == ticket else { return }
            if let last = targets.last { cursor = last } else { reachedEnd = true }
            for target in targets { enqueue(target) }
            pump()
        } catch { OathDiagnostics.record(error, component: "send", operation: "balance_refresh_resume") }
    }
    private func pump() {
        while enabled, flights.count < 4, !queued.isEmpty {
            let target = queued.removeFirst(), id = UUID()
            let task = Task {
                await OathDiagnostics.$chain.withValue(target.networkID) {
                    await OathDiagnostics.$operationID.withValue(id) { await self.run(target) }
                }
                await self.finished(target, id: id)
            }
            flights[target] = (id, task)
        }
    }
    private func run(_ target: SendBalanceRefreshTarget) async {
        for (attempt, delay) in delays.enumerated() {
            do {
                try Task.checkCancellation()
                if delay > .zero { try await sleep(delay) }
                try Task.checkCancellation()
                let revisions = try await database.sendBalanceRefreshRevisions(target)
                let sends = try await database.pendingSendBalanceRefreshes(target)
                if sends.isEmpty { return }
                let observed = try await refresh(target, sends)
                try Task.checkCancellation()
                // A buggy adapter cannot acknowledge another wallet's work.
                let validIDs = observed.intersection(Set(sends.map(\.id)))
                try await database.completeSendBalanceRefreshes(validIDs, target: target, revisions: revisions)
                if try await database.pendingSendBalanceRefreshes(target).isEmpty { return }
                // Indexer propagation is expected. Keep the job pending and
                // retry even if the RPC succeeded with stale pre-send data.
            } catch {
                if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { return }
                OathDiagnostics.record(error, component: "send", operation: "balance_refresh",
                    context: ["chain": target.networkID, "stage": "balance", "attempt": String(attempt + 1)])
            }
        }
    }
    private func finished(_ target: SendBalanceRefreshTarget, id: UUID) async {
        guard flights[target]?.0 == id else { return }
        flights[target] = nil
        if enabled, rerun.remove(target) != nil { enqueue(target) }
        pump()
        // Completed targets make room for more durable targets without keeping
        // an unbounded queue or immediately restarting an exhausted burst.
        if enabled { await fillQueue() }
    }
}
