import Foundation
import GRDB
import XCTest
@testable import OathAnkr
@testable import OathDatabase

private actor SendProgressProbe {
    var values: [SendProgress?] = []
    func append(_ value: SendProgress?) { values.append(value) }
    func has(_ outcome: SendProgress.Outcome?) -> Bool {
        guard let last = values.last else { return false }
        return last?.outcome == outcome
    }
}

extension EVMSendJournalTests {
    private func progressFixture() async throws -> (OathDatabase, URL, EVMSignedSend) {
        let (db, folder, plan) = try await fixture()
        try await draft("progress", plan: plan, db: db)
        try await db.queueEVMSend(sendID: "progress", plan: plan)
        let signed = try EVMSendCrypto.sign(plan, privateKey: key)
        try await db.journalEVMSignature(sendID: "progress", signed: signed)
        return (db, folder, signed)
    }
    private func observeProgress(_ db: OathDatabase, probe: SendProgressProbe) -> Task<Void, Error> {
        Task {
            for try await value in db.observeSendProgress(sendID: "progress") { await probe.append(value) }
        }
    }
    private func waitForProgress(_ probe: SendProgressProbe, _ outcome: SendProgress.Outcome?, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<300 {
            if await probe.has(outcome) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Expected progress was not observed", file: file, line: line)
        throw StoreError.invalidValue("test progress timeout")
    }

    func testProgressObservesAtomicReceiptAndEachTerminalOutcome() async throws {
        for outcome: EVMSendReceipt.Outcome in [.confirmed, .failed, .cancelled, .replaced] {
            let (db, folder, signed) = try await progressFixture()
            defer { try? FileManager.default.removeItem(at: folder) }
            let probe = SendProgressProbe(), task = observeProgress(db, probe: probe)
            defer { task.cancel() }
            try await waitForProgress(probe, .pending)
            _ = try await db.transitionSend("progress", from: "signed", to: "broadcast")
            for result: EVMSendReceipt.Outcome in [.accepted, .unknown] {
                try await db.settleEVMSend(sendID: "progress", receipt: .init(hash: signed.hash, outcome: result))
            }
            // Aged/retried sends remain observable and never become failures
            // merely because a provider has not found a receipt yet.
            try await db.pool.write { sql in
                try sql.execute(sql: "UPDATE sends SET createdAt=1 WHERE id='progress'")
                try sql.execute(sql: "UPDATE sendStatusChecks SET attempts=150 WHERE sendID='progress'")
            }
            let mined = outcome == .confirmed || outcome == .failed
            let replacement = mined ? nil : "0x" + String(repeating: "f", count: 64)
            try await db.settleEVMSend(sendID: "progress", receipt: .init(hash: signed.hash, outcome: outcome,
                fee: mined ? 500 : nil, height: mined ? 123 : nil, timestamp: mined ? 123 : nil, replacementHash: replacement))
            let expected: SendProgress.Outcome = outcome == .confirmed ? .confirmed : outcome == .failed ? .failed : outcome == .cancelled ? .cancelled : .replaced
            try await waitForProgress(probe, expected)
            task.cancel(); _ = await task.result
            let values = await probe.values.compactMap { $0 }
            XCTAssertEqual(values.map(\.outcome), [.pending, expected], "Unrelated writes and broadcast acceptance must not emit duplicate progress")
            XCTAssertNil(values.first?.actualFee, "Never display the pending gas cap as the paid fee")
            XCTAssertEqual(values.last?.actualFee, mined ? "500" : nil)
            XCTAssertEqual(values.last?.blockHeight, mined ? 123 : nil)
            XCTAssertEqual(values.last?.replacementHash, replacement)
        }
    }

    func testClosingObserverDoesNotStopWorkerAndReopeningGetsFinalState() async throws {
        let (db, folder, signed) = try await progressFixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let probe = SendProgressProbe(), task = observeProgress(db, probe: probe)
        try await waitForProgress(probe, .pending)
        task.cancel(); _ = await task.result
        let worker = SendStatusTracker(database: db) { send in
            try await db.settleEVMSend(sendID: send.id, receipt: .init(hash: signed.hash, outcome: .confirmed, fee: 500, height: 123, timestamp: 123))
        }
        await worker.resume()
        let live = SendProgressProbe(), liveTask = observeProgress(db, probe: live)
        defer { liveTask.cancel() }
        try await waitForProgress(live, .confirmed)
        await worker.pause()
        liveTask.cancel(); _ = await liveTask.result
        let originalValues = await probe.values
        XCTAssertEqual(originalValues.compactMap { $0?.outcome }, [.pending])
        let reopened = try await OathDatabase.open(at: folder.appendingPathComponent("db.sqlite"))
        var iterator = reopened.observeSendProgress(sendID: "progress").makeAsyncIterator()
        let restored = try await iterator.next()
        XCTAssertEqual(restored??.outcome, .confirmed)
        XCTAssertEqual(restored??.actualFee, "500")
    }

    func testProgressKeepsObservingReorgAndClearsObsoleteReceipt() async throws {
        let (db, folder, signed) = try await progressFixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let probe = SendProgressProbe(), task = observeProgress(db, probe: probe)
        defer { task.cancel() }
        try await db.settleEVMSend(sendID: "progress", receipt: .init(hash: signed.hash, outcome: .confirmed, fee: 500, height: 123, timestamp: 123))
        try await waitForProgress(probe, .confirmed)
        try await db.pool.write { sql in
            try sql.execute(sql: "UPDATE transactions SET state='reorged',blockHeight=NULL WHERE hash=?", arguments: [signed.hash])
        }
        try await waitForProgress(probe, .pending)
        let values = await probe.values.compactMap { $0 }
        XCTAssertNil(values.last?.actualFee)
        XCTAssertNil(values.last?.blockHeight)
        try await db.settleEVMSend(sendID: "progress", receipt: .init(hash: signed.hash, outcome: .confirmed, fee: 600, height: 124, timestamp: 124))
        try await waitForProgress(probe, .confirmed)
        task.cancel(); _ = await task.result
        let finalValues = await probe.values.compactMap { $0 }
        XCTAssertEqual(finalValues.last?.actualFee, "600")
    }

    func testProgressHidesDeletedWalletAndReset() async throws {
        let (db, folder, _) = try await progressFixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let probe = SendProgressProbe(), task = observeProgress(db, probe: probe)
        defer { task.cancel() }
        try await waitForProgress(probe, .pending)
        try await db.reconcileWalletLifecycle([.init(id: "w1", deletedAt: 100)])
        try await waitForProgress(probe, nil)
        try await db.reconcileWalletLifecycle([.init(id: "w1", deletedAt: nil)])
        try await waitForProgress(probe, .pending)
        _ = try await db.beginWalletReset()
        try await waitForProgress(probe, nil)
        task.cancel(); _ = await task.result
    }
}
