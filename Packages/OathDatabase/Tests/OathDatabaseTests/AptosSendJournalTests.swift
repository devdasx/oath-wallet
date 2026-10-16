import XCTest
import GRDB
@testable import OathAnkr
@testable import OathDatabase

@MainActor final class AptosSendJournalTests:XCTestCase {
    let key=Data(repeating:1,count:32)
    func fixture() async throws -> (OathDatabase,URL,AptosSendPlan) {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("AptosJournal-"+UUID().uuidString)
        let db=try await OathDatabase.open(at:folder.appendingPathComponent("db.sqlite")),owner=try AptosSendCrypto.address(privateKey:key)
        try await db.seed(networks:[.init(id:"aptos",name:"Aptos",family:"account",symbol:"APT",decimals:8,derivationPath:"m/44'/637'/0'/0'/0'",logo:"aptos",sortOrder:0)],assets:[.init(id:"aptos:native",networkID:"aptos",reference:"native",name:"Aptos",symbol:"APT",decimals:8)])
        for i in 1...2 { try await db.importWalletIfNeeded(.init(id:"w\(i)",name:"Test",kind:"hd",vaultReference:"test\(i)",createdAt:1),accounts:[.init(id:"a\(i)",walletID:"w\(i)",networkID:"aptos",address:owner,derivationPath:"m/44'/637'/0'/0'/0'")]) }
        let p=AptosSendPlan(network:.mainnet,sender:owner,recipient:try AptosSendCrypto.address(privateKey:Data(repeating:2,count:32)),reference:"native",publicKey:try AptosSendCrypto.publicKey(privateKey:key),decimals:8,requestedAmount:123456,amount:123456,assetBalance:100_000_000,nativeBalance:100_000_000,sequence:7,gasUnitPrice:100,maxGasAmount:2000,expiration:UInt64(Date.now.timeIntervalSince1970)+300)
        return (db,folder,p)
    }
    func draft(_ id:String,wallet:Int=1,plan:AptosSendPlan,db:OathDatabase) async throws {
        try await db.saveDraft(.init(id:id,walletID:"w\(wallet)",accountID:"a\(wallet)",networkID:"aptos",assetID:"aptos:native",idempotencyKey:id,recipient:plan.recipient,amountAtomic:String(plan.amount),state:"draft",createdAt:Date.now.timeIntervalSince1970,updatedAt:Date.now.timeIntervalSince1970))
    }
    func testSignatureDurabilityExclusiveSenderAndAcceptedNotFinal() async throws {
        let (db,folder,p)=try await fixture();defer { try? FileManager.default.removeItem(at:folder) }
        try await draft("one",plan:p,db:db);try await db.queueAptosSend(sendID:"one",plan:p)
        try await draft("two",wallet:2,plan:p,db:db)
        do { try await db.queueAptosSend(sendID:"two",plan:p);XCTFail("Double reserved") } catch { XCTAssertEqual(error as? AptosSendError,.busy) }
        let s=try AptosSendCrypto.sign(p,privateKey:key);try await db.journalAptosSignature(sendID:"one",signed:s)
        let reopened=try await OathDatabase.open(at:folder.appendingPathComponent("db.sqlite"))
        let stored=try await reopened.send("one");XCTAssertEqual(try JSONDecoder().decode(AptosSignedSend.self,from:XCTUnwrap(stored?.signedPayload)),s)
        let jobs=try await reopened.claimSendStatusChecks(owner:"restarted");XCTAssertEqual(jobs.count,1)
        _ = try await reopened.transitionSend("one",from:"signed",to:"broadcast")
        for outcome:AptosSendReceipt.Outcome in [.unknown,.accepted] { try await reopened.settleAptosSend(sendID:"one",receipt:.init(hash:s.hash,outcome:outcome)) }
        let pending=try await reopened.send("one");XCTAssertEqual(pending?.state,"broadcast")
        do { _ = try await reopened.transitionSend("one",from:"broadcast",to:"cancelled");XCTFail("Cancelled signed send") } catch {}
        try await reopened.settleAptosSend(sendID:"one",receipt:.init(hash:s.hash,outcome:.confirmed,fee:50000,version:123,timestamp:Date.now.timeIntervalSince1970))
        let settled=try await reopened.send("one");XCTAssertEqual(settled?.state,"confirmed")
        let count=try await reopened.pool.read { try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM sendStatusChecks") };XCTAssertEqual(count,0)
        try await reopened.queueAptosSend(sendID:"two",plan:p)
    }
    func testHistoryHydrationPreservesIntentAndBalanceRefreshVersion() async throws {
        for failed in [false,true] {
            let (db,folder,p)=try await fixture();defer { try? FileManager.default.removeItem(at:folder) }
            try await draft("one",plan:p,db:db);try await db.queueAptosSend(sendID:"one",plan:p)
            let signed=try AptosSendCrypto.sign(p,privateKey:key);try await db.journalAptosSignature(sendID:"one",signed:signed)
            try await db.settleAptosSend(sendID:"one",receipt:.init(hash:signed.hash,outcome:failed ? .failed:.confirmed,fee:50000,version:123,timestamp:123))
            let ticket=try await db.beginAptosSync(accountID:"a1")
            try await db.commitAptosInventory(.init(owner:p.sender,holdings:[.init(token:.native,amount:"90000000")],failedReferences:[],discoveryComplete:true,ledgerVersion:123,observedAt:.now,raw:Data()),ticket:ticket,catalog:.empty)
            let cursor=try await db.aptosHistoryWork(ticket).first!
            let tx=AptosTransaction(hash:signed.hash,version:123,timestamp:123,failed:failed,fee:"50000",sender:p.sender,events:failed ? []:[.init(index:1,token:.native,owner:p.sender,direction:"outgoing",amount:String(p.amount))],raw:Data())
            try await db.commitAptosPage(.init(transactions:[tx],next:nil,head:123,raw:Data()),cursor:cursor,ticket:ticket,catalog:.empty)
            let activities=try await db.pool.read { try ActivityRecord.fetchAll($0,sql:"SELECT * FROM activity WHERE accountID='a1'") }
            XCTAssertEqual(activities.count,1);XCTAssertEqual(activities.first?.counterparty,p.recipient)
            XCTAssertEqual(activities.first?.amountAtomic,String(p.amount))
            let saved=try await db.send("one");let send=try XCTUnwrap(saved)
            let current=try await db.aptosSendBalanceIsCurrent(send);XCTAssertTrue(current)
        }
    }
    func testForgedSignatureAndInvalidFinalReceiptNeverRelease() async throws {
        let (db,folder,p)=try await fixture();defer { try? FileManager.default.removeItem(at:folder) }
        try await draft("one",plan:p,db:db);try await db.queueAptosSend(sendID:"one",plan:p)
        let s=try AptosSendCrypto.sign(p,privateKey:key)
        do { try await db.journalAptosSignature(sendID:"one",signed:.init(bytes:s.bytes,publicKey:s.publicKey,signature:Data(repeating:0,count:64),hash:s.hash));XCTFail() } catch {}
        try await db.journalAptosSignature(sendID:"one",signed:s)
        for r in [AptosSendReceipt(hash:s.hash,outcome:.confirmed),.init(hash:s.hash,outcome:.confirmed,fee:p.fee+1,version:123,timestamp:1),.init(hash:s.hash,outcome:.expired,fee:1),.init(hash:s.hash,outcome:.replaced,replacementHash:s.hash)] {
            do { try await db.settleAptosSend(sendID:"one",receipt:r);XCTFail("Invalid receipt") } catch {}
        }
        let stored=try await db.send("one");XCTAssertEqual(stored?.state,"signed")
    }
    func testFailureExpiryAndReplacementAreTerminalWithoutFalseGas() async throws {
        for outcome:AptosSendReceipt.Outcome in [.failed,.expired,.replaced] {
            let (db,folder,p)=try await fixture();defer { try? FileManager.default.removeItem(at:folder) }
            try await draft("one",plan:p,db:db);try await db.queueAptosSend(sendID:"one",plan:p)
            let s=try AptosSendCrypto.sign(p,privateKey:key);try await db.journalAptosSignature(sendID:"one",signed:s)
            let r=AptosSendReceipt(hash:s.hash,outcome:outcome,fee:outcome == .failed ? 500: nil,version:outcome == .failed ? 123:nil,timestamp:outcome == .failed ? 123:nil,replacementHash:outcome == .replaced ? "0x"+String(repeating:"f",count:64):nil)
            try await db.settleAptosSend(sendID:"one",receipt:r)
            let stored=try await db.send("one");XCTAssertEqual(stored?.state,"failed")
            let count=try await db.pool.read { try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM sendStatusChecks") };XCTAssertEqual(count,0)
            do { try await db.settleAptosSend(sendID:"one",receipt:.init(hash:s.hash,outcome:.confirmed,fee:500,version:123,timestamp:123));XCTFail("Changed final outcome") } catch {}
        }
    }
}
