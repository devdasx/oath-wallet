import Foundation
import GRDB
import Testing
@testable import Aperture

/// Real GRDB migrations, accepted-receipt writes and observations. Public
/// mainnet addresses are fixtures only; these tests never sign or send funds.
@Suite("App-only sent recipient persistence")
struct SendRecipientBroadcastPersistenceTests {
    private typealias Fixtures = SendRecipientHistoryTestFixtures

    @Test
    func duplicateAndConcurrentCallbacksCountOnceWithoutChangingRecency() async throws {
        let database = try WalletDatabase.temporary()
        let scope = try await Fixtures.seed(database)
        try await Fixtures.broadcast(in: database, hash: "0xabc123", date: 10)
        try await withThrowingTaskGroup(of: String.self) { group in
            for index in 0..<12 {
                group.addTask {
                    try await Fixtures.broadcast(
                        in: database, hash: "0xABC123", date: Double(20 + index)
                    )
                }
            }
            for try await _ in group {}
        }
        let snapshot = try await database.sendRecipientHistorySnapshot(scope: scope)
        #expect(snapshot.recentRecipients.first?.sendCount == 1)
        #expect(snapshot.recentRecipients.first?.lastSentAt == Date(timeIntervalSince1970: 10))
        #expect(try await database.pool.read { try DBSendRecipientBroadcastRecord.fetchCount($0) } == 1)
    }

    @Test(arguments: ["eth", "bitcoin", "bitcoin_cash", "ton", "xrp", "sui", "aptos"])
    func equivalentAddressEncodingsShareOneRecipientAndDeduplicateOneBroadcast(networkID: String) async throws {
        let network = try #require(AssetNetworkSelectorOption.allSupported.first { $0.id == networkID })
        let asset = try SendEntryTestFixtures.nativeChoice(for: network)
        let standard = SendEntryTestFixtures.address(for: network.blockchain)
        let original: String
        let alias: String
        switch networkID {
        case "eth":
            original = Fixtures.recipient
            alias = original.lowercased()
        case "bitcoin":
            original = standard
            alias = standard.uppercased()
        case "bitcoin_cash":
            original = standard
            alias = "1BpEi6DfDAUFd7GtittLSdBeYJvcoaVggu"
        case "ton":
            original = standard
            alias = try #require(TONAddress.rawAddress(from: standard))
        case "xrp":
            original = try #require(XRPAddress.signingDestination(classicAddress: standard, destinationTag: 0))
            alias = standard
        case "sui":
            original = "0x2"
            alias = "0x" + String(repeating: "0", count: 63) + "2"
        default:
            original = "0x1"
            alias = "0x" + String(repeating: "0", count: 63) + "1"
        }
        let database = try WalletDatabase.temporary()
        let scope = try await Fixtures.seed(database, asset: asset)
        let memo: String? = networkID == "xrp" ? "0" : nil
        try await Fixtures.broadcast(in: database, asset: asset, hash: "same-transfer", address: original, memo: memo, date: 1)
        try await Fixtures.broadcast(in: database, asset: asset, hash: "same-transfer", address: alias, memo: memo, date: 2)
        let deduplicated = try await database.sendRecipientHistorySnapshot(scope: scope)
        #expect(deduplicated.assessment(address: alias, networkID: networkID, memo: memo) == .previouslySent(count: 1))
        #expect(deduplicated.recentRecipients.first?.lastSentAt == Date(timeIntervalSince1970: 1))
        if networkID == "xrp" {
            // Canonical account and its explicit tag are saved together, even
            // when the original payment used a tag-zero X-address.
            #expect(deduplicated.recentRecipients.first?.address == standard)
            #expect(deduplicated.recentRecipients.first?.networkMemo == "0")
        }
        try await Fixtures.broadcast(in: database, asset: asset, hash: "next-transfer", address: alias, memo: memo, date: 3)
        let snapshot = try await database.sendRecipientHistorySnapshot(scope: scope)
        #expect(snapshot.recentRecipients.count == 1)
        #expect(snapshot.assessment(address: original, networkID: networkID, memo: memo) == .previouslySent(count: 2))
    }

    @Test
    func acceptedSilentPaymentPersistsCompleteLocalTransactionAndRecipientHistory() async throws {
        let address =
            "sp1qqgste7k9hx0qftg6qmwlkqtwuy6cycyavzmzj85c6qdfhjdpdjtdgqjuex"
            + "zk6murw56suy3e0rd2cgqvycxttddwsvgxe2usfpxumr70xc9pkqwv"
        let asset = try Fixtures.asset(
            networkID: BitcoinFamilyChain.bitcoin.networkID
        )
        let database = try WalletDatabase.temporary()
        let scope = try await Fixtures.seed(database, asset: asset)

        let transactionID = try await Fixtures.broadcast(
            in: database,
            asset: asset,
            hash: "silent-payment-transaction",
            address: address
        )

        let records = try await database.pool.read { database in
            (
                try DBTransactionRecord.fetchOne(
                    database,
                    key: transactionID
                ),
                try DBTransactionTransferRecord.fetchOne(
                    database,
                    key: "\(transactionID)|primary"
                ),
                try DBSendRecipientBroadcastRecord.fetchAll(database)
            )
        }
        let transaction = try #require(records.0)
        let transfer = try #require(records.1)
        #expect(records.2.count == 1)
        let recipient = try #require(records.2.first)
        let history = try await database.sendRecipientHistorySnapshot(
            scope: scope
        )

        #expect(transaction.toAddress == address)
        #expect(transfer.toAddress == address)
        #expect(recipient.recipientAddress == address)
        #expect(recipient.recipientIdentity == "silent-payment:\(address)")
        #expect(
            history.assessment(
                address: address,
                networkID: BitcoinFamilyChain.bitcoin.networkID
            ) == .previouslySent(count: 1)
        )
    }

    @Test(arguments: ["solana", "sui", "near"])
    func base58TransactionHashesRemainCaseSensitive(networkID: String) async throws {
        let network = try #require(AssetNetworkSelectorOption.allSupported.first { $0.id == networkID })
        let asset = try SendEntryTestFixtures.nativeChoice(for: network)
        let database = try WalletDatabase.temporary()
        let scope = try await Fixtures.seed(database, asset: asset)
        try await Fixtures.broadcast(in: database, asset: asset, hash: "AbC123")
        try await Fixtures.broadcast(in: database, asset: asset, hash: "abc123")
        #expect(try await database.sendRecipientHistorySnapshot(scope: scope).recentRecipients.first?.sendCount == 2)
    }

    @Test
    func uncertainSubmissionIsNotPromotedByAPIHistoryButAnAcceptedCallbackIsCountedOnce() async throws {
        let database = try WalletDatabase.temporary()
        let scope = try await Fixtures.seed(database)
        let transactionID = try await Fixtures.broadcast(in: database, hash: "uncertain", outcome: .outcomeUnknown)
        try await Fixtures.save([
            Fixtures.transaction(id: transactionID, hash: "uncertain", status: "confirmed")
        ], in: database)
        #expect(try await database.sendRecipientHistorySnapshot(scope: scope).recentRecipients.isEmpty)
        try await Fixtures.broadcast(in: database, hash: "uncertain", outcome: .accepted)
        try await Fixtures.broadcast(in: database, hash: "uncertain", outcome: .accepted)
        try await Fixtures.broadcast(in: database, hash: "execution-failed", outcome: .executionFailed)
        #expect(try await database.sendRecipientHistorySnapshot(scope: scope).recentRecipients.first?.sendCount == 1)
    }

    @Test
    func nativeAndUnpricedTokenSendsShareNetworkRecipientsWithoutUsingProviderTokenHistory() async throws {
        let database = try WalletDatabase.temporary()
        let scope = try await Fixtures.seed(database)
        let contract = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"
        let token = SendAssetChoice(
            id: AssetIdentityKey.make(networkID: "eth", contractAddress: contract),
            name: "USD Coin", symbol: "USDC", networkID: "eth", networkName: "Ethereum",
            blockchain: .ethereum, contractAddress: contract, decimals: 6,
            logoSource: .unavailable, networkLogoSource: .network(blockchain: .ethereum),
            balance: 100, fiatValue: 0, balanceAtomic: "100000000",
            sourceAddress: SendEntryTestFixtures.ethereum.sourceAddress
        )
        _ = try await Fixtures.seed(database, asset: token)
        try await Fixtures.broadcast(in: database, hash: "native")
        try await Fixtures.broadcast(in: database, asset: token, hash: "token")
        try await Fixtures.save([
            Fixtures.transaction(hash: "api-token", assetID: token.id, usdValue: "1000")
        ], in: database)
        let snapshot = try await database.sendRecipientHistorySnapshot(scope: scope)
        #expect(snapshot.recentRecipients.count == 1)
        #expect(snapshot.assessment(address: Fixtures.recipient, networkID: "eth") == .previouslySent(count: 2))
    }

    @Test(arguments: ["12.5", "0.000000000000001", "1234567890123456"])
    func issuedXRPDecimalReceiptsRecordRecipientsWithoutLosingTheReceipt(amount: String) async throws {
        let database = try WalletDatabase.temporary()
        let asset = issuedXRPAsset
        let scope = try await Fixtures.seed(database, asset: asset)
        let canonical = try XRPAmount.canonicalIssuedPayment(amount)
        // Mirrors SendXRPTransactionService: issued-currency receipts use the
        // same exact decimal text for amount and amountAtomic, unlike drops.
        let receipt = Fixtures.receipt(asset: asset, amount: canonical, amountAtomic: canonical)
        let transactionID = try await database.recordSubmittedSend(
            receipt: receipt,
            draft: SendEntryTestFixtures.draft(asset: asset, amount: canonical, memo: "512"),
            outcome: .accepted
        )
        let snapshot = try await database.sendRecipientHistorySnapshot(scope: scope)
        #expect(snapshot.assessment(address: receipt.toAddress, networkID: asset.networkID, memo: "512") == .previouslySent(count: 1))
        #expect(snapshot.recentRecipients.first?.networkMemo == "512")
        let transfer = try await database.pool.read { db in
            try DBTransactionTransferRecord.fetchOne(db, key: "\(transactionID)|primary")
        }
        #expect(transfer?.amount == canonical)
        #expect(transfer?.amountAtomic == canonical)
    }

    @Test(arguments: ["0", "0.000", "-0.01", "1e2", "١.٥", "１２.５", "1\u{FE0F}", "12.5text", "1.2.3"])
    func invalidIssuedXRPAmountsCannotEstablishAPreviousSend(amount: String) async throws {
        let database = try WalletDatabase.temporary()
        let asset = issuedXRPAsset
        _ = try await Fixtures.seed(database, asset: asset)
        await #expect(throws: WalletDataStoreError.self) {
            try await database.recordSubmittedSend(
                receipt: Fixtures.receipt(asset: asset, amount: amount, amountAtomic: amount),
                draft: SendEntryTestFixtures.draft(asset: asset), outcome: .accepted
            )
        }
        #expect(try await database.pool.read { try DBSendRecipientBroadcastRecord.fetchCount($0) } == 0)
        #expect(try await database.pool.read { try DBTransactionRecord.fetchCount($0) } == 0)
    }

    private var issuedXRPAsset: SendAssetChoice {
        let contract = "524C555344000000000000000000000000000000:rMxCKbEDwqr76QuheSUMdEGf4B9xJ8m5De"
        return SendAssetChoice(
            id: AssetIdentityKey.make(networkID: XRPConstants.networkID, contractAddress: contract),
            name: "Ripple USD", symbol: "RLUSD", networkID: XRPConstants.networkID, networkName: "XRP",
            blockchain: .xrp, contractAddress: contract, decimals: 15,
            logoSource: .unavailable, networkLogoSource: .network(blockchain: .xrp),
            balance: 100, fiatValue: 0, balanceAtomic: nil,
            sourceAddress: SendEntryTestFixtures.address(for: .xrp)
        )
    }

    @Test
    func persistenceSurvivesAppReopenActivityPruningAndAccountDisablement() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try WalletDatabase.applicationDatabase(at: directory)
        let scope = try await Fixtures.seed(database)
        try await Fixtures.broadcast(in: database)
        try await database.pool.write { db in
            try db.execute(sql: "DELETE FROM transactions")
            try db.execute(sql: "DELETE FROM assets WHERE id = ?", arguments: [SendEntryTestFixtures.ethereum.id])
            try db.execute(sql: "UPDATE walletAccounts SET isEnabled = 0 WHERE walletID = ?", arguments: [scope.walletID])
        }
        try database.pool.close()
        let reopened = try WalletDatabase.applicationDatabase(at: directory)
        defer { try? reopened.pool.close() }
        let snapshot = try await reopened.sendRecipientHistorySnapshot(scope: scope)
        #expect(snapshot.assessment(address: Fixtures.recipient, networkID: "eth") == .previouslySent(count: 1))
        #expect(try await reopened.pool.read { try DBTransactionRecord.fetchCount($0) } == 0)
    }

    @Test
    func additiveUpgradePreservesHistoryAndDoesNotBackfillUnprovenAppSends() async throws {
        let database = try WalletDatabase.temporary()
        let scope = try await Fixtures.seed(database)
        try await Fixtures.save([Fixtures.transaction(hash: "provider-history")], in: database)
        try await Fixtures.broadcast(in: database, hash: "old-pending", outcome: .outcomeUnknown)
        // Restore this isolated fixture's pre-v44 schema shape, then run the
        // production migrator exactly as an app upgrade does.
        try await database.pool.write { db in
            try db.execute(sql: "DROP TABLE sendRecipientBroadcasts")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v44_app_send_recipient_broadcasts'")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v45_app_send_recipient_memos'")
        }
        try WalletDatabase.migrator.migrate(database.pool)
        let counts = try await database.pool.read { db in
            (try DBWalletRecord.fetchCount(db), try DBTransactionRecord.fetchCount(db),
             try DBSendRecipientBroadcastRecord.fetchCount(db),
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pragma_foreign_key_check"))
        }
        #expect(counts.0 == 1)
        #expect(counts.1 == 2)
        #expect(counts.2 == 0)
        #expect(counts.3 == 0)
        #expect(try await database.sendRecipientHistorySnapshot(scope: scope).recentRecipients.isEmpty)
        try await Fixtures.broadcast(in: database, hash: "new-accepted")
        #expect(try await database.sendRecipientHistorySnapshot(scope: scope).recentRecipients.first?.sendCount == 1)
    }

    @Test
    func recipientWriteFailureRollsBackTheReceiptAndPreservesTheDatabaseError() async throws {
        let database = try WalletDatabase.temporary()
        _ = try await Fixtures.seed(database)
        try await database.pool.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_recipient_write BEFORE INSERT ON sendRecipientBroadcasts
                BEGIN SELECT RAISE(ABORT, 'test_recipient_write_failure'); END
                """)
        }
        await #expect(throws: DatabaseError.self) {
            try await Fixtures.broadcast(in: database)
        }
        let counts = try await database.pool.read { db in
            (try DBTransactionRecord.fetchCount(db), try DBTransactionTransferRecord.fetchCount(db),
             try DBSendRecipientBroadcastRecord.fetchCount(db))
        }
        #expect(counts.0 == 0)
        #expect(counts.1 == 0)
        #expect(counts.2 == 0)
    }

    @Test(arguments: ["0", "", "-1", "1.5", "١", "１２", "1e18"])
    func invalidOrZeroAmountsCannotEstablishAPreviousSend(amountAtomic: String) async throws {
        let database = try WalletDatabase.temporary()
        _ = try await Fixtures.seed(database)
        let receipt = Fixtures.receipt(amountAtomic: amountAtomic)
        await #expect(throws: WalletDataStoreError.self) {
            try await database.recordSubmittedSend(
                receipt: receipt, draft: SendEntryTestFixtures.draft(), outcome: .accepted
            )
        }
        #expect(try await database.pool.read { try DBSendRecipientBroadcastRecord.fetchCount($0) } == 0)
        #expect(try await database.pool.read { try DBTransactionRecord.fetchCount($0) } == 0)
    }

    @Test
    func invalidRecipientAndMissingHashCannotEstablishAPreviousSend() async throws {
        let database = try WalletDatabase.temporary()
        _ = try await Fixtures.seed(database)
        for receipt in [Fixtures.receipt(address: "not-an-address"), Fixtures.receipt(hash: "  \n ")] {
            await #expect(throws: WalletDataStoreError.self) {
                try await database.recordSubmittedSend(
                    receipt: receipt, draft: SendEntryTestFixtures.draft(), outcome: .accepted
                )
            }
        }
        #expect(try await database.pool.read { try DBSendRecipientBroadcastRecord.fetchCount($0) } == 0)
    }

    @Test
    func walletDeletionAndAppResetRemoveRecipientsWithoutOrphans() async throws {
        let database = try WalletDatabase.temporary()
        _ = try await Fixtures.seed(database)
        _ = try await Fixtures.seed(database, walletID: "other-wallet", selected: false)
        try await Fixtures.broadcast(in: database)
        try await Fixtures.broadcast(in: database, walletID: "other-wallet")
        _ = try await database.pool.write { db in
            try DBWalletRecord.deleteOne(db, key: Fixtures.walletID)
        }
        let remaining = try await database.pool.read { try DBSendRecipientBroadcastRecord.fetchAll($0) }
        #expect(remaining.count == 1)
        #expect(remaining.first?.walletID == "other-wallet")
        try await database.eraseAllData()
        #expect(try await database.pool.read { try DBSendRecipientBroadcastRecord.fetchCount($0) } == 0)
        #expect(try await database.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM pragma_foreign_key_check") } == 0)
    }

    @Test
    func corruptedRecipientIdentityFailsClosedInsteadOfInventingFamiliarity() async throws {
        let database = try WalletDatabase.temporary()
        let scope = try await Fixtures.seed(database)
        try await Fixtures.broadcast(in: database)
        try await database.pool.write { db in
            try db.execute(sql: "UPDATE sendRecipientBroadcasts SET recipientIdentity = 'invalid'")
        }
        await #expect(throws: DatabaseError.self) {
            try await database.sendRecipientHistorySnapshot(scope: scope)
        }
    }
}
