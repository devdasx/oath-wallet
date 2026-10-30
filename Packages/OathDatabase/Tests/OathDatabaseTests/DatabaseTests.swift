import XCTest
import GRDB
@testable import OathDatabase

@MainActor final class DatabaseTests: XCTestCase {
    private func fixture() async throws -> (OathDatabase, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("OathDatabaseTests-" + UUID().uuidString).appendingPathComponent("wallet.sqlite")
        let db = try await OathDatabase.open(at: url)
        try await db.seed(networks: [NetworkRecord(id: "bitcoin", name: "Bitcoin", family: "utxo", symbol: "BTC", decimals: 8, derivationPath: "test", logo: "btc", sortOrder: 0),
                                   NetworkRecord(id: "ethereum", name: "Ethereum", family: "evm", symbol: "ETH", decimals: 18, derivationPath: "test", logo: "eth", sortOrder: 1)],
                          assets: [AssetRecord(id: "btc", networkID: "bitcoin", reference: "native", name: "Bitcoin", symbol: "BTC", decimals: 8),
                                   AssetRecord(id: "eth", networkID: "ethereum", reference: "native", name: "Ethereum", symbol: "ETH", decimals: 18)])
        for i in 1...2 {
            try await db.importWalletIfNeeded(WalletRecord(id: "w\(i)", name: "Wallet \(i)", kind: "hd", vaultReference: "fixture-\(i)", createdAt: Double(i)),
                accounts: [AccountRecord(id: "a\(i)", walletID: "w\(i)", networkID: "bitcoin", address: "public-fixture-\(i)", derivationPath: "test"),
                           AccountRecord(id: "e\(i)", walletID: "w\(i)", networkID: "ethereum", address: "0xPUBLICFIXTURE", derivationPath: "test")])
        }
        return (db, url)
    }
    private func balance(_ account: String, _ value: String, at time: Double) -> BalanceRecord {
        BalanceRecord(accountID: account, assetID: "btc", networkID: "bitcoin", amountAtomic: value, observedAt: time, source: "fixture")
    }
    private func draft(_ id: String, evm: Bool = false, wallet: Int = 1) -> SendRecord {
        SendRecord(id: id, walletID: "w\(wallet)", accountID: "\(evm ? "e" : "a")\(wallet)", networkID: evm ? "ethereum" : "bitcoin", assetID: evm ? "eth" : "btc", idempotencyKey: id,
                   recipient: "public-recipient", amountAtomic: "100", state: "draft", createdAt: 1, updatedAt: 1)
    }

    func testRemovedWalletCannotQueueNewSpending() async throws {
        let (db, _) = try await fixture()
        try await db.saveDraft(draft("before", evm: true))
        try await db.reconcileWalletLifecycle([.init(id: "w1", deletedAt: 100)])
        do { try await db.saveDraft(draft("after", evm: true)); XCTFail("Deleted wallet created a send") } catch { }
        do { _ = try await db.queueSend("before", networkNonce: 1); XCTFail("Deleted wallet reserved a send") } catch { }
        try await db.reconcileWalletLifecycle([.init(id: "w1", deletedAt: nil)])
        _ = try await db.queueSend("before", networkNonce: 1)
        do { try await db.validateWalletRemoval(["w1"]); XCTFail("Removal accepted a pending send") } catch { }
    }

    func testWalletLifecycleOrderingAndReopen() async throws {
        let (db, url) = try await fixture()
        try await db.reorderWallets(["w2", "w1"])
        let ordered = try await db.wallets()
        XCTAssertEqual(ordered.map(\.id), ["w2", "w1"])
        XCTAssertEqual(ordered.map(\.nameIndex), [1, 0])
        try await db.setSetting("activeWalletID", value: "w2")
        try await db.reconcileWalletLifecycle([.init(id: "w2", deletedAt: 100)])
        let active = try await db.wallets()
        let removed = try await db.wallets(includingDeleted: true)
        let settings = try await db.settings()
        XCTAssertEqual(active.map(\.id), ["w1"])
        XCTAssertEqual(removed.map(\.id), ["w2", "w1"])
        XCTAssertEqual(removed.first?.deletedAt, 100)
        XCTAssertNil(settings["activeWalletID"])
        let reopened = try await OathDatabase.open(at: url)
        let persisted = try await reopened.wallets(includingDeleted: true)
        XCTAssertEqual(persisted, removed)
        try await reopened.reconcileWalletLifecycle([.init(id: "w2", deletedAt: nil)])
        let restored = try await reopened.wallets()
        XCTAssertEqual(restored.map(\.id), ["w2", "w1"])
        XCTAssertEqual(restored.map(\.nameIndex), [1, 0])
        for order in [["w1"], ["w1", "w1"], ["w1", "foreign"]] {
            do { try await db.reorderWallets(order); XCTFail("Accepted invalid order") } catch { }
        }
        do { try await db.reconcileWalletLifecycle([.init(id: "w1", deletedAt: .nan)]); XCTFail("Accepted invalid deadline") } catch { }
    }

    func testWalletRemovalRevokesBackgroundWrites() async throws {
        let (db, _) = try await fixture()
        let backup = CloudBackupRecord(walletID: "w1", backupID: UUID(), accountID: "synthetic-cloud", encryptedDocument: Data([1, 2, 3]))
        try await db.queueCloudBackup(backup)
        let accountBefore = try await db.accounts(walletID: "w1").first { $0.id == "a1" }!
        try await db.pool.write { sql in
            try sql.execute(sql: "INSERT INTO bitcoinWallets(accountID,descriptor,preferredType,scanID) VALUES('a1',?,'legacy','old-scan')", arguments: [Data("{}".utf8)])
        }
        try await db.reconcileWalletLifecycle([.init(id: "w1", deletedAt: 100)])
        let accountAfter = try await db.accounts(walletID: "w1").first { $0.id == "a1" }!
        let cloud = try await db.cloudBackup(walletID: "w1")
        let scanID = try await db.pool.read { try String.fetchOne($0, sql: "SELECT scanID FROM bitcoinWallets WHERE accountID='a1'") }
        XCTAssertEqual(accountAfter.syncGeneration, accountBefore.syncGeneration + 1)
        XCTAssertNil(scanID)
        XCTAssertEqual(cloud?.enabled, false)
        XCTAssertNil(cloud?.encryptedDocument)
        do { try await db.queueCloudBackup(backup); XCTFail("A late encryption result re-enabled deleted wallet backup") } catch { }
        try await db.updateCloudBackup(backupID: backup.backupID, state: "uploaded")
        let afterLateUpload = try await db.cloudBackup(walletID: "w1")
        XCTAssertEqual(afterLateUpload?.enabled, false)
        try await db.reconcileWalletLifecycle([.init(id: "w1", deletedAt: 100)])
        let unchanged = try await db.accounts(walletID: "w1").first { $0.id == "a1" }!
        XCTAssertEqual(unchanged.syncGeneration, accountAfter.syncGeneration, "Journal replay is idempotent")
    }

    func testPermanentRemovalKeepsSharedAndUnrelatedTransactions() async throws {
        let (db, _) = try await fixture()
        try await db.pool.write { sql in
            for id in ["owned", "shared", "unrelated"] {
                try TransactionRecord(id: id, networkID: "bitcoin", hash: id, state: "confirmed", timestamp: 1, updatedAt: 1).insert(sql)
            }
            for (id, wallet, account, transaction) in [("first", "w1", "a1", "owned"), ("second", "w1", "a1", "shared"), ("third", "w2", "a2", "shared")] {
                try ActivityRecord(id: id, walletID: wallet, accountID: account, networkID: "bitcoin", transactionID: transaction,
                    assetID: "btc", direction: "incoming", amountAtomic: "1", counterparty: "fixture", timestamp: 1).insert(sql)
            }
        }
        try await db.setSetting("currency", value: "EUR")
        try await db.savePrices([.init(assetID: "btc", currency: "USD", value: "123", observedAt: 1, source: "fixture")])
        try await db.deleteWalletMetadata("w1")
        let transactions = try await db.pool.read { try String.fetchAll($0, sql: "SELECT id FROM transactions ORDER BY id") }
        let activity = try await db.pool.read { try String.fetchAll($0, sql: "SELECT id FROM activity") }
        let settings = try await db.settings()
        let cachedPrice = try await db.pool.read { try String.fetchOne($0, sql: "SELECT value FROM prices WHERE assetID='btc' AND currency='USD'") }
        XCTAssertEqual(transactions, ["shared", "unrelated"])
        XCTAssertEqual(activity, ["third"])
        XCTAssertEqual(settings["currency"], "EUR")
        XCTAssertEqual(cachedPrice, "123")
    }

    func testMigrationReopenAndExactQuantities() async throws {
        let (db, url) = try await fixture()
        try await db.saveBalances([balance("a1", "100000001", at: 1)])
        try await db.setSetting("language", value: "ar")
        let reopened = try await OathDatabase.open(at: url)
        let value = try await reopened.balance(accountID: "a1", assetID: "btc")
        XCTAssertEqual(value?.amountAtomic, "100000001")
        let settings = try await reopened.settings()
        XCTAssertEqual(settings["language"], "ar")
        let huge = String(repeating: "9", count: 78)
        XCTAssertEqual(try AtomicAmount(huge).rawValue, huge)
        XCTAssertEqual(try AtomicAmount("100000001").units(decimals: 8), "1.00000001")
        for invalid in ["", "00", "1.2", "-1", "1e18", String(repeating: "9", count: 194)] {
            XCTAssertThrowsError(try AtomicAmount(invalid))
        }
    }
    func testMultiwalletIsolationAndUnknownIsNotStoredZero() async throws {
        let (db, _) = try await fixture()
        try await db.saveBalances([balance("a1", "100000000", at: 1), balance("a2", "250000000", at: 1)])
        try await db.savePrices([PriceRecord(assetID: "btc", currency: "USD", value: "10.25", observedAt: 1, source: "fixture")])
        let first = try await db.snapshot(walletID: "w1", currency: "USD")
        let second = try await db.snapshot(walletID: "w2", currency: "USD")
        XCTAssertEqual(first.totalFiat, Decimal(string: "10.25"))
        XCTAssertEqual(second.totalFiat, Decimal(string: "25.625"))
        let missing = try await db.snapshot(walletID: "w1", currency: "JOD")
        XCTAssertFalse(missing.valuationComplete)
        XCTAssertNil(missing.holdings.first?.price)
        XCTAssertEqual(missing.totalFiat, 0)
    }
    func testOldBalanceResponsesDoNotOverwriteNewerData() async throws {
        let (db, _) = try await fixture()
        try await db.saveBalances([balance("a1", "9", at: 5)])
        try await db.saveBalances([balance("a1", "2", at: 2)])
        let stored = try await db.balance(accountID: "a1", assetID: "btc")
        XCTAssertEqual(stored?.amountAtomic, "9")
    }
    func testCrossNetworkBalanceRejectedAndBatchRollsBack() async throws {
        let (db, _) = try await fixture()
        do {
            try await db.saveBalances([balance("a1", "10", at: 1), BalanceRecord(accountID: "a1", assetID: "eth", networkID: "bitcoin", amountAtomic: "1", observedAt: 1, source: "fixture")])
            XCTFail("Cross-chain foreign key accepted")
        } catch { }
        let stored = try await db.balance(accountID: "a1", assetID: "btc")
        XCTAssertNil(stored)
    }
    func testSyncCursorAtomicityRetriesAndHistoryPagination() async throws {
        let (db, _) = try await fixture()
        var batch = SyncBatch(cursor: SyncCursor(accountID: "a1", stream: "history", cursor: "page1", updatedAt: 1), expectedCursor: nil)
        for i in 0..<6 {
            batch.transactions.append(TransactionRecord(id: "tx\(i)", networkID: "bitcoin", hash: "hash\(i)", state: "confirmed", blockHeight: 100, timestamp: 1, updatedAt: 1))
            batch.activity.append(ActivityRecord(id: "event\(i)", walletID: "w1", accountID: "a1", networkID: "bitcoin", transactionID: "tx\(i)", assetID: "btc", direction: "incoming", amountAtomic: "1", counterparty: "fixture", timestamp: 1))
        }
        let applied = try await db.apply(batch)
        let retried = try await db.apply(batch)
        XCTAssertTrue(applied); XCTAssertFalse(retried)
        let page1 = try await db.history(walletID: "w1", limit: 3)
        let last = try XCTUnwrap(page1.last)
        let page2 = try await db.history(walletID: "w1", before: HistoryCursor(timestamp: last.timestamp, id: last.id), limit: 3)
        XCTAssertEqual(Set((page1 + page2).map(\.id)).count, 6)
        XCTAssertEqual(page2.count, 3)
        let other = try await db.history(walletID: "w2")
        XCTAssertTrue(other.isEmpty)
        batch.cursor.cursor = "page2"; batch.expectedCursor = "wrong"
        do { try await db.apply(batch); XCTFail("Accepted stale cursor") }
        catch { XCTAssertEqual(error as? StoreError, .staleSync) }
        batch.expectedCursor = "page1"
        batch.activity.append(ActivityRecord(id: "bad", walletID: "w2", accountID: "a1", networkID: "bitcoin", transactionID: "tx0", assetID: "btc", direction: "incoming", amountAtomic: "1", counterparty: "fixture", timestamp: 1))
        do { try await db.apply(batch); XCTFail("Accepted cross-wallet history") } catch { }
        let cursor = try await db.cursor(accountID: "a1", stream: "history")
        XCTAssertEqual(cursor?.cursor, "page1")
    }
    func testConcurrentUTXOReservationHasExactlyOneWinner() async throws {
        let (db, _) = try await fixture()
        var batch = SyncBatch(cursor: SyncCursor(accountID: "a1", stream: "utxos", cursor: "one", updatedAt: 1), expectedCursor: nil)
        batch.utxos = [UTXORecord(networkID: "bitcoin", transactionHash: "output", outputIndex: 0, accountID: "a1", value: 500, script: "00", updatedAt: 1)]
        try await db.apply(batch)
        try await db.saveDraft(draft("send1")); try await db.saveDraft(draft("send2"))
        let winners = await withTaskGroup(of: Bool.self) { group in
            for id in ["send1", "send2"] {
                group.addTask {
                    do { _ = try await db.queueSend(id, outputs: [Outpoint(hash: "output", index: 0)]); return true }
                    catch { return false }
                }
            }
            var count = 0
            for await result in group { if result { count += 1 } }
            return count
        }
        XCTAssertEqual(winners, 1)
        let outputs = try await db.spendableOutputs(accountID: "a1")
        XCTAssertTrue(outputs.isEmpty)
        let pending = try await db.pendingSends()
        let send = try XCTUnwrap(pending.first)
        batch.cursor.cursor = "two"; batch.expectedCursor = "one"; batch.utxos[0].updatedAt = 2
        try await db.apply(batch)
        let reserved = try await db.reservedOutputs(sendID: send.id)
        XCTAssertEqual(reserved.count, 1, "Sync cleared local input reservation")
        _ = try await db.transitionSend(send.id, from: "queued", to: "cancelled")
        let released = try await db.spendableOutputs(accountID: "a1")
        XCTAssertEqual(released.count, 1)
    }
    func testNonceReservationAndSignedSendSurviveReopen() async throws {
        let (db, url) = try await fixture()
        try await db.saveDraft(draft("n1", evm: true)); try await db.saveDraft(draft("n2", evm: true, wallet: 2))
        async let a = db.queueSend("n1", networkNonce: 4)
        async let b = db.queueSend("n2", networkNonce: 4)
        let both = try await [a, b]
        XCTAssertEqual(Set(both.compactMap(\.nonce)), ["4", "5"])
        _ = try await db.transitionSend("n1", from: "queued", to: "signed", signedPayload: Data("public-fixture".utf8))
        let reopened = try await OathDatabase.open(at: url)
        let saved = try await reopened.send("n1")
        XCTAssertEqual(saved?.state, "signed")
        do { _ = try await db.transitionSend("n1", from: "signed", to: "cancelled"); XCTFail("Released a signed send") }
        catch { XCTAssertEqual(error as? StoreError, .invalidTransition) }
    }
    func testSettingsMigrationIsOneWayAndObservationSeesCommittedValues() async throws {
        let (db, _) = try await fixture()
        try await db.migrateLegacySettings(["language": "ar"])
        try await db.migrateLegacySettings(["language": "de"])
        var updates = db.observeSettings().makeAsyncIterator()
        let first = try await updates.next()
        XCTAssertEqual(first?["language"], "ar")
        try await db.setSetting("language", value: "en")
        let second = try await updates.next()
        XCTAssertEqual(second?["language"], "en")
        async let firstToggle: Void = db.toggleBalanceVisibility()
        async let secondToggle: Void = db.toggleBalanceVisibility()
        _ = try await (firstToggle, secondToggle)
        let settings = try await db.settings()
        XCTAssertEqual(settings["balancesHidden"], "false")
    }
    func testNotesLabelsReceiveAndCascadeAreWalletScoped() async throws {
        let (db, _) = try await fixture()
        try await db.saveNote(NoteRecord(id: "note", walletID: "w1", subjectType: "account", subjectID: "a1", body: "Invoice", updatedAt: 1))
        try await db.saveLabel(LabelRecord(id: "label", walletID: "w1", name: "Savings", color: "blue", updatedAt: 1))
        try await db.assignLabel(LabelAssignment(labelID: "label", walletID: "w1", subjectType: "account", subjectID: "a1"))
        do {
            try await db.assignLabel(LabelAssignment(labelID: "label", walletID: "w1", subjectType: "account", subjectID: "a2")); XCTFail("Cross-wallet label accepted")
        } catch { }
        try await db.saveReceive(ReceiveRecord(id: "receive", accountID: "a1", networkID: "bitcoin", assetID: "btc", address: "public-fixture-1", state: "open", createdAt: 1))
        let requests = try await db.receives(accountID: "a1")
        XCTAssertEqual(requests.count, 1)
        try await db.deleteWalletMetadata("w1")
        let notes = try await db.notes(walletID: "w1")
        let accounts = try await db.accounts(walletID: "w1")
        let labels = try await db.labels(walletID: "w1")
        XCTAssertTrue(notes.isEmpty); XCTAssertTrue(accounts.isEmpty); XCTAssertTrue(labels.isEmpty)
        let remaining = try await db.wallets()
        XCTAssertEqual(remaining.map(\.id), ["w2"])
    }
    @MainActor func testDatabaseWorkDoesNotRunOnMainThreadAndIndexesAreUsed() async throws {
        let (db, _) = try await fixture()
        let onMain = try await db.pool.read { _ in Thread.isMainThread }
        XCTAssertFalse(onMain)
        let writerOnMain = try await db.pool.write { _ in Thread.isMainThread }
        XCTAssertFalse(writerOnMain)
        let details = try await db.pool.read { db in
            try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN SELECT * FROM activity WHERE walletID='w1' ORDER BY timestamp DESC,id DESC LIMIT 50").map { $0["detail"] as String }
        }
        XCTAssertTrue(details.contains { $0.contains("activity_wallet_page") })
        let check = try await db.pool.read { try String.fetchOne($0, sql: "PRAGMA integrity_check") }
        XCTAssertEqual(check, "ok")
    }

    func testSharedUTXOHasOneReservationAcrossWallets() async throws {
        let (db, _) = try await fixture()
        try await db.importWalletIfNeeded(WalletRecord(id: "w3", name: "Duplicate address", kind: "hd", vaultReference: "fixture-3", createdAt: 3),
            accounts: [AccountRecord(id: "a3", walletID: "w3", networkID: "bitcoin", address: "public-fixture-1", derivationPath: "test")])
        for account in ["a1", "a3"] {
            var batch = SyncBatch(cursor: SyncCursor(accountID: account, stream: "utxos", cursor: "one", updatedAt: 1), expectedCursor: nil)
            batch.utxos = [UTXORecord(networkID: "bitcoin", transactionHash: "shared", outputIndex: 0, accountID: account, value: 500, script: "00", updatedAt: 1)]
            try await db.apply(batch)
        }
        try await db.saveDraft(draft("s1")); try await db.saveDraft(draft("s3", wallet: 3))
        _ = try await db.queueSend("s1", outputs: [Outpoint(hash: "shared", index: 0)])
        do { _ = try await db.queueSend("s3", outputs: [Outpoint(hash: "shared", index: 0)]); XCTFail("Reserved one output twice") }
        catch { XCTAssertEqual(error as? StoreError, .reservationConflict) }
        let outputs = try await db.spendableOutputs(accountID: "a3")
        XCTAssertTrue(outputs.isEmpty)
        do { try await db.deleteWalletMetadata("w1"); XCTFail("Deleted an active send") }
        catch { XCTAssertEqual(error as? StoreError, .invalidTransition) }
        _ = try await db.transitionSend("s1", from: "queued", to: "cancelled")
        try await db.deleteWalletMetadata("w1")
        let remaining = try await db.spendableOutputs(accountID: "a3")
        XCTAssertEqual(remaining.count, 1, "Deleting one owner deleted a shared output")
    }

    func testReorgRejectsInFlightPageAndKeepsReservations() async throws {
        let (db, _) = try await fixture()
        var batch = SyncBatch(cursor: SyncCursor(accountID: "a1", stream: "chain", cursor: "100", blockHeight: 100, updatedAt: 1), expectedCursor: nil)
        batch.balances = [balance("a1", "500", at: 1)]
        batch.transactions = [TransactionRecord(id: "tx", networkID: "bitcoin", hash: "hash", state: "confirmed", blockHeight: 100, blockHash: "block", timestamp: 1, updatedAt: 1)]
        batch.utxos = [UTXORecord(networkID: "bitcoin", transactionHash: "hash", outputIndex: 0, accountID: "a1", value: 500, script: "00", blockHeight: 100, updatedAt: 1)]
        try await db.apply(batch)
        try await db.saveDraft(draft("spend"))
        _ = try await db.queueSend("spend", outputs: [Outpoint(hash: "hash", index: 0)])
        try await db.invalidate(networkID: "bitcoin", fromBlock: 99)
        let checkpoint = try await db.checkpoint(accountID: "a1", stream: "chain")
        XCTAssertEqual(checkpoint.generation, 1)
        XCTAssertNil(checkpoint.cursor)
        let transaction = try await db.transaction("tx")
        XCTAssertEqual(transaction?.state, "reorged")
        let stored = try await db.balance(accountID: "a1", assetID: "btc")
        XCTAssertNil(stored)
        let reserved = try await db.reservedOutputs(sendID: "spend")
        XCTAssertEqual(reserved.count, 1)
        do { try await db.apply(batch); XCTFail("Accepted response from an invalidated chain") }
        catch { XCTAssertEqual(error as? StoreError, .staleSync) }
        batch.expectedGeneration = checkpoint.generation
        batch.cursor.cursor = "replacement"; batch.transactions[0].blockHash = "new-block"
        try await db.apply(batch)
        let repaired = try await db.transaction("tx")
        XCTAssertEqual(repaired?.blockHash, "new-block")
    }

    func testNoteSearchUpdatesDeletesAndNeverCrossesWallets() async throws {
        let (db, _) = try await fixture()
        var note = NoteRecord(id: "one", walletID: "w1", subjectType: "wallet", subjectID: "w1", body: "Invoice for design", updatedAt: 1)
        try await db.saveNote(note)
        try await db.saveNote(NoteRecord(id: "two", walletID: "w2", subjectType: "wallet", subjectID: "w2", body: "Invoice for design", updatedAt: 1))
        var found = try await db.searchNotes(walletID: "w1", query: "invo des")
        XCTAssertEqual(found.map(\.id), ["one"])
        note.body = "Savings"; note.updatedAt = 2
        try await db.saveNote(note)
        found = try await db.searchNotes(walletID: "w1", query: "invoice")
        XCTAssertTrue(found.isEmpty)
        found = try await db.searchNotes(walletID: "w1", query: "savings")
        XCTAssertEqual(found.map(\.id), ["one"])
        try await db.deleteNote("one", walletID: "w1")
        found = try await db.searchNotes(walletID: "w1", query: "savings")
        XCTAssertTrue(found.isEmpty)
        let errors = try await db.pool.read { try Row.fetchAll($0, sql: "PRAGMA foreign_key_check").count }
        XCTAssertEqual(errors, 0)
    }

    func testPortfolioObservationPublishesCommittedPricesAndBalances() async throws {
        let (db, _) = try await fixture()
        var iterator = db.observeWallet(walletID: "w1", currency: "USD").makeAsyncIterator()
        let initial = try await iterator.next()
        XCTAssertNil(initial?.holdings.first?.amountAtomic)
        try await db.saveBalances([balance("a1", "100000000", at: 1)])
        var updated = try await iterator.next()
        XCTAssertEqual(updated?.holdings.first?.amountAtomic, "100000000")
        try await db.savePrices([PriceRecord(assetID: "btc", currency: "USD", value: "10", observedAt: 10, source: "fixture"),
                                 PriceRecord(assetID: "btc", currency: "USD", value: "1", observedAt: 1, source: "fixture")])
        updated = try await iterator.next()
        XCTAssertEqual(updated?.totalFiat, 10)
        try await db.setSetting("currency", value: "JOD")
        updated = try await iterator.next()
        XCTAssertEqual(updated?.currency, "JOD")
        XCTAssertNil(updated?.holdings.first?.price)
    }

    func testRenameWalletChangesOnlyItsNameAndValidatesInput() async throws {
        let (db, url) = try await fixture()
        let original = try await db.wallet("w1")
        var expected = try XCTUnwrap(original)
        let other = try await db.wallet("w2")
        let accounts = try await db.accounts(walletID: "w1")
        try await db.setSetting("activeWalletID", value: "w2")
        try await db.renameWallet("w1", name: " \nادخار 🏡\t ")
        expected.name = "ادخار 🏡"
        expected.confirmedName = expected.name
        let renamed = try await db.wallet("w1")
        XCTAssertEqual(renamed, expected)
        for invalid in ["", " \t\n", String(repeating: "x", count: 101)] {
            do { try await db.renameWallet("w1", name: invalid); XCTFail("Invalid name accepted") }
            catch { XCTAssertEqual(error as? StoreError, .invalidValue("wallet name")) }
        }
        do { try await db.renameWallet("missing", name: "Savings"); XCTFail("Missing wallet accepted") }
        catch { XCTAssertEqual(error as? StoreError, .missingRecord) }
        let reopened = try await OathDatabase.open(at: url)
        let persisted = try await reopened.wallet("w1")
        let untouched = try await reopened.wallet("w2")
        let persistedAccounts = try await reopened.accounts(walletID: "w1")
        let settings = try await reopened.settings()
        XCTAssertEqual(persisted, expected, "Invalid edits must retain the last committed name")
        XCTAssertEqual(untouched, other, "Another wallet must not be modified")
        XCTAssertEqual(persistedAccounts, accounts)
        XCTAssertEqual(settings["activeWalletID"], "w2")
        let maximumName = String(repeating: "🏡", count: 100)
        try await db.renameWallet("w1", name: maximumName)
        let maximum = try await db.wallet("w1")
        XCTAssertEqual(maximum?.name, maximumName, "The limit counts characters, not UTF-8 bytes")
    }

    func testWalletListObservationAndSelectionSurviveReopen() async throws {
        let (db, url) = try await fixture()
        var iterator = db.observeWallets().makeAsyncIterator()
        let initial = try await iterator.next()
        XCTAssertEqual(initial?.map(\.id), ["w1", "w2"])
        try await db.setSetting("activeWalletID", value: "w2")
        try await db.renameWallet("w2", name: "Savings")
        let renamed = try await iterator.next()
        XCTAssertEqual(renamed?.last?.name, "Savings")
        try await db.importWalletIfNeeded(
            WalletRecord(id: "w3", name: "Imported", kind: "imported", vaultReference: "fixture-3", createdAt: 3),
            accounts: [])
        let added = try await iterator.next()
        XCTAssertEqual(added?.map(\.id), ["w1", "w2", "w3"])
        let reopened = try await OathDatabase.open(at: url)
        let settings = try await reopened.settings()
        XCTAssertEqual(settings["activeWalletID"], "w2", "Insertion must not silently change an existing selection")
        let wallets = try await reopened.wallets()
        XCTAssertEqual(wallets.map(\.id), ["w1", "w2", "w3"])
        XCTAssertEqual(wallets[1].name, "Savings")
        do {
            try await reopened.setSetting("activeWalletID", value: "missing")
            XCTFail("A nonexistent wallet cannot be selected")
        } catch { XCTAssertEqual(error as? StoreError, .missingRecord) }
        let unchanged = try await reopened.settings()
        XCTAssertEqual(unchanged["activeWalletID"], "w2")
    }

    func testWalletCustomizationIsAtomicObservedAndIsolated() async throws {
        let (db, url) = try await fixture()
        let other = try await db.wallet("w2")
        let accounts = try await db.accounts(walletID: "w1")
        try await db.setSetting("activeWalletID", value: "w2")
        var updates = db.observeWallets().makeAsyncIterator()
        _ = try await updates.next()
        try await db.customizeWallet("w1", name: "  ادخار 🏡  ", colorHex: "DF438D")
        let observed = try await updates.next()
        XCTAssertEqual(observed?.first?.name, "ادخار 🏡")
        XCTAssertEqual(observed?.first?.colorHex, "DF438D")
        let reopened = try await OathDatabase.open(at: url)
        let persisted = try await reopened.snapshot(walletID: "w1", currency: "USD")
        XCTAssertEqual(persisted.wallet.name, "ادخار 🏡")
        XCTAssertEqual(persisted.wallet.colorHex, "DF438D")
        let untouched = try await reopened.wallet("w2")
        let keptAccounts = try await reopened.accounts(walletID: "w1")
        let settings = try await reopened.settings()
        XCTAssertEqual(untouched, other)
        XCTAssertEqual(keptAccounts, accounts)
        XCTAssertEqual(settings["activeWalletID"], "w2")
        try await db.markBackedUp("w1")
        try await db.renameWallet("w1", name: "Savings")
        let renamed = try await db.wallet("w1")
        XCTAssertEqual(renamed?.colorHex, "DF438D", "Other metadata updates must retain the chosen color")
        try await db.customizeWallet("w1", name: "Savings", colorHex: nil)
        let reset = try await db.wallet("w1")
        XCTAssertNil(reset?.colorHex)
    }

    func testWalletCustomizationRejectsInvalidInputWithoutPartialEdits() async throws {
        let (db, _) = try await fixture()
        let original = try await db.wallet("w1")
        for color in ["", "#123456", "12345", "1234567", "abcdef", "ZZZZZZ", "１２３４５６"] {
            do { try await db.customizeWallet("w1", name: "Changed", colorHex: color); XCTFail("Invalid color accepted") }
            catch { XCTAssertEqual(error as? StoreError, .invalidValue("wallet color")) }
        }
        for name in ["", " \n", String(repeating: "x", count: 101)] {
            do { try await db.customizeWallet("w1", name: name, colorHex: "FF0000"); XCTFail("Invalid name accepted") }
            catch { XCTAssertEqual(error as? StoreError, .invalidValue("wallet name")) }
        }
        do { try await db.customizeWallet("missing", name: "Missing", colorHex: "FFFFFF"); XCTFail("Unknown wallet accepted") }
        catch { XCTAssertEqual(error as? StoreError, .missingRecord) }
        let unchanged = try await db.wallet("w1")
        XCTAssertEqual(unchanged, original)
        for color in ["000000", "FFFFFF", "12ABEF"] {
            try await db.customizeWallet("w1", name: "Valid", colorHex: color)
            let changed = try await db.wallet("w1")
            XCTAssertEqual(changed?.colorHex, color)
        }
        let plan = try await db.pool.read { db in
            try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN UPDATE wallets SET colorHex='000000' WHERE id='w1'").map { $0["detail"] as String }
        }
        XCTAssertTrue(plan.contains { $0.contains("sqlite_autoindex_wallets") })
    }

    func testAppearanceMigrationPreservesExistingV2Wallet() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("legacy.sqlite")
        let old = try DatabaseQueue(path: url.path)
        try Schema.migrator.migrate(old, upTo: "v2_encrypted_icloud_backups")
        try await old.write { db in
            try db.execute(sql: "INSERT INTO wallets (id,name,kind,vaultReference,createdAt,backedUp) VALUES ('legacy','Existing','hd','fixture',1,1)")
            try db.execute(sql: "INSERT INTO settings (key,value,updatedAt) VALUES ('activeWalletID','legacy',1)")
        }
        let upgraded = try await OathDatabase.open(at: url)
        let wallet = try await upgraded.wallet("legacy")
        XCTAssertEqual(wallet?.name, "Existing")
        XCTAssertEqual(wallet?.vaultReference, "fixture")
        XCTAssertEqual(wallet?.backedUp, true)
        XCTAssertNil(wallet?.colorHex, "Old wallets retain the exact original palette")
        XCTAssertEqual(wallet?.needsCustomization, false, "An app update must not restart setup for existing wallets")
        try await upgraded.customizeWallet("legacy", name: "Existing", colorHex: "8B36C9")
        let reopened = try await OathDatabase.open(at: url)
        let saved = try await reopened.wallet("legacy")
        XCTAssertEqual(saved?.colorHex, "8B36C9")
    }

    func testPendingCustomizationSurvivesRestartUntilAtomicApply() async throws {
        let (db, url) = try await fixture()
        try await db.importWalletIfNeeded(WalletRecord(id: "pending", name: "", kind: "hd",
            vaultReference: "fixture-pending", createdAt: 3, needsCustomization: true), accounts: [])
        let reopened = try await OathDatabase.open(at: url)
        let pending = try await reopened.wallet("pending")
        XCTAssertEqual(pending?.needsCustomization, true)
        do {
            try await reopened.customizeWallet("pending", name: " ", colorHex: "DF438D")
            XCTFail("Invalid customization must not finish setup")
        } catch { XCTAssertEqual(error as? StoreError, .invalidValue("wallet name")) }
        let unchanged = try await reopened.wallet("pending")
        XCTAssertEqual(unchanged, pending)
        try await reopened.customizeWallet("pending", name: "  Savings  ", colorHex: "DF438D")
        let committed = try await reopened.wallet("pending")
        XCTAssertEqual(committed?.name, "Savings")
        XCTAssertEqual(committed?.colorHex, "DF438D")
        XCTAssertEqual(committed?.needsCustomization, false)
        // Retrying creation metadata cannot reset an already completed wallet.
        try await db.importWalletIfNeeded(pending!, accounts: [])
        let retried = try await db.wallet("pending")
        XCTAssertEqual(retried, committed)
    }

    func testCoordinatorBoundsConcurrentWorkAndIsolatesFailures() async throws {
        let (db, _) = try await fixture()
        let coordinator = SyncCoordinator(database: db, maximumConcurrency: 2)
        let probe = WorkProbe()
        let jobs = (0..<8).map { index in
            SyncJob(accountID: "a1", stream: "stream\(index)") { _ in
                await probe.enter()
                try await Task.sleep(for: .milliseconds(10))
                await probe.leave()
                if index == 3 { throw StoreError.missingRecord }
                return SyncBatch(cursor: SyncCursor(accountID: "a1", stream: "stream\(index)", cursor: "one", updatedAt: 1), expectedCursor: nil)
            }
        }
        let outcomes = await coordinator.synchronize(jobs + [jobs[0]])
        XCTAssertEqual(outcomes.count, 8)
        XCTAssertEqual(outcomes.filter { $0.status == .committed }.count, 7)
        XCTAssertEqual(outcomes.filter { $0.status == .failed }.count, 1)
        let maximum = await probe.maximum
        XCTAssertEqual(maximum, 2)
    }

    func testCancelledSyncDoesNotCommitAndNextRefreshWorks() async throws {
        let (db, _) = try await fixture()
        let coordinator = SyncCoordinator(database: db, maximumConcurrency: 1)
        let gate = WorkProbe()
        let job = SyncJob(accountID: "a1", stream: "cancel") { _ in
            await gate.enter()
            try await Task.sleep(for: .seconds(1))
            return SyncBatch(cursor: SyncCursor(accountID: "a1", stream: "cancel", cursor: "one", updatedAt: 1), expectedCursor: nil)
        }
        let running = Task { await coordinator.synchronize([job]) }
        while await gate.maximum == 0 { await Task.yield() }
        let duplicate = await coordinator.synchronize([job])
        XCTAssertEqual(duplicate.first?.status, .inProgress)
        running.cancel()
        let cancelled = await running.value
        XCTAssertEqual(cancelled.first?.status, .cancelled)
        let cursor = try await db.cursor(accountID: "a1", stream: "cancel")
        XCTAssertNil(cursor)
        let retry = SyncJob(accountID: "a1", stream: "cancel") { _ in
            SyncBatch(cursor: SyncCursor(accountID: "a1", stream: "cancel", cursor: "one", updatedAt: 1), expectedCursor: nil)
        }
        let outcomes = await coordinator.synchronize([retry])
        XCTAssertEqual(outcomes.first?.status, .committed)
    }

    func testOutputPaginationAndPriceIndexes() async throws {
        let (db, _) = try await fixture()
        var batch = SyncBatch(cursor: SyncCursor(accountID: "a1", stream: "utxos", cursor: "one", updatedAt: 1), expectedCursor: nil)
        batch.utxos = (0..<250).map {
            UTXORecord(networkID: "bitcoin", transactionHash: "fixture-output", outputIndex: $0,
                       accountID: "a1", value: 500, script: "00", updatedAt: 1)
        }
        try await db.apply(batch)
        let first = try await db.spendableOutputs(accountID: "a1")
        let last = try XCTUnwrap(first.last)
        let second = try await db.spendableOutputs(accountID: "a1", after: OutputCursor(value: last.value, hash: last.transactionHash, index: last.outputIndex))
        XCTAssertEqual(first.count, 200)
        XCTAssertEqual(second.count, 50)
        XCTAssertEqual(Set((first + second).map(\.outputIndex)).count, 250)
        let plan = try await db.pool.read { db in
            try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN SELECT * FROM prices WHERE assetID='btc' AND currency='USD' ORDER BY observedAt DESC LIMIT 1").map { $0["detail"] as String }
        }
        XCTAssertTrue(plan.contains { $0.contains("prices_latest") || $0.contains("sqlite_autoindex_prices") })
        XCTAssertFalse(plan.contains { $0.contains("SCAN prices") || $0.contains("TEMP B-TREE") })
    }

    func testSeparateInstallationStartsEmpty() async throws {
        let (db, _) = try await fixture()
        try await db.setSetting("language", value: "ar")
        let freshURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("fresh.sqlite")
        let fresh = try await OathDatabase.open(at: freshURL)
        let wallets = try await fresh.wallets()
        let settings = try await fresh.settings()
        XCTAssertTrue(wallets.isEmpty)
        XCTAssertTrue(settings.isEmpty)
    }

    func testPortfolioIncludesOnlyHeldTokensAndUsesStoredCatalog() async throws {
        let (db, _) = try await fixture()
        let assets = (0..<100).map { AssetRecord(id: "token\($0)", networkID: "ethereum", reference: "contract\($0)", name: "Token \($0)", symbol: "T\($0)", decimals: 6) }
        try await db.seed(networks: [], assets: assets)
        try await db.saveBalances([BalanceRecord(accountID: "e1", assetID: "token1", networkID: "ethereum", amountAtomic: "1500000", observedAt: 1, source: "fixture")])
        let networks = try await db.networks()
        var network = try XCTUnwrap(networks.first { $0.id == "ethereum" })
        network.name = "Stored network name"
        try await db.saveNetwork(network)
        let portfolio = try await db.snapshot(walletID: "w1", currency: "USD")
        XCTAssertEqual(Set(portfolio.holdings.map(\.assetID)), ["btc", "eth", "token1"])
        XCTAssertEqual(portfolio.holdings.first { $0.assetID == "token1" }?.nativeDisplayValue, Decimal(string: "1.5"))
        XCTAssertEqual(portfolio.networks.first { $0.id == "ethereum" }?.name, "Stored network name")
        let other = try await db.snapshot(walletID: "w2", currency: "USD")
        XCTAssertEqual(Set(other.holdings.map(\.assetID)), ["btc", "eth"])
    }
}

private actor WorkProbe {
    private var current = 0
    private(set) var maximum = 0
    func enter() { current += 1; maximum = max(maximum, current) }
    func leave() { current -= 1 }
}
