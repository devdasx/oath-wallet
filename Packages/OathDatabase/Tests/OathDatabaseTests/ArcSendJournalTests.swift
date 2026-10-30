import XCTest
import GRDB
@testable import OathAnkr
@testable import OathDatabase

@MainActor final class ArcSendJournalTests:XCTestCase {
    let key=Data(repeating:1,count:32)
    func fixture() async throws -> (OathDatabase,URL,ArcSendPlan) {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("ArcJournal-"+UUID().uuidString)
        let db=try await OathDatabase.open(at:folder.appendingPathComponent("db.sqlite")),owner=try ArcSendCrypto.address(privateKey:key)
        try await db.seed(networks:[.init(id:"arc",name:"Arc",family:"account",symbol:"USDC",decimals:18,derivationPath:"m/44'/60'/0'/0/0",logo:"arc",sortOrder:0)],assets:[.init(id:"arc:native",networkID:"arc",reference:"native",name:"Arc",symbol:"USDC",decimals:18)])
        for i in 1...2 { try await db.importWalletIfNeeded(.init(id:"w\(i)",name:"Test",kind:"hd",vaultReference:"test\(i)",createdAt:1),accounts:[.init(id:"a\(i)",walletID:"w\(i)",networkID:"arc",address:owner,derivationPath:"m/44'/60'/0'/0/0")]) }
        let p=ArcSendPlan(network:.mainnet,sender:owner,recipient:try ArcSendCrypto.address(privateKey:Data(repeating:2,count:32)),reference:"native",decimals:18,requestedAmount:"123456",amount:"123456",assetBalance:"1000000000000000000",nativeBalance:"1000000000000000000",nonce:7,gasLimit:21000,maxFeePerGas:41000000000,maxPriorityFeePerGas:1000000000,blockHeight:100)

        return (db,folder,p)
    }
    func draft(_ id:String,wallet:Int=1,plan:ArcSendPlan,db:OathDatabase) async throws {
        try await db.saveDraft(.init(id:id,walletID:"w\(wallet)",accountID:"a\(wallet)",networkID:"arc",assetID:"arc:native",idempotencyKey:id,recipient:plan.recipient,amountAtomic:String(plan.amount),state:"draft",createdAt:Date.now.timeIntervalSince1970,updatedAt:Date.now.timeIntervalSince1970))
    }
    func testSignatureDurabilityExclusiveSenderAndAcceptedNotFinal() async throws {
        let (db,folder,p)=try await fixture();defer { try? FileManager.default.removeItem(at:folder) }
        try await draft("one",plan:p,db:db);try await db.queueArcSend(sendID:"one",plan:p)
        try await draft("two",wallet:2,plan:p,db:db)
        do { try await db.queueArcSend(sendID:"two",plan:p);XCTFail("Double reserved") } catch { XCTAssertEqual(error as? ArcSendError,.busy) }
        let s=try ArcSendCrypto.sign(p,privateKey:key);try await db.journalArcSignature(sendID:"one",signed:s)
        let reopened=try await OathDatabase.open(at:folder.appendingPathComponent("db.sqlite"))
        let stored=try await reopened.send("one");XCTAssertEqual(try JSONDecoder().decode(ArcSignedSend.self,from:XCTUnwrap(stored?.signedPayload)),s)
        let jobs=try await reopened.claimSendStatusChecks(owner:"restarted");XCTAssertEqual(jobs.count,1)
        _ = try await reopened.transitionSend("one",from:"signed",to:"broadcast")
        for outcome:ArcSendReceipt.Outcome in [.unknown,.accepted] { try await reopened.settleArcSend(sendID:"one",receipt:.init(hash:s.hash,outcome:outcome)) }
        let pending=try await reopened.send("one");XCTAssertEqual(pending?.state,"broadcast")
        do { _ = try await reopened.transitionSend("one",from:"broadcast",to:"cancelled");XCTFail("Cancelled signed send") } catch {}
        try await reopened.settleArcSend(sendID:"one",receipt:.init(hash:s.hash,outcome:.confirmed,fee:50000,height:123,timestamp:Date.now.timeIntervalSince1970))
        let settled=try await reopened.send("one");XCTAssertEqual(settled?.state,"confirmed")
        let count=try await reopened.pool.read { try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM sendStatusChecks") };XCTAssertEqual(count,0)
        try await reopened.queueArcSend(sendID:"two",plan:p)
    }
    func testArcInclusionUpdatesReceiptWithoutReleasingFinalityWork() async throws {
        let (db,folder,p)=try await fixture();defer { try? FileManager.default.removeItem(at:folder) }
        try await draft("included",plan:p,db:db);try await db.queueArcSend(sendID:"included",plan:p)
        let signed=try ArcSendCrypto.sign(p,privateKey:key)
        try await db.journalArcSignature(sendID:"included",signed:signed)
        try await db.settleArcSend(sendID:"included",receipt:.init(hash:signed.hash,outcome:.accepted,
            inclusion:.init(succeeded:true,blockHash:"0x"+String(repeating:"a",count:64),fee:500,height:123,timestamp:123)))
        let state=try await db.sendSubmission(walletID:"w1",networkID:"arc",hash:signed.hash)
        let journal=try await db.send("included")
        XCTAssertEqual(state?.outcome,.confirmed);XCTAssertEqual(journal?.state,"signed")
        let work=try await db.pool.read { try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM sendStatusChecks") }
        XCTAssertEqual(work,1)
        try await db.settleArcSend(sendID:"included",receipt:.init(hash:signed.hash,outcome:.confirmed,fee:500,height:123,timestamp:123))
        let finalHash=try await db.pool.read { try String.fetchOne($0,sql:"SELECT blockHash FROM transactions WHERE id=?",arguments:["arc:"+signed.hash]) }
        XCTAssertNil(finalHash)
    }
    func testHistoryHydrationPreservesIntentAndBalanceRefreshHeight() async throws {
        for failed in [false,true] {
            let (db,folder,p)=try await fixture();defer { try? FileManager.default.removeItem(at:folder) }
            try await draft("one",plan:p,db:db);try await db.queueArcSend(sendID:"one",plan:p)
            let signed=try ArcSendCrypto.sign(p,privateKey:key);try await db.journalArcSignature(sendID:"one",signed:signed)
            try await db.settleArcSend(sendID:"one",receipt:.init(hash:signed.hash,outcome:failed ? .failed:.confirmed,fee:50000,height:123,timestamp:123))
            let ticket=try await db.beginArcSync(accountID:"a1")
            try await db.commitArcInventory(.init(owner:p.sender,block:124,blockHash:"0x"+String(repeating:"f",count:64),observedAt:.now,holdings:[.init(token:.native,amount:"90000000")],complete:true,raw:Data()),ticket:ticket,catalog:.empty)
            try await db.prepareArcHistory(ticket,through:124)
            let cursor=try await db.arcHistoryWork(ticket).first!
            let tx=ArcTransaction(hash:signed.hash,block:123,timestamp:123,from:p.sender,to:p.recipient,failed:failed,fee:"50000",raw:Data())
            let events:[ArcEvent]=failed ? []:[.init(id:signed.hash+":1",hash:signed.hash,logIndex:1,token:.native,amount:p.amount,from:p.sender,to:p.recipient)]
            try await db.commitArcPage(.init(fromBlock:cursor.nextBlock,nextBlock:124,transactions:[tx],events:events,raw:Data()),cursor:cursor,ticket:ticket)
            let activities=try await db.pool.read { try ActivityRecord.fetchAll($0,sql:"SELECT * FROM activity WHERE accountID='a1'") }
            XCTAssertEqual(activities.count,1);XCTAssertEqual(activities.first?.counterparty,p.recipient)
            XCTAssertEqual(activities.first?.amountAtomic,p.amount)
            let saved=try await db.send("one");let send=try XCTUnwrap(saved)
            let current=try await db.arcSendBalanceIsCurrent(send);XCTAssertTrue(current)
            let targets=try await db.pendingSendBalanceRefreshTargets();XCTAssertFalse(targets.isEmpty)
        }
    }
    func testForgedSignatureAndInvalidFinalReceiptNeverRelease() async throws {
        let (db,folder,p)=try await fixture();defer { try? FileManager.default.removeItem(at:folder) }
        try await draft("one",plan:p,db:db);try await db.queueArcSend(sendID:"one",plan:p)
        let s=try ArcSendCrypto.sign(p,privateKey:key)
        do { try await db.journalArcSignature(sendID:"one",signed:.init(bytes:s.bytes,signature:Data(repeating:0,count:65),hash:s.hash));XCTFail() } catch {}
        try await db.journalArcSignature(sendID:"one",signed:s)
        for r in [ArcSendReceipt(hash:s.hash,outcome:.confirmed),.init(hash:s.hash,outcome:.confirmed,fee:p.fee+1,height:123,timestamp:1),.init(hash:s.hash,outcome:.cancelled,fee:1),.init(hash:s.hash,outcome:.replaced,replacementHash:s.hash)] {
            do { try await db.settleArcSend(sendID:"one",receipt:r);XCTFail("Invalid receipt") } catch {}
        }
        let stored=try await db.send("one");XCTAssertEqual(stored?.state,"signed")
    }
    func testTokenReceiptPersistsActualDeliveryWithoutFalseFailure() async throws {
        let (db,folder,native)=try await fixture();defer { try? FileManager.default.removeItem(at:folder) }
        let reference="0x"+String(repeating:"3",count:40),asset="arc:"+reference
        let p=ArcSendPlan(network:.mainnet,sender:native.sender,recipient:native.recipient,reference:reference,decimals:6,requestedAmount:"100",amount:"100",assetBalance:"1000",nativeBalance:native.nativeBalance,nonce:7,gasLimit:50000,maxFeePerGas:native.maxFeePerGas,maxPriorityFeePerGas:native.maxPriorityFeePerGas,blockHeight:100)
        try await db.pool.write { sql in
            try AssetRecord(id:asset,networkID:"arc",reference:reference,name:"Test",symbol:"TEST",decimals:6).insert(sql)
        }
        try await db.saveDraft(.init(id:"token",walletID:"w1",accountID:"a1",networkID:"arc",assetID:asset,idempotencyKey:"token",recipient:p.recipient,amountAtomic:p.amount,state:"draft",createdAt:1,updatedAt:1))
        try await db.queueArcSend(sendID:"token",plan:p)
        let s=try ArcSendCrypto.sign(p,privateKey:key);try await db.journalArcSignature(sendID:"token",signed:s)
        do {
            try await db.settleArcSend(sendID:"token",receipt:.init(hash:s.hash,outcome:.confirmed,fee:50000,height:123,timestamp:123))
            XCTFail("A token receipt must include observed delivery")
        } catch { XCTAssertEqual(error as? ArcSendError,.changed) }
        try await db.settleArcSend(sendID:"token",receipt:.init(hash:s.hash,outcome:.confirmed,fee:50000,height:123,timestamp:123,deliveredAmount:"99"))
        let record=try await db.send("token");XCTAssertEqual(record?.state,"confirmed");XCTAssertEqual(record?.amountAtomic,"100")
        let activity=try await db.pool.read { try ActivityRecord.fetchOne($0,sql:"SELECT * FROM activity WHERE transactionID=?",arguments:["arc:"+s.hash]) }
        XCTAssertEqual(activity?.amountAtomic,"99")
    }
    func testFailureCancellationAndReplacementAreTerminalWithoutFalseGas() async throws {
        for outcome:ArcSendReceipt.Outcome in [.failed,.cancelled,.replaced] {
            let (db,folder,p)=try await fixture();defer { try? FileManager.default.removeItem(at:folder) }
            try await draft("one",plan:p,db:db);try await db.queueArcSend(sendID:"one",plan:p)
            let s=try ArcSendCrypto.sign(p,privateKey:key);try await db.journalArcSignature(sendID:"one",signed:s)
            let r=ArcSendReceipt(hash:s.hash,outcome:outcome,fee:outcome == .failed ? 500: nil,height:outcome == .failed ? 123:nil,timestamp:outcome == .failed ? 123:nil,replacementHash:[.replaced,.cancelled].contains(outcome) ? "0x"+String(repeating:"f",count:64):nil)
            try await db.settleArcSend(sendID:"one",receipt:r)
            let stored=try await db.send("one");XCTAssertEqual(stored?.state,"failed")
            let evidence=try await db.pool.read { try String.fetchOne($0,sql:"SELECT outcome FROM transactionEvidence WHERE accountID='a1'") }
            if outcome == .cancelled { XCTAssertEqual(evidence,"canceled") }
            if outcome == .replaced { XCTAssertEqual(evidence,"replaced") }
            let count=try await db.pool.read { try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM sendStatusChecks") };XCTAssertEqual(count,0)
            do { try await db.settleArcSend(sendID:"one",receipt:.init(hash:s.hash,outcome:.confirmed,fee:500,height:123,timestamp:123));XCTFail("Changed final outcome") } catch {}
        }
    }
}
