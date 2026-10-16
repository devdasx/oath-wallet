import XCTest
import GRDB
@testable import OathAnkr
@testable import OathDatabase

@MainActor final class SolanaSendJournalTests:XCTestCase {
    let key=Data(repeating:1,count:32)
    func fixture() async throws -> (OathDatabase,URL,SolanaSendPlan) {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("SolanaJournal-"+UUID().uuidString)
        let db=try await OathDatabase.open(at:folder.appendingPathComponent("db.sqlite")),owner=try SolanaSendCrypto.address(privateKey:key)
        try await db.seed(networks:[.init(id:"solana",name:"Solana",family:"account",symbol:"SOL",decimals:9,derivationPath:"m/44'/501'/0'/0'/0'",logo:"solana",sortOrder:0)],assets:[.init(id:"solana:native",networkID:"solana",reference:"native",name:"Solana",symbol:"SOL",decimals:9)])
        for i in 1...2 { try await db.importWalletIfNeeded(.init(id:"w\(i)",name:"Test",kind:"hd",vaultReference:"test\(i)",createdAt:1),accounts:[.init(id:"a\(i)",walletID:"w\(i)",networkID:"solana",address:owner,derivationPath:"m/44'/501'/0'/0'/0'")]) }
        let p=SolanaSendPlan(network:.mainnet,sender:owner,recipient:try SolanaSendCrypto.address(privateKey:Data(repeating:2,count:32)),
            requestedAmount:123456,amount:123456,assetBalance:100_000_000,nativeBalance:100_000_000,blockhash:SolanaSendCrypto.encode(Data(repeating:3,count:32)),lastValidBlockHeight:500,slot:100,transactionFee:5000)
        return (db,folder,p)
    }
    func draft(_ id:String,wallet:Int=1,plan:SolanaSendPlan,db:OathDatabase) async throws {
        try await db.saveDraft(.init(id:id,walletID:"w\(wallet)",accountID:"a\(wallet)",networkID:"solana",assetID:"solana:native",idempotencyKey:id,recipient:plan.recipient,amountAtomic:String(plan.amount),state:"draft",createdAt:Date.now.timeIntervalSince1970,updatedAt:Date.now.timeIntervalSince1970))
    }
    func testSignatureDurabilityExclusiveSenderAndAcceptedNotFinal() async throws {
        let (db,folder,p)=try await fixture();defer { try? FileManager.default.removeItem(at:folder) }
        try await draft("one",plan:p,db:db);try await db.queueSolanaSend(sendID:"one",plan:p)
        try await draft("two",wallet:2,plan:p,db:db)
        do { try await db.queueSolanaSend(sendID:"two",plan:p);XCTFail("Double reserved") } catch { XCTAssertEqual(error as? SolanaSendError,.busy) }
        let s=try SolanaSendCrypto.sign(p,privateKey:key);try await db.journalSolanaSignature(sendID:"one",signed:s)
        let reopened=try await OathDatabase.open(at:folder.appendingPathComponent("db.sqlite"))
        let stored=try await reopened.send("one");XCTAssertEqual(try JSONDecoder().decode(SolanaSignedSend.self,from:XCTUnwrap(stored?.signedPayload)),s)
        let jobs=try await reopened.claimSendStatusChecks(owner:"restarted");XCTAssertEqual(jobs.count,1)
        _ = try await reopened.transitionSend("one",from:"signed",to:"broadcast")
        for outcome:SolanaSendReceipt.Outcome in [.unknown,.accepted] { try await reopened.settleSolanaSend(sendID:"one",receipt:.init(hash:s.hash,outcome:outcome)) }
        let pending=try await reopened.send("one");XCTAssertEqual(pending?.state,"broadcast")
        do { _ = try await reopened.transitionSend("one",from:"broadcast",to:"cancelled");XCTFail("Cancelled signed send") } catch {}
        try await reopened.settleSolanaSend(sendID:"one",receipt:.init(hash:s.hash,outcome:.confirmed,fee:5000,slot:123,timestamp:Date.now.timeIntervalSince1970))
        let settled=try await reopened.send("one");XCTAssertEqual(settled?.state,"confirmed")
        let count=try await reopened.pool.read { try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM sendStatusChecks") };XCTAssertEqual(count,0)
        try await reopened.queueSolanaSend(sendID:"two",plan:p)
    }
    func testSelectedDerivationIsReservedAndJournaledAcrossReopen() async throws {
        let (db,folder,original)=try await fixture();defer { try? FileManager.default.removeItem(at:folder) }
        let other=try SolanaSendCrypto.address(privateKey:Data(repeating:3,count:32))
        let base="m/44'/501'/0'/0'/0'",selected="m/44'/501'/0'",phantom="m/44'/501'/0'/0'"
        _ = try await db.prepareSolanaReceive(accountID:"a1",addresses:[.init(path:base,address:original.sender),.init(path:selected,address:other),.init(path:phantom,address:original.recipient)],preferredPath:base)
        _ = try await db.selectSolanaReceivePath(accountID:"a1",path:selected)
        let account=try await db.solanaSigningAccount(accountID:"a1");XCTAssertEqual(account.address,other);XCTAssertEqual(account.derivationPath,selected)
        let p=SolanaSendPlan(network:.mainnet,sender:other,recipient:original.recipient,requestedAmount:123456,amount:123456,assetBalance:100_000_000,nativeBalance:100_000_000,blockhash:original.blockhash,lastValidBlockHeight:500,slot:100,transactionFee:5000)
        try await draft("selected",plan:p,db:db);try await db.queueSolanaSend(sendID:"selected",plan:p)
        let signed=try SolanaSendCrypto.sign(p,privateKey:Data(repeating:3,count:32));try await db.journalSolanaSignature(sendID:"selected",signed:signed)
        let saved=try await db.send("selected");XCTAssertEqual(saved?.senderAddress,other)
        let count=try await db.pool.read { try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM solanaActivity WHERE owner=?",arguments:[other]) };XCTAssertEqual(count,1)
    }
    func testForgedSignatureAndInvalidFinalReceiptNeverRelease() async throws {
        let (db,folder,p)=try await fixture();defer { try? FileManager.default.removeItem(at:folder) }
        try await draft("one",plan:p,db:db);try await db.queueSolanaSend(sendID:"one",plan:p)
        let s=try SolanaSendCrypto.sign(p,privateKey:key)
        do { try await db.journalSolanaSignature(sendID:"one",signed:.init(bytes:s.bytes,publicKey:s.publicKey,signature:Data(repeating:0,count:64),hash:s.hash));XCTFail() } catch {}
        try await db.journalSolanaSignature(sendID:"one",signed:s)
        for r in [SolanaSendReceipt(hash:s.hash,outcome:.confirmed),.init(hash:s.hash,outcome:.confirmed,fee:p.transactionFee+1,slot:123,timestamp:1),.init(hash:s.hash,outcome:.expired,fee:1)] {
            do { try await db.settleSolanaSend(sendID:"one",receipt:r);XCTFail("Invalid receipt") } catch {}
        }
        let stored=try await db.send("one");XCTAssertEqual(stored?.state,"signed")
    }
    func testFailureAndExpiryAreTerminalWithoutFalseGas() async throws {
        for outcome:SolanaSendReceipt.Outcome in [.failed,.expired] {
            let (db,folder,p)=try await fixture();defer { try? FileManager.default.removeItem(at:folder) }
            try await draft("one",plan:p,db:db);try await db.queueSolanaSend(sendID:"one",plan:p)
            let s=try SolanaSendCrypto.sign(p,privateKey:key);try await db.journalSolanaSignature(sendID:"one",signed:s)
            let r=SolanaSendReceipt(hash:s.hash,outcome:outcome,fee:outcome == .failed ? 500: nil,slot:outcome == .failed ? 123:nil,timestamp:outcome == .failed ? 123:nil)
            try await db.settleSolanaSend(sendID:"one",receipt:r)
            let stored=try await db.send("one");XCTAssertEqual(stored?.state,"failed")
            let count=try await db.pool.read { try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM sendStatusChecks") };XCTAssertEqual(count,0)
            do { try await db.settleSolanaSend(sendID:"one",receipt:.init(hash:s.hash,outcome:.confirmed,fee:500,slot:123,timestamp:123));XCTFail("Changed final outcome") } catch {}
        }
    }
    func testHistoryMergePreservesAuthorizedAmountAndRecipient() async throws {
        let (db,folder,p)=try await fixture();defer { try? FileManager.default.removeItem(at:folder) }
        try await draft("one",plan:p,db:db);try await db.queueSolanaSend(sendID:"one",plan:p)
        let signed=try SolanaSendCrypto.sign(p,privateKey:key);try await db.journalSolanaSignature(sendID:"one",signed:signed)
        let ticket=try await db.beginSolanaSync(accountID:"a1")
        let work=try await db.solanaHistoryWork(ticket,since:1)
        let cursor=try XCTUnwrap(work.first)
        let tx=SolanaTransaction(signature:signed.hash,slot:123,timestamp:1_800_000_000,failed:false,fee:"5000",
            changes:[.init(mint:"native",decimals:9,amount:String(p.amount+5000),direction:"outgoing")],tokenAccounts:[],raw:Data("{}".utf8))
        try await db.commitSolanaHistory([tx],page:.init(signatures:[.init(signature:signed.hash,slot:123,blockTime:1_800_000_000,failed:false)],archival:true),cursor:cursor,ticket:ticket,backfill:false,pageSize:20,catalog:[:])
        let history=try await db.assetHistory(walletID:"w1",accountID:"a1",assetID:"solana:native")
        XCTAssertEqual(history.count,1);XCTAssertEqual(history.first?.amountAtomic,String(p.amount))
        let activity=try await db.pool.read { try ActivityRecord.fetchOne($0,sql:"SELECT * FROM activity WHERE transactionID=?",arguments:["solana:"+signed.hash]) }
        XCTAssertEqual(activity?.counterparty,p.recipient)
        // A history row is not enough to release the durable send. The exact
        // signed transaction is still checked by the status worker.
        let send=try await db.send("one");XCTAssertEqual(send?.state,"signed")
    }
    func testPostSendRefreshRequiresTheSettledSlotAndOriginalOwner() async throws {
        let (db,folder,p)=try await fixture();defer { try? FileManager.default.removeItem(at:folder) }
        try await draft("one",plan:p,db:db);try await db.queueSolanaSend(sendID:"one",plan:p)
        let signed=try SolanaSendCrypto.sign(p,privateKey:key);try await db.journalSolanaSignature(sendID:"one",signed:signed)
        try await db.settleSolanaSend(sendID:"one",receipt:.init(hash:signed.hash,outcome:.confirmed,fee:5000,slot:123,timestamp:1_800_000_000))
        let stored=try await db.send("one")
        let send=try XCTUnwrap(stored),ticket=try await db.beginSolanaSync(accountID:"a1")
        for slot:UInt64 in [122,123] {
            let inventory=SolanaInventory(owner:p.sender,lamports:"5000",nativeSlot:slot,tokenSlot:slot,token2022Slot:slot,accounts:[],fetchedAt:.now,raw:Data("{}".utf8))
            try await db.commitSolanaInventory(inventory,ticket:ticket,catalog:[:])
            let current=try await db.solanaSendBalanceIsCurrent(send);XCTAssertEqual(current,slot==123)
        }
        try await db.failSolanaSync(ticket,history:false)
        let failed=try await db.solanaSendBalanceIsCurrent(send);XCTAssertFalse(failed)
    }

}
