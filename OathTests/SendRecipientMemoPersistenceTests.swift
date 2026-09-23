import Foundation
import GRDB
import Testing
@testable import Aperture

/// Exercises the production receipt write, GRDB query and on-disk reopening.
/// Receipts are fixtures with public mainnet addresses; no funds are broadcast.
@Suite("App broadcast recipient routing persistence")
struct SendRecipientMemoPersistenceTests {
    private typealias Fixtures = SendRecipientHistoryTestFixtures

    @Test(arguments: ["xrp", "stellar", "ton", "solana"])
    func successfulBroadcastsStoreAndCountEachExactRoutingSeparately(networkID: String) async throws {
        let database = try WalletDatabase.temporary()
        let asset = try Fixtures.asset(networkID: networkID)
        let scope = try await Fixtures.seed(database, asset: asset)
        let address = SendEntryTestFixtures.address(for: asset.blockchain)
        for (hash, memo, date) in [("one", "123", 10.0), ("two", "123", 20.0), ("other", "456", 30.0)] {
            try await Fixtures.broadcast(in: database, asset: asset, hash: hash, memo: memo, date: date)
        }
        try await Fixtures.broadcast(in: database, asset: asset, hash: "no-memo", date: 40)
        try await Fixtures.broadcast(in: database, asset: asset, hash: "unknown", memo: "789", outcome: .outcomeUnknown)
        try await Fixtures.broadcast(in: database, asset: asset, hash: "failed", memo: "789", outcome: .executionFailed)
        // Provider-imported activity must never add memo familiarity.
        try await Fixtures.save([Fixtures.transaction(hash: "api", scope: scope, address: address)], in: database)

        let snapshot = try await database.sendRecipientHistorySnapshot(scope: scope)
        #expect(snapshot.recentRecipients.count == 3)
        #expect(snapshot.recentRecipients.map(\.networkMemo) == [nil, "456", "123"])
        #expect(snapshot.recentRecipients.allSatisfy { $0.address == address && $0.id.memoRecorded })
        #expect(snapshot.assessment(address: address, networkID: networkID, memo: "123") == .previouslySent(count: 2))
        #expect(snapshot.assessment(address: address, networkID: networkID, memo: "456") == .previouslySent(count: 1))
        #expect(snapshot.assessment(address: address, networkID: networkID) == .previouslySent(count: 1))
        #expect(snapshot.assessment(address: address, networkID: networkID, memo: "789") == .newRecipient)
        let records = try await database.pool.read { try DBSendRecipientBroadcastRecord.fetchAll($0) }
        #expect(records.count == 4)
        #expect(records.allSatisfy { $0.memoRecorded })
    }

    @Test(arguments: ["stellar", "solana", "ton"])
    func unicodeMemoBytesSurviveSQLiteGroupingAndDecoding(networkID: String) async throws {
        let database = try WalletDatabase.temporary()
        let asset = try Fixtures.asset(networkID: networkID)
        let scope = try await Fixtures.seed(database, asset: asset)
        let values = ["Café", "Cafe\u{301}"]
        for (index, value) in values.enumerated() {
            try await Fixtures.broadcast(in: database, asset: asset, memo: value, date: Double(index))
        }
        let snapshot = try await database.sendRecipientHistorySnapshot(scope: scope)
        #expect(snapshot.recentRecipients.count == 2)
        #expect(Set(snapshot.recentRecipients.compactMap { $0.networkMemo.map { Data($0.utf8) } })
            == Set(values.map { Data($0.utf8) }))
        #expect(snapshot.recentRecipients.allSatisfy { $0.sendCount == 1 })
    }

    @Test
    func xAddressStoresEmbeddedTagEvenWhenReceiptContainsOnlyClassicAddress() async throws {
        let database = try WalletDatabase.temporary()
        let asset = try Fixtures.asset(networkID: "xrp")
        let scope = try await Fixtures.seed(database, asset: asset)
        let classic = SendEntryTestFixtures.address(for: .xrp)
        let xAddress = "X76UnYEMbQfEs3mUqgtjp4zFy9exgThRj7XVZ6UxsdrBptF"
        let receipt = Fixtures.receipt(asset: asset, hash: "embedded-tag", address: classic)
        try await database.recordSubmittedSend(
            receipt: receipt, draft: SendEntryTestFixtures.draft(asset: asset, recipient: xAddress), outcome: .accepted
        )
        let snapshot = try await database.sendRecipientHistorySnapshot(scope: scope)
        #expect(snapshot.recentRecipients.first?.address == classic)
        #expect(snapshot.recentRecipients.first?.networkMemo == "12345")
        #expect(snapshot.assessment(address: classic, networkID: "xrp", memo: "12345") == .previouslySent(count: 1))
        #expect(snapshot.assessment(address: xAddress, networkID: "xrp") == .previouslySent(count: 1))
        #expect(snapshot.assessment(address: classic, networkID: "xrp") == .newRecipient)
    }

    @Test(arguments: ["xrp", "stellar", "ton", "solana"])
    func duplicateCallbacksAreIdempotentButCannotOverwriteAcceptedMemo(networkID: String) async throws {
        let database = try WalletDatabase.temporary()
        let asset = try Fixtures.asset(networkID: networkID)
        let scope = try await Fixtures.seed(database, asset: asset)
        let transactionID = try await Fixtures.broadcast(in: database, asset: asset, hash: "same", memo: "42", date: 1)
        try await withThrowingTaskGroup(of: String.self) { group in
            for index in 0..<8 {
                group.addTask {
                    try await Fixtures.broadcast(in: database, asset: asset, hash: "same", memo: "42", date: Double(index + 2))
                }
            }
            for try await _ in group {}
        }
        await #expect(throws: WalletDataStoreError.self) {
            try await Fixtures.broadcast(in: database, asset: asset, hash: "same", memo: "99", date: 100)
        }
        let snapshot = try await database.sendRecipientHistorySnapshot(scope: scope)
        #expect(snapshot.recentRecipients.count == 1)
        #expect(snapshot.recentRecipients.first?.sendCount == 1)
        #expect(snapshot.recentRecipients.first?.networkMemo == "42")
        #expect(snapshot.recentRecipients.first?.lastSentAt == Date(timeIntervalSince1970: 1))
        let transaction = try await database.pool.read { try DBTransactionRecord.fetchOne($0, key: transactionID) }
        #expect(transaction?.updatedAt != 100) // Failed inconsistent callback rolled back its receipt write.
    }

    @Test
    func duplicateXRPCallbackAcceptsEquivalentTagTextAndKeepsZeroDistinctFromNoTag() async throws {
        let database = try WalletDatabase.temporary()
        let asset = try Fixtures.asset(networkID: "xrp")
        let scope = try await Fixtures.seed(database, asset: asset)
        try await Fixtures.broadcast(in: database, asset: asset, hash: "zero", memo: "0000000000")
        try await Fixtures.broadcast(in: database, asset: asset, hash: "zero", memo: "0")
        try await Fixtures.broadcast(in: database, asset: asset, hash: "none")
        let snapshot = try await database.sendRecipientHistorySnapshot(scope: scope)
        #expect(snapshot.recentRecipients.count == 2)
        #expect(snapshot.recentRecipients.allSatisfy { $0.sendCount == 1 })
        #expect(Set(snapshot.recentRecipients.map(\.networkMemo)) == Set([nil, "0"]))
    }

    @Test
    func localNoteNeverBecomesRoutingMemoAndOtherWalletsDoNotAffectCounts() async throws {
        let database = try WalletDatabase.temporary()
        let asset = try Fixtures.asset(networkID: "stellar")
        let scope = try await Fixtures.seed(database, asset: asset)
        _ = try await Fixtures.seed(database, asset: asset, walletID: "other", selected: false)
        let receipt = Fixtures.receipt(asset: asset)
        let draft = SendDraft(
            request: .manualEntry(networkID: "stellar").replacingMemo("Deposit-123"),
            asset: asset, recipient: receipt.toAddress, amount: "1", note: "Local note only"
        )
        let transactionID = try await database.recordSubmittedSend(receipt: receipt, draft: draft, outcome: .accepted)
        try await Fixtures.broadcast(in: database, asset: asset, walletID: "other", memo: "Deposit-123")
        let snapshot = try await database.sendRecipientHistorySnapshot(scope: scope)
        #expect(snapshot.recentRecipients.first?.networkMemo == "Deposit-123")
        #expect(snapshot.recentRecipients.first?.sendCount == 1)
        let note = try await database.pool.read { try DBTransactionNoteRecord.fetchOne($0, key: transactionID) }
        #expect(note?.note == "Local note only")
    }

    @Test(arguments: ["xrp", "stellar", "ton", "solana"])
    func savedMemoSurvivesAppReopenAndActivityCachePruning(networkID: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try WalletDatabase.applicationDatabase(at: directory)
        let asset = try Fixtures.asset(networkID: networkID)
        let scope = try await Fixtures.seed(database, asset: asset)
        try await Fixtures.broadcast(in: database, asset: asset, memo: "123")
        try await database.pool.write { db in try db.execute(sql: "DELETE FROM transactions") }
        try database.pool.close()
        let reopened = try WalletDatabase.applicationDatabase(at: directory)
        defer { try? reopened.pool.close() }
        let saved = try #require(try await reopened.sendRecipientHistorySnapshot(scope: scope).recentRecipients.first)
        #expect(saved.networkMemo == "123")
        #expect(saved.id.memoRecorded)
        #expect(saved.sendCount == 1)
    }

    @Test
    func invalidOrMismatchedRoutingRollsBackWithoutSavingAFamiliarRecipient() async throws {
        let database = try WalletDatabase.temporary()
        let asset = try Fixtures.asset(networkID: "xrp")
        let scope = try await Fixtures.seed(database, asset: asset)
        let receipt = Fixtures.receipt(asset: asset)
        let drafts = [
            SendEntryTestFixtures.draft(asset: asset, memo: "4294967296"),
            SendEntryTestFixtures.draft(asset: asset, recipient: "rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh", memo: "42"),
            SendEntryTestFixtures.draft(asset: asset, recipient: "X76UnYEMbQfEs3mUqgtjp4zFy9exgThRj7XVZ6UxsdrBptF", memo: "9")
        ]
        for draft in drafts {
            await #expect(throws: WalletDataStoreError.self) {
                try await database.recordSubmittedSend(receipt: receipt, draft: draft, outcome: .accepted)
            }
        }
        #expect(try await database.sendRecipientHistorySnapshot(scope: scope).recentRecipients.isEmpty)
        #expect(try await database.pool.read { try DBTransactionRecord.fetchCount($0) } == 0)
    }

    @Test
    func noncanonicalMemoDataFailsClosedInsteadOfShowingAFamiliarAddress() async throws {
        let database = try WalletDatabase.temporary()
        let asset = try Fixtures.asset(networkID: "xrp")
        let scope = try await Fixtures.seed(database, asset: asset)
        try await Fixtures.broadcast(in: database, asset: asset, memo: "42")
        try await database.pool.write { db in
            try db.execute(sql: "UPDATE sendRecipientBroadcasts SET networkMemo = '00042'")
        }
        await #expect(throws: DatabaseError.self) {
            try await database.sendRecipientHistorySnapshot(scope: scope)
        }
    }
}
