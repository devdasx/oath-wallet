import Foundation
import GRDB

enum WalletDataStoreError: Error {
    case invalidAddress
    case missingRecord
    case invalidMainnet
    case invalidState
}

struct WalletContactAddressDraft: Sendable {
    let id: String
    let networkID: String?
    let address: String
    let label: String?
    let isFavorite: Bool

    init(
        id: String = UUID().uuidString.lowercased(),
        networkID: String?,
        address: String,
        label: String? = nil,
        isFavorite: Bool = false
    ) {
        self.id = id
        self.networkID = networkID
        self.address = address
        self.label = label
        self.isFavorite = isFavorite
    }
}

actor WalletDataStore {
    static let shared = WalletDataStore(
        databaseProvider: WalletDatabaseRuntime.require
    )

    private let databaseProvider:
        @Sendable () throws -> WalletDatabase

    init(database: WalletDatabase) {
        databaseProvider = { database }
    }

    init(
        databaseProvider:
            @escaping @Sendable () throws -> WalletDatabase
    ) {
        self.databaseProvider = databaseProvider
    }

    private var database: WalletDatabase {
        get throws {
            try databaseProvider()
        }
    }

    func wallets(
        profileID: String = WalletDatabase.defaultProfileID,
        includesArchived: Bool = false
    ) async throws -> [DBWalletRecord] {
        try await database.pool.read { db in
            var request = DBWalletRecord
                .filter(Column("profileID") == profileID)
            if !includesArchived {
                request = request.filter(Column("archivedAt") == nil)
            }
            return try request
                .order(Column("sortOrder"), Column("createdAt"))
                .fetchAll(db)
        }
    }

    func accounts(walletID: String) async throws -> [DBWalletAccountRecord] {
        try await database.pool.read { db in
            try DBWalletAccountRecord
                .filter(Column("walletID") == walletID)
                .order(Column("networkID"))
                .fetchAll(db)
        }
    }

    func renameWallet(id: String, name: String) async throws {
        let normalizedName = name.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalizedName.isEmpty else {
            throw WalletDataStoreError.invalidState
        }
        try await database.pool.write { db in
            try db.execute(
                sql: "UPDATE wallets SET name = ?, updatedAt = ? WHERE id = ? AND archivedAt IS NULL",
                arguments: [
                    normalizedName,
                    Date().timeIntervalSince1970,
                    id
                ]
            )
            guard db.changesCount > 0 else {
                throw WalletDataStoreError.missingRecord
            }
        }
    }

    func selectWallet(id: String) async throws {
        try await database.pool.write { db in
            guard let wallet = try DBWalletRecord.fetchOne(db, key: id),
                  wallet.archivedAt == nil else {
                throw WalletDataStoreError.missingRecord
            }
            let now = Date().timeIntervalSince1970
            try db.execute(
                sql: "UPDATE wallets SET isSelected = 0 WHERE profileID = ?",
                arguments: [wallet.profileID]
            )
            try db.execute(
                sql: "UPDATE wallets SET isSelected = 1, lastOpenedAt = ?, updatedAt = ? WHERE id = ?",
                arguments: [now, now, id]
            )
        }
    }

    func archiveWallet(id: String) async throws {
        try await database.pool.write { db in
            guard let wallet = try DBWalletRecord.fetchOne(db, key: id) else {
                throw WalletDataStoreError.missingRecord
            }
            let now = Date().timeIntervalSince1970
            try db.execute(
                sql: "UPDATE wallets SET archivedAt = ?, isSelected = 0, updatedAt = ? WHERE id = ?",
                arguments: [now, now, id]
            )
            if wallet.isSelected,
               let replacementID = try String.fetchOne(
                   db,
                   sql: """
                   SELECT id FROM wallets
                   WHERE profileID = ? AND archivedAt IS NULL
                   ORDER BY sortOrder, createdAt
                   LIMIT 1
                   """,
                   arguments: [wallet.profileID]
               ) {
                try db.execute(
                    sql: "UPDATE wallets SET isSelected = 1, updatedAt = ? WHERE id = ?",
                    arguments: [now, replacementID]
                )
            }
        }
    }

    func setAssetVisibility(
        accountID: String,
        assetID: String,
        isEnabled: Bool,
        isHidden: Bool
    ) async throws {
        try await database.pool.write { db in
            try db.execute(
                sql: """
                UPDATE accountAssets
                SET isEnabled = ?, isHidden = ?, updatedAt = ?
                WHERE accountID = ? AND assetID = ?
                """,
                arguments: [
                    isEnabled,
                    isHidden,
                    Date().timeIntervalSince1970,
                    accountID,
                    assetID
                ]
            )
            guard db.changesCount > 0 else {
                throw WalletDataStoreError.missingRecord
            }
        }
    }

    func saveMarketSnapshot(
        _ snapshot: DBMarketSnapshotRecord
    ) async throws {
        try await database.pool.write { db in
            try snapshot.save(db)
        }
    }

    func latestMarketSnapshot(
        assetID: String,
        quoteCurrency: String
    ) async throws -> DBMarketSnapshotRecord? {
        try await database.pool.read { db in
            try DBMarketSnapshotRecord
                .filter(Column("assetID") == assetID)
                .filter(
                    Column("quoteCurrency")
                        == quoteCurrency.uppercased()
                )
                .order(Column("observedAt").desc)
                .fetchOne(db)
        }
    }

    func saveNFTHolding(
        collection: DBNFTCollectionRecord,
        item: DBNFTItemRecord,
        holding: DBAccountNFTHoldingRecord
    ) async throws {
        try await database.pool.write { db in
            try Self.requireMainnet(
                networkID: collection.networkID,
                database: db
            )
            try collection.save(db)
            try item.save(db)
            try holding.save(db)
        }
    }

    func nftHoldings(
        accountID: String,
        includesHidden: Bool = false
    ) async throws -> [DBAccountNFTHoldingRecord] {
        try await database.pool.read { db in
            var request = DBAccountNFTHoldingRecord
                .filter(Column("accountID") == accountID)
            if !includesHidden {
                request = request.filter(Column("isHidden") == false)
            }
            return try request
                .order(Column("lastSeenAt").desc)
                .fetchAll(db)
        }
    }

    func saveContact(
        id: String = UUID().uuidString.lowercased(),
        profileID: String = WalletDatabase.defaultProfileID,
        name: String,
        note: String?,
        addresses: [WalletContactAddressDraft]
    ) async throws -> String {
        let normalizedName = name.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalizedName.isEmpty else {
            throw WalletDataStoreError.invalidState
        }
        let normalizedAddresses = try addresses.map { draft in
            let normalized = draft.address.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).lowercased()
            guard AnkrAPIClient.isValidAddress(normalized) else {
                throw WalletDataStoreError.invalidAddress
            }
            return (draft, normalized)
        }

        try await database.pool.write { db in
            let now = Date().timeIntervalSince1970
            let existing = try DBContactRecord.fetchOne(db, key: id)
            try DBContactRecord(
                id: id,
                profileID: profileID,
                name: normalizedName,
                note: note,
                createdAt: existing?.createdAt ?? now,
                updatedAt: now
            ).save(db)
            try db.execute(
                sql: "DELETE FROM contactAddresses WHERE contactID = ?",
                arguments: [id]
            )
            for (draft, normalizedAddress) in normalizedAddresses {
                if let networkID = draft.networkID {
                    try Self.requireMainnet(
                        networkID: networkID,
                        database: db
                    )
                }
                try DBContactAddressRecord(
                    id: draft.id,
                    contactID: id,
                    networkID: draft.networkID,
                    address: draft.address,
                    normalizedAddress: normalizedAddress,
                    label: draft.label,
                    isFavorite: draft.isFavorite,
                    createdAt: now
                ).insert(db)
            }
        }
        return id
    }

    func contacts(
        query: String = "",
        profileID: String = WalletDatabase.defaultProfileID
    ) async throws -> [DBContactRecord] {
        try await database.pool.read { db in
            let normalizedQuery = query.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if normalizedQuery.isEmpty {
                return try DBContactRecord
                    .filter(Column("profileID") == profileID)
                    .order(Column("name").collating(.localizedCaseInsensitiveCompare))
                    .fetchAll(db)
            }
            return try DBContactRecord.fetchAll(
                db,
                sql: """
                SELECT DISTINCT contacts.*
                FROM contacts
                LEFT JOIN contactAddresses
                  ON contactAddresses.contactID = contacts.id
                WHERE contacts.profileID = ?
                  AND (
                    contacts.name LIKE ? ESCAPE '\\' COLLATE NOCASE
                    OR contactAddresses.address LIKE ? ESCAPE '\\' COLLATE NOCASE
                    OR contactAddresses.label LIKE ? ESCAPE '\\' COLLATE NOCASE
                  )
                ORDER BY contacts.name COLLATE NOCASE
                """,
                arguments: [
                    profileID,
                    Self.likePattern(normalizedQuery),
                    Self.likePattern(normalizedQuery),
                    Self.likePattern(normalizedQuery)
                ]
            )
        }
    }

    func deleteContact(id: String) async throws {
        try await database.pool.write { db in
            _ = try DBContactRecord.deleteOne(db, key: id)
        }
    }

    func saveDApp(
        _ dapp: DBConnectedDAppRecord,
        permissions: [DBDAppPermissionRecord]
    ) async throws {
        try await database.pool.write { db in
            let requestedChainIDs = Array(
                Set(permissions.map(\.chainID))
            )
            if !requestedChainIDs.isEmpty {
                let placeholders = Array(
                    repeating: "?",
                    count: requestedChainIDs.count
                ).joined(separator: ",")
                let mainnetChainIDs = Set(
                    try Int64.fetchAll(
                        db,
                        sql: """
                        SELECT chainID
                        FROM networks
                        WHERE isMainnet = 1
                          AND chainID IN (\(placeholders))
                        """,
                        arguments: StatementArguments(requestedChainIDs)
                    )
                )
                guard requestedChainIDs.allSatisfy(
                    mainnetChainIDs.contains
                ) else {
                    throw WalletDataStoreError.invalidMainnet
                }
            }

            try dapp.save(db)
            try db.execute(
                sql: "DELETE FROM dappPermissions WHERE dappID = ?",
                arguments: [dapp.id]
            )
            for permission in permissions {
                try permission.insert(db)
            }
        }
    }

    func disconnectDApp(id: String) async throws {
        try await database.pool.write { db in
            _ = try DBConnectedDAppRecord.deleteOne(db, key: id)
        }
    }

    func userSettings(
        profileID: String = WalletDatabase.defaultProfileID
    ) async throws -> DBUserSettingsRecord {
        try await database.pool.read { db in
            guard let settings = try DBUserSettingsRecord.fetchOne(
                db,
                key: profileID
            ) else {
                throw WalletDataStoreError.missingRecord
            }
            return settings
        }
    }

    func saveUserSettings(_ settings: DBUserSettingsRecord) async throws {
        try await database.pool.write { db in
            try settings.save(db)
        }
    }

    func savePriceAlert(_ alert: DBPriceAlertRecord) async throws {
        try await database.pool.write { db in
            try alert.save(db)
        }
    }

    func priceAlerts(
        profileID: String = WalletDatabase.defaultProfileID,
        enabledOnly: Bool = false
    ) async throws -> [DBPriceAlertRecord] {
        try await database.pool.read { db in
            var request = DBPriceAlertRecord
                .filter(Column("profileID") == profileID)
            if enabledOnly {
                request = request.filter(Column("isEnabled") == true)
            }
            return try request
                .order(Column("createdAt").desc)
                .fetchAll(db)
        }
    }

    func deletePriceAlert(id: String) async throws {
        try await database.pool.write { db in
            _ = try DBPriceAlertRecord.deleteOne(db, key: id)
        }
    }

    func saveNotification(_ notification: DBNotificationRecord) async throws {
        try await database.pool.write { db in
            try notification.save(db)
        }
    }

    func notifications(
        profileID: String = WalletDatabase.defaultProfileID,
        unreadOnly: Bool = false,
        limit: Int = 100
    ) async throws -> [DBNotificationRecord] {
        try await database.pool.read { db in
            var request = DBNotificationRecord
                .filter(Column("profileID") == profileID)
            if unreadOnly {
                request = request.filter(Column("readAt") == nil)
            }
            return try request
                .order(Column("createdAt").desc)
                .limit(max(1, min(limit, 500)))
                .fetchAll(db)
        }
    }

    func markNotificationRead(id: String, isRead: Bool) async throws {
        try await database.pool.write { db in
            try db.execute(
                sql: "UPDATE notifications SET readAt = ? WHERE id = ?",
                arguments: [
                    isRead ? Date().timeIntervalSince1970 : nil,
                    id
                ]
            )
        }
    }

    func saveSyncState(_ state: DBSyncStateRecord) async throws {
        try await database.pool.write { db in
            try state.save(db)
        }
    }

    func syncState(
        accountID: String,
        resource: String
    ) async throws -> DBSyncStateRecord? {
        try await database.pool.read { db in
            try DBSyncStateRecord
                .filter(Column("accountID") == accountID)
                .filter(Column("resource") == resource)
                .fetchOne(db)
        }
    }

    func enqueueOperation(
        _ operation: DBPendingOperationRecord
    ) async throws {
        guard operation.state == "draft"
                || operation.state == "awaitingSignature"
                || operation.state == "submitted"
        else {
            throw WalletDataStoreError.invalidState
        }
        try await database.pool.write { db in
            try operation.save(db)
        }
    }

    func dueOperations(
        at date: Date = Date(),
        limit: Int = 50
    ) async throws -> [DBPendingOperationRecord] {
        try await database.pool.read { db in
            try DBPendingOperationRecord.fetchAll(
                db,
                sql: """
                SELECT * FROM pendingOperations
                WHERE state IN ('draft', 'awaitingSignature', 'submitted')
                  AND (nextRetryAt IS NULL OR nextRetryAt <= ?)
                ORDER BY createdAt
                LIMIT ?
                """,
                arguments: [
                    date.timeIntervalSince1970,
                    max(1, min(limit, 500))
                ]
            )
        }
    }

    func setTransactionNote(
        transactionID: String,
        note: String?
    ) async throws {
        let database = try database
        try await database.setTransactionNote(
            transactionID: transactionID,
            note: note
        )
    }

    func transactionNote(
        transactionID: String
    ) async throws -> String? {
        let database = try database
        return try await database.transactionNote(
            transactionID: transactionID
        )
    }

    func saveTag(
        id: String = UUID().uuidString.lowercased(),
        profileID: String = WalletDatabase.defaultProfileID,
        name: String
    ) async throws -> String {
        let normalizedName = name.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalizedName.isEmpty else {
            throw WalletDataStoreError.invalidState
        }
        try await database.pool.write { db in
            try DBTagRecord(
                id: id,
                profileID: profileID,
                name: normalizedName,
                createdAt: Date().timeIntervalSince1970
            ).save(db)
        }
        return id
    }

    func setTag(
        transactionID: String,
        tagID: String,
        isAttached: Bool
    ) async throws {
        try await database.pool.write { db in
            if isAttached {
                try DBTransactionTagRecord(
                    transactionID: transactionID,
                    tagID: tagID
                ).save(db)
            } else {
                _ = try DBTransactionTagRecord.deleteOne(
                    db,
                    key: [
                        "transactionID": transactionID,
                        "tagID": tagID
                    ]
                )
            }
        }
    }

    func activityRecords(
        accountID: String,
        query: String = "",
        limit: Int = 100,
        offset: Int = 0
    ) async throws -> [DBTransactionRecord] {
        try await database.pool.read { db in
            let boundedLimit = max(1, min(limit, 500))
            let boundedOffset = max(0, offset)
            let normalizedQuery = query.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !normalizedQuery.isEmpty else {
                return try DBTransactionRecord
                    .filter(Column("accountID") == accountID)
                    .order(Column("timestamp").desc)
                    .limit(boundedLimit, offset: boundedOffset)
                    .fetchAll(db)
            }
            let pattern = Self.likePattern(normalizedQuery)
            return try DBTransactionRecord.fetchAll(
                db,
                sql: """
                SELECT * FROM transactions
                WHERE accountID = ?
                  AND (
                    transactionHash LIKE ? ESCAPE '\\' COLLATE NOCASE
                    OR assetSymbol LIKE ? ESCAPE '\\' COLLATE NOCASE
                    OR fromAddress LIKE ? ESCAPE '\\' COLLATE NOCASE
                    OR toAddress LIKE ? ESCAPE '\\' COLLATE NOCASE
                  )
                ORDER BY timestamp DESC, blockNumber DESC
                LIMIT ? OFFSET ?
                """,
                arguments: [
                    accountID,
                    pattern,
                    pattern,
                    pattern,
                    pattern,
                    boundedLimit,
                    boundedOffset
                ]
            )
        }
    }
}

private extension WalletDataStore {
    static func requireMainnet(
        networkID: String,
        database: Database
    ) throws {
        guard let isMainnet = try Bool.fetchOne(
            database,
            sql: "SELECT isMainnet FROM networks WHERE id = ?",
            arguments: [networkID]
        ), isMainnet else {
            throw WalletDataStoreError.invalidMainnet
        }
    }

    static func likePattern(_ query: String) -> String {
        let escaped = query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return "%\(escaped)%"
    }
}
