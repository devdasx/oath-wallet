import XCTest
import GRDB
@testable import OathAnkr
@testable import OathDatabase

@MainActor final class NearSendJournalTests: XCTestCase {
    let key = Data(repeating:7,count:32)
    func fixture() async throws -> (OathDatabase,URL,NearSendPlan) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NearSend-"+UUID().uuidString)
        let db = try await OathDatabase.open(at:folder.appendingPathComponent("wallet.sqlite"))
        let owner = try NearSendCrypto.address(privateKey:key)
        try await db.seed(networks:[.init(id:"near",name:"Near",family:"account",symbol:"NEAR",decimals:24,derivationPath:"m/44'/397'/0'",logo:"near",sortOrder:0)],assets:[.init(id:"near:native",networkID:"near",reference:"native",name:"Near",symbol:"NEAR",decimals:24)])
        for i in 1...2 { try await db.importWalletIfNeeded(.init(id:"w\(i)",name:"Test",kind:"hd",vaultReference:"test\(i)",createdAt:1),accounts:[.init(id:"a\(i)",walletID:"w\(i)",networkID:"near",address:owner,derivationPath:"m/44'/397'/0'")]) }
        let plan = NearSendPlan(network:.mainnet,sender:owner,recipient:try NearSendCrypto.address(privateKey:Data(repeating:8,count:32)),reference:"native",publicKey:try NearSendCrypto.publicKey(privateKey:key),decimals:24,
            requestedAmount:"100000000000000000000000",amount:"100000000000000000000000",assetBalance:"10000000000000000000000000",nativeBalance:"10000000000000000000000000",reserve:"1820000000000000000000",storageDeposit:"0",fee:"1000000000000000000000",gasPriceCeiling:"200000000",gas:0,storageGas:0,nonce:123456789000001,blockHash:String(repeating:"1",count:32),blockHeight:100,validityPeriod:86400)
        return (db,folder,plan)
    }
    func draft(_ id:String, wallet:Int = 1, plan:NearSendPlan, db:OathDatabase) async throws {
        try await db.saveDraft(.init(id:id,walletID:"w\(wallet)",accountID:"a\(wallet)",networkID:"near",assetID:"near:native",idempotencyKey:id,
            recipient:plan.recipient,amountAtomic:String(plan.amount),state:"draft",createdAt:Date.now.timeIntervalSince1970,updatedAt:Date.now.timeIntervalSince1970))
    }
    func testCrossWalletReservationAndCancelledAuthenticationReleasesOnlyUnsigned() async throws {
        let (db,folder,plan) = try await fixture(); defer { try? FileManager.default.removeItem(at:folder) }
        try await draft("one",plan:plan,db:db); try await draft("two",wallet:2,plan:plan,db:db)
        try await db.queueNearSend(sendID:"one",plan:plan)
        do { try await db.queueNearSend(sendID:"two",plan:plan); XCTFail("Shared address double reservation") } catch { XCTAssertEqual(error as? NearSendError,.busy) }
        _ = try await db.transitionSend("one",from:"queued",to:"cancelled")
        try await db.queueNearSend(sendID:"two",plan:plan)
        let signed = try NearSendCrypto.sign(plan,privateKey:key)
        try await db.journalNearSignature(sendID:"two",signed:signed)
        do { _ = try await db.transitionSend("two",from:"signed",to:"cancelled"); XCTFail("Signed send released") } catch { XCTAssertEqual(error as? StoreError,.invalidTransition) }
    }
    func testExactSignedBytesSurviveReopenAndUnknownBroadcastReservesSender() async throws {
        let (db,folder,plan) = try await fixture(); defer { try? FileManager.default.removeItem(at:folder) }
        try await draft("one",plan:plan,db:db); try await db.queueNearSend(sendID:"one",plan:plan)
        let signed = try NearSendCrypto.sign(plan,privateKey:key)
        try await db.journalNearSignature(sendID:"one",signed:signed)
        _ = try await db.transitionSend("one",from:"signed",to:"broadcast")
        try await db.settleNearSend(sendID:"one",receipt:.init(hash:signed.hash,outcome:.accepted))
        let acknowledged = try await db.pool.read { try Double.fetchOne($0,sql:"SELECT submittedAt FROM nearSendPlans WHERE sendID='one'") }
        XCTAssertNotNil(acknowledged)
        let checking = try await db.pool.read { try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM sendStatusChecks WHERE sendID='one'") }
        XCTAssertEqual(checking,1,"Acknowledgement must retain durable finality tracking")
        let reopened = try await OathDatabase.open(at:folder.appendingPathComponent("wallet.sqlite"))
        let fetched = try await reopened.send("one")
        let stored = try XCTUnwrap(fetched)
        XCTAssertEqual(try JSONDecoder().decode(NearSignedSend.self,from:XCTUnwrap(stored.signedPayload)),signed)
        try await reopened.settleNearSend(sendID:"one",receipt:.init(hash:signed.hash,outcome:.unknown,fee:nil))
        let pending = try await reopened.send("one"); XCTAssertEqual(pending?.state,"broadcast")
        try await draft("two",wallet:2,plan:plan,db:reopened)
        do { try await reopened.queueNearSend(sendID:"two",plan:plan); XCTFail("Unknown broadcast released") } catch { XCTAssertEqual(error as? NearSendError,.busy) }
        try await reopened.settleNearSend(sendID:"one",receipt:.init(hash:signed.hash,outcome:.confirmed,fee:"12",block:101))
        let confirmed = try await reopened.send("one"); XCTAssertEqual(confirmed?.state,"confirmed")
        try await reopened.queueNearSend(sendID:"two",plan:plan)
        let targets = try await reopened.pendingSendBalanceRefreshTargets(); XCTAssertEqual(targets.count,1)
    }
    func testSubmissionObservationRequiresFinalJournalAndWalletScope() async throws {
        let(db,folder,plan)=try await fixture();defer{try? FileManager.default.removeItem(at:folder)}
        try await draft("one",plan:plan,db:db);try await db.queueNearSend(sendID:"one",plan:plan)
        let signed=try NearSendCrypto.sign(plan,privateKey:key);try await db.journalNearSignature(sendID:"one",signed:signed)
        _=try await db.transitionSend("one",from:"signed",to:"broadcast")
        // History can observe a head-node failure before solid finality. The UI
        // must continue to read the send journal, not this tentative row.
        try await db.pool.write{try $0.execute(sql:"UPDATE transactions SET state='failed' WHERE id=?",arguments:["near:"+signed.hash])}
        let pending=try await db.nearSubmission(walletID:"w1",hash:signed.hash);XCTAssertEqual(pending?.state,"broadcast")
        let other=try await db.nearSubmission(walletID:"w2",hash:signed.hash);XCTAssertNil(other)
        try await db.settleNearSend(sendID:"one",receipt:.init(hash:signed.hash,outcome:.confirmed,fee:"12",block:101))
        let final=try await db.nearSubmission(walletID:"w1",hash:signed.hash);XCTAssertEqual(final?.state,"confirmed")
    }
    func testTamperedSignedTransactionAndTestnetPlanRejectedBeforeJournal() async throws {
        let (db,folder,plan) = try await fixture(); defer { try? FileManager.default.removeItem(at:folder) }
        try await draft("one",plan:plan,db:db); try await db.queueNearSend(sendID:"one",plan:plan)
        let signed = try NearSendCrypto.sign(plan,privateKey:key)
        var badBytes = signed.bytes; badBytes[20] ^= 1
        do { try await db.journalNearSignature(sendID:"one",signed:.init(bytes:badBytes,publicKey:signed.publicKey,signature:signed.signature,hash:signed.hash)); XCTFail("Tampered payload") } catch { XCTAssertEqual(error as? NearSendError,.signing) }
        var j=try JSONSerialization.jsonObject(with:JSONEncoder().encode(plan)) as! [String:Any];j["network"]="testnet"
        let testnet=try JSONDecoder().decode(NearSendPlan.self,from:JSONSerialization.data(withJSONObject:j))
        do { try await db.queueNearSend(sendID:"one",plan:testnet); XCTFail("Testnet in production ledger") } catch { XCTAssertEqual(error as? NearSendError,.wrongNetwork) }
    }
    func testFailedExecutionSettlesAsFailureAndNeverSuccess() async throws {
        let (db,folder,plan) = try await fixture(); defer { try? FileManager.default.removeItem(at:folder) }
        try await draft("one",plan:plan,db:db); try await db.queueNearSend(sendID:"one",plan:plan)
        let signed = try NearSendCrypto.sign(plan,privateKey:key)
        try await db.journalNearSignature(sendID:"one",signed:signed)
        try await db.settleNearSend(sendID:"one",receipt:.init(hash:signed.hash,outcome:.failed,fee:"12",block:101))
        let failed = try await db.send("one"); XCTAssertEqual(failed?.state,"failed")
        do { try await db.settleNearSend(sendID:"one",receipt:.init(hash:signed.hash,outcome:.confirmed,fee:"12",block:101)); XCTFail("Conflicting result") } catch { XCTAssertEqual(error as? StoreError,.invalidTransition) }
        let targets = try await db.pendingSendBalanceRefreshTargets(); XCTAssertEqual(targets.count,1)
        do { try await db.settleNearSend(sendID:"one",receipt:.init(hash:signed.hash,outcome:.expired)); XCTFail("Expiry overwrote fee-consuming failure") } catch { XCTAssertEqual(error as? StoreError,.invalidTransition) }
    }
    func testProvenExpiryReleasesSenderWithoutClaimingFeeOrBalanceRefresh() async throws {
        let (db,folder,plan) = try await fixture(); defer { try? FileManager.default.removeItem(at:folder) }
        try await draft("one",plan:plan,db:db); try await db.queueNearSend(sendID:"one",plan:plan)
        let signed = try NearSendCrypto.sign(plan,privateKey:key)
        try await db.journalNearSignature(sendID:"one",signed:signed)
        try await db.settleNearSend(sendID:"one",receipt:.init(hash:signed.hash,outcome:.expired))
        let expired = try await db.send("one"); XCTAssertEqual(expired?.state,"failed"); XCTAssertEqual(expired?.failureCode,"expired")
        let targets = try await db.pendingSendBalanceRefreshTargets(); XCTAssertTrue(targets.isEmpty)
        try await draft("two",wallet:2,plan:plan,db:db); try await db.queueNearSend(sendID:"two",plan:plan)
        do { try await db.settleNearSend(sendID:"one",receipt:.init(hash:signed.hash,outcome:.failed,fee:"12",block:101)); XCTFail("Conflicting terminal evidence") } catch { XCTAssertEqual(error as? StoreError,.invalidTransition) }
    }
}
