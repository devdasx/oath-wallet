import Foundation
import GRDB

extension WalletDatabase {
    /// Observe the selected wallet's enabled accounts, independently of the Home history limit.
    /// New failures let the owner reconcile previously pending rows; confirmation removes a row.
    func pendingActivity(walletID: String, since: Date) -> AsyncValueObservation<[WalletTransaction]> {
        ValueObservation.tracking { database in
            try Self.pendingActivity(walletID: walletID, since: since, database: database)
        }.values(in: pool, bufferingPolicy: .bufferingNewest(1))
    }

    static func pendingActivity(walletID: String, since: Date, database: Database) throws -> [WalletTransaction] {
        guard let wallet = try DBWalletRecord.fetchOne(database, key: walletID),
              wallet.profileID == defaultProfileID, wallet.archivedAt == nil else { return [] }
        let accountIDs = try DBWalletAccountRecord
            .filter(Column("walletID") == walletID && Column("isEnabled") == true)
            .fetchAll(database).map(\.id)
        guard !accountIDs.isEmpty else { return [] }
        let records = try DBTransactionRecord
            .filter(accountIDs.contains(Column("accountID")))
            .filter(Column("status") == "pending"
                || (["failed", "canceled"].contains(Column("status")) && Column("updatedAt") >= since.timeIntervalSince1970))
            .order(sql: "COALESCE(timestamp, firstSeenAt) DESC, id DESC")
            .fetchAll(database)
        return try pendingActivityTransactions(records: records, database: database)
    }

    func pendingActivityTransaction(id: String) -> AsyncValueObservation<WalletTransaction?> {
        ValueObservation.tracking { database -> WalletTransaction? in
            guard let record = try DBTransactionRecord.fetchOne(database, key: id) else { return nil }
            return try Self.pendingActivityTransactions(records: [record], database: database).first
        }.values(in: pool, bufferingPolicy: .bufferingNewest(1))
    }

    private static func pendingActivityTransactions(records: [DBTransactionRecord], database: Database) throws -> [WalletTransaction] {
        guard !records.isEmpty else { return [] }
        let assetIDs = Array(Set(records.compactMap(\.assetID)))
        let assets = try DBAssetRecord.filter(assetIDs.contains(Column("id"))).fetchAll(database)
        let assetsByID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        let networkIDs = Array(Set(records.map(\.networkID)))
        let networks = try DBNetworkRecord.filter(networkIDs.contains(Column("id"))).fetchAll(database)
        let networksByID = Dictionary(uniqueKeysWithValues: networks.map { ($0.id, $0) })
        let transactionIDs = records.map(\.id)
        let notes = try DBTransactionNoteRecord.filter(transactionIDs.contains(Column("transactionID")))
            .fetchAll(database)
        let notesByID = Dictionary(uniqueKeysWithValues: notes.map { ($0.transactionID, $0.note) })
        let transfers = try DBTransactionTransferRecord.filter(transactionIDs.contains(Column("transactionID")))
            .fetchAll(database).filter { $0.id == "\($0.transactionID)|primary" }
        let transfersByID = Dictionary(uniqueKeysWithValues: transfers.map { ($0.transactionID, $0) })
        var prices: [String: Decimal] = [:]
        for assetID in assetIDs {
            if let record = try latestValidUSDPriceRecord(assetID: assetID, database: database),
               let value = decimal(record.price) { prices[assetID] = value }
        }
        return records.compactMap { record in
            guard networksByID[record.networkID]?.isMainnet == true,
                  isDisplayEligibleTransaction(record, assetsByID: assetsByID),
                  let transaction = walletTransaction(transactionByApplyingCachedUSDPrice(record,
                    unitUSDPricesByAssetID: prices), assetsByID: assetsByID, networkByID: networksByID,
                    localNote: notesByID[record.id], primaryTransfer: transfersByID[record.id]),
                  WalletTransactionVisibilityPolicy.includes(transaction) else { return nil }
            return transaction
        }
    }
}
