import Foundation
import GRDB

/// An app-accepted broadcast, not an API activity row. No dependency on the
/// transaction cache: refreshing/pruning activity cannot erase familiarity.
struct DBSendRecipientBroadcastRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "sendRecipientBroadcasts"

    let walletID: String
    let networkID: String
    let normalizedTransactionHash: String
    let recipientIdentity: String
    let recipientAddress: String
    let networkMemo: String?
    let memoRecorded: Bool
    let broadcastedAt: Double
}

extension WalletDatabase {
    /// Called in the same GRDB write transaction as the accepted Send receipt.
    /// Never called by provider history import or uncertain/failed submissions.
    static func recordAcceptedSendRecipient(
        receipt: SendTransactionReceipt,
        draft: SendDraft,
        asset: DBAssetRecord,
        walletID: String,
        database: Database
    ) throws {
        guard let addressIdentity = SendRecipientAddressIdentity(
            address: receipt.toAddress, networkID: receipt.networkID
        ) else { throw WalletDataStoreError.invalidAddress }
        guard draft.asset.networkID == receipt.networkID, draft.asset.id == receipt.assetID,
              let identity = SendRecipientIdentity(
                  address: draft.recipient, networkID: receipt.networkID, memo: draft.request.memo
              ), identity.address == addressIdentity
        else { throw WalletDataStoreError.invalidState }
        let hash = receipt.transactionHash.trimmingCharacters(in: .whitespacesAndNewlines)
        // XRP issued currencies carry exact decimal quantities in the receipt,
        // not integer drops. Other native/token receipts use atomic integers.
        let isIssuedXRP = receipt.networkID == XRPConstants.networkID
            && asset.assetType == DatabaseAssetType.fungibleToken.rawValue
            && !asset.contractAddress.isEmpty
        guard !hash.isEmpty, receipt.submittedAt.timeIntervalSince1970.isFinite,
              receipt.amountAtomic.utf8.allSatisfy({
                  (48...57).contains($0) || (isIssuedXRP && $0 == 46)
              }),
              let amount = try? SendDecimalAmount.parseUserUnits(
                  receipt.amountAtomic, maximumFractionDigits: isIssuedXRP ? nil : 0
              ), !amount.isZero
        else { throw WalletDataStoreError.invalidState }

        // Solana signatures and Sui/NEAR transaction digests are Base58.
        // Hex hashes on other supported chains are case-insensitive.
        let caseSensitiveHash = [
            SolanaConstants.networkID, SuiConstants.networkID, NEARConstants.networkID
        ].contains(receipt.networkID)
        let address = receipt.networkID == XRPConstants.networkID
            ? addressIdentity.value
            : receipt.toAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedHash = caseSensitiveHash ? hash : hash.lowercased()
        let key = [
            "walletID": walletID, "networkID": receipt.networkID,
            "normalizedTransactionHash": normalizedHash, "recipientIdentity": addressIdentity.value
        ]
        if let existing = try DBSendRecipientBroadcastRecord.fetchOne(database, key: key),
           existing.memoRecorded,
           existing.networkMemo.map({ Data($0.utf8) }) != identity.networkMemo.map({ Data($0.utf8) }) {
            // One signed transaction cannot acquire a different routing memo
            // from a duplicate callback. Preserve the original accepted record.
            throw WalletDataStoreError.invalidState
        }
        try database.execute(sql: """
            INSERT INTO sendRecipientBroadcasts (
                walletID, networkID, normalizedTransactionHash,
                recipientIdentity, recipientAddress, networkMemo, memoRecorded, broadcastedAt
            ) VALUES (?, ?, ?, ?, ?, ?, 1, ?)
            ON CONFLICT(walletID, networkID, normalizedTransactionHash, recipientIdentity) DO UPDATE SET
                networkMemo = excluded.networkMemo, memoRecorded = 1
                WHERE sendRecipientBroadcasts.memoRecorded = 0
            """, arguments: [
                walletID, receipt.networkID, normalizedHash,
                addressIdentity.value, address, identity.networkMemo, receipt.submittedAt.timeIntervalSince1970
            ])
    }
}
