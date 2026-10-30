import XCTest
import GRDB
@testable import OathAnkr
@testable import OathDatabase

@MainActor final class PolkadotSendJournalTests: XCTestCase {
    let key = Data(repeating:7,count:32)
    func fixture() async throws -> (OathDatabase,URL,PolkadotSendPlan) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PolkadotSend-"+UUID().uuidString)
        let db = try await OathDatabase.open(at:folder.appendingPathComponent("wallet.sqlite"))
        let owner = try PolkadotIdentity.address(publicKey:PolkadotSendCrypto.publicKey(privateKey:key))
        try await db.seed(networks:[.init(id:"polkadot",name:"Polkadot",family:"account",symbol:"DOT",decimals:10,derivationPath:"m/44'/354'/0'/0'/0'",logo:"polkadot",sortOrder:0)],assets:[.init(id:"polkadot:native",networkID:"polkadot",reference:"native",name:"Polkadot",symbol:"DOT",decimals:10)])
        for i in 1...2 { try await db.importWalletIfNeeded(.init(id:"w\(i)",name:"Test",kind:"hd",vaultReference:"test\(i)",createdAt:1),accounts:[.init(id:"a\(i)",walletID:"w\(i)",networkID:"polkadot",address:owner,derivationPath:"m/44'/354'/0'/0'/0'")]) }
        let extensions = ["AuthorizeCall","CheckNonZeroSender","CheckSpecVersion","CheckTxVersion","CheckGenesis","CheckMortality","CheckNonce","CheckWeight","ChargeAssetTxPayment","PrevalidateAttests","CheckMetadataHash","EthSetOrigin","StorageWeightReclaim"]
        let plan = try PolkadotSendPlan(network:.mainnet,sender:owner,recipient:PolkadotIdentity.address(publicKey:PolkadotSendCrypto.publicKey(privateKey:Data(repeating:8,count:32))),token:.native,requestedAmount:"10000000000",amount:"10000000000",assetBalance:"100000000000",nativeBalance:"100000000000",reserve:"100000000",fee:"100000000",nonce:1,specVersion:2005001,transactionVersion:15,blockHeight:100,blockHash:"0x"+String(repeating:"33",count:32),metadataHash:"0x"+String(repeating:"44",count:32),callIndex:Data([10,3]),extensions:extensions,createdAt:.now)
        return (db,folder,plan)
    }
    func draft(_ id:String, wallet:Int = 1, plan:PolkadotSendPlan, db:OathDatabase) async throws {
        try await db.saveDraft(.init(id:id,walletID:"w\(wallet)",accountID:"a\(wallet)",networkID:"polkadot",assetID:"polkadot:native",idempotencyKey:id,
            recipient:plan.recipient,amountAtomic:String(plan.amount),state:"draft",createdAt:Date.now.timeIntervalSince1970,updatedAt:Date.now.timeIntervalSince1970))
    }
    func testCrossWalletReservationAndCancelledAuthenticationReleasesOnlyUnsigned() async throws {
        let (db,folder,plan) = try await fixture(); defer { try? FileManager.default.removeItem(at:folder) }
        try await draft("one",plan:plan,db:db); try await draft("two",wallet:2,plan:plan,db:db)
        try await db.queuePolkadotSend(sendID:"one",plan:plan)
        do { try await db.queuePolkadotSend(sendID:"two",plan:plan); XCTFail("Shared address double reservation") } catch { XCTAssertEqual(error as? PolkadotSendError,.busy) }
        _ = try await db.transitionSend("one",from:"queued",to:"cancelled")
        try await db.queuePolkadotSend(sendID:"two",plan:plan)
        let signed = try PolkadotSendCrypto.sign(plan,privateKey:key)
        try await db.journalPolkadotSignature(sendID:"two",signed:signed)
        do { _ = try await db.transitionSend("two",from:"signed",to:"cancelled"); XCTFail("Signed send released") } catch { XCTAssertEqual(error as? StoreError,.invalidTransition) }
    }
    func testExactSignedBytesSurviveReopenAndUnknownBroadcastReservesSender() async throws {
        let (db,folder,plan) = try await fixture(); defer { try? FileManager.default.removeItem(at:folder) }
        try await draft("one",plan:plan,db:db); try await db.queuePolkadotSend(sendID:"one",plan:plan)
        let signed = try PolkadotSendCrypto.sign(plan,privateKey:key)
        try await db.journalPolkadotSignature(sendID:"one",signed:signed)
        _ = try await db.transitionSend("one",from:"signed",to:"broadcast")
        try await db.settlePolkadotSend(sendID:"one",receipt:.init(hash:signed.hash,outcome:.accepted))
        let acknowledged = try await db.pool.read { try Double.fetchOne($0,sql:"SELECT submittedAt FROM polkadotSendPlans WHERE sendID='one'") }
        XCTAssertNotNil(acknowledged)
        let checking = try await db.pool.read { try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM sendStatusChecks WHERE sendID='one'") }
        XCTAssertEqual(checking,1,"Acknowledgement must retain durable finality tracking")
        let reopened = try await OathDatabase.open(at:folder.appendingPathComponent("wallet.sqlite"))
        let fetched = try await reopened.send("one")
        let stored = try XCTUnwrap(fetched)
        XCTAssertEqual(try JSONDecoder().decode(PolkadotSignedSend.self,from:XCTUnwrap(stored.signedPayload)),signed)
        try await reopened.settlePolkadotSend(sendID:"one",receipt:.init(hash:signed.hash,outcome:.unknown,fee:nil))
        let pending = try await reopened.send("one"); XCTAssertEqual(pending?.state,"broadcast")
        try await draft("two",wallet:2,plan:plan,db:reopened)
        do { try await reopened.queuePolkadotSend(sendID:"two",plan:plan); XCTFail("Unknown broadcast released") } catch { XCTAssertEqual(error as? PolkadotSendError,.busy) }
        try await reopened.settlePolkadotSend(sendID:"one",receipt:.init(hash:signed.hash,outcome:.confirmed,fee:"12",block:101))
        let confirmed = try await reopened.send("one"); XCTAssertEqual(confirmed?.state,"confirmed")
        try await reopened.queuePolkadotSend(sendID:"two",plan:plan)
        let targets = try await reopened.pendingSendBalanceRefreshTargets(); XCTAssertEqual(targets.count,1)
    }
    func testSubmissionObservationRequiresFinalJournalAndWalletScope() async throws {
        let(db,folder,plan)=try await fixture();defer{try? FileManager.default.removeItem(at:folder)}
        try await draft("one",plan:plan,db:db);try await db.queuePolkadotSend(sendID:"one",plan:plan)
        let signed=try PolkadotSendCrypto.sign(plan,privateKey:key);try await db.journalPolkadotSignature(sendID:"one",signed:signed)
        _=try await db.transitionSend("one",from:"signed",to:"broadcast")
        // History can observe a head-node failure before solid finality. The UI
        // must continue to read the send journal, not this tentative row.
        try await db.pool.write{try $0.execute(sql:"UPDATE transactions SET state='failed' WHERE id=?",arguments:["polkadot:"+signed.hash])}
        let pending=try await db.polkadotSubmission(walletID:"w1",hash:signed.hash);XCTAssertEqual(pending?.state,"broadcast")
        let other=try await db.polkadotSubmission(walletID:"w2",hash:signed.hash);XCTAssertNil(other)
        try await db.settlePolkadotSend(sendID:"one",receipt:.init(hash:signed.hash,outcome:.confirmed,fee:"12",block:101))
        let final=try await db.polkadotSubmission(walletID:"w1",hash:signed.hash);XCTAssertEqual(final?.state,"confirmed")
    }
    func testTamperedSignedTransactionAndTestnetPlanRejectedBeforeJournal() async throws {
        let (db,folder,plan) = try await fixture(); defer { try? FileManager.default.removeItem(at:folder) }
        try await draft("one",plan:plan,db:db); try await db.queuePolkadotSend(sendID:"one",plan:plan)
        let signed = try PolkadotSendCrypto.sign(plan,privateKey:key)
        var badBytes = signed.bytes; badBytes[20] ^= 1
        do { try await db.journalPolkadotSignature(sendID:"one",signed:.init(bytes:badBytes,signature:signed.signature,hash:signed.hash)); XCTFail("Tampered payload") } catch { XCTAssertEqual(error as? PolkadotSendError,.signing) }
        var j=try JSONSerialization.jsonObject(with:JSONEncoder().encode(plan)) as! [String:Any];j["network"]="paseo"
        let testnet=try JSONDecoder().decode(PolkadotSendPlan.self,from:JSONSerialization.data(withJSONObject:j))
        do { try await db.queuePolkadotSend(sendID:"one",plan:testnet); XCTFail("Testnet in production ledger") } catch { XCTAssertEqual(error as? PolkadotSendError,.wrongNetwork) }
    }
    func testFailedExecutionSettlesAsFailureAndNeverSuccess() async throws {
        let (db,folder,plan) = try await fixture(); defer { try? FileManager.default.removeItem(at:folder) }
        try await draft("one",plan:plan,db:db); try await db.queuePolkadotSend(sendID:"one",plan:plan)
        let signed = try PolkadotSendCrypto.sign(plan,privateKey:key)
        try await db.journalPolkadotSignature(sendID:"one",signed:signed)
        try await db.settlePolkadotSend(sendID:"one",receipt:.init(hash:signed.hash,outcome:.failed,fee:"12",block:101))
        let failed = try await db.send("one"); XCTAssertEqual(failed?.state,"failed")
        do { try await db.settlePolkadotSend(sendID:"one",receipt:.init(hash:signed.hash,outcome:.confirmed,fee:"12",block:101)); XCTFail("Conflicting result") } catch { XCTAssertEqual(error as? StoreError,.invalidTransition) }
        let targets = try await db.pendingSendBalanceRefreshTargets(); XCTAssertEqual(targets.count,1)
        do { try await db.settlePolkadotSend(sendID:"one",receipt:.init(hash:signed.hash,outcome:.expired)); XCTFail("Expiry overwrote fee-consuming failure") } catch { XCTAssertEqual(error as? StoreError,.invalidTransition) }
    }

    func testPublicJournalRejectsTestnetEvenWhenFixtureIsQueuedInternally() async throws {
        let (db,folder,plan) = try await fixture(); defer { try? FileManager.default.removeItem(at:folder) }
        var json = try JSONSerialization.jsonObject(with:JSONEncoder().encode(plan)) as! [String:Any]
        json["network"] = "paseo"
        let testnet = try JSONDecoder().decode(PolkadotSendPlan.self,from:JSONSerialization.data(withJSONObject:json))
        try await draft("testnet",plan:testnet,db:db)
        try await db.queueValidatedPolkadotSend(sendID:"testnet",plan:testnet)
        let signed = try PolkadotSendCrypto.sign(testnet,privateKey:key)
        do {
            try await db.journalPolkadotSignature(sendID:"testnet",signed:signed)
            XCTFail("App-facing journal accepted testnet")
        } catch { XCTAssertEqual(error as? PolkadotSendError,.changed) }
        let rejected = try await db.send("testnet")
        XCTAssertEqual(rejected?.state,"queued"); XCTAssertNil(rejected?.signedPayload)
        try await db.journalPolkadotSignature(sendID:"testnet",signed:signed,allowingTestnet:true)
        let accepted = try await db.send("testnet")
        XCTAssertEqual(accepted?.state,"signed")
    }
    func testProvenExpiryReleasesSenderWithoutClaimingFeeOrBalanceRefresh() async throws {
        let (db,folder,plan) = try await fixture(); defer { try? FileManager.default.removeItem(at:folder) }
        try await draft("one",plan:plan,db:db); try await db.queuePolkadotSend(sendID:"one",plan:plan)
        let signed = try PolkadotSendCrypto.sign(plan,privateKey:key)
        try await db.journalPolkadotSignature(sendID:"one",signed:signed)
        try await db.settlePolkadotSend(sendID:"one",receipt:.init(hash:signed.hash,outcome:.expired))
        let expired = try await db.send("one"); XCTAssertEqual(expired?.state,"failed"); XCTAssertEqual(expired?.failureCode,"expired")
        let targets = try await db.pendingSendBalanceRefreshTargets(); XCTAssertTrue(targets.isEmpty)
        try await draft("two",wallet:2,plan:plan,db:db); try await db.queuePolkadotSend(sendID:"two",plan:plan)
        do { try await db.settlePolkadotSend(sendID:"one",receipt:.init(hash:signed.hash,outcome:.failed,fee:"12",block:101)); XCTFail("Conflicting terminal evidence") } catch { XCTAssertEqual(error as? StoreError,.invalidTransition) }
    }

    func testFinalizedHashAndIndexerPositionMergeInEitherArrivalOrder() async throws {
        for historyFirst in [true,false] {
            for transfer in [true,false] {
                let (db,folder,plan)=try await fixture();defer { try? FileManager.default.removeItem(at:folder) }
                try await draft("one",plan:plan,db:db);try await db.queuePolkadotSend(sendID:"one",plan:plan)
                let signed=try PolkadotSendCrypto.sign(plan,privateKey:key)
                try await db.journalPolkadotSignature(sendID:"one",signed:signed)
                let ticket=try await db.beginPolkadotSync(accountID:"a1")
                let event=PolkadotEvent(id:transfer ? "event:101-7":"extrinsic:101-5",transaction:"101-5",reference:"native",amount:transfer ? plan.amount:"0",from:plan.sender,to:transfer ? plan.recipient:plan.sender,height:101,timestamp:1000,successful:true,token:.native)
                let page=PolkadotHistoryPage(events:[event],next:nil)
                if historyFirst { try await db.commitPolkadotHistory(page,ticket:ticket,stream:"native",currentPage:0,advance:false) }
                try await db.settlePolkadotSend(sendID:"one",receipt:.init(hash:signed.hash,outcome:.confirmed,fee:"12",block:101,extrinsicIndex:5))
                // Replay after reopening also resolves the durable indexer alias.
                let reopened=try await OathDatabase.open(at:folder.appendingPathComponent("wallet.sqlite"))
                try await reopened.commitPolkadotHistory(page,ticket:ticket,stream:"native",currentPage:0,advance:false)
                let history=try await reopened.chainHistory(walletID:"w1",currency:"USD")
                XCTAssertEqual(history.count,1);XCTAssertEqual(history.first?.entry.amountAtomic,plan.amount)
                XCTAssertEqual(history.first?.entry.state,"confirmed")
                let tx=try await reopened.pool.read { db in try TransactionRecord.fetchOne(db,key:"polkadot:"+signed.hash) }
                XCTAssertEqual(tx?.hash,signed.hash);XCTAssertEqual(tx?.feeAtomic,"12")
                let count=try await reopened.pool.read { try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM transactions WHERE networkID='polkadot'") }
                XCTAssertEqual(count,1)
            }
        }
    }
}
