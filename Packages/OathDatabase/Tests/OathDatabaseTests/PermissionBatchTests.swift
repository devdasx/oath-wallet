import XCTest
import GRDB
@testable import OathAnkr
@testable import OathDatabase

@MainActor final class PermissionBatchTests: XCTestCase {
    func item(_ plan: EVMSendPlan, batch: String = UUID().uuidString, ordinal: Int = 0) throws -> PermissionBatchItem {
        let id=UUID().uuidString, removal=plan.removal!
        let permission=WalletPermission(network:plan.network.rawValue,owner:plan.sender,contract:removal.contract,
            spender:removal.spender,kind:.token,amount:removal.expected)
        return try .init(id:id,batchID:batch,walletID:"w1",accountID:"a1",permission:permission,
            scope:.evm(sendID:id,walletID:"w1",accountID:"a1",plan:plan),ordinal:ordinal,createdAt:Date.now.timeIntervalSince1970)
    }
    func testRestartPausesUnsignedAndPreservesOrderAndIsolation() async throws {
        let (db,folder,p)=try await PermissionPersistenceTests().fixture();defer{try? FileManager.default.removeItem(at:folder)}
        let first=try item(p);try await db.savePermissionBatch([first])
        try await db.setPermissionBatchItem(first.id,state:"processing")
        let reopened=try await OathDatabase.open(at:folder.appendingPathComponent("db.sqlite"))
        try await reopened.reconcilePermissionBatches(walletID:"w1",interruptUnsigned:true)
        let rows=try await reopened.permissionBatchItems(walletID:"w1")
        XCTAssertEqual(rows.map(\.id),[first.id]);XCTAssertEqual(rows.first?.state,"paused")
        XCTAssertEqual(rows.first?.scope,first.scope)
        let other=try await reopened.permissionBatchItems(walletID:"w2");XCTAssertTrue(other.isEmpty)
        // A fresh reviewed attempt has a new send id; stale callbacks cannot change it.
        let second=try item(p);try await db.savePermissionBatch([second])
        try await db.setPermissionBatchItem(first.id,state:"submitted")
        let resumed=try await db.permissionBatchItems(walletID:"w1")
        XCTAssertEqual(resumed.first?.id,second.id);XCTAssertEqual(resumed.first?.state,"queued")
        XCTAssertEqual(resumed.last?.state,"paused")
    }
    func testDuplicateActivePermissionRejectedAtomically() async throws {
        let (db,folder,p)=try await PermissionPersistenceTests().fixture();defer{try? FileManager.default.removeItem(at:folder)}
        let first=try item(p);try await db.savePermissionBatch([first])
        do { try await db.savePermissionBatch([item(p)]);XCTFail("Duplicate spending job") } catch {}
        let rows=try await db.permissionBatchItems(walletID:"w1");XCTAssertEqual(rows.count,1)
        try await db.setPermissionBatchItem(first.id,state:"failed",errorCode:"unavailable")
        try await db.savePermissionBatch([item(p)])
        let retried=try await db.permissionBatchItems(walletID:"w1");XCTAssertEqual(retried.count,2)
    }
    func testAlreadyRemovedReadbackSurvivesRestartAndIgnoresStaleCallbacks() async throws {
        let (db,folder,p)=try await PermissionPersistenceTests().fixture();defer{try? FileManager.default.removeItem(at:folder)}
        let row=try item(p);try await db.savePermissionBatch([row])
        try await db.setPermissionBatchItem(row.id,state:"processing")
        let before=Date.now.timeIntervalSince1970
        try await db.setPermissionBatchItem(row.id,state:"alreadyRemoved")
        let reopened=try await OathDatabase.open(at:folder.appendingPathComponent("db.sqlite"))
        try await reopened.reconcilePermissionBatches(walletID:"w1",interruptUnsigned:true)
        let result=try await reopened.permissionBatchItems(walletID:"w1")
        XCTAssertEqual(result.first?.state,"alreadyRemoved")
        let verified=try XCTUnwrap(result.first?.verifiedAt);XCTAssertGreaterThanOrEqual(verified,before)
        try await reopened.setPermissionBatchItem(row.id,state:"failed",errorCode:"unavailable")
        try await reopened.setPermissionBatchItem(row.id,state:"alreadyRemoved")
        let after=try await reopened.permissionBatchItems(walletID:"w1")
        XCTAssertEqual(after.first?.state,"alreadyRemoved");XCTAssertEqual(after.first?.verifiedAt,verified)
        let sends=try await db.send(row.id);XCTAssertNil(sends,"Already revoked access must not create a transaction")
    }
    func testAlreadyRemovedCannotOverrideSignedTransaction() async throws {
        let (db,folder,p)=try await PermissionPersistenceTests().fixture();defer{try? FileManager.default.removeItem(at:folder)}
        let row=try item(p);try await db.savePermissionBatch([row])
        try await EVMSendJournalTests().draft(row.id,plan:p,db:db)
        try await db.queueEVMSend(sendID:row.id,plan:p)
        let signed=try EVMSendCrypto.sign(p,privateKey:Data(repeating:1,count:32))
        try await db.journalEVMSignature(sendID:row.id,signed:signed)
        do { try await db.setPermissionBatchItem(row.id,state:"alreadyRemoved");XCTFail("Signed transaction bypassed confirmation") }
        catch { XCTAssertEqual(error as? StoreError,.invalidTransition) }
        try await db.reconcilePermissionBatches(walletID:"w1",interruptUnsigned:true)
        let rows=try await db.permissionBatchItems(walletID:"w1")
        XCTAssertEqual(rows.first?.state,"submitted");XCTAssertNil(rows.first?.verifiedAt)
    }
    func testSignatureJournalWinsAfterKillBeforeBatchUpdateAndRequiresReadback() async throws {
        let (db,folder,p)=try await PermissionPersistenceTests().fixture();defer{try? FileManager.default.removeItem(at:folder)}
        let row=try item(p);try await db.savePermissionBatch([row])
        let available=try await db.permissionBatchCanPrepare(row.scope!);XCTAssertTrue(available)
        try await EVMSendJournalTests().draft(row.id,plan:p,db:db)
        try await db.queueEVMSend(sendID:row.id,plan:p)
        let reserved=try await db.permissionBatchCanPrepare(row.scope!);XCTAssertFalse(reserved)
        let signed=try EVMSendCrypto.sign(p,privateKey:Data(repeating:1,count:32))
        try await db.journalEVMSignature(sendID:row.id,signed:signed)
        // A batch callback can be interrupted after the signature is durable.
        // Even an earlier failure/paused label must yield to the signed journal.
        try await db.setPermissionBatchItem(row.id,state:"failed",errorCode:"unavailable")
        try await db.reconcilePermissionBatches(walletID:"w1",interruptUnsigned:true)
        var rows=try await db.permissionBatchItems(walletID:"w1");XCTAssertEqual(rows.first?.state,"submitted")
        try await db.settleEVMSend(sendID:row.id,receipt:.init(hash:signed.hash,outcome:.confirmed,fee:50000,height:123,timestamp:Date.now.timeIntervalSince1970))
        try await db.reconcilePermissionBatches(walletID:"w1",interruptUnsigned:true)
        rows=try await db.permissionBatchItems(walletID:"w1");XCTAssertEqual(rows.first?.state,"submitted","Receipt alone cannot assert revoked access")
        try await db.completePermissionRemoval(sendID:row.id,removed:true)
        rows=try await db.permissionBatchItems(walletID:"w1");XCTAssertEqual(rows.first?.state,"removed");XCTAssertNotNil(rows.first?.verifiedAt)
        let verifiedAt=rows.first?.verifiedAt
        try await db.completePermissionRemoval(sendID:row.id,removed:false)
        rows=try await db.permissionBatchItems(walletID:"w1")
        XCTAssertEqual(rows.first?.state,"removed","A late readback cannot restore a completed permission row")
        XCTAssertEqual(rows.first?.verifiedAt,verifiedAt)
        try await db.pool.write { try $0.execute(sql:"UPDATE transactions SET state='pending',blockHeight=NULL WHERE id=?",arguments:[p.network.rawValue+":"+signed.hash]) }
        try await db.reconcilePermissionBatches(walletID:"w1",interruptUnsigned:true)
        rows=try await db.permissionBatchItems(walletID:"w1");XCTAssertEqual(rows.first?.state,"submitted","Reorg must undo verified status")
    }
    func testResetRejectsLateBatchWritesAndErasesQueue() async throws {
        let (db,folder,p)=try await PermissionPersistenceTests().fixture();defer{try? FileManager.default.removeItem(at:folder)}
        let row=try item(p);try await db.savePermissionBatch([row])
        let reset=try await db.beginWalletReset()
        do { try await db.setPermissionBatchItem(row.id,state:"processing");XCTFail("Reset accepted late worker update") } catch {}
        do { try await db.savePermissionBatch([item(p)]);XCTFail("Reset accepted late queue") } catch {}
        try await db.eraseWalletData(resetID:reset)
        let remaining=try await db.permissionBatchItems(walletID:"w1");XCTAssertTrue(remaining.isEmpty)
        try await db.finishWalletReset(resetID:reset)
    }
    func testCrossWalletScopeRejectedAndWalletErasureCascades() async throws {
        let (db,folder,p)=try await PermissionPersistenceTests().fixture();defer{try? FileManager.default.removeItem(at:folder)}
        let original=try item(p)
        let forged=PermissionBatchItem(id:original.id,batchID:original.batchID,walletID:"w2",accountID:"a1",
            permission:original.permission,scope:original.scope,ordinal:0,createdAt:original.createdAt)
        do { try await db.savePermissionBatch([forged]);XCTFail("Cross wallet") } catch { XCTAssertEqual(error as? StoreError,.conflictingIdentity) }
        try await db.savePermissionBatch([original])
        try await db.pool.write { try $0.execute(sql:"DELETE FROM wallets WHERE id='w1'") }
        let remaining=try await db.permissionBatchItems(walletID:"w1");XCTAssertTrue(remaining.isEmpty)
    }
}
