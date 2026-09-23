import Foundation
import GRDB
import Testing
@testable import Aperture

struct PushNotificationHistoryTests {
    @Test
    @MainActor
    func openAuditOutboxIsDurableAndIdempotent() async throws {
        let database = try WalletDatabase.temporary()
        let persistence =
            PushNotificationPersistence(database: database)
        let notificationID =
            "307257a4-2965-48d5-9338-8f241537ea38"
        let openedAt = Date(timeIntervalSince1970: 2_000_000_000)

        try await persistence.enqueueOpenAudit(
            notificationID: notificationID,
            openedAt: openedAt
        )
        try await persistence.enqueueOpenAudit(
            notificationID: notificationID,
            openedAt: openedAt
        )
        var pending = try await persistence.pendingOpenAudits(
            dueAt: openedAt
        )
        #expect(pending.count == 1)
        #expect(pending.first?.attemptCount == 0)

        let retryAt = openedAt.addingTimeInterval(60)
        try await persistence.markOpenAuditFailed(
            notificationID: notificationID,
            errorCode: "transport_timeout",
            attemptedAt: openedAt,
            retryAt: retryAt
        )
        pending = try await persistence.pendingOpenAudits(
            dueAt: retryAt
        )
        #expect(pending.first?.attemptCount == 1)
        #expect(
            pending.first?.lastErrorCode == "transport_timeout"
        )

        try await persistence.markOpenAuditSucceeded(
            notificationID: notificationID
        )
        #expect(
            try await persistence.pendingOpenAudits(
                dueAt: .distantFuture
            ).isEmpty
        )

        try await persistence.enqueueOpenAudit(
            notificationID: notificationID,
            openedAt: openedAt
        )
        try await database.eraseAllData()
        #expect(
            try await persistence.pendingOpenAudits(
                dueAt: .distantFuture
            ).isEmpty
        )
    }

    @Test
    @MainActor
    func serverHistoryBackfillIsDurableAndIdempotent()
        async throws {
        let database = try WalletDatabase.temporary()
        let identity = PushInstallationIdentity(
            installationID:
                "fd20cbaf-6d71-41b7-8442-c244381d7696",
            credential: Data(repeating: 4, count: 32),
            apnsToken: Data(repeating: 5, count: 32),
            remoteUserID:
                "458ffbf9-8ce5-4601-a17d-c0cc8bfa2546"
        )
        _ = try await PushNotificationRegistrationRepository(
            database: database
        ).snapshot(
            identity: identity,
            apnsEnvironment: "sandbox"
        )
        let persistence =
            PushNotificationPersistence(database: database)
        let items = [
            PushNotificationHistoryItem(
                notificationID:
                    "5e68243f-74f3-4332-a45d-51ab03862364",
                category: .received,
                state: .sent,
                titleKey: "notification.received.title",
                bodyKey: "notification.received.body.priced",
                arguments: [
                    "1.25",
                    "ETH",
                    "EUR 1.15",
                    "Ethereum"
                ],
                title: nil,
                body: nil,
                walletID: "wallet-1",
                networkID: "eth",
                transactionHash: "0xabc",
                assetSymbol: "ETH",
                createdAt: "2026-07-26T00:00:00.000Z",
                sentAt: "2026-07-26T00:00:01.000Z",
                openedAt: nil
            ),
            PushNotificationHistoryItem(
                notificationID:
                    "a3665e5d-1e05-4447-9d6e-e332064324a2",
                category: .admin,
                state: .opened,
                titleKey: "notification.generic.title",
                bodyKey: "notification.generic.body",
                arguments: [],
                title: "Maintenance",
                body: "Service restored",
                walletID: nil,
                networkID: nil,
                transactionHash: nil,
                assetSymbol: nil,
                createdAt: "2026-07-26T00:00:02.000Z",
                sentAt: "2026-07-26T00:00:03.000Z",
                openedAt: "2026-07-26T00:00:04.000Z"
            )
        ]

        let first = try await persistence.record(
            historyItems: items
        )
        let second = try await persistence.record(
            historyItems: items
        )
        try await persistence.setHistoryBackfillCursor(
            "history_cursor"
        )

        #expect(first.insertedCount == 2)
        #expect(first.existingCount == 0)
        #expect(second.insertedCount == 0)
        #expect(second.existingCount == 2)
        #expect(
            try await persistence.historyBackfillCursor()
                == "history_cursor"
        )
        let records = try await database.pool.read { database in
            try DBNotificationRecord
                .order(Column("createdAt"))
                .fetchAll(database)
        }
        #expect(records.count == 2)
        #expect(records.first?.titleText == nil)
        let receivedRecord = try #require(records.first)
        let receivedContent = PushNotificationContentFormatter.content(
            for: receivedRecord
        )
        #expect(
            receivedContent.title
                == EnglishNumbers.localized(
                    "notification.received.title.compact",
                    "ETH"
                )
        )
        #expect(
            receivedContent.body
                == EnglishNumbers.localized(
                    "notification.received.body.priced",
                    "1.25",
                    "ETH",
                    "EUR 1.15",
                    "Ethereum"
                )
        )
        #expect(!receivedContent.title.contains("%@"))
        #expect(!receivedContent.body.contains("%@"))
        #expect(records.last?.titleText == "Maintenance")
        #expect(records.last?.bodyText == "Service restored")
        #expect(records.last?.openedAt != nil)
        #expect(records.last?.readAt != nil)
    }

    @Test
    func invalidTransactionHistoryArgumentsUseGenericCopy() throws {
        let invalidArguments = try JSONSerialization.data(
            withJSONObject: ["1.25", "ETH"]
        )
        let record = DBNotificationRecord(
            id: "notification-display-test",
            profileID: WalletDatabase.defaultProfileID,
            category: PushNotificationCategory.received.rawValue,
            titleKey: "notification.received.title",
            bodyKey: "notification.received.body",
            argumentsJSON: invalidArguments,
            relatedTransactionID: nil,
            createdAt: 0,
            readAt: nil,
            deliveredAt: 0,
            remoteNotificationID:
                "628d9f45-ce69-4f5d-aa18-50371ea19d0c",
            titleText: nil,
            bodyText: nil,
            walletID: nil,
            networkID: nil,
            transactionHash: nil,
            openedAt: nil
        )

        let content = PushNotificationContentFormatter.content(for: record)

        #expect(
            content.title
                == WalletLocalization.string("notification.generic.title")
        )
        #expect(
            content.body
                == WalletLocalization.string("notification.generic.body")
        )
        #expect(!content.title.contains("%@"))
        #expect(!content.body.contains("%@"))
    }

}
