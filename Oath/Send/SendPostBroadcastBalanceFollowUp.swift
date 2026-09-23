import Foundation
import GRDB

struct SendPostBroadcastRefreshRequest: Sendable {
    let receipt: SendTransactionReceipt
    var knownTerminalStatus: SendTransactionNetworkStatus? = nil
}

struct SendPostBroadcastRefreshTask {
    let id: UUID
    let knownTerminalStatus: SendTransactionNetworkStatus?
    let task: Task<Void, Never>
}

/// Only ledger quantities are compared. Prices, formatting and new unrelated
/// holdings cannot imply that this transfer was applied to the account.
struct SendBalanceSnapshot: Equatable, Sendable {
    let quantities: [String: String]
}

extension WalletDatabase {
    func sendBalanceSnapshot(receipt: SendTransactionReceipt) async throws -> SendBalanceSnapshot {
        try await pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT h.assetID, h.balanceAtomic, h.balance, a.decimals
                FROM accountAssets h JOIN assets a ON a.id = h.assetID
                WHERE h.accountID = ? AND a.networkID = ?
                    AND (a.assetType = 'native' OR a.id = ?)
                """, arguments: [receipt.accountID, receipt.networkID, receipt.assetID])
            var quantities: [String: String] = [:]
            for row in rows {
                let value: String
                if let atomic: String = row["balanceAtomic"] {
                    value = try BitcoinFamilyAtomicInteger(validating: atomic).decimalText
                } else if let decimals: Int = row["decimals"] {
                    value = try SendNetworkFeeBaseUnitConverter.baseUnits(
                        from: row["balance"], decimals: decimals, permitsZero: true)
                } else { continue }
                quantities[row["assetID"]] = value
            }
            return SendBalanceSnapshot(quantities: quantities)
        }
    }
}

/// Reconciles balances independently of the Send sheet. A balance is never a
/// transaction-status oracle: self-transfers and simultaneous credits can leave
/// it unchanged. This owner reads only; it never retries signing or broadcasting.
struct SendPostBroadcastBalanceFollowUp: Sendable {
    typealias Sleeper = @Sendable (Duration) async throws -> Void
    private let sleep: Sleeper

    init(sleep: @escaping Sleeper = { try await Task.sleep(for: $0) }) {
        self.sleep = sleep
    }

    func run(
        knownTerminalStatus: SendTransactionNetworkStatus? = nil,
        snapshot: @escaping @Sendable () async throws -> SendBalanceSnapshot,
        status: @escaping @Sendable () async throws -> SendTransactionNetworkStatus,
        refresh: @escaping @Sendable (SendTransactionNetworkStatus?) async -> Bool
    ) async {
        let baseline = try? await snapshot()
        var terminal = knownTerminalStatus?.isTerminal == true ? knownTerminalStatus : nil
        var attempt = 0
        var terminalRefreshes = 0
        var delay = SendPostBroadcastChainRefreshPolicy.delay
        while !Task.isCancelled {
            do { try await sleep(delay); try Task.checkCancellation() } catch { return }
            let terminalBeforeRefresh = terminal
            // Start the balance request without waiting for a slow status RPC.
            // Shared status reads coalesce with the app's confirmation monitor.
            async let observation = observedStatus(terminal: terminal, reader: status)
            let refreshed = await refresh(terminalBeforeRefresh)
            let observed = await observation
            guard !Task.isCancelled else { return }
            if let observed, observed.isTerminal { terminal = observed }
            let current = try? await snapshot()
            let changed = baseline.map { !$0.quantities.isEmpty && current != nil && current != $0 } ?? false

            if refreshed, terminalBeforeRefresh != nil {
                terminalRefreshes += 1
                // Failure needs one fresh read AFTER the result was known.
                // Confirmation with an unchanged balance gets five fresh reads
                // (2, 4, 8, 16, 30 seconds apart), then normal wallet sync takes
                // over: a valid unchanged balance must not poll forever.
                if terminal == .failed || changed || terminalRefreshes >= 5 { return }
            }
            if terminal != nil {
                delay = .seconds(min(30, 2 * (1 << min(terminalRefreshes, 4))))
            } else {
                attempt += 1
                delay = .seconds(changed ? 30 : min(30, 2 * (1 << min(attempt, 4))))
            }
        }
    }

    private func observedStatus(
        terminal: SendTransactionNetworkStatus?,
        reader: @Sendable () async throws -> SendTransactionNetworkStatus
    ) async -> SendTransactionNetworkStatus? {
        if let terminal { return terminal }
        // A failed lookup is unknown, never a failed transaction. The existing
        // status monitor owns actionable provider diagnostics and persistence.
        return try? await reader()
    }
}
