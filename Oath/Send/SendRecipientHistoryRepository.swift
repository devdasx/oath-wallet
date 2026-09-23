import Foundation
import GRDB

struct SendRecipientHistoryScope: Sendable {
    let walletID: String
    let networkID: String
}

enum SendRecipientHistoryError: Error {
    case walletUnavailable, accountUnavailable, walletChanged, unsupportedNetwork

    var localizedMessage: String {
        switch self {
        case .walletUnavailable: WalletLocalization.string("send.recipient.history.wallet_unavailable")
        case .accountUnavailable: WalletLocalization.string("send.recipient.history.account_unavailable")
        case .walletChanged: WalletLocalization.string("send.recipient.history.wallet_changed")
        case .unsupportedNetwork: WalletLocalization.string("send.error.unsupported_network")
        }
    }
}

extension WalletDatabase {
    func sendRecipientHistoryScope(asset: SendAssetChoice) async throws -> SendRecipientHistoryScope {
        try await pool.read { database in
            guard let network = try DBNetworkRecord.fetchOne(database, key: asset.networkID),
                  network.isMainnet, network.isEnabled else {
                throw SendRecipientHistoryError.unsupportedNetwork
            }
            guard let wallet = try DBWalletRecord
                .filter(Column("profileID") == Self.defaultProfileID)
                .filter(Column("isSelected") == true)
                .filter(Column("archivedAt") == nil)
                .fetchOne(database) else { throw SendRecipientHistoryError.walletUnavailable }
            let accounts = try DBWalletAccountRecord
                .filter(Column("walletID") == wallet.id)
                .filter(Column("networkID") == asset.networkID)
                .filter(Column("isEnabled") == true)
                .fetchAll(database)
            guard !accounts.isEmpty else { throw SendRecipientHistoryError.accountUnavailable }
            if let sourceAddress = asset.sourceAddress {
                guard let source = SendRecipientAddressIdentity(address: sourceAddress, networkID: asset.networkID),
                      accounts.contains(where: {
                          SendRecipientAddressIdentity(address: $0.address, networkID: asset.networkID) == source
                      }) else { throw SendRecipientHistoryError.accountUnavailable }
            }
            return SendRecipientHistoryScope(walletID: wallet.id, networkID: asset.networkID)
        }
    }

    func sendRecipientHistoryObservation(
        scope: SendRecipientHistoryScope
    ) -> AsyncValueObservation<SendRecipientHistorySnapshot> {
        ValueObservation.tracking { database in
            try Self.sendRecipientHistorySnapshot(scope: scope, database: database)
        }
        .removeDuplicates()
        .values(in: pool, bufferingPolicy: .bufferingNewest(1))
    }

    func sendRecipientHistorySnapshot(scope: SendRecipientHistoryScope) async throws -> SendRecipientHistorySnapshot {
        try await pool.read { database in
            try Self.sendRecipientHistorySnapshot(scope: scope, database: database)
        }
    }

    private static func sendRecipientHistorySnapshot(
        scope: SendRecipientHistoryScope, database: Database
    ) throws -> SendRecipientHistorySnapshot {
        guard let wallet = try DBWalletRecord.fetchOne(database, key: scope.walletID),
              wallet.isSelected, wallet.archivedAt == nil,
              wallet.profileID == Self.defaultProfileID else { throw SendRecipientHistoryError.walletChanged }
        let accountIDs = try DBWalletAccountRecord
            .filter(Column("walletID") == scope.walletID)
            .filter(Column("networkID") == scope.networkID)
            .select(Column("id"), as: String.self)
            .fetchAll(database)
        guard !accountIDs.isEmpty else { throw SendRecipientHistoryError.accountUnavailable }

        // This table has one row per accepted app broadcast and canonical
        // recipient. API history, current token prices, and cached transaction
        // status must never establish (or erase) prior app sends.
        let rows = try Row.fetchCursor(database, sql: """
            SELECT recipientIdentity, networkMemo, memoRecorded, MIN(recipientAddress) AS recipientAddress,
                   COUNT(*) AS sendCount, MAX(broadcastedAt) AS lastSentAt
            FROM sendRecipientBroadcasts
            WHERE walletID = ? AND networkID = ?
            GROUP BY recipientIdentity, memoRecorded, networkMemo
            """, arguments: [scope.walletID, scope.networkID])
        var recipients: [SendRecipientIdentity: SendRecentRecipient] = [:]
        while let row = try rows.next() {
            let address: String = row["recipientAddress"]
            let storedIdentity: String = row["recipientIdentity"]
            let memo: String? = row["networkMemo"]
            let memoRecorded: Bool = row["memoRecorded"]
            guard let identity = SendRecipientIdentity(
                address: address, networkID: scope.networkID, memo: memo, memoRecorded: memoRecorded
            ), identity.address.value == storedIdentity, identity.memoRecorded == memoRecorded,
               identity.networkMemo.map({ Data($0.utf8) }) == memo.map({ Data($0.utf8) }) else {
                throw DatabaseError(resultCode: .SQLITE_CORRUPT, message: "Invalid saved recipient identity")
            }
            recipients[identity] = SendRecentRecipient(
                id: identity, address: address, sendCount: row["sendCount"],
                lastSentAt: Date(timeIntervalSince1970: row["lastSentAt"])
            )
        }
        return SendRecipientHistorySnapshot(recipientsByIdentity: recipients)
    }
}
