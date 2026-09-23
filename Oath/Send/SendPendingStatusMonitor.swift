import Foundation
import Observation
import GRDB

/// App-root lifetime, independent of selected wallet, sheets and history limits.
/// Database changes discover new work; each identity keeps its own retry clock.
@MainActor @Observable
final class SendPendingStatusMonitor {
    typealias Reader = @Sendable (SendPendingStatusTarget) async throws -> SendTransactionNetworkStatus
    typealias BalanceReader = @Sendable (WalletDatabase, SendPendingStatusTarget) async -> WalletChainSyncOutcome
    private let reader: Reader?
    private let refreshesBalances: Bool
    private let balanceReader: BalanceReader?
    @ObservationIgnored private var onUpdate: (@MainActor @Sendable () async -> Void)?
    @ObservationIgnored private var workers: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var activeRunID: UUID?
    private(set) var failureCodes: [String: String] = [:]
    private(set) var observationFailure: String?

    init(refreshesBalances: Bool = true, balanceReader: BalanceReader? = nil, reader: Reader? = nil) {
        self.reader = reader
        self.refreshesBalances = refreshesBalances
        self.balanceReader = balanceReader
    }

    func run(database: WalletDatabase, onUpdate: (@MainActor @Sendable () async -> Void)? = nil) async {
        let runID = UUID()
        activeRunID = runID
        workers.values.forEach { $0.cancel() }
        workers.removeAll()
        self.onUpdate = onUpdate
        let balances = Task { if refreshesBalances { await refreshBalances(database: database) } }
        defer {
            balances.cancel()
            if activeRunID == runID {
                workers.values.forEach { $0.cancel() }
                workers.removeAll()
                activeRunID = nil
            }
        }
        while !Task.isCancelled {
            do {
                for try await targets in database.pendingStatusTargets() {
                    try Task.checkCancellation()
                    observationFailure = nil
                    reconcile(targets, database: database)
                }
                return
            } catch is CancellationError { return }
            catch {
                observationFailure = SendTransactionStatusService.diagnosticCode(error)
                do { try await Task.sleep(for: .seconds(4)) } catch { return }
            }
        }
    }

    private func reconcile(_ targets: [SendPendingStatusTarget], database: WalletDatabase) {
        let ids = Set(targets.map(\.id))
        for id in Array(workers.keys) where !ids.contains(id) {
            workers.removeValue(forKey: id)?.cancel()
            failureCodes[id] = nil
        }
        for target in targets where workers[target.id] == nil {
            workers[target.id] = Task { [self] in await monitor(target, database: database) }
        }
    }

    private func monitor(_ target: SendPendingStatusTarget, database: WalletDatabase) async {
        var failures = 0
        var terminal: SendTransactionNetworkStatus?
        while !Task.isCancelled {
            do {
                let status: SendTransactionNetworkStatus
                if let terminal { status = terminal }
                else if !target.isTONHistory, let stored = try await database.persistedTerminalSendStatus(target.receipt) { status = stored }
                else if let reader { status = try await reader(target) }
                else { status = try await PendingTransactionReconciler(database: database).status(for: target) }
                try Task.checkCancellation()
                let changed = try await database.recordPendingObservation(status, target: target)
                if changed { await onUpdate?() }
                if status.isTerminal {
                    terminal = status
                    // Keep retrying persistence after a successful network read.
                    // Never strand the details screen because one write failed.
                    if target.isTONHistory {
                        try await database.persistPendingTONHistoryStatus(target, status: status)
                    } else {
                        _ = try await database.updateSubmittedSendStatus(receipt: target.receipt, status: status)
                    }
                    failureCodes[target.id] = nil
                    await onUpdate?()
                    return
                }
                failures = 0
                failureCodes[target.id] = nil
            } catch is CancellationError { return }
            catch {
                guard !Task.isCancelled else { return }
                failures += 1
                failureCodes[target.id] = SendTransactionStatusService.diagnosticCode(error)
            }
            do {
                try await Task.sleep(for: SendTransactionStatusPollingPolicy.interval(
                    networkID: target.receipt.networkID, failures: failures))
            } catch { return }
        }
    }

    /// Separate from status workers: committing a terminal status removes its
    /// worker, but must not cancel the balance read that removes a phantom credit.
    private func refreshBalances(database: WalletDatabase) async {
        var lastRead: [String: Date] = [:]
        var failures: [String: Int] = [:]
        while !Task.isCancelled {
            do {
                let targets = try await database.pool.read {
                    try WalletDatabase.pendingStatusTargets(in: $0, includeDirtyBalances: true)
                }
                var unique: [String: SendPendingStatusTarget] = [:]
                for target in targets {
                    guard let wallet = target.walletID else { continue }
                    let key = wallet + ":" + target.receipt.networkID
                    if unique[key] == nil || target.balanceNeedsRefresh { unique[key] = target }
                }
                let due = unique.filter { key, value in
                    let retry = min(60.0, pow(2.0, Double(min(failures[key] ?? 0, 6))))
                    return Date().timeIntervalSince(lastRead[key] ?? .distantPast) >= (value.balanceNeedsRefresh ? max(2, retry) : 30)
                }.sorted { (lastRead[$0.key] ?? .distantPast) < (lastRead[$1.key] ?? .distantPast) }.prefix(4)
                await withTaskGroup(of: (String, Bool, Bool).self) { group in
                    for (key, target) in due {
                        let started = Date()
                        lastRead[key] = started
                        let balanceReader = balanceReader
                        group.addTask {
                            guard let walletID = target.walletID else { return (key, false, false) }
                            let outcome: WalletChainSyncOutcome
                            if let balanceReader { outcome = await balanceReader(database, target) }
                            else {
                                do { try Task.checkCancellation() }
                                catch { return (key, false, false) }
                                outcome = await SendPostBroadcastBalanceRefreshPool.shared.refresh(database: database,
                                    walletID: walletID, receipt: target.receipt, afterInFlightRead: target.balanceNeedsRefresh,
                                    onProgress: nil)
                            }
                            if !Task.isCancelled && outcome.didPersistData && outcome.failures.isEmpty {
                                // A newer status change during the read remains dirty.
                                try? await database.pool.write { db in
                                    try db.execute(sql: """
                                        UPDATE pendingTransactionEvidence SET balanceNeedsRefresh = 0
                                        WHERE accountID = ? AND networkID = ? AND balanceInvalidatedAt <= ?
                                        """, arguments: [target.receipt.accountID, target.receipt.networkID,
                                            started.timeIntervalSince1970])
                                }
                            }
                            return (key, outcome.didPersistData, outcome.didPersistData && outcome.failures.isEmpty)
                        }
                    }
                    for await (key, updated, succeeded) in group {
                        failures[key] = succeeded ? 0 : (failures[key] ?? 0) + 1
                        if updated { await onUpdate?() }
                    }
                }
            } catch is CancellationError { return }
            catch { observationFailure = SendTransactionStatusService.diagnosticCode(error) }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
        }
    }
}
