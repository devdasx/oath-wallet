import XCTest
import GRDB
@testable import OathAnkr
@testable import OathDatabase

@MainActor final class TonSendJournalTests:XCTestCase {
    let key=Data(repeating:1,count:32)
    func fixture(token:Bool=false) async throws -> (OathDatabase,URL,TonSendPlan) {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("TonJournal-"+UUID().uuidString)
        let db=try await OathDatabase.open(at:folder.appendingPathComponent("db.sqlite")),pub=try TonSendCrypto.publicKey(privateKey:key),owner=try TonSendCrypto.address(publicKey:pub)
        try await db.seed(networks:[.init(id:"ton",name:"Gram",family:"account",symbol:"GRAM",decimals:9,derivationPath:"m/44'/607'/0'",logo:"ton",sortOrder:0)],assets:[.init(id:"ton:native",networkID:"ton",reference:"native",name:"Gram",symbol:"GRAM",decimals:9)])
        if token { try await db.seed(networks:[],assets:[.init(id:"ton:0:"+String(repeating:"a",count:64),networkID:"ton",reference:"0:"+String(repeating:"a",count:64),name:"Test token",symbol:"TEST",decimals:9)]) }
        for i in 1...2 { try await db.importWalletIfNeeded(.init(id:"w\(i)",name:"Test",kind:"hd",vaultReference:"test\(i)",createdAt:1),accounts:[.init(id:"a\(i)",walletID:"w\(i)",networkID:"ton",address:owner,derivationPath:"m/44'/607'/0'")]) }
        let p=TonSendPlan(network:.mainnet,sender:owner,recipient:try TonSendCrypto.address(publicKey:TonSendCrypto.publicKey(privateKey:Data(repeating:2,count:32))),reference:token ? "0:"+String(repeating:"a",count:64):"native",publicKey:pub,decimals:9,requestedAmount:123456,amount:123456,assetBalance:1_000_000_000,nativeBalance:1_000_000_000,sequence:7,expiration:UInt32(Date.now.timeIntervalSince1970)+300,deploy:false,bounce:token,fee:1_000_000,feeReserve:2_000_000,attached:token ? 150_000_000:123456,jettonWallet:token ? owner:nil,recipientJettonWallet:token ? owner:nil)
        return (db,folder,p)
    }
    func draft(_ id:String,wallet:Int=1,plan:TonSendPlan,db:OathDatabase) async throws {
        try await db.saveDraft(.init(id:id,walletID:"w\(wallet)",accountID:"a\(wallet)",networkID:"ton",assetID:"ton:"+plan.reference,idempotencyKey:id,recipient:plan.recipient,amountAtomic:String(plan.amount),state:"draft",createdAt:Date.now.timeIntervalSince1970,updatedAt:Date.now.timeIntervalSince1970))
    }
    func testRestartReservationAcceptanceAndFinalHashMigration() async throws {
        let (db,folder,p)=try await fixture();defer { try? FileManager.default.removeItem(at:folder) }
        try await draft("one",plan:p,db:db);try await db.queueTonSend(sendID:"one",plan:p)
        try await draft("two",wallet:2,plan:p,db:db)
        do { try await db.queueTonSend(sendID:"two",plan:p);XCTFail("Double reserved") } catch { XCTAssertEqual(error as? TonSendError,.busy) }
        let s=try TonSendCrypto.sign(p,privateKey:key);try await db.journalTonSignature(sendID:"one",signed:s)
        let reopened=try await OathDatabase.open(at:folder.appendingPathComponent("db.sqlite"))
        let stored=try await reopened.send("one");XCTAssertEqual(try JSONDecoder().decode(TonSignedSend.self,from:XCTUnwrap(stored?.signedPayload)),s)
        let jobs=try await reopened.claimSendStatusChecks(owner:"restarted");XCTAssertEqual(jobs.count,1)
        _ = try await reopened.transitionSend("one",from:"signed",to:"broadcast")
        for outcome:TonSendReceipt.Outcome in [.unknown,.accepted] { try await reopened.settleTonSend(sendID:"one",receipt:.init(hash:s.hash,outcome:outcome)) }
        let pending=try await reopened.send("one");XCTAssertEqual(pending?.state,"broadcast")
        let hash=String(repeating:"f",count:64)
        try await reopened.settleTonSend(sendID:"one",receipt:.init(hash:s.hash,outcome:.confirmed,transactionHash:hash,fee:1_000_000,lt:123,timestamp:Date.now.timeIntervalSince1970))
        let settled=try await reopened.tonSubmission(walletID:"w1",hash:s.hash);XCTAssertEqual(settled?.state,"confirmed");XCTAssertEqual(settled?.transactionID,"ton:"+hash)
        let count=try await reopened.pool.read { try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM sendStatusChecks") };XCTAssertEqual(count,0)
        try await reopened.queueTonSend(sendID:"two",plan:p)
    }
    func testEarlierHistoryAndLaterHistoryDoNotDuplicateLocalSend() async throws {
        for (historyFirst,token) in [(true,false),(false,false),(true,true),(false,true)] {
            let (db,folder,p)=try await fixture(token:token);defer { try? FileManager.default.removeItem(at:folder) }
            try await draft("one",plan:p,db:db);try await db.queueTonSend(sendID:"one",plan:p)
            let signed=try TonSendCrypto.sign(p,privateKey:key);try await db.journalTonSignature(sendID:"one",signed:signed)
            let hash=String(repeating:"e",count:64)
            let current=try await db.beginTonSync(accountID:"a1"),currentCursor=try await db.tonHistoryWork(current).first!
            let tx=TonTransaction(hash:hash,lt:123,timestamp:123,failed:false,fee:"1000000",events:[.init(index:0,token:token ? .init(reference:p.reference,name:"Test token",symbol:"TEST",decimals:9):.native,from:p.sender,to:p.recipient,amount:String(p.amount))],raw:Data())
            let page=TonHistoryPage(transactions:[tx],next:nil,head:123,raw:Data())
            if historyFirst { try await db.commitTonPage(page,cursor:currentCursor,ticket:current) }
            try await db.settleTonSend(sendID:"one",receipt:.init(hash:signed.hash,outcome:.confirmed,transactionHash:hash,fee:1_000_000,lt:123,timestamp:123))
            if !historyFirst { try await db.commitTonPage(page,cursor:currentCursor,ticket:current) }
            let rows=try await db.pool.read { try ActivityRecord.fetchAll($0,sql:"SELECT * FROM activity WHERE accountID='a1'") }
            XCTAssertEqual(rows.count,1);XCTAssertEqual(rows.first?.counterparty,p.recipient)
            let count=try await db.pool.read { try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM transactions") };XCTAssertEqual(count,1)
        }
    }
    func testForgedSignaturesAndInvalidFinalReceiptsStayTracked() async throws {
        let (db,folder,p)=try await fixture();defer { try? FileManager.default.removeItem(at:folder) }
        try await draft("one",plan:p,db:db);try await db.queueTonSend(sendID:"one",plan:p)
        let s=try TonSendCrypto.sign(p,privateKey:key)
        do { try await db.journalTonSignature(sendID:"one",signed:.init(bytes:s.bytes,signature:Data(repeating:0,count:64),hash:s.hash,bodyHash:s.bodyHash));XCTFail() } catch {}
        try await db.journalTonSignature(sendID:"one",signed:s)
        for r in [TonSendReceipt(hash:s.hash,outcome:.confirmed),.init(hash:s.hash,outcome:.confirmed,transactionHash:String(repeating:"a",count:64),fee:p.nativeBalance+1,lt:123,timestamp:1),.init(hash:s.hash,outcome:.expired,fee:1)] {
            do { try await db.settleTonSend(sendID:"one",receipt:r);XCTFail("Invalid receipt") } catch {}
        }
        let stored=try await db.send("one");XCTAssertEqual(stored?.state,"signed")
    }
}
