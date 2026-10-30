import Foundation
import GRDB
import XCTest
@testable import OathDatabase

private actor RefreshProbe {
    var calls: [SendBalanceRefreshTarget] = []
    var waits: [Duration] = []
    func call(_ target: SendBalanceRefreshTarget) -> Int { calls.append(target); return calls.count }
    func sleep(_ duration: Duration) { waits.append(duration) }
}
private actor RefreshGate {
    var entered = false
    var waiter: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; await withCheckedContinuation { waiter = $0 } }
    func release() { waiter?.resume(); waiter = nil }
}
private actor ParallelRefreshProbe {
    var active = 0
    var peak = 0
    var calls = 0
    func begin() { active += 1; calls += 1; peak = max(peak, active) }
    func end() { active -= 1 }
}

@MainActor final class PostSendBalanceRefreshTests: XCTestCase {
    private let networks = ["bitcoin", "bitcoincash", "litecoin", "dogecoin", "future-chain"]
    private func fixture(extraNetwork: String? = nil) async throws -> (OathDatabase, URL) {
        let networks = self.networks + (extraNetwork.map { self.networks.contains($0) ? [] : [$0] } ?? [])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PostSend-" + UUID().uuidString).appendingPathComponent("db.sqlite")
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
    private func journal(_ db: OathDatabase, _ id: String, network: String = "bitcoin", wallet: String = "w1", broadcast: Bool = true) async throws -> SendBalanceRefreshTarget {
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
        return .init(walletID: wallet, networkID: network)
    }
    private func wait(_ predicate: () async throws -> Bool) async throws {
        for _ in 0..<300 {
            if try await predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Refresh did not reach the expected state")
    }

    func testAutomaticJournalHookRoutesAllFourChainsAndFutureChain() async throws {
        let (db, url) = try await fixture()
        for network in networks { try await journal(db, network, network: network) }
        try await journal(db, "not-broadcast", wallet: "w2", broadcast: false)
        let reopened = try await OathDatabase.open(at: url)
        let probe = RefreshProbe()
        let worker = PostSendBalanceRefresher(database: reopened, delays: [.zero], sleep: { _ in }) { target, sends in
            _ = await probe.call(target)
            XCTAssertTrue(sends.allSatisfy { $0.walletID == target.walletID && $0.networkID == target.networkID })
            return Set(sends.map(\.id))
        }
        await worker.resume()
        try await wait { try await reopened.pendingSendBalanceRefreshTargets().isEmpty }
        let calls = await probe.calls
        XCTAssertEqual(Set(calls.map(\.networkID)), Set(networks)); XCTAssertEqual(calls.count, 5)
        XCTAssertTrue(calls.allSatisfy { $0.walletID == "w1" })
        for target in calls { await worker.request(target) }
        try await Task.sleep(for: .milliseconds(30))
        let repeated = await probe.calls.count
        XCTAssertEqual(repeated, 5, "Repeated acknowledgement must not refresh already completed work")
        let signed = try await reopened.send("not-broadcast")
        XCTAssertEqual(signed?.state, "signed")
        await worker.pause()
    }

    func testRetriesTransportFailureThenStaleSuccessWithoutChangingSendState() async throws {
        let (db, _) = try await fixture()
        let target = try await journal(db, "send")
        let probe = RefreshProbe()
        let worker = PostSendBalanceRefresher(database: db, delays: [.zero, .seconds(1), .seconds(2)], sleep: { await probe.sleep($0) }) { target, sends in
            switch await probe.call(target) {
            case 1: throw URLError(.notConnectedToInternet)
            case 2: return [] // Successful request; provider has not indexed our send.
            default: return Set(sends.map(\.id))
            }
        }
        await worker.resume()
        try await wait { try await db.pendingSendBalanceRefreshes(target).isEmpty }
        let waits = await probe.waits, calls = await probe.calls
        XCTAssertEqual(waits, [.seconds(1), .seconds(2)]); XCTAssertEqual(calls.count, 3)
        let send = try await db.send("send"), reserved = try await db.reservedOutputs(sendID: "send")
        XCTAssertEqual(send?.state, "broadcast"); XCTAssertEqual(reserved.count, 1)
        await worker.pause()
    }

    func testExhaustionSurvivesRestartAndResumesWithoutRebroadcast() async throws {
        let (db, url) = try await fixture()
        let target = try await journal(db, "offline")
        let probe = RefreshProbe()
        let worker = PostSendBalanceRefresher(database: db, delays: [.zero, .zero, .zero], sleep: { _ in }) { target, _ in
            _ = await probe.call(target); throw URLError(.timedOut)
        }
        await worker.resume()
        try await wait { await probe.calls.count == 3 }
        try await Task.sleep(for: .milliseconds(30))
        let count = await probe.calls.count
        XCTAssertEqual(count, 3, "Retries must stop after the bounded burst")
        await worker.pause()
        let reopened = try await OathDatabase.open(at: url)
        let pending = try await reopened.pendingSendBalanceRefreshes(target)
        XCTAssertEqual(pending.map(\.id), ["offline"])
        let resumed = PostSendBalanceRefresher(database: reopened, delays: [.zero], sleep: { _ in }) { _, sends in Set(sends.map(\.id)) }
        await resumed.resume()
        try await wait { try await reopened.pendingSendBalanceRefreshes(target).isEmpty }
        let send = try await reopened.send("offline")
        XCTAssertEqual(send?.signedPayload, Data("public-fixture".utf8)); XCTAssertEqual(send?.state, "broadcast")
        await resumed.pause()
    }

    func testPauseRejectsLateCompletionAndResumeKeepsPendingWork() async throws {
        let (db, _) = try await fixture()
        let target = try await journal(db, "locked")
        let gate = RefreshGate(), probe = RefreshProbe()
        let worker = PostSendBalanceRefresher(database: db, delays: [.zero], sleep: { _ in }) { target, sends in
            if await probe.call(target) == 1 { await gate.wait() }
            return Set(sends.map(\.id)) // Deliberately returns after cancellation.
        }
        await worker.resume()
        try await wait { await gate.entered }
        await worker.pause()
        await worker.request(target)
        await gate.release()
        try await Task.sleep(for: .milliseconds(30))
        let pending = try await db.pendingSendBalanceRefreshes(target), count = await probe.calls.count
        XCTAssertEqual(pending.count, 1); XCTAssertEqual(count, 1)
        await worker.resume()
        try await wait { try await db.pendingSendBalanceRefreshes(target).isEmpty }
        await worker.pause()
    }

    func testNewSendDuringRefreshIsNotLostAndDuplicateRequestsCoalesce() async throws {
        let (db, _) = try await fixture()
        let target = try await journal(db, "first")
        let gate = RefreshGate(), probe = RefreshProbe()
        let worker = PostSendBalanceRefresher(database: db, delays: [.zero], sleep: { _ in }) { target, sends in
            if await probe.call(target) == 1 { await gate.wait() }
            return Set(sends.map(\.id))
        }
        await worker.resume()
        try await wait { await gate.entered }
        try await journal(db, "second")
        for _ in 0..<20 { await worker.request(target) }
        await gate.release()
        try await wait { try await db.pendingSendBalanceRefreshes(target).isEmpty }
        let count = await probe.calls.count
        XCTAssertEqual(count, 2)
        await worker.pause()
    }

    func testWalletAndChainIsolationAlsoProtectsAcknowledgements() async throws {
        let (db, _) = try await fixture()
        let first = try await journal(db, "first")
        let other = try await journal(db, "other", network: "dogecoin", wallet: "w2")
        try await db.completeSendBalanceRefreshes(["other"], target: first, revisions: ["other": 0])
        let pending = try await db.pendingSendBalanceRefreshes(other)
        XCTAssertEqual(pending.map(\.id), ["other"])
        let firstPage = try await db.pendingSendBalanceRefreshTargets(limit: 1)
        let secondPage = try await db.pendingSendBalanceRefreshTargets(after: firstPage.first, limit: 1)
        XCTAssertEqual(firstPage, [first]); XCTAssertEqual(secondPage, [other])
        try await db.reconcileWalletLifecycle([.init(id: "w2", deletedAt: 100)])
        let deleted = try await db.pendingSendBalanceRefreshes(other)
        XCTAssertTrue(deleted.isEmpty)
        let reset = try await db.beginWalletReset()
        try await db.eraseWalletData(resetID: reset)
        let rows = try await db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sendBalanceRefreshes") }
        XCTAssertEqual(rows, 0)
    }

    func testMigrationRecoversPendingBroadcastsWithoutReplayingOldConfirmedHistory() async throws {
        let (db, url) = try await fixture()
        let target = try await journal(db, "pending")
        try await journal(db, "signed", broadcast: false)
        try await journal(db, "old-confirmed")
        try await db.pool.write { db in
            try TransactionRecord(id: "bitcoin:confirmed", networkID: "bitcoin", hash: "confirmed",
                state: "confirmed", blockHeight: 100, timestamp: 1, updatedAt: 1).insert(db)
            try db.execute(sql: "UPDATE sends SET transactionID='bitcoin:confirmed' WHERE id='old-confirmed'")
        }
        _ = try await db.transitionSend("old-confirmed", from: "broadcast", to: "confirmed")
        try await db.pool.write { sql in
            for name in try String.fetchAll(sql, sql: "SELECT name FROM sqlite_master WHERE type='trigger' AND name GLOB 'send_balance_*'") {
                try sql.execute(sql: "DROP TRIGGER \(name)")
            }
            try sql.execute(sql: "DROP TABLE sendBalanceRefreshSignal; DROP TABLE sendBalanceRefreshes; DELETE FROM grdb_migrations WHERE identifier IN ('v33_post_send_balance_refresh','v72_live_send_balance_refresh')")
        }
        let reopened = try await OathDatabase.open(at: url)
        let rows = try await reopened.pendingSendBalanceRefreshes(target)
        XCTAssertEqual(rows.map(\.id), ["pending"])
    }

    func testDurableQueuePagesBeyondMemoryLimitWithBoundedConcurrency() async throws {
        let (db, _) = try await fixture()
        for index in 0..<70 {
            let wallet = String(format: "bulk-%03d", index)
            try await db.importWalletIfNeeded(.init(id: wallet, name: "Fixture", kind: "hd", vaultReference: wallet, createdAt: 1),
                accounts: [.init(id: wallet + "bitcoin", walletID: wallet, networkID: "bitcoin", address: "public-fixture", derivationPath: "fixture")])
            try await journal(db, wallet, wallet: wallet)
        }
        let probe = ParallelRefreshProbe()
        let worker = PostSendBalanceRefresher(database: db, delays: [.zero], sleep: { _ in }) { _, sends in
            await probe.begin()
            try await Task.sleep(for: .milliseconds(10))
            await probe.end()
            return Set(sends.map(\.id))
        }
        await worker.resume()
        try await wait { try await db.pendingSendBalanceRefreshTargets().isEmpty }
        let count = await probe.calls, peak = await probe.peak
        XCTAssertEqual(count, 70)
        XCTAssertGreaterThan(peak, 1)
        XCTAssertLessThanOrEqual(peak, 4)
        await worker.pause()
    }
    func testNewBroadcastWakesIdleWorkerWithoutScreenCallback() async throws {
        let (db, _) = try await fixture()
        let probe = RefreshProbe()
        let worker = PostSendBalanceRefresher(database: db, delays: [.zero], sleep: { _ in }) { target, sends in
            _ = await probe.call(target)
            return Set(sends.map(\.id))
        }
        await worker.resume()
        try await Task.sleep(for: .milliseconds(30))
        _ = try await journal(db, "late-send", network: "litecoin")
        try await wait { await probe.calls.count == 1 }
        try await wait { try await db.pendingSendBalanceRefreshTargets().isEmpty }
        await worker.pause()
    }

    func testConfirmationWakesAnExhaustedBurstWithoutReopeningApp() async throws {
        let (db, _) = try await fixture()
        let target = try await journal(db, "slow")
        let probe = RefreshProbe()
        let worker = PostSendBalanceRefresher(database: db, delays: [.zero], sleep: { _ in }) { target, sends in
            _ = await probe.call(target)
            return Set(sends.filter { $0.state == "confirmed" }.map(\.id))
        }
        await worker.resume()
        try await wait { await probe.calls.count > 0 }
        try await Task.sleep(for: .milliseconds(100))
        try await db.pool.write { sql in
            try TransactionRecord(id: "bitcoin:slow", networkID: "bitcoin", hash: "slow", state: "confirmed", blockHeight: 10, timestamp: 1, updatedAt: 1).insert(sql)
            try sql.execute(sql: "UPDATE sends SET transactionID='bitcoin:slow' WHERE id='slow'")
        }
        _ = try await db.transitionSend("slow", from: "broadcast", to: "confirmed")
        try await wait { try await db.pendingSendBalanceRefreshes(target).isEmpty }
        let calls = await probe.calls.count
        XCTAssertGreaterThanOrEqual(calls, 2)
        await worker.pause()
    }

    func testNewReceiptCannotBeClearedByOlderInFlightBalanceRead() async throws {
        let (db, _) = try await fixture()
        let target = try await journal(db, "race")
        let old = try await db.sendBalanceRefreshRevisions(target)
        try await db.pool.write { try $0.execute(sql: "UPDATE sendBalanceRefreshes SET completedAt=NULL WHERE sendID='race'") }
        try await db.completeSendBalanceRefreshes(["race"], target: target, revisions: old)
        let pending = try await db.pendingSendBalanceRefreshes(target)
        XCTAssertEqual(pending.map(\.id), ["race"])
        let fresh = try await db.sendBalanceRefreshRevisions(target)
        try await db.completeSendBalanceRefreshes(["race"], target: target, revisions: fresh)
        let completed = try await db.pendingSendBalanceRefreshes(target)
        XCTAssertTrue(completed.isEmpty)
    }

    func testEveryAcknowledgementJournalAutomaticallyRequeuesOnce() async throws {
        for (network, table) in [
            ("bitcoin", "bitcoinSendPlans"), ("bitcoincash", "bitcoinSendPlans"),
            ("litecoin", "bitcoinSendPlans"), ("dogecoin", "bitcoinSendPlans"),
            ("ethereum", "evmSendPlans"), ("arc", "arcSendPlans"), ("aptos", "aptosSendPlans"),
            ("ton", "tonSendPlans"), ("solana", "solanaSendPlans"), ("tron", "tronSendPlans"),
            ("near", "nearSendPlans"), ("polkadot", "polkadotSendPlans"), ("stellar", "stellarSendPlans"), ("xrpl", "xrplSendPlans"),
            ("thorchain", "thorchainSendPlans")
        ] {
            // Public journal fixtures isolate scheduling; per-chain journal
            // suites separately exercise cryptographic receipt validation.
            let (db, _) = try await fixture(extraNetwork: network)
            let target = try await journal(db, "ack", network: network, broadcast: true)
            try await db.pool.write { sql in
                try sql.execute(sql: "INSERT INTO \(table)(sendID,plan) VALUES('ack',X'00')")
            }
            let before = try await db.sendBalanceRefreshRevisions(target)
            try await db.completeSendBalanceRefreshes(["ack"], target: target, revisions: before)
            let probe = RefreshProbe()
            let worker = PostSendBalanceRefresher(database: db, delays: [.zero], sleep: { _ in }) { target, sends in
                _ = await probe.call(target); return Set(sends.map(\.id))
            }
            await worker.resume()
            try await Task.sleep(for: .milliseconds(20))
            try await db.pool.write { try $0.execute(sql: "UPDATE \(table) SET submittedAt=123 WHERE sendID='ack'") }
            try await wait { await probe.calls.count == 1 }
            try await wait { try await db.pendingSendBalanceRefreshTargets().isEmpty }
            try await db.pool.write { try $0.execute(sql: "UPDATE \(table) SET submittedAt=COALESCE(submittedAt,456) WHERE sendID='ack'") }
            try await Task.sleep(for: .milliseconds(20))
            let count = await probe.calls.count
            XCTAssertEqual(count, 1, network)
            await worker.pause()
        }
    }

    func testExpiredUnexecutedSendDoesNotRetryBalancesForever() async throws {
        let (db, _) = try await fixture(extraNetwork: "aptos")
        let target = try await journal(db, "expired", network: "aptos")
        try await db.pool.write { try $0.execute(sql: "UPDATE sends SET state='failed',failureCode='expired' WHERE id='expired'") }
        let pending = try await db.pendingSendBalanceRefreshes(target)
        XCTAssertTrue(pending.isEmpty)
        let targets = try await db.pendingSendBalanceRefreshTargets()
        XCTAssertTrue(targets.isEmpty)
    }

}
