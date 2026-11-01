import XCTest
import GRDB
@testable import OathAnkr
@testable import OathDatabase

/// Real SQL/signature journal, synthetic keys; no provider or funded transaction.
@MainActor final class PermissionReadbackIdempotencyTests: XCTestCase {
    func testLateRemovedCallbackCannotReplaceActiveBatchResult() async throws {
        try await exercise(firstRemoved: false, reorg: false)
    }
    func testLateActiveCallbackCannotReplaceRemovedBatchResult() async throws {
        try await exercise(firstRemoved: true, reorg: false)
    }
    func testReorgAllowsFreshReadbackInBothDirections() async throws {
        try await exercise(firstRemoved: false, reorg: true)
        try await exercise(firstRemoved: true, reorg: true)
    }
    private func exercise(firstRemoved: Bool, reorg: Bool) async throws {
        let (db, folder, plan) = try await PermissionPersistenceTests().fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let item = try PermissionBatchTests().item(plan)
        try await db.savePermissionBatch([item])
        try await EVMSendJournalTests().draft(item.id, plan: plan, db: db)
        try await db.queueEVMSend(sendID: item.id, plan: plan)
        let signed = try EVMSendCrypto.sign(plan, privateKey: Data(repeating: 1, count: 32))
        try await db.journalEVMSignature(sendID: item.id, signed: signed)
        try await db.settleEVMSend(sendID: item.id, receipt: .init(hash: signed.hash,
            outcome: .confirmed, fee: 50_000, height: 123, timestamp: Date.now.timeIntervalSince1970))
        try await db.completePermissionRemoval(sendID: item.id, removed: firstRemoved)
        let initial = try await db.permissionRemoval(sendID: item.id)
        XCTAssertEqual(initial?.status, firstRemoved ? "removed" : "active")
        XCTAssertNotNil(initial?.checkedAt)
        let initialItems = try await db.permissionBatchItems(walletID: item.walletID)
        XCTAssertEqual(initialItems.first?.state, initial?.status)
        XCTAssertEqual(initialItems.first?.verifiedAt, initial?.checkedAt)
        let reopened = try await OathDatabase.open(at: folder.appendingPathComponent("db.sqlite"))
        if reorg {
            try await reopened.pool.write { database in
                try database.execute(sql: "UPDATE transactions SET state='pending',blockHeight=NULL WHERE id=?",
                    arguments: [plan.network.rawValue + ":" + signed.hash])
            }
            let reset = try await reopened.permissionRemoval(sendID: item.id)
            XCTAssertEqual(reset?.status, "pending")
            XCTAssertNil(reset?.checkedAt)
            try await reopened.settleEVMSend(sendID: item.id, receipt: .init(hash: signed.hash,
                outcome: .confirmed, fee: 50_000, height: 124, timestamp: Date.now.timeIntervalSince1970))
        }
        // Do not reconcile first: observers must never see a contradictory
        // verified batch state while waiting for a later reconciliation pass.
        try await reopened.completePermissionRemoval(sendID: item.id, removed: !firstRemoved)
        let final = try await reopened.permissionRemoval(sendID: item.id)
        let items = try await reopened.permissionBatchItems(walletID: item.walletID)
        let expected = (reorg ? !firstRemoved : firstRemoved) ? "removed" : "active"
        XCTAssertEqual(final?.status, expected)
        if !reorg { XCTAssertEqual(final?.checkedAt, initial?.checkedAt) }
        XCTAssertEqual(items.first?.state, expected, "Duplicate readback must preserve the verified batch result")
        XCTAssertEqual(items.first?.verifiedAt, final?.checkedAt)
        let deadline = try await reopened.nextSendStatusDeadline()
        XCTAssertNil(deadline)
        let otherWallet = try await reopened.permissionBatchItems(walletID: "w2")
        XCTAssertTrue(otherWallet.isEmpty)
    }
}
