import Foundation
import GRDB
import Testing
@testable import Aperture

struct SendRecipientMemoMigrationTests {
    private typealias Fixtures = SendRecipientHistoryTestFixtures

    @Test
    func additiveV45UpgradePreservesAllOldRecipientsWithoutGuessingTheirMemos() async throws {
        let database = try WalletDatabase.temporary()
        var scopes: [SendRecipientHistoryScope] = []
        for networkID in ["eth", "xrp", "stellar", "ton", "solana"] {
            let asset = try Fixtures.asset(networkID: networkID)
            let scope = try await Fixtures.seed(database, asset: asset)
            scopes.append(scope)
            try await Fixtures.broadcast(in: database, asset: asset, hash: "legacy", memo: "123", date: 10)
        }
        // Construct the shipped v44 schema in this isolated test database.
        // Leave cached transactions (including XRP tag metadata) in place: the
        // migration must not infer routing from provider/cache history.
        try await database.pool.write { db in
            try db.execute(sql: """
                DROP INDEX sendRecipientBroadcasts_by_routing;
                ALTER TABLE sendRecipientBroadcasts DROP COLUMN memoRecorded;
                ALTER TABLE sendRecipientBroadcasts DROP COLUMN networkMemo;
                DELETE FROM grdb_migrations WHERE identifier = 'v45_app_send_recipient_memos';
                """)
        }
        try WalletDatabase.migrator.migrate(database.pool)
        #expect(try await database.pool.read { try DBSendRecipientBroadcastRecord.fetchCount($0) } == 5)
        #expect(try await database.pool.read { try DBTransactionRecord.fetchCount($0) } == 5)
        #expect(try await database.pool.read { try DBWalletAccountRecord.fetchCount($0) } == 5)
        for scope in scopes {
            let snapshot = try await database.sendRecipientHistorySnapshot(scope: scope)
            let legacy = try #require(snapshot.recentRecipients.first)
            #expect(legacy.sendCount == 1)
            #expect(legacy.lastSentAt == Date(timeIntervalSince1970: 10))
            #expect(legacy.networkMemo == nil)
            #expect(legacy.id.memoRecorded == (scope.networkID == "eth"))
            #expect(snapshot.assessment(address: legacy.address, networkID: scope.networkID)
                == (scope.networkID == "eth" ? .previouslySent(count: 1) : .newRecipient))
        }

        let xrp = try Fixtures.asset(networkID: "xrp")
        let scope = try #require(scopes.first { $0.networkID == "xrp" })
        // A new known-no-tag send must not merge with an old unknown-tag send.
        try await Fixtures.broadcast(in: database, asset: xrp, hash: "new-no-tag", date: 20)
        #expect(try await database.sendRecipientHistorySnapshot(scope: scope).recentRecipients.count == 2)

        // Only an accepted callback carrying the original request can fill the
        // legacy memo, once, without adding a broadcast or changing its date.
        try await Fixtures.broadcast(in: database, asset: xrp, hash: "legacy", memo: "123", date: 30)
        try await Fixtures.broadcast(in: database, asset: xrp, hash: "legacy", memo: "123", date: 40)
        let upgraded = try await database.sendRecipientHistorySnapshot(scope: scope)
        let known = try #require(upgraded.recentRecipients.first { $0.networkMemo == "123" })
        #expect(known.sendCount == 1)
        #expect(known.lastSentAt == Date(timeIntervalSince1970: 10))
        #expect(upgraded.recentRecipients.allSatisfy { $0.id.memoRecorded })
        #expect(upgraded.assessment(address: known.address, networkID: "xrp", memo: "123") == .previouslySent(count: 1))
        #expect(upgraded.assessment(address: known.address, networkID: "xrp") == .previouslySent(count: 1))
        #expect(try await database.pool.read { try DBSendRecipientBroadcastRecord.fetchCount($0) } == 6)
        #expect(try await database.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM pragma_foreign_key_check") } == 0)
    }
}
