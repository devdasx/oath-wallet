import Foundation
import GRDB
import XCTest
@testable import OathDatabase

private actor StatusProbe {
    var calls: [String] = []
    var active = 0
    var peak = 0
    func begin(_ id: String) { calls.append(id); active += 1; peak = max(peak, active) }
    func end() { active -= 1 }
}

private actor StatusDeadlineProbe {
    private var values: [Double?] = []
    func append(_ value: Double?) { values.append(value) }
    func lastIs(_ value: Double?) -> Bool { !values.isEmpty && values[values.count - 1] == value }
}

@MainActor final class SendStatusTrackingTests: XCTestCase {
    private let networks = ["bitcoin", "bitcoincash", "litecoin", "dogecoin", "sui", "xrpl", "stellar", "tron", "near", "solana", "arc", "future-chain"]
    private func fixture() async throws -> (OathDatabase, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Status-" + UUID().uuidString).appendingPathComponent("db.sqlite")
        let db = try await OathDatabase.open(at: url)
        try await db.seed(networks: networks.enumerated().map {
            .init(id: $0.element, name: $0.element, family: "utxo", symbol: "TEST", decimals: 8,
                  derivationPath: "fixture", logo: "", sortOrder: $0.offset)
        }, assets: networks.map { .init(id: $0 + ":native", networkID: $0, reference: "native", name: "Test", symbol: "TEST", decimals: 8) })
        for wallet in ["w1", "w2"] {
            try await db.importWalletIfNeeded(.init(id: wallet, name: "Fixture", kind: "hd", vaultReference: "fixture-" + wallet, createdAt: 1),
                accounts: networks.map { .init(id: wallet + $0, walletID: wallet, networkID: $0, address: "public-fixture", derivationPath: "fixture") })
        }
        return (db, url)
    }
    @discardableResult
    private func journal(_ db: OathDatabase, _ id: String, network: String = "bitcoin", wallet: String = "w1", broadcast: Bool = true) async throws -> String {
        let account = wallet + network
        try await db.saveDraft(.init(id: id, walletID: wallet, accountID: account, networkID: network,
            assetID: network + ":native", idempotencyKey: id, recipient: "fixture", amountAtomic: "100", state: "draft", createdAt: 1, updatedAt: 1))
        let stream = "fixture-" + id
        var batch = SyncBatch(cursor: .init(accountID: account, stream: stream, cursor: "one", updatedAt: 1), expectedCursor: nil)
        batch.utxos = [.init(networkID: network, transactionHash: id, outputIndex: 0, accountID: account, value: 500, script: "00", updatedAt: 1)]
        try await db.apply(batch)
        _ = try await db.queueSend(id, outputs: [.init(hash: id, index: 0)])
        _ = try await db.transitionSend(id, from: "queued", to: "signed", signedPayload: Data("public-fixture".utf8))
        if broadcast { _ = try await db.transitionSend(id, from: "signed", to: "broadcast") }
        return id
    }
    private func wait(file: StaticString = #filePath, line: UInt = #line, _ predicate: () async throws -> Bool) async throws {
        for _ in 0..<300 {
            if try await predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Refresh did not reach the expected state", file: file, line: line)
    }


    nonisolated private static func confirm(_ db: OathDatabase, _ send: SendRecord) async throws {
        try await db.pool.write { sql in
            let txID = send.networkID + ":" + send.id
            try TransactionRecord(id: txID, networkID: send.networkID, hash: send.id,
                state: "confirmed", blockHeight: 100, timestamp: 1, updatedAt: 1).insert(sql)
            try sql.execute(sql: "UPDATE sends SET state='confirmed',transactionID=? WHERE id=?", arguments: [txID,send.id])
        }
    }
    private func count(_ db: OathDatabase) async throws -> Int {
        try await db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sendStatusChecks")! }
    }
    func testEveryChainAndFutureJournalEnrollsAndResumesAfterReopen() async throws {
        let (db, url) = try await fixture()
        for chain in networks { try await journal(db, chain, network: chain, broadcast: chain != "sui") }
        let reopened = try await OathDatabase.open(at: url)
        let probe = StatusProbe()
        let worker = SendStatusTracker(database: reopened) { send in
            await probe.begin(send.networkID)
            try await Self.confirm(reopened, send)
            await probe.end()
        }
        await worker.resume()
        try await wait { try await self.count(reopened) == 0 }
        await worker.pause()
        let calls = await probe.calls
        XCTAssertEqual(Set(calls), Set(networks))
        XCTAssertEqual(calls.count, networks.count)
        for chain in networks {
            let state = try await reopened.send(chain)?.state
            XCTAssertEqual(state, "confirmed")
        }
    }
    func testFailureAndUnknownStayDurableWithoutRetryLimit() async throws {
        let (db, _) = try await fixture()
        try await journal(db, "offline")
        for attempt in 0..<150 {
            let claims = try await db.claimSendStatusChecks(owner: "one", now: Double(attempt) * 1000)
            let check = try XCTUnwrap(claims.first)
            try await db.finishSendStatusCheck(check, failed: attempt % 2 == 0, now: Double(attempt) * 1000)
        }
        let state = try await db.send("offline")?.state
        let reserved = try await db.reservedOutputs(sendID: "offline")
        let rows = try await count(db)
        XCTAssertEqual(state, "broadcast"); XCTAssertEqual(reserved.count, 1); XCTAssertEqual(rows, 1)
        let attempts = try await db.pool.read { try Int.fetchOne($0, sql: "SELECT attempts FROM sendStatusChecks") }
        XCTAssertEqual(attempts, 150)
    }
    func testLeaseExclusivityCrashRecoveryAndStaleCompletion() async throws {
        let (db, url) = try await fixture()
        try await journal(db, "crashed")
        let firstClaims = try await db.claimSendStatusChecks(owner: "old", now: 10)
        let first = try XCTUnwrap(firstClaims.first)
        let duplicate = try await db.claimSendStatusChecks(owner: "old", now: 11)
        XCTAssertTrue(duplicate.isEmpty)
        let slow = try await db.claimSendStatusChecks(owner:"old",now:2000,excluding:["crashed"])
        XCTAssertTrue(slow.isEmpty,"An adapter still running after its lease deadline must not overlap itself")
        let deadline = try await db.nextSendStatusDeadline(excluding:["crashed"])
        XCTAssertNil(deadline)
        let reopened = try await OathDatabase.open(at: url)
        try await reopened.resumeSendStatusChecks(owner: "new")
        let nextClaims = try await reopened.claimSendStatusChecks(owner: "new", now: 12)
        let next = try XCTUnwrap(nextClaims.first)
        XCTAssertNotEqual(first.token, next.token)
        try await reopened.finishSendStatusCheck(first, failed: true, now: 13)
        let token = try await reopened.pool.read { try String.fetchOne($0, sql: "SELECT leaseToken FROM sendStatusChecks") }
        XCTAssertEqual(token, next.token)
        try await Self.confirm(reopened, next.send)
        try await reopened.finishSendStatusCheck(next, failed: false)
        let rows = try await count(reopened)
        XCTAssertEqual(rows, 0, "Late finish cannot recreate a terminal job")
    }
    func testBoundedParallelismAndNewSendsWhileAlreadyRunning() async throws {
        let (db, _) = try await fixture()
        let probe = StatusProbe()
        let worker = SendStatusTracker(database: db) { send in
            await probe.begin(send.id)
            try await Task.sleep(for: .milliseconds(15))
            try await Self.confirm(db, send)
            await probe.end()
        }
        await worker.resume()
        for i in 0..<72 { try await journal(db, "batch-\(i)") }
        try await wait { try await self.count(db) == 0 }
        await worker.pause()
        let peak = await probe.peak, calls = await probe.calls
        XCTAssertGreaterThan(peak, 1); XCTAssertLessThanOrEqual(peak, 4)
        XCTAssertEqual(Set(calls).count, 72); XCTAssertEqual(calls.count, 72)
    }
    func testPauseCancelsChecksThenResumesWithoutLosingWork() async throws {
        let (db, _) = try await fixture()
        try await journal(db, "pause")
        let probe = StatusProbe()
        let worker = SendStatusTracker(database: db) { send in
            await probe.begin(send.id)
            if await probe.calls.count == 1 { try await Task.sleep(for: .seconds(60)) }
            try await Self.confirm(db, send)
        }
        await worker.resume()
        try await wait { await probe.calls.count == 1 }
        await worker.pause()
        let state = try await db.send("pause")?.state
        XCTAssertEqual(state, "broadcast")
        let attempts = try await db.pool.read { try Int.fetchOne($0, sql: "SELECT attempts FROM sendStatusChecks") }
        XCTAssertEqual(attempts, 0)
        await worker.resume()
        try await wait { try await self.count(db) == 0 }
        await worker.pause()
    }
    func testRemovedWalletAndResetNeverRunChecks() async throws {
        let (db, _) = try await fixture()
        try await journal(db, "removed", wallet: "w2")
        try await db.reconcileWalletLifecycle([.init(id: "w2", deletedAt: 100)])
        let none = try await db.claimSendStatusChecks(owner: "test")
        XCTAssertTrue(none.isEmpty)
        try await db.reconcileWalletLifecycle([.init(id: "w2", deletedAt: nil)])
        let restored = try await db.claimSendStatusChecks(owner: "test")
        XCTAssertEqual(restored.count, 1)
        let reset = try await db.beginWalletReset()
        try await db.finishSendStatusCheck(restored[0], failed: false, cancelled: true)
        let blocked = try await db.claimSendStatusChecks(owner: "test")
        XCTAssertTrue(blocked.isEmpty)
        try await db.eraseWalletData(resetID: reset)
        let rows = try await count(db)
        XCTAssertEqual(rows, 0)
    }
    func testTerminalFailureCancellationAndReorgTransitionsAreAtomic() async throws {
        let (db,url)=try await fixture()
        for state in ["failed","cancelled","confirmed"] {
            try await journal(db,state)
            try await db.pool.write { sql in
                let txID="bitcoin:"+state
                try TransactionRecord(id:txID,networkID:"bitcoin",hash:state,state:state == "cancelled" ? "replaced" : state,blockHeight:100,timestamp:1,updatedAt:1).insert(sql)
                try sql.execute(sql:"UPDATE sends SET state=?,transactionID=? WHERE id=?",arguments:[state,txID,state])
            }
        }
        let zero=try await count(db);XCTAssertEqual(zero,0)
        try await db.pool.write { try $0.execute(sql:"UPDATE transactions SET state='reorged',blockHeight=NULL WHERE id='bitcoin:confirmed'") }
        let reopened=try await OathDatabase.open(at:url)
        let jobs=try await reopened.claimSendStatusChecks(owner:"reorg")
        XCTAssertEqual(jobs.map(\.send.id),["confirmed"])
        XCTAssertEqual(jobs.first?.send.state,"broadcast")
    }
    func testStartupCancelsOnlyUnsignedWorkFromPreviousProcess() async throws {
        let (db,_)=try await fixture()
        try await journal(db,"oldSigned",broadcast:false)
        try await journal(db,"oldUnsigned",broadcast:false)
        try await journal(db,"newUnsigned",broadcast:false)
        try await db.pool.write { sql in
            try sql.execute(sql:"UPDATE sends SET state='queued',signedPayload=NULL,createdAt=CASE id WHEN 'newUnsigned' THEN 300 ELSE 1 END WHERE id IN ('oldUnsigned','newUnsigned')")
            try sql.execute(sql:"DELETE FROM sendStatusChecks WHERE sendID IN ('oldUnsigned','newUnsigned')")
        }
        try await db.cancelAbandonedUnsignedSends(before:200)
        let old=try await db.send("oldUnsigned"),fresh=try await db.send("newUnsigned"),signed=try await db.send("oldSigned")
        XCTAssertEqual(old?.state,"cancelled");XCTAssertEqual(fresh?.state,"queued");XCTAssertEqual(signed?.state,"signed")
        let freed=try await db.reservedOutputs(sendID:"oldUnsigned"),kept=try await db.reservedOutputs(sendID:"oldSigned")
        XCTAssertTrue(freed.isEmpty);XCTAssertEqual(kept.count,1)
    }
    func testMigrationBackfillsOnlyUnfinishedAndUsesDueIndex() async throws {
        let (db, url) = try await fixture()
        try await journal(db, "pending")
        try await journal(db, "signed", broadcast: false)
        try await journal(db, "finished")
        let finished = try await db.send("finished")
        try await Self.confirm(db, XCTUnwrap(finished))
        try await db.pool.write {
            try $0.execute(sql: """
                DROP TRIGGER send_status_insert; DROP TRIGGER send_status_pending; DROP TRIGGER send_status_terminal; DROP TRIGGER send_status_reorg;
                DROP TABLE sendStatusChecks; DELETE FROM grdb_migrations WHERE identifier='v40_send_status_tracking';
                """)
        }
        let reopened = try await OathDatabase.open(at: url)
        let rows = try await reopened.claimSendStatusChecks(owner: "migrated")
        XCTAssertEqual(Set(rows.map { $0.send.id }), ["pending","signed"])
        let indexes = try await reopened.pool.read { try String.fetchAll($0, sql: "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='sendStatusChecks'") }
        XCTAssertTrue(indexes.contains("send_status_due"))
        let plan = try await reopened.pool.read { sql in
            try Row.fetchAll(sql,sql:"EXPLAIN QUERY PLAN SELECT sendID FROM sendStatusChecks WHERE availableAt<=? ORDER BY availableAt,sendID LIMIT 4",arguments:[100]).map { $0["detail"] as String }
        }
        XCTAssertTrue(plan.contains { $0.contains("send_status_due") })
        XCTAssertFalse(plan.contains { $0.contains("TEMP B-TREE") },"Due checks must not sort the entire queue")
    }

    /// Upgrading an installed v40 is different from creating a fresh database:
    /// changing the CREATE TABLE text cannot add a column to that installation.
    func testUpgradeFromInstalledStatusQueueWithoutAvailableAt() async throws {
        let (db, url) = try await fixture()
        for id in ["retry", "leased", "later", "settled"] { try await journal(db, id) }
        let settled = try await db.send("settled")
        try await Self.confirm(db, XCTUnwrap(settled))
        try await db.pool.write { sql in
            try sql.execute(sql: """
                UPDATE sendStatusChecks SET nextAttemptAt=40,attempts=7,lastCheckedAt=12 WHERE sendID='retry';
                UPDATE sendStatusChecks SET nextAttemptAt=30,attempts=2,lastCheckedAt=10,
                    leaseToken='fixture-lease',leaseOwner='fixture-owner',leaseUntil=100 WHERE sendID='leased';
                UPDATE sendStatusChecks SET nextAttemptAt=180,attempts=5,lastCheckedAt=20,
                    leaseToken='fixture-later',leaseOwner='fixture-owner',leaseUntil=90 WHERE sendID='later';
                DROP INDEX send_status_due;
                ALTER TABLE sendStatusChecks DROP COLUMN availableAt;
                CREATE INDEX send_status_due ON sendStatusChecks(nextAttemptAt,sendID);
                DELETE FROM grdb_migrations WHERE identifier='v47_send_status_available_at';
                """)
        }
        let v40Recorded = try await db.pool.read { try Bool.fetchOne($0, sql: "SELECT EXISTS(SELECT 1 FROM grdb_migrations WHERE identifier='v40_send_status_tracking')") }
        XCTAssertEqual(v40Recorded, true)
        do {
            _ = try await db.nextSendStatusDeadline()
            XCTFail("Legacy fixture did not reproduce the missing-column failure")
        } catch let error as DatabaseError {
            XCTAssertEqual(error.resultCode, .SQLITE_ERROR)
            XCTAssertTrue(error.message?.contains("no such column: c.availableAt") == true)
        }

        let before = try await queueFields(db)
        let sendsBefore = try await db.pool.read { try SendRecord.fetchAll($0, sql: "SELECT * FROM sends ORDER BY id") }
        let reopened = try await OathDatabase.open(at: url)
        let after = try await queueFields(reopened)
        XCTAssertEqual(before, after, "Upgrade must preserve retries and in-flight leases")
        let sendsAfter = try await reopened.pool.read { try SendRecord.fetchAll($0, sql: "SELECT * FROM sends ORDER BY id") }
        XCTAssertEqual(sendsBefore, sendsAfter, "Upgrade must not rewrite signed transactions or history")
        let wallets = try await reopened.wallets()
        XCTAssertEqual(wallets.count, 2)
        let deadline = try await reopened.nextSendStatusDeadline()
        XCTAssertEqual(deadline, 40)
        let remainingDeadline = try await reopened.nextSendStatusDeadline(excluding: ["retry"])
        XCTAssertEqual(remainingDeadline, 100, "Lease deadline must delay an otherwise due retry")
        let laterDeadline = try await reopened.nextSendStatusDeadline(excluding: ["retry", "leased"])
        XCTAssertEqual(laterDeadline, 180, "Later retry deadline must win over earlier lease")
        let premature = try await reopened.claimSendStatusChecks(owner: "worker", now: 39)
        XCTAssertTrue(premature.isEmpty)
        let due = try await reopened.claimSendStatusChecks(owner: "worker", now: 40)
        XCTAssertEqual(due.map(\.send.id), ["retry"])
        let check = try XCTUnwrap(due.first)
        try await reopened.finishSendStatusCheck(check, failed: false, now: 40)
        let next = try await reopened.nextSendStatusDeadline()
        XCTAssertEqual(next, 100, "Finishing a check must update its computed deadline")

        try await assertDueIndex(reopened)
        let integrity = try await reopened.pool.read { try String.fetchOne($0, sql: "PRAGMA integrity_check") }
        XCTAssertEqual(integrity, "ok")
        let violations = try await reopened.pool.read { try Row.fetchAll($0, sql: "PRAGMA foreign_key_check").count }
        XCTAssertEqual(violations, 0)

        // Reopening must not reset backoff or leases and must not add twice.
        let persisted = try await queueFields(reopened)
        let again = try await OathDatabase.open(at: url)
        let persistedAgain = try await queueFields(again)
        XCTAssertEqual(persisted, persistedAgain)
        let leased = try await again.send("leased")
        try await Self.confirm(again, XCTUnwrap(leased))
        let afterSettlement = try await queueFields(again)
        XCTAssertEqual(afterSettlement.map(\.sendID), ["later", "retry"])
        try await journal(again, "new-after-upgrade", broadcast: false)
        let newJobs = try await again.claimSendStatusChecks(owner: "worker", now: 0)
        XCTAssertEqual(newJobs.map(\.send.id), ["new-after-upgrade"], "Enrollment trigger must survive upgrade")
    }

    func testUpgradeWithStoredAvailableAtPreservesColumnAndRepairsIndex() async throws {
        let (db, url) = try await fixture()
        try await journal(db, "current")
        try await db.pool.write { sql in
            try sql.execute(sql: """
                DROP INDEX send_status_due;
                CREATE INDEX send_status_due ON sendStatusChecks(nextAttemptAt,sendID);
                DELETE FROM grdb_migrations WHERE identifier='v47_send_status_available_at';
                """)
        }
        let before = try await queueFields(db)
        let reopened = try await OathDatabase.open(at: url)
        let columns = try await reopened.pool.read { sql in
            try Row.fetchAll(sql, sql: "PRAGMA table_xinfo(sendStatusChecks)")
                .filter { ($0["name"] as String) == "availableAt" }.map { $0["hidden"] as Int }
        }
        XCTAssertEqual(columns, [3], "Existing STORED column must be recognized, not re-added")
        let after = try await queueFields(reopened)
        XCTAssertEqual(before, after)
        try await assertDueIndex(reopened)
        let deadline = try await reopened.nextSendStatusDeadline()
        XCTAssertEqual(deadline, 0)
    }

    func testUpgradedDeadlineObservationTracksLeaseRetryAndSettlement() async throws {
        try await assertDeadlineObservation(upgrade: true)
    }

    func testStoredDeadlineObservationTracksLeaseRetryAndSettlement() async throws {
        try await assertDeadlineObservation(upgrade: false)
    }

    private func assertDeadlineObservation(upgrade: Bool) async throws {
        let (db, url) = try await fixture()
        try await journal(db, "observed")
        if upgrade {
            try await db.pool.write { sql in
                try sql.execute(sql: """
                    DROP INDEX send_status_due;
                    ALTER TABLE sendStatusChecks DROP COLUMN availableAt;
                    CREATE INDEX send_status_due ON sendStatusChecks(nextAttemptAt,sendID);
                    DELETE FROM grdb_migrations WHERE identifier='v47_send_status_available_at';
                    """)
            }
        }
        let reopened = try await OathDatabase.open(at: url)
        let probe = StatusDeadlineProbe()
        let observation = Task {
            do {
                for try await value in reopened.observeSendStatusDeadline() { await probe.append(value) }
            } catch {
                if !Task.isCancelled { XCTFail("Upgraded deadline observation failed") }
            }
        }
        defer { observation.cancel() }
        try await wait { await probe.lastIs(0) }
        let claimed = try await reopened.claimSendStatusChecks(owner: "observation", now: 100)
        let check = try XCTUnwrap(claimed.first)
        try await wait { await probe.lastIs(1_000) }
        try await reopened.finishSendStatusCheck(check, failed: false, now: 100)
        try await wait { await probe.lastIs(102) }
        try await Self.confirm(reopened, check.send)
        try await wait { await probe.lastIs(nil) }

        // Starting the actual worker on the upgraded queue must also observe
        // newly journaled sends and settle them without an app restart.
        let worker = SendStatusTracker(database: reopened) { send in try await Self.confirm(reopened, send) }
        await worker.resume()
        try await journal(reopened, "after-observation")
        try await wait { try await self.count(reopened) == 0 }
        await worker.pause()
        let final = try await reopened.send("after-observation")
        XCTAssertEqual(final?.state, "confirmed")
    }

    private struct QueueFields: Decodable, FetchableRecord, Equatable, Sendable {
        let sendID: String
        let nextAttemptAt: Double
        let attempts: Int
        let lastCheckedAt: Double?
        let leaseToken: String?
        let leaseOwner: String?
        let leaseUntil: Double?
    }
    private func queueFields(_ db: OathDatabase) async throws -> [QueueFields] {
        try await db.pool.read {
            try QueueFields.fetchAll($0, sql: "SELECT sendID,nextAttemptAt,attempts,lastCheckedAt,leaseToken,leaseOwner,leaseUntil FROM sendStatusChecks ORDER BY sendID")
        }
    }
    private func assertDueIndex(_ db: OathDatabase) async throws {
        let plan = try await db.pool.read { sql in
            try Row.fetchAll(sql, sql: """
                EXPLAIN QUERY PLAN SELECT c.availableAt,c.nextAttemptAt,c.leaseUntil FROM sendStatusChecks c INDEXED BY send_status_due
                JOIN sends s ON s.id=c.sendID JOIN wallets w ON w.id=s.walletID
                WHERE s.state IN ('signed','broadcast') AND w.deletedAt IS NULL
                AND NOT EXISTS(SELECT 1 FROM metadata WHERE key='walletReset')
                ORDER BY c.availableAt,c.sendID LIMIT 1
                """).map { $0["detail"] as String }
        }
        XCTAssertTrue(plan.contains { $0.contains("send_status_due") })
        XCTAssertFalse(plan.contains { $0.contains("TEMP B-TREE") })
    }
}
