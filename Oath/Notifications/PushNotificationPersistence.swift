import Foundation
import GRDB
import UserNotifications

struct PushNotificationHistoryPersistenceResult: Sendable {
    let insertedCount: Int
    let existingCount: Int
}

@MainActor
struct PushNotificationPersistence: Sendable {
    let database: WalletDatabase

    func record(
        notification: UNNotification,
        openedAt: Date? = nil
    ) async throws -> PushNotificationRoute? {
        let content = notification.request.content
        guard let payload = PushNotificationPayload(
            userInfo: content.userInfo
        ) else {
            return nil
        }
        let now = Date().timeIntervalSince1970
        let openedTimestamp = openedAt?.timeIntervalSince1970
        let relatedTransactionID = try await relatedTransactionID(
            walletID: payload.walletID,
            networkID: payload.networkID,
            transactionHash: payload.transactionHash
        )
        let arguments = Self.safeArguments(
            payload.localizationArguments
        )
        let titleText = Self.bounded(content.title, limit: 500)
        let bodyText = Self.bounded(
            content.subtitle.isEmpty
                ? content.body
                : content.subtitle,
            limit: 2_000
        )
        let createdAt = payload.createdAt ?? now

        try await database.pool.write { database in
            if var existing = try DBNotificationRecord
                .filter(
                    Column("remoteNotificationID")
                        == payload.notificationID
                )
                .fetchOne(database) {
                existing.assetSymbol = payload.assetSymbol ?? existing.assetSymbol
                existing.deliveredAt = existing.deliveredAt ?? now
                existing.openedAt = openedTimestamp ?? existing.openedAt
                existing.readAt = openedTimestamp ?? existing.readAt
                try existing.update(database)
                if openedTimestamp != nil {
                    try Self.enqueueOpenAudit(
                        notificationID: payload.notificationID,
                        now: now,
                        database: database
                    )
                }
                return
            }

            try DBNotificationRecord(
                id: UUID().uuidString.lowercased(),
                profileID: WalletDatabase.defaultProfileID,
                category: payload.category.rawValue,
                titleKey: payload.titleKey,
                bodyKey: payload.bodyKey,
                argumentsJSON: arguments,
                relatedTransactionID: relatedTransactionID,
                createdAt: createdAt,
                readAt: openedTimestamp,
                deliveredAt: now,
                remoteNotificationID: payload.notificationID,
                titleText: titleText,
                bodyText: bodyText,
                walletID: payload.walletID,
                networkID: payload.networkID,
                transactionHash: payload.transactionHash,
                openedAt: openedTimestamp,
                assetSymbol: payload.assetSymbol
            ).insert(database)
            if openedTimestamp != nil {
                try Self.enqueueOpenAudit(
                    notificationID: payload.notificationID,
                    now: now,
                    database: database
                )
            }
        }

        return PushNotificationRoute(
            notificationID: payload.notificationID,
            category: payload.category,
            walletID: payload.walletID,
            networkID: payload.networkID,
            transactionHash: payload.transactionHash
        )
    }

    func record(
        historyItems: [PushNotificationHistoryItem]
    ) async throws -> PushNotificationHistoryPersistenceResult {
        try await database.pool.write { database in
            var insertedCount = 0
            var existingCount = 0
            for item in historyItems {
                guard let createdAt = PushServiceDate
                    .parse(item.createdAt)?
                    .timeIntervalSince1970 else {
                    throw PushNotificationAPIError
                        .invalidResponse("history_created_at")
                }
                let sentAt = item.sentAt
                    .flatMap(PushServiceDate.parse)?
                    .timeIntervalSince1970
                let serverOpenedAt = item.openedAt
                    .flatMap(PushServiceDate.parse)?
                    .timeIntervalSince1970
                let openedAt = serverOpenedAt
                    ?? (
                        item.state == .opened
                            ? sentAt ?? createdAt
                            : nil
                    )
                if var existing = try DBNotificationRecord
                    .filter(
                        Column("remoteNotificationID")
                            == item.notificationID
                    )
                    .fetchOne(database) {
                    existingCount += 1
                    existing.assetSymbol = item.assetSymbol ?? existing.assetSymbol
                    existing.deliveredAt =
                        existing.deliveredAt ?? sentAt ?? createdAt
                    existing.openedAt =
                        existing.openedAt ?? openedAt
                    existing.readAt = existing.readAt ?? openedAt
                    if existing.titleText == nil || item.category == .admin {
                        existing.titleText = Self.bounded(
                            item.title ?? "",
                            limit: 500
                        )
                    }
                    if existing.bodyText == nil || item.category == .admin {
                        existing.bodyText = Self.bounded(
                            item.body ?? "",
                            limit: 2_000
                        )
                    }
                    try existing.update(database)
                    continue
                }

                let relatedTransactionID =
                    try Self.relatedTransactionID(
                        walletID: item.walletID,
                        networkID: item.networkID,
                        transactionHash: item.transactionHash,
                        database: database
                    )
                try DBNotificationRecord(
                    id: UUID().uuidString.lowercased(),
                    profileID: WalletDatabase.defaultProfileID,
                    category: item.category.rawValue,
                    titleKey: item.titleKey,
                    bodyKey: item.bodyKey,
                    argumentsJSON: Self.safeArguments(item.arguments),
                    relatedTransactionID: relatedTransactionID,
                    createdAt: createdAt,
                    readAt: openedAt,
                    deliveredAt: sentAt ?? createdAt,
                    remoteNotificationID: item.notificationID,
                    titleText: Self.bounded(
                        item.title ?? "",
                        limit: 500
                    ),
                    bodyText: Self.bounded(
                        item.body ?? "",
                        limit: 2_000
                    ),
                    walletID: item.walletID,
                    networkID: item.networkID,
                    transactionHash: item.transactionHash,
                    openedAt: openedAt,
                    assetSymbol: item.assetSymbol
                ).insert(database)
                insertedCount += 1
            }
            return PushNotificationHistoryPersistenceResult(
                insertedCount: insertedCount,
                existingCount: existingCount
            )
        }
    }

    func needsLocalizationBackfill() async throws -> Bool {
        try await database.pool.read { database in
            try Bool.fetchOne(database, sql: """
                SELECT NOT localizationBackfillCompleted FROM notificationProfiles WHERE profileID = ?
                """, arguments: [WalletDatabase.defaultProfileID]) ?? false
        }
    }

    func completeLocalizationBackfill() async throws {
        try await database.pool.write { database in
            try database.execute(sql: """
                UPDATE notificationProfiles SET localizationBackfillCompleted = 1 WHERE profileID = ?
                """, arguments: [WalletDatabase.defaultProfileID])
        }
    }

    func historyBackfillCursor() async throws -> String? {
        try await database.pool.read { database in
            try String.fetchOne(
                database,
                sql: """
                SELECT historyBackfillCursor
                FROM notificationProfiles
                WHERE profileID = ?
                """,
                arguments: [WalletDatabase.defaultProfileID]
            )
        }
    }

    func setHistoryBackfillCursor(
        _ cursor: String?
    ) async throws {
        try await database.pool.write { database in
            try database.execute(
                sql: """
                UPDATE notificationProfiles
                SET historyBackfillCursor = ?,
                    updatedAt = ?
                WHERE profileID = ?
                """,
                arguments: [
                    cursor,
                    Date().timeIntervalSince1970,
                    WalletDatabase.defaultProfileID
                ]
            )
        }
    }

    func pendingOpenAudits(
        dueAt: Date = Date(),
        limit: Int = 20
    ) async throws -> [DBNotificationOpenAuditRecord] {
        let boundedLimit = max(1, min(limit, 100))
        return try await database.pool.read { database in
            try DBNotificationOpenAuditRecord
                .filter(
                    Column("nextAttemptAt")
                        <= dueAt.timeIntervalSince1970
                )
                .order(
                    Column("nextAttemptAt"),
                    Column("createdAt")
                )
                .limit(boundedLimit)
                .fetchAll(database)
        }
    }

    func enqueueOpenAudit(
        notificationID: String,
        openedAt: Date = Date()
    ) async throws {
        guard UUID(uuidString: notificationID) != nil else {
            return
        }
        try await database.pool.write { database in
            try Self.enqueueOpenAudit(
                notificationID: notificationID,
                now: openedAt.timeIntervalSince1970,
                database: database
            )
        }
    }

    func nextOpenAuditDate() async throws -> Date? {
        try await database.pool.read { database in
            try Double.fetchOne(
                database,
                sql: """
                SELECT MIN(nextAttemptAt)
                FROM notificationOpenAudits
                """
            ).map(Date.init(timeIntervalSince1970:))
        }
    }

    func markOpenAuditSucceeded(
        notificationID: String
    ) async throws {
        try await database.pool.write { database in
            _ = try DBNotificationOpenAuditRecord.deleteOne(
                database,
                key: notificationID
            )
        }
    }

    func markOpenAuditFailed(
        notificationID: String,
        errorCode: String,
        attemptedAt: Date,
        retryAt: Date
    ) async throws {
        try await database.pool.write { database in
            try database.execute(
                sql: """
                UPDATE notificationOpenAudits
                SET attemptCount = attemptCount + 1,
                    lastAttemptAt = ?,
                    nextAttemptAt = ?,
                    lastErrorCode = ?
                WHERE notificationID = ?
                """,
                arguments: [
                    attemptedAt.timeIntervalSince1970,
                    retryAt.timeIntervalSince1970,
                    Self.sanitized(errorCode),
                    notificationID
                ]
            )
        }
    }

    func markOpened(notificationID: String) async throws {
        let now = Date().timeIntervalSince1970
        try await database.pool.write { database in
            try database.execute(
                sql: """
                UPDATE notifications
                SET openedAt = COALESCE(openedAt, ?),
                    readAt = COALESCE(readAt, ?)
                WHERE remoteNotificationID = ?
                """,
                arguments: [now, now, notificationID]
            )
        }
    }

    nonisolated private static func enqueueOpenAudit(
        notificationID: String,
        now: Double,
        database: Database
    ) throws {
        try database.execute(
            sql: """
            INSERT INTO notificationOpenAudits (
                notificationID,
                createdAt,
                attemptCount,
                lastAttemptAt,
                nextAttemptAt,
                lastErrorCode
            ) VALUES (?, ?, 0, NULL, ?, NULL)
            ON CONFLICT(notificationID) DO NOTHING
            """,
            arguments: [notificationID, now, now]
        )
    }

    private func relatedTransactionID(
        walletID: String?,
        networkID: String?,
        transactionHash: String?
    ) async throws -> String? {
        guard let walletID, let networkID, let transactionHash else {
            return nil
        }
        return try await database.pool.read { database in
            try NotificationTransactionStore.records(walletID: walletID, networkID: networkID,
                hash: transactionHash, in: database).first?.id
        }
    }

    nonisolated private static func relatedTransactionID(
        walletID: String?,
        networkID: String?,
        transactionHash: String?,
        database: Database
    ) throws -> String? {
        guard let walletID, let networkID, let transactionHash else {
            return nil
        }
        return try NotificationTransactionStore.records(walletID: walletID, networkID: networkID,
            hash: transactionHash, in: database).first?.id
    }

    nonisolated private static func safeArguments(
        _ values: [String]
    ) -> Data? {
        guard !values.isEmpty,
              JSONSerialization.isValidJSONObject(values) else {
            return nil
        }
        return try? JSONSerialization.data(withJSONObject: values)
    }

    nonisolated private static func bounded(
        _ value: String,
        limit: Int
    ) -> String? {
        guard !value.isEmpty else { return nil }
        return String(value.prefix(limit))
    }

    nonisolated private static func sanitized(
        _ value: String
    ) -> String {
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "_.-")
        )
        return String(
            value.unicodeScalars
                .filter(allowed.contains)
                .prefix(160)
                .map(Character.init)
        )
    }
}


extension WalletDatabase {
    static func registerNotificationLocalizationMigration(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v76_notification_asset_symbol") { database in
            try database.execute(sql: """
                ALTER TABLE notifications ADD COLUMN assetSymbol TEXT;
                ALTER TABLE notificationProfiles ADD COLUMN localizationBackfillCompleted INTEGER NOT NULL DEFAULT 0;
                UPDATE notificationProfiles SET historyBackfillCursor = NULL;
                UPDATE notifications
                SET assetSymbol = (
                    SELECT assetSymbol FROM transactions
                    WHERE transactions.id = notifications.relatedTransactionID
                );
                """)
        }
    }
}
