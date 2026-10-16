import XCTest
import GRDB
@testable import OathAnkr
@testable import OathDatabase

@MainActor final class ThorchainSendJournalTests:XCTestCase {
    let key=Data(repeating:1,count:32)
    func fixture() async throws -> (OathDatabase,URL,ThorchainSendPlan) {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("ThorchainJournal-"+UUID().uuidString)
        let db=try await OathDatabase.open(at:folder.appendingPathComponent("db.sqlite")),owner=try ThorchainSendCrypto.address(publicKey:ThorchainSendCrypto.publicKey(privateKey:key),network:.mainnet)
        try await db.seed(networks:[.init(id:"thorchain",name:"Thorchain",family:"account",symbol:"RUNE",decimals:8,derivationPath:"m/44'/931'/0'/0/0",logo:"thorchain",sortOrder:0)],assets:[.init(id:"thorchain:native",networkID:"thorchain",reference:"native",name:"Thorchain",symbol:"RUNE",decimals:8)])
        for i in 1...2 { try await db.importWalletIfNeeded(.init(id:"w\(i)",name:"Test",kind:"hd",vaultReference:"test\(i)",createdAt:1),accounts:[.init(id:"a\(i)",walletID:"w\(i)",networkID:"thorchain",address:owner,derivationPath:"m/44'/931'/0'/0/0")]) }
        let p=ThorchainSendPlan(network:.mainnet,sender:owner,recipient:try ThorchainSendCrypto.address(publicKey:ThorchainSendCrypto.publicKey(privateKey:Data(repeating:2,count:32)),network:.mainnet),reference:"native",publicKey:try ThorchainSendCrypto.publicKey(privateKey:key),decimals:8,requestedAmount:"123456",amount:"123456",assetBalance:"100000000",nativeBalance:"100000000",accountNumber:123,sequence:7,fee:2000000,height:100,timeoutHeight:130)
        return (db,folder,p)
    }
    func draft(_ id:String,wallet:Int=1,plan:ThorchainSendPlan,db:OathDatabase) async throws {
        try await db.saveDraft(.init(id:id,walletID:"w\(wallet)",accountID:"a\(wallet)",networkID:"thorchain",assetID:"thorchain:native",idempotencyKey:id,recipient:plan.recipient,amountAtomic:String(plan.amount),state:"draft",createdAt:Date.now.timeIntervalSince1970,updatedAt:Date.now.timeIntervalSince1970))
    }
    func testSignatureDurabilityExclusiveSenderAndAcceptedNotFinal() async throws {
        let (db,folder,p)=try await fixture();defer { try? FileManager.default.removeItem(at:folder) }
        try await draft("one",plan:p,db:db);try await db.queueThorchainSend(sendID:"one",plan:p)
        try await draft("two",wallet:2,plan:p,db:db)
        do { try await db.queueThorchainSend(sendID:"two",plan:p);XCTFail("Double reserved") } catch { XCTAssertEqual(error as? ThorchainSendError,.busy) }
        let s=try ThorchainSendCrypto.sign(p,privateKey:key);try await db.journalThorchainSignature(sendID:"one",signed:s)
        let reopened=try await OathDatabase.open(at:folder.appendingPathComponent("db.sqlite"))
        let stored=try await reopened.send("one");XCTAssertEqual(try JSONDecoder().decode(ThorchainSignedSend.self,from:XCTUnwrap(stored?.signedPayload)),s)
        let jobs=try await reopened.claimSendStatusChecks(owner:"restarted");XCTAssertEqual(jobs.count,1)
        _ = try await reopened.transitionSend("one",from:"signed",to:"broadcast")
        for outcome:ThorchainSendReceipt.Outcome in [.unknown,.accepted] { try await reopened.settleThorchainSend(sendID:"one",receipt:.init(hash:s.hash,outcome:outcome)) }
        let pending=try await reopened.send("one");XCTAssertEqual(pending?.state,"broadcast")
        do { _ = try await reopened.transitionSend("one",from:"broadcast",to:"cancelled");XCTFail("Cancelled signed send") } catch {}
        let executionFee=ThorchainSendPlan.feeLimit+1
        try await reopened.settleThorchainSend(sendID:"one",receipt:.init(hash:s.hash,outcome:.confirmed,fee:executionFee,height:123,timestamp:Date.now.timeIntervalSince1970))
        let settled=try await reopened.send("one");XCTAssertEqual(settled?.state,"confirmed")
        let recordedFee=try await reopened.pool.read { try TransactionRecord.fetchOne($0,key:"thorchain:"+s.hash)?.feeAtomic };XCTAssertEqual(recordedFee,String(executionFee))
        let count=try await reopened.pool.read { try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM sendStatusChecks") };XCTAssertEqual(count,0)
        try await reopened.queueThorchainSend(sendID:"two",plan:p)
    }
    func testHistoryHydrationPreservesIntentAndHeightBasedBalanceProof() async throws {
        for failed in [false,true] {
            let (db,folder,p)=try await fixture();defer {try? FileManager.default.removeItem(at:folder)}
            try await draft("one",plan:p,db:db);try await db.queueThorchainSend(sendID:"one",plan:p)
            let signed=try ThorchainSendCrypto.sign(p,privateKey:key);try await db.journalThorchainSignature(sendID:"one",signed:signed)
            try await db.settleThorchainSend(sendID:"one",receipt:.init(hash:signed.hash,outcome:failed ? .failed:.confirmed,fee:p.fee,height:123,timestamp:123))
            let ticket=try await db.beginThorchainSync(accountID:"a1")
            try await db.commitThorchainInventory(.init(owner:p.sender,holdings:[.init(reference:"native",amount:"90000000")],height:122),ticket:ticket,catalog:.init())
            let stored=try await db.send("one"),send=try XCTUnwrap(stored)
            let stale=try await db.thorchainSendBalanceIsCurrent(send);XCTAssertFalse(stale)
            try await db.commitThorchainInventory(.init(owner:p.sender,holdings:[.init(reference:"native",amount:"90000000")],height:123),ticket:ticket,catalog:.init())
            let cursor=try await db.thorchainCursor(ticket:ticket,stream:"transfer.sender",lane:"recent",height:123)
            let event=ThorchainEvent(id:signed.hash+":2:0",hash:signed.hash,reference:"native",amount:failed ? "0":p.amount,direction:"outgoing",counterparty:failed ? "":p.recipient,state:failed ? "failed":"confirmed",height:123,timestamp:123,fee:String(p.fee))
            try await db.commitThorchainHistory(.init(owner:p.sender,events:[event],next:nil,rawCount:1),cursor:cursor,ticket:ticket,catalog:.init())
            let activities=try await db.pool.read {try ActivityRecord.fetchAll($0,sql:"SELECT * FROM activity WHERE accountID='a1'")}
            XCTAssertEqual(activities.count,1);XCTAssertEqual(activities.first?.amountAtomic,p.amount);XCTAssertEqual(activities.first?.counterparty,p.recipient)
            let current=try await db.thorchainSendBalanceIsCurrent(send);XCTAssertTrue(current)
        }
    }
    func testForgedSignatureAndInvalidFinalReceiptNeverRelease() async throws {
        let (db,folder,p)=try await fixture();defer { try? FileManager.default.removeItem(at:folder) }
        try await draft("one",plan:p,db:db);try await db.queueThorchainSend(sendID:"one",plan:p)
        let s=try ThorchainSendCrypto.sign(p,privateKey:key)
        do { try await db.journalThorchainSignature(sendID:"one",signed:.init(bytes:s.bytes,signature:Data(repeating:0,count:64),hash:s.hash));XCTFail() } catch {}
        try await db.journalThorchainSignature(sendID:"one",signed:s)
        for r in [ThorchainSendReceipt(hash:s.hash,outcome:.confirmed),.init(hash:s.hash,outcome:.confirmed,fee:p.fee,height:p.timeoutHeight+1,timestamp:1),.init(hash:s.hash,outcome:.expired,fee:1),.init(hash:s.hash,outcome:.replaced,replacementHash:s.hash)] {
            do { try await db.settleThorchainSend(sendID:"one",receipt:r);XCTFail("Invalid receipt") } catch {}
        }
        let stored=try await db.send("one");XCTAssertEqual(stored?.state,"signed")
    }
    func testFailureExpiryAndReplacementAreTerminalWithoutFalseGas() async throws {
        for outcome:ThorchainSendReceipt.Outcome in [.failed,.expired,.replaced] {
            let (db,folder,p)=try await fixture();defer { try? FileManager.default.removeItem(at:folder) }
            try await draft("one",plan:p,db:db);try await db.queueThorchainSend(sendID:"one",plan:p)
            let s=try ThorchainSendCrypto.sign(p,privateKey:key);try await db.journalThorchainSignature(sendID:"one",signed:s)
            let r=ThorchainSendReceipt(hash:s.hash,outcome:outcome,fee:outcome == .failed ? 500: nil,height:outcome == .failed ? 123:nil,timestamp:outcome == .failed ? 123:nil,replacementHash:outcome == .replaced ? String(repeating:"F",count:64):nil)
            try await db.settleThorchainSend(sendID:"one",receipt:r)
            let stored=try await db.send("one");XCTAssertEqual(stored?.state,"failed")
            let count=try await db.pool.read { try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM sendStatusChecks") };XCTAssertEqual(count,0)
            do { try await db.settleThorchainSend(sendID:"one",receipt:.init(hash:s.hash,outcome:.confirmed,fee:500,height:123,timestamp:123));XCTFail("Changed final outcome") } catch {}
        }
    }
}
