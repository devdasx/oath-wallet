import XCTest
import GRDB
@testable import OathAnkr
@testable import OathDatabase

@MainActor final class EVMSendJournalTests:XCTestCase {
    let key=Data(repeating:1,count:32)
    func fixture(network:EVMSendNetwork = .arbitrum) async throws -> (OathDatabase,URL,EVMSendPlan) {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("EVMJournal-"+UUID().uuidString)
        let db=try await OathDatabase.open(at:folder.appendingPathComponent("db.sqlite")),owner=try EVMSendCrypto.address(privateKey:key)
        try await db.seed(networks:[.init(id:network.rawValue,name:network.rawValue,family:"account",symbol:network.symbol,decimals:18,derivationPath:"m/44'/60'/0'/0/0",logo:network.rawValue,sortOrder:0)],assets:[.init(id:network.rawValue+":native",networkID:network.rawValue,reference:"native",name:network.rawValue,symbol:network.symbol,decimals:18)])
        for i in 1...2 { try await db.importWalletIfNeeded(.init(id:"w\(i)",name:"Test",kind:"hd",vaultReference:"test\(i)",createdAt:1),accounts:[.init(id:"a\(i)",walletID:"w\(i)",networkID:network.rawValue,address:owner,derivationPath:"m/44'/60'/0'/0/0")]) }
        let p=EVMSendPlan(network:network,sender:owner,recipient:try EVMSendCrypto.address(privateKey:Data(repeating:2,count:32)),reference:"native",decimals:18,requestedAmount:"123456",amount:"123456",assetBalance:"1000000000000000000",nativeBalance:"1000000000000000000",nonce:7,gasLimit:21000,maxFeePerGas:41000000000,maxPriorityFeePerGas:1000000000,blockHeight:100)

        return (db,folder,p)
    }
    func draft(_ id:String,wallet:Int=1,plan:EVMSendPlan,db:OathDatabase) async throws {
        try await db.saveDraft(.init(id:id,walletID:"w\(wallet)",accountID:"a\(wallet)",networkID:plan.network.rawValue,assetID:plan.network.rawValue+":native",idempotencyKey:id,recipient:plan.recipient,amountAtomic:String(plan.amount),state:"draft",createdAt:Date.now.timeIntervalSince1970,updatedAt:Date.now.timeIntervalSince1970))
    }
    func testWalletConnectRequestCanRetryUnsignedButNeverReplaceSignedBytes() async throws {
        let (db,folder,p)=try await fixture();defer { try? FileManager.default.removeItem(at:folder) }
        let id="wc:"+String(repeating:"a",count:64)
        try await draft(id,plan:p,db:db);try await db.queueEVMSend(sendID:id,plan:p)
        do { try await db.resetUnsentWalletConnectEVM(id,walletID:"w2",accountID:"a2");XCTFail("Must preserve another wallet's draft") } catch {}
        let stillQueued=try await db.send(id);XCTAssertEqual(stillQueued?.state,"queued")
        try await db.resetUnsentWalletConnectEVM(id,walletID:"w1",accountID:"a1")
        let absent=try await db.send(id),oldPlan=try await db.evmSendPlan(sendID:id)
        XCTAssertNil(absent);XCTAssertNil(oldPlan)
        try await draft(id,plan:p,db:db);try await db.queueEVMSend(sendID:id,plan:p)
        let signed=try EVMSendCrypto.sign(p,privateKey:key)
        try await db.journalEVMSignature(sendID:id,signed:signed)
        let reopened=try await OathDatabase.open(at:folder.appendingPathComponent("db.sqlite"))
        for state in ["signed","broadcast"] {
            if state=="broadcast" { _=try await reopened.transitionSend(id,from:"signed",to:"broadcast") }
            do { try await reopened.resetUnsentWalletConnectEVM(id,walletID:"w1",accountID:"a1");XCTFail("Signed transaction must never reset") } catch {}
            let stored=try await reopened.send(id)
            XCTAssertEqual(stored?.state,state)
            XCTAssertEqual(try JSONDecoder().decode(EVMSignedSend.self,from:XCTUnwrap(stored?.signedPayload)),signed)
        }
        do { try await db.resetUnsentWalletConnectEVM("ordinary-send",walletID:"w1",accountID:"a1");XCTFail("Not a WalletConnect request") } catch {}
    }
    func testSignatureDurabilityExclusiveSenderAndAcceptedNotFinal() async throws {
        for network in EVMSendNetwork.allCases where !network.isTestnet {
        let (db,folder,p)=try await fixture(network:network);defer { try? FileManager.default.removeItem(at:folder) }
        try await draft("one",plan:p,db:db);try await db.queueEVMSend(sendID:"one",plan:p)
        try await draft("two",wallet:2,plan:p,db:db)
        do { try await db.queueEVMSend(sendID:"two",plan:p);XCTFail("Double reserved") } catch { XCTAssertEqual(error as? EVMSendError,.busy) }
        let s=try EVMSendCrypto.sign(p,privateKey:key);try await db.journalEVMSignature(sendID:"one",signed:s)
        let reopened=try await OathDatabase.open(at:folder.appendingPathComponent("db.sqlite"))
        let stored=try await reopened.send("one");XCTAssertEqual(try JSONDecoder().decode(EVMSignedSend.self,from:XCTUnwrap(stored?.signedPayload)),s)
        let jobs=try await reopened.claimSendStatusChecks(owner:"restarted");XCTAssertEqual(jobs.count,1)
        _ = try await reopened.transitionSend("one",from:"signed",to:"broadcast")
        for outcome:EVMSendReceipt.Outcome in [.unknown,.accepted] { try await reopened.settleEVMSend(sendID:"one",receipt:.init(hash:s.hash,outcome:outcome)) }
        let pending=try await reopened.send("one");XCTAssertEqual(pending?.state,"broadcast")
        do { _ = try await reopened.transitionSend("one",from:"broadcast",to:"cancelled");XCTFail("Cancelled signed send") } catch {}
        try await reopened.settleEVMSend(sendID:"one",receipt:.init(hash:s.hash,outcome:.confirmed,fee:50000,height:123,timestamp:Date.now.timeIntervalSince1970))
        let settled=try await reopened.send("one");XCTAssertEqual(settled?.state,"confirmed")
        let count=try await reopened.pool.read { try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM sendStatusChecks") };XCTAssertEqual(count,0)
        try await reopened.queueEVMSend(sendID:"two",plan:p)
        }
    }
    func testSuccessorNonceDoesNotWaitForFinalityOrReleaseOldJournal() async throws {
        let (db,folder,p)=try await fixture(network:.ethereum)
        defer { try? FileManager.default.removeItem(at:folder) }
        var object=try JSONSerialization.jsonObject(with:JSONEncoder().encode(p)) as! [String:Any]
        object["nonce"]=p.nonce+1
        let next=try JSONDecoder().decode(EVMSendPlan.self,from:JSONSerialization.data(withJSONObject:object))
        try await draft("approval",plan:p,db:db)
        try await db.queueEVMSend(sendID:"approval",plan:p)
        try await draft("swap",wallet:2,plan:next,db:db)
        do { try await db.queueEVMSend(sendID:"swap",plan:next);XCTFail("An active unsigned authorization must still block") }
        catch { XCTAssertEqual(error as? EVMSendError,.busy) }
        let signed=try EVMSendCrypto.sign(p,privateKey:key)
        try await db.journalEVMSignature(sendID:"approval",signed:signed)
        _ = try await db.transitionSend("approval",from:"signed",to:"broadcast")

        try await draft("sameNonce",wallet:2,plan:p,db:db)
        do { try await db.queueEVMSend(sendID:"sameNonce",plan:p);XCTFail("Same nonce must remain reserved") }
        catch { XCTAssertEqual(error as? EVMSendError,.busy) }
        // A fresh production quote/preflight supplies a consumed latest nonce.
        // The predecessor remains pending until the normal finality worker settles it.
        try await db.queueEVMSend(sendID:"swap",plan:next)
        let old=try await db.send("approval"), successor=try await db.send("swap")
        XCTAssertEqual(old?.state,"broadcast")
        XCTAssertNotNil(old?.signedPayload)
        XCTAssertEqual(successor?.state,"queued")
        let checks=try await db.pool.read { try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM sendStatusChecks WHERE sendID='approval'") }
        XCTAssertEqual(checks,1,"Do not delete finality/recovery work to permit a successor")
        try await draft("duplicate",plan:next,db:db)
        do { try await db.queueEVMSend(sendID:"duplicate",plan:next);XCTFail("Duplicate imports cannot concurrently spend the next nonce") }
        catch { XCTAssertEqual(error as? EVMSendError,.busy) }
    }

    func testTokenReceiptPersistsActualDeliveryWithoutFalseFailure() async throws {
        let (db,folder,native)=try await fixture();defer { try? FileManager.default.removeItem(at:folder) }
        let reference="0x"+String(repeating:"3",count:40),asset="arbitrum:"+reference
        let p=EVMSendPlan(network:.arbitrum,sender:native.sender,recipient:native.recipient,reference:reference,decimals:6,requestedAmount:"100",amount:"100",assetBalance:"1000",nativeBalance:native.nativeBalance,nonce:7,gasLimit:50000,maxFeePerGas:native.maxFeePerGas,maxPriorityFeePerGas:native.maxPriorityFeePerGas,blockHeight:100)
        try await db.pool.write { sql in
            try AssetRecord(id:asset,networkID:"arbitrum",reference:reference,name:"Test",symbol:"TEST",decimals:6).insert(sql)
        }
        try await db.saveDraft(.init(id:"token",walletID:"w1",accountID:"a1",networkID:"arbitrum",assetID:asset,idempotencyKey:"token",recipient:p.recipient,amountAtomic:p.amount,state:"draft",createdAt:1,updatedAt:1))
        try await db.queueEVMSend(sendID:"token",plan:p)
        let s=try EVMSendCrypto.sign(p,privateKey:key);try await db.journalEVMSignature(sendID:"token",signed:s)
        do {
            try await db.settleEVMSend(sendID:"token",receipt:.init(hash:s.hash,outcome:.confirmed,fee:50000,height:123,timestamp:123))
            XCTFail("A token receipt must include observed delivery")
        } catch { XCTAssertEqual(error as? EVMSendError,.changed) }
        try await db.pool.write { sql in
            for (i,amount) in ["60","39"].enumerated() {
                try ActivityRecord(id:"indexed-\(i)",walletID:"w1",accountID:"a1",networkID:"arbitrum",transactionID:"arbitrum:"+s.hash,assetID:asset,direction:"outgoing",amountAtomic:amount,counterparty:p.recipient,timestamp:123).insert(sql)
            }
        }
        try await db.settleEVMSend(sendID:"token",receipt:.init(hash:s.hash,outcome:.confirmed,fee:50000,height:123,timestamp:123,deliveredAmount:"99"))
        let record=try await db.send("token");XCTAssertEqual(record?.state,"confirmed");XCTAssertEqual(record?.amountAtomic,"100")
        let activity=try await db.pool.read { try ActivityRecord.fetchAll($0,sql:"SELECT * FROM activity WHERE transactionID=? ORDER BY id",arguments:["arbitrum:"+s.hash]) }
        XCTAssertEqual(activity.map(\.amountAtomic),["60","39"],"Indexed events replace the placeholder and retain individual amounts")
    }
    func testFailureCancellationAndReplacementAreTerminalWithoutFalseGas() async throws {
        for outcome:EVMSendReceipt.Outcome in [.failed,.cancelled,.replaced] {
            let (db,folder,p)=try await fixture();defer { try? FileManager.default.removeItem(at:folder) }
            try await draft("one",plan:p,db:db);try await db.queueEVMSend(sendID:"one",plan:p)
            let s=try EVMSendCrypto.sign(p,privateKey:key);try await db.journalEVMSignature(sendID:"one",signed:s)
            let r=EVMSendReceipt(hash:s.hash,outcome:outcome,fee:outcome == .failed ? 500: nil,height:outcome == .failed ? 123:nil,timestamp:outcome == .failed ? 123:nil,replacementHash:[.replaced,.cancelled].contains(outcome) ? "0x"+String(repeating:"f",count:64):nil)
            try await db.settleEVMSend(sendID:"one",receipt:r)
            let stored=try await db.send("one");XCTAssertEqual(stored?.state,"failed")
            let evidence=try await db.pool.read { try String.fetchOne($0,sql:"SELECT outcome FROM transactionEvidence WHERE accountID='a1'") }
            if outcome == .cancelled { XCTAssertEqual(evidence,"canceled") }
            if outcome == .replaced { XCTAssertEqual(evidence,"replaced") }
            let count=try await db.pool.read { try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM sendStatusChecks") };XCTAssertEqual(count,0)
            do { try await db.settleEVMSend(sendID:"one",receipt:.init(hash:s.hash,outcome:.confirmed,fee:500,height:123,timestamp:123));XCTFail("Changed final outcome") } catch {}
        }
    }
    func testConfirmedSendRefreshesDedicatedPortfoliosAndRejectsStaleInventory() async throws {
        for network:EVMSendNetwork in [.hyperevm,.robinhood,.monad,.unichain] {
            let (db,folder,p)=try await fixture(network:network);defer { try? FileManager.default.removeItem(at:folder) }
            func inventory(_ block:Int,_ amount:String) throws -> Data {
                try JSONSerialization.data(withJSONObject:["chain":network.rawValue,"owner":p.sender,"block":block,"blockHash":"0x"+String(repeating:"a",count:64),
                    "observedAt":Date.now.timeIntervalSinceReferenceDate,"holdings":[["token":["reference":"native","name":network.rawValue,"symbol":network.symbol,"decimals":18],"amount":amount]],"complete":true,"raw":Data("{}".utf8).base64EncodedString()])
            }
            func commit(_ block:Int,_ amount:String) async throws {
                for account in ["a1","a2"] {
                    let data=try inventory(block,amount)
                    switch network {
                    case .hyperevm:
                        let ticket=try await db.beginHyperEVMSync(accountID:account)
                        try await db.commitHyperEVMInventory(JSONDecoder().decode(HyperEVMInventory.self,from:data),ticket:ticket,catalog:.empty)
                    case .robinhood:
                        let ticket=try await db.beginRobinhoodSync(accountID:account)
                        try await db.commitRobinhoodInventory(JSONDecoder().decode(RobinhoodInventory.self,from:data),ticket:ticket,catalog:.empty)
                    default:
                        let chain=try XCTUnwrap(IndexedEVMChain(rawValue:network.rawValue)),ticket=try await db.beginIndexedEVMSync(accountID:account)
                        try await db.commitIndexedEVMInventory(JSONDecoder().decode(IndexedEVMInventory.self,from:data),ticket:ticket,catalog:.empty(chain))
                    }
                }
            }
            try await commit(100,p.nativeBalance)
            try await draft("one",plan:p,db:db);try await db.queueEVMSend(sendID:"one",plan:p)
            let signed=try EVMSendCrypto.sign(p,privateKey:key);try await db.journalEVMSignature(sendID:"one",signed:signed)
            try await db.settleEVMSend(sendID:"one",receipt:.init(hash:signed.hash,outcome:.confirmed,fee:100,height:101,timestamp:123))
            let send=try await db.send("one")
            let client=try EVMSendClient(network:network,endpoints:[URL(string:"https://test.example")!],transport:EVMBalanceFixture(network:network))
            let refreshed=try await db.refreshEVMSendBalance(XCTUnwrap(send),client:client);XCTAssertTrue(refreshed)
            for wallet in ["w1","w2"] {
                let snapshot=try await db.snapshot(walletID:wallet,currency:"USD")
                XCTAssertEqual(snapshot.holdings.first{$0.reference=="native"}?.amountAtomic,"123",network.rawValue)
            }
            try await commit(100,"999") // A slower inventory must not restore the spent balance.
            let snapshot=try await db.snapshot(walletID:"w1",currency:"USD")
            XCTAssertEqual(snapshot.holdings.first{$0.reference=="native"}?.amountAtomic,"123")
            try await commit(102,"456")
            let updated=try await db.snapshot(walletID:"w1",currency:"USD")
            XCTAssertEqual(updated.holdings.first{$0.reference=="native"}?.amountAtomic,"456")
        }
    }

}

private struct EVMBalanceFixture:AnkrTransport {
    let network:EVMSendNetwork
    func send(_ request:URLRequest) async throws -> (Data,Int) {
        let calls=try JSONDecoder().decode(SolanaJSON.self,from:request.httpBody!).array!
        let rows=try calls.map { call -> SolanaJSON in
            let result:SolanaJSON
            switch call["method"].string {
            case "eth_chainId":result = .string("0x"+String(network.chainID,radix:16))
            case "eth_getBlockByNumber": result = .object(["number":.string("0x65"),"hash":.string("0x"+String(repeating:"a",count:64))])
            case "eth_getBalance":
                guard call["params"].array?.last?.string==(network == .hyperevm ? "latest":"0x65") else { throw EVMSendError.changed }
                result = .string("0x7b")
            default:throw EVMSendError.malformed
            }
            return .object(["jsonrpc":.string("2.0"),"id":call["id"],"result":result])
        }
        return (try JSONEncoder().encode(SolanaJSON.array(rows)),200)
    }
}
