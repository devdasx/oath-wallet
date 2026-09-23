import Foundation
import GRDB

struct SendPendingStatusTarget: Hashable, Sendable {
    let receipt: SendTransactionReceipt
    let transactionID: String?
    let accountAddress: String
    let isTONHistory: Bool
    let contractAddress: String?
    var nonce: Int64? = nil
    var walletID: String? = nil
    var balanceNeedsRefresh: Bool = false
    var normalizedHash: String { WalletDatabase.normalizedSendHash(receipt.transactionHash, networkID: receipt.networkID) }
    var hasCaseSensitiveHash: Bool { ["solana", "sui", "near"].contains(receipt.networkID) }
    var id: String {
        let identity = receipt.accountID + ":" + receipt.networkID + ":" + WalletDatabase.normalizedSendHash(
            receipt.transactionHash, networkID: receipt.networkID)
        return isTONHistory ? identity + ":" + (transactionID ?? receipt.assetID) : identity
    }
}

extension WalletDatabase {
    static func trackSendStatus(_ receipt: SendTransactionReceipt, status: String = "pending", in db: Database) throws {
        try db.execute(sql: """
            INSERT INTO sendStatusTracking(accountID, networkID, transactionHash, normalizedTransactionHash,
                                           fromAddress, toAddress, submittedAt, status)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(accountID, networkID, normalizedTransactionHash) DO UPDATE SET
                status = CASE WHEN sendStatusTracking.status = 'pending' THEN excluded.status ELSE sendStatusTracking.status END
            """, arguments: [receipt.accountID, receipt.networkID, receipt.transactionHash,
                normalizedSendHash(receipt.transactionHash, networkID: receipt.networkID), receipt.fromAddress,
                receipt.toAddress, receipt.submittedAt.timeIntervalSince1970, status])
    }

    func persistedTerminalSendStatus(_ receipt: SendTransactionReceipt) async throws -> SendTransactionNetworkStatus? {
        try await pool.read { db in
            let value = try String.fetchOne(db, sql: """
                SELECT status FROM transactions WHERE accountID = ? AND networkID = ?
                  AND (transactionHash = ? OR (? = 1 AND lower(transactionHash) = lower(?)))
                  AND status IN ('confirmed', 'failed', 'canceled') LIMIT 1
                """, arguments: [receipt.accountID, receipt.networkID,
                    receipt.transactionHash,
                    ![SolanaConstants.networkID, SuiConstants.networkID, NEARConstants.networkID].contains(receipt.networkID),
                    receipt.transactionHash])
            return value.flatMap(SendTransactionNetworkStatus.init(rawValue:))
        }
    }

    func persistPendingTONHistoryStatus(_ target: SendPendingStatusTarget,
                                        status: SendTransactionNetworkStatus) async throws {
        guard status.isTerminal, target.isTONHistory, let id = target.transactionID else { return }
        try await pool.write { db in
            try db.execute(sql: """
                UPDATE transactions SET status = ?, updatedAt = ?
                WHERE id = ? AND accountID = ? AND networkID = 'ton' AND transactionHash = ? AND status = 'pending'
                """, arguments: [status.databaseStatus, Date().timeIntervalSince1970, id,
                    target.receipt.accountID, target.receipt.transactionHash])
        }
    }

    func pendingStatusTargets() -> AsyncValueObservation<[SendPendingStatusTarget]> {
        ValueObservation.tracking { db in try Self.pendingStatusTargets(in: db) }
            .values(in: pool, bufferingPolicy: .bufferingNewest(1))
    }

    static func pendingStatusTargets(in db: Database, includeDirtyBalances: Bool = false) throws -> [SendPendingStatusTarget] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT t.id, t.accountID, t.networkID, t.transactionHash, t.fromAddress, t.toAddress,
                   COALESCE(t.timestamp, t.firstSeenAt) AS submittedAt, a.address AS accountAddress,
                   t.assetID, t.assetSymbol, t.assetAmount, t.direction, s.transactionHash AS localHash,
                   x.contractAddress, t.nonce, w.id AS walletID, COALESCE(e.balanceNeedsRefresh, 0) AS balanceNeedsRefresh
            FROM transactions t JOIN walletAccounts a ON a.id = t.accountID
            JOIN wallets w ON w.id = a.walletID JOIN networks n ON n.id = t.networkID
            LEFT JOIN assets x ON x.id = t.assetID
            LEFT JOIN pendingTransactionEvidence e ON e.accountID = t.accountID AND e.networkID = t.networkID
                AND (e.transactionHash = t.normalizedTransactionHash OR e.transactionHash = t.transactionHash)
            LEFT JOIN sendStatusTracking s ON s.accountID = t.accountID AND s.networkID = t.networkID
                AND s.normalizedTransactionHash = t.normalizedTransactionHash
            WHERE (t.status = 'pending' OR (? = 1 AND e.balanceNeedsRefresh = 1))
                AND a.isEnabled = 1 AND w.archivedAt IS NULL AND n.isMainnet = 1
                AND w.profileID = ?
            ORDER BY t.firstSeenAt DESC
            """, arguments: [includeDirtyBalances, defaultProfileID])
        var byID: [String: SendPendingStatusTarget] = [:]
        for row in rows {
            let network: String = row["networkID"]
            // Incoming UTXO status must use our receiving address, never an
            // unrelated sender. Direct txid lookup also handles HD child sends.
            let address: String = row["accountAddress"]
            let from: String = row["fromAddress"] ?? (network == NEARConstants.networkID ? "" : address)
            let to: String = row["toAddress"] ?? ""
            let receipt = SendTransactionReceipt(transactionHash: row["transactionHash"], accountID: row["accountID"],
                networkID: network, fromAddress: from, toAddress: to,
                assetID: row["assetID"] ?? "", assetSymbol: row["assetSymbol"], amount: row["assetAmount"],
                amountAtomic: "0", networkFee: nil, networkFeeAtomic: nil, networkFeeSymbol: "",
                submittedAt: Date(timeIntervalSince1970: row["submittedAt"]))
            let target = SendPendingStatusTarget(receipt: receipt, transactionID: row["id"], accountAddress: address,
                isTONHistory: network == TONConstants.networkID && (row["localHash"] as String?) == nil,
                contractAddress: (row["contractAddress"] as String?).flatMap { $0.isEmpty ? nil : $0 },
                nonce: row["nonce"], walletID: row["walletID"], balanceNeedsRefresh: row["balanceNeedsRefresh"])
            if byID[target.id]?.balanceNeedsRefresh != true || target.balanceNeedsRefresh {
                byID[target.id] = target
            }
        }
        // Durable submissions survive a receipt-write failure and app termination.
        // Legacy in-flight evidence is included without a schema rewrite of wallet data.
        let evidence = try Row.fetchAll(db, sql: """
            SELECT s.accountID, s.networkID, s.transactionHash, s.fromAddress, s.toAddress,
                   s.submittedAt, a.address AS accountAddress, w.id AS walletID
            FROM sendStatusTracking s JOIN walletAccounts a ON a.id = s.accountID
            JOIN wallets w ON w.id = a.walletID JOIN networks n ON n.id = s.networkID
            WHERE s.status = 'pending' AND a.isEnabled = 1 AND w.archivedAt IS NULL AND n.isMainnet = 1
                AND w.profileID = ?
            UNION ALL
            SELECT s.accountID, s.networkID, s.transactionHash, s.fromAddress, '', s.createdAt, a.address, w.id
            FROM sendPendingSubmissions s JOIN walletAccounts a ON a.id = s.accountID
            JOIN wallets w ON w.id = a.walletID JOIN networks n ON n.id = s.networkID
            WHERE a.isEnabled = 1 AND w.archivedAt IS NULL AND n.isMainnet = 1 AND w.profileID = ?
            UNION ALL
            SELECT s.accountID, s.networkID, s.transactionHash, s.fromAddress, '', s.createdAt, a.address, w.id
            FROM sendSpendReservations s JOIN walletAccounts a ON a.id = s.accountID
            JOIN wallets w ON w.id = a.walletID JOIN networks n ON n.id = s.networkID
            WHERE s.state = 'submissionStarted' AND a.isEnabled = 1 AND w.archivedAt IS NULL
                AND n.isMainnet = 1 AND w.profileID = ?
            """, arguments: [defaultProfileID, defaultProfileID, defaultProfileID])
        for row in evidence {
            let receipt = SendTransactionReceipt(transactionHash: row["transactionHash"], accountID: row["accountID"],
                networkID: row["networkID"], fromAddress: row["fromAddress"], toAddress: row["toAddress"],
                assetID: "", assetSymbol: "", amount: "0", amountAtomic: "0", networkFee: nil,
                networkFeeAtomic: nil, networkFeeSymbol: "", submittedAt: Date(timeIntervalSince1970: row["submittedAt"]))
            let target = SendPendingStatusTarget(receipt: receipt, transactionID: nil, accountAddress: row["accountAddress"],
                isTONHistory: false, contractAddress: nil, walletID: row["walletID"])
            for key in Array(byID.keys) where byID[key]?.isTONHistory == true
                && byID[key]?.receipt.accountID == receipt.accountID
                && byID[key]?.receipt.networkID == receipt.networkID
                && byID[key]?.receipt.transactionHash == receipt.transactionHash {
                byID[key] = nil
            }
            if byID[target.id] == nil { byID[target.id] = target }
        }
        return byID.values.sorted { $0.receipt.submittedAt > $1.receipt.submittedAt }
    }
}
