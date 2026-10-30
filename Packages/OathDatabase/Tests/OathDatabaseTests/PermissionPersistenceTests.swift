import XCTest
import GRDB
@testable import OathAnkr
@testable import OathDatabase

@MainActor final class PermissionPersistenceTests:XCTestCase {
    func fixture() async throws -> (OathDatabase,URL,EVMSendPlan) {
        let helper=EVMSendJournalTests(),(db,folder,p)=try await helper.fixture()
        let r=EVMPermissionRemoval(kind:.token,contract:p.recipient,spender:"0x"+String(repeating:"3",count:40),expected:"5000")
        let plan=EVMSendPlan(network:p.network,sender:p.sender,recipient:p.recipient,reference:"native",decimals:18,requestedAmount:"0",amount:"0",assetBalance:p.nativeBalance,nativeBalance:p.nativeBalance,nonce:p.nonce,gasLimit:70000,maxFeePerGas:p.maxFeePerGas,maxPriorityFeePerGas:p.maxPriorityFeePerGas,blockHeight:p.blockHeight,removal:r)
        return (db,folder,plan)
    }
    func testConfirmedRemovalRetainsDurableReadbackAcrossRestart() async throws {
        let(db,folder,p)=try await fixture();defer { try? FileManager.default.removeItem(at:folder) }
        try await EVMSendJournalTests().draft("revoke",plan:p,db:db)
        try await db.queueEVMSend(sendID:"revoke",plan:p)
        let signed=try EVMSendCrypto.sign(p,privateKey:Data(repeating:1,count:32));try await db.journalEVMSignature(sendID:"revoke",signed:signed)
        do { try await db.completePermissionRemoval(sendID:"revoke",removed:true);XCTFail("Unconfirmed marked removed") } catch { XCTAssertEqual(error as? StoreError,.invalidTransition) }
        let before=try await db.permissionRemoval(sendID:"revoke");XCTAssertEqual(before?.status,"pending")
        let activity=try await db.pool.read { try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM activity") };XCTAssertEqual(activity,0,"Permission changes must not appear as zero-valued transfers")
        try await db.settleEVMSend(sendID:"revoke",receipt:.init(hash:signed.hash,outcome:.confirmed,fee:50000,height:123,timestamp:Date.now.timeIntervalSince1970))
        let reopened=try await OathDatabase.open(at:folder.appendingPathComponent("db.sqlite"))
        let checks=try await reopened.claimSendStatusChecks(owner:"new-process");XCTAssertEqual(checks.count,1);XCTAssertEqual(checks.first?.send.state,"confirmed")
        let history=try await reopened.permissionHistory(walletID:"w1");XCTAssertEqual(history.count,1);XCTAssertEqual(history.first?.removal.status,"pending")
        try await reopened.completePermissionRemoval(sendID:"revoke",removed:true)
        let after=try await reopened.permissionRemoval(sendID:"revoke");XCTAssertEqual(after?.status,"removed");XCTAssertNotNil(after?.checkedAt)
        let deadline=try await reopened.nextSendStatusDeadline();XCTAssertNil(deadline)
        let other=try await reopened.permissionHistory(walletID:"w2");XCTAssertTrue(other.isEmpty)
    }
    func testReorgRestartsReceiptAndPermissionVerification() async throws {
        let(db,folder,p)=try await fixture();defer{try? FileManager.default.removeItem(at:folder)}
        try await EVMSendJournalTests().draft("revoke",plan:p,db:db);try await db.queueEVMSend(sendID:"revoke",plan:p)
        let signed=try EVMSendCrypto.sign(p,privateKey:Data(repeating:1,count:32));try await db.journalEVMSignature(sendID:"revoke",signed:signed)
        try await db.settleEVMSend(sendID:"revoke",receipt:.init(hash:signed.hash,outcome:.confirmed,fee:50000,height:123,timestamp:Date.now.timeIntervalSince1970))
        try await db.completePermissionRemoval(sendID:"revoke",removed:true)
        try await db.pool.write {try $0.execute(sql:"UPDATE transactions SET state='pending',blockHeight=NULL WHERE id=?",arguments:[p.network.rawValue+":"+signed.hash])}
        let removal=try await db.permissionRemoval(sendID:"revoke");XCTAssertEqual(removal?.status,"pending");XCTAssertNil(removal?.checkedAt)
        let checks=try await db.claimSendStatusChecks(owner:"reorg-process");XCTAssertEqual(checks.first?.send.state,"broadcast")
    }
    func testVerifiedStillActiveStopsRetryWithoutFalseSuccess() async throws {
        let(db,folder,p)=try await fixture();defer { try? FileManager.default.removeItem(at:folder) }
        try await EVMSendJournalTests().draft("revoke",plan:p,db:db);try await db.queueEVMSend(sendID:"revoke",plan:p)
        let signed=try EVMSendCrypto.sign(p,privateKey:Data(repeating:1,count:32));try await db.journalEVMSignature(sendID:"revoke",signed:signed)
        try await db.settleEVMSend(sendID:"revoke",receipt:.init(hash:signed.hash,outcome:.confirmed,fee:50000,height:123,timestamp:Date.now.timeIntervalSince1970))
        try await db.completePermissionRemoval(sendID:"revoke",removed:false)
        let state=try await db.permissionRemoval(sendID:"revoke");XCTAssertEqual(state?.status,"active")
        let deadline=try await db.nextSendStatusDeadline();XCTAssertNil(deadline)
        try await db.completePermissionRemoval(sendID:"revoke",removed:true)
        let unchanged=try await db.permissionRemoval(sendID:"revoke");XCTAssertEqual(unchanged?.status,"active","A late duplicate must not change verified history")
    }
    func testScansSurviveRestartAndCannotCrossWalletOwnerOrReset() async throws {
        let(db,folder,p)=try await fixture();defer { try? FileManager.default.removeItem(at:folder) }
        let permission=WalletPermission(network:"arbitrum",owner:p.sender,contract:p.recipient,spender:"0x"+String(repeating:"3",count:40),kind:.token,amount:"5000")
        let scan=PermissionScan(network:"arbitrum",owner:p.sender,permissions:[permission],coverage:.partial)
        try await db.savePermissionScan(walletID:"w1",accountID:"a1",scan:scan)
        let reopened=try await OathDatabase.open(at:folder.appendingPathComponent("db.sqlite"))
        let rows=try await reopened.permissionScans(walletID:"w1");XCTAssertEqual(rows,[scan])
        do { try await db.savePermissionScan(walletID:"w2",accountID:"a1",scan:scan);XCTFail("Cross-wallet snapshot") } catch {}
        do { try await db.savePermissionScan(walletID:"w1",accountID:"a1",scan:.init(network:"arbitrum",owner:p.recipient,permissions:[],coverage:.checked));XCTFail("Wrong owner") } catch {}
        try await db.pool.write { try $0.execute(sql:"INSERT INTO metadata(key,value) VALUES('walletReset','1')") }
        do { try await db.savePermissionScan(walletID:"w1",accountID:"a1",scan:scan);XCTFail("Wrote during reset") } catch {}
    }
}
