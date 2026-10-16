import XCTest
import GRDB
@testable import OathAnkr
@testable import OathDatabase

@MainActor final class TronSendJournalTests: XCTestCase {
    let key = Data(repeating:7,count:32)
    func fixture() async throws -> (OathDatabase,URL,TronSendPlan) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TronSend-"+UUID().uuidString)
        let db = try await OathDatabase.open(at:folder.appendingPathComponent("wallet.sqlite"))
        let owner = try TronSendCrypto.address(privateKey:key)
        try await db.seed(networks:[.init(id:"tron",name:"Tron",family:"account",symbol:"TRX",decimals:6,derivationPath:"m/44'/195'/0'/0/0",logo:"tron",sortOrder:0)],assets:[.init(id:"tron:native",networkID:"tron",reference:"native",name:"Tron",symbol:"TRX",decimals:6)])
        for i in 1...2 { try await db.importWalletIfNeeded(.init(id:"w\(i)",name:"Test",kind:"hd",vaultReference:"test\(i)",createdAt:1),accounts:[.init(id:"a\(i)",walletID:"w\(i)",networkID:"tron",address:owner,derivationPath:"m/44'/195'/0'/0/0")]) }
        let ms=UInt64(Date.now.timeIntervalSince1970*1000)
        let plan = TronSendPlan(network:.mainnet,sender:owner,recipient:try TronSendCrypto.address(privateKey:Data(repeating:8,count:32)),reference:"native",amount:"1000000",requestedAmount:"1000000",assetBalance:"100000000",decimals:6,nativeBalance:100000000,fee:1000,estimatedFee:100,feeLimit:0,energyPrice:100,bandwidthPrice:1000,blockID:"0000000000000064"+String(repeating:"a",count:48),blockNumber:100,timestamp:ms,expiration:ms+180000)
        return (db,folder,plan)
    }
    func draft(_ id:String, wallet:Int = 1, plan:TronSendPlan, db:OathDatabase) async throws {
        try await db.saveDraft(.init(id:id,walletID:"w\(wallet)",accountID:"a\(wallet)",networkID:"tron",assetID:"tron:native",idempotencyKey:id,
            recipient:plan.recipient,amountAtomic:String(plan.amount),state:"draft",createdAt:Date.now.timeIntervalSince1970,updatedAt:Date.now.timeIntervalSince1970))
    }
    func testCrossWalletReservationAndCancelledAuthenticationReleasesOnlyUnsigned() async throws {
        let (db,folder,plan) = try await fixture(); defer { try? FileManager.default.removeItem(at:folder) }
        try await draft("one",plan:plan,db:db); try await draft("two",wallet:2,plan:plan,db:db)
        try await db.queueTronSend(sendID:"one",plan:plan)
        do { try await db.queueTronSend(sendID:"two",plan:plan); XCTFail("Shared address double reservation") } catch { XCTAssertEqual(error as? TronSendError,.busy) }
        _ = try await db.transitionSend("one",from:"queued",to:"cancelled")
        try await db.queueTronSend(sendID:"two",plan:plan)
        let signed = try TronSendCrypto.sign(plan,privateKey:key)
        try await db.journalTronSignature(sendID:"two",signed:signed)
        do { _ = try await db.transitionSend("two",from:"signed",to:"cancelled"); XCTFail("Signed send released") } catch { XCTAssertEqual(error as? StoreError,.invalidTransition) }
    }
    func testExactSignedBytesSurviveReopenAndUnknownBroadcastReservesSender() async throws {
        let (db,folder,plan) = try await fixture(); defer { try? FileManager.default.removeItem(at:folder) }
        try await draft("one",plan:plan,db:db); try await db.queueTronSend(sendID:"one",plan:plan)
        let signed = try TronSendCrypto.sign(plan,privateKey:key)
        try await db.journalTronSignature(sendID:"one",signed:signed)
        _ = try await db.transitionSend("one",from:"signed",to:"broadcast")
        let reopened = try await OathDatabase.open(at:folder.appendingPathComponent("wallet.sqlite"))
        let fetched = try await reopened.send("one")
        let stored = try XCTUnwrap(fetched)
        XCTAssertEqual(try JSONDecoder().decode(TronSignedSend.self,from:XCTUnwrap(stored.signedPayload)),signed)
        try await reopened.settleTronSend(sendID:"one",receipt:.init(hash:signed.hash,outcome:.unknown,fee:nil))
        let pending = try await reopened.send("one"); XCTAssertEqual(pending?.state,"broadcast")
        try await draft("two",wallet:2,plan:plan,db:reopened)
        do { try await reopened.queueTronSend(sendID:"two",plan:plan); XCTFail("Unknown broadcast released") } catch { XCTAssertEqual(error as? TronSendError,.busy) }
        try await reopened.settleTronSend(sendID:"one",receipt:.init(hash:signed.hash,outcome:.confirmed,fee:12,block:101))
        let confirmed = try await reopened.send("one"); XCTAssertEqual(confirmed?.state,"confirmed")
        try await reopened.queueTronSend(sendID:"two",plan:plan)
        let targets = try await reopened.pendingSendBalanceRefreshTargets(); XCTAssertEqual(targets.count,1)
    }
    func testSubmissionObservationRequiresFinalJournalAndWalletScope() async throws {
        let(db,folder,plan)=try await fixture();defer{try? FileManager.default.removeItem(at:folder)}
        try await draft("one",plan:plan,db:db);try await db.queueTronSend(sendID:"one",plan:plan)
        let signed=try TronSendCrypto.sign(plan,privateKey:key);try await db.journalTronSignature(sendID:"one",signed:signed)
        _=try await db.transitionSend("one",from:"signed",to:"broadcast")
        // History can observe a head-node failure before solid finality. The UI
        // must continue to read the send journal, not this tentative row.
        try await db.pool.write{try $0.execute(sql:"UPDATE transactions SET state='failed' WHERE id=?",arguments:["tron:"+signed.hash])}
        let pending=try await db.tronSubmission(walletID:"w1",hash:signed.hash);XCTAssertEqual(pending?.state,"broadcast")
        XCTAssertEqual(pending?.accepted,false)
        let other=try await db.tronSubmission(walletID:"w2",hash:signed.hash);XCTAssertNil(other)
        try await db.settleTronSend(sendID:"one",receipt:.init(hash:signed.hash,outcome:.confirmed,fee:12,block:101))
        let final=try await db.tronSubmission(walletID:"w1",hash:signed.hash);XCTAssertEqual(final?.state,"confirmed")
        XCTAssertEqual(final?.accepted,true)
    }
    func testAcknowledgedSubmissionSurvivesReopenButRemainsPendingAndReserved() async throws {
        let(db,folder,plan)=try await fixture();defer{try? FileManager.default.removeItem(at:folder)}
        try await draft("one",plan:plan,db:db);try await db.queueTronSend(sendID:"one",plan:plan)
        let signed=try TronSendCrypto.sign(plan,privateKey:key);try await db.journalTronSignature(sendID:"one",signed:signed)
        _=try await db.transitionSend("one",from:"signed",to:"broadcast")
        let accepted=TronSendReceipt(hash:signed.hash,outcome:.submitted)
        try await db.settleTronSend(sendID:"one",receipt:accepted)
        try await db.settleTronSend(sendID:"one",receipt:accepted)
        let reopened=try await OathDatabase.open(at:folder.appendingPathComponent("wallet.sqlite"))
        try await reopened.settleTronSend(sendID:"one",receipt:.init(hash:signed.hash,outcome:.unknown))
        let observed=try await reopened.tronSubmission(walletID:"w1",hash:signed.hash)
        XCTAssertEqual(observed?.state,"broadcast");XCTAssertEqual(observed?.accepted,true)
        let other=try await reopened.tronSubmission(walletID:"w2",hash:signed.hash);XCTAssertNil(other)
        let state=try await reopened.pool.read{try String.fetchOne($0,sql:"SELECT state FROM transactions WHERE id=?",arguments:["tron:"+signed.hash])}
        XCTAssertEqual(state,"pending")
        try await draft("two",wallet:2,plan:plan,db:reopened)
        do{try await reopened.queueTronSend(sendID:"two",plan:plan);XCTFail("Accepted broadcast released reservation")}catch{XCTAssertEqual(error as? TronSendError,.busy)}
        try await reopened.settleTronSend(sendID:"one",receipt:.init(hash:signed.hash,outcome:.confirmed,fee:12,block:101))
        // An out-of-order acknowledgement must not regress confirmation.
        try await reopened.settleTronSend(sendID:"one",receipt:accepted)
        let final=try await reopened.tronSubmission(walletID:"w1",hash:signed.hash)
        XCTAssertEqual(final?.state,"confirmed");XCTAssertEqual(final?.accepted,true)
        try await reopened.queueTronSend(sendID:"two",plan:plan)
    }
    func testAcknowledgementCannotHideLaterFailureOrAcceptAnotherTransaction() async throws {
        let(db,folder,plan)=try await fixture();defer{try? FileManager.default.removeItem(at:folder)}
        try await draft("one",plan:plan,db:db);try await db.queueTronSend(sendID:"one",plan:plan)
        let signed=try TronSendCrypto.sign(plan,privateKey:key);try await db.journalTronSignature(sendID:"one",signed:signed)
        _=try await db.transitionSend("one",from:"signed",to:"broadcast")
        do{try await db.settleTronSend(sendID:"one",receipt:.init(hash:String(repeating:"a",count:64),outcome:.submitted));XCTFail("Wrong hash accepted")}catch{XCTAssertEqual(error as? StoreError,.invalidTransition)}
        do{try await db.settleTronSend(sendID:"one",receipt:.init(hash:signed.hash,outcome:.submitted,fee:1,block:101));XCTFail("Acknowledgement claimed execution")}catch{XCTAssertEqual(error as? TronSendError,.changed)}
        let before=try await db.tronSubmission(walletID:"w1",hash:signed.hash);XCTAssertEqual(before?.accepted,false)
        try await db.settleTronSend(sendID:"one",receipt:.init(hash:signed.hash,outcome:.submitted))
        try await db.settleTronSend(sendID:"one",receipt:.init(hash:signed.hash,outcome:.failed,fee:12,block:101))
        try await db.settleTronSend(sendID:"one",receipt:.init(hash:signed.hash,outcome:.submitted))
        let final=try await db.tronSubmission(walletID:"w1",hash:signed.hash)
        XCTAssertEqual(final?.state,"failed");XCTAssertEqual(final?.accepted,false)
    }
    func testMigrationPreservesOldSignedSendWithoutInventingAcceptance() async throws {
        let(db,folder,plan)=try await fixture();defer{try? FileManager.default.removeItem(at:folder)}
        try await draft("one",plan:plan,db:db);try await db.queueTronSend(sendID:"one",plan:plan)
        let signed=try TronSendCrypto.sign(plan,privateKey:key);try await db.journalTronSignature(sendID:"one",signed:signed)
        _=try await db.transitionSend("one",from:"signed",to:"broadcast")
        // Recreate the previous shipped table shape with an in-flight send.
        try await db.pool.write {
            try $0.execute(sql:"ALTER TABLE tronSendPlans DROP COLUMN submittedAt")
            try $0.execute(sql:"DELETE FROM grdb_migrations WHERE identifier='v39_tron_submission_acknowledgement'")
        }
        let migrated=try await OathDatabase.open(at:folder.appendingPathComponent("wallet.sqlite"))
        let observed=try await migrated.tronSubmission(walletID:"w1",hash:signed.hash)
        XCTAssertEqual(observed?.state,"broadcast");XCTAssertEqual(observed?.accepted,false)
        let stored=try await migrated.send("one")
        XCTAssertEqual(try JSONDecoder().decode(TronSignedSend.self,from:XCTUnwrap(stored?.signedPayload)),signed)
        let storedPlan=try await migrated.tronSendPlan(sendID:"one");XCTAssertEqual(storedPlan,plan)
        try await migrated.settleTronSend(sendID:"one",receipt:.init(hash:signed.hash,outcome:.submitted))
        let accepted=try await migrated.tronSubmission(walletID:"w1",hash:signed.hash);XCTAssertEqual(accepted?.accepted,true)
    }
    func testTamperedSignedTransactionAndTestnetPlanRejectedBeforeJournal() async throws {
        let (db,folder,plan) = try await fixture(); defer { try? FileManager.default.removeItem(at:folder) }
        try await draft("one",plan:plan,db:db); try await db.queueTronSend(sendID:"one",plan:plan)
        let signed = try TronSendCrypto.sign(plan,privateKey:key)
        var badBytes = signed.bytes; badBytes[20] ^= 1
        do { try await db.journalTronSignature(sendID:"one",signed:.init(bytes:badBytes,signature:signed.signature,hash:signed.hash)); XCTFail("Tampered payload") } catch { XCTAssertEqual(error as? TronSendError,.signing) }
        let testnet = TronSendPlan(network:.nile,sender:plan.sender,recipient:plan.recipient,reference:plan.reference,amount:plan.amount,requestedAmount:plan.requestedAmount,assetBalance:plan.assetBalance,decimals:plan.decimals,nativeBalance:plan.nativeBalance,fee:plan.fee,estimatedFee:plan.estimatedFee,feeLimit:0,energyPrice:100,bandwidthPrice:1000,blockID:plan.blockID,blockNumber:plan.blockNumber,timestamp:plan.timestamp,expiration:plan.expiration)
        do { try await db.queueTronSend(sendID:"one",plan:testnet); XCTFail("Testnet in production ledger") } catch { XCTAssertEqual(error as? TronSendError,.wrongNetwork) }
    }
    func testFailedExecutionSettlesAsFailureAndNeverSuccess() async throws {
        let (db,folder,plan) = try await fixture(); defer { try? FileManager.default.removeItem(at:folder) }
        try await draft("one",plan:plan,db:db); try await db.queueTronSend(sendID:"one",plan:plan)
        let signed = try TronSendCrypto.sign(plan,privateKey:key)
        try await db.journalTronSignature(sendID:"one",signed:signed)
        try await db.settleTronSend(sendID:"one",receipt:.init(hash:signed.hash,outcome:.failed,fee:12,block:101))
        let failed = try await db.send("one"); XCTAssertEqual(failed?.state,"failed")
        do { try await db.settleTronSend(sendID:"one",receipt:.init(hash:signed.hash,outcome:.confirmed,fee:12,block:101)); XCTFail("Conflicting result") } catch { XCTAssertEqual(error as? StoreError,.invalidTransition) }
        let targets = try await db.pendingSendBalanceRefreshTargets(); XCTAssertEqual(targets.count,1)
        do { try await db.settleTronSend(sendID:"one",receipt:.init(hash:signed.hash,outcome:.expired)); XCTFail("Expiry overwrote fee-consuming failure") } catch { XCTAssertEqual(error as? StoreError,.invalidTransition) }
    }
    func testProvenExpiryReleasesSenderWithoutClaimingFeeOrBalanceRefresh() async throws {
        let (db,folder,plan) = try await fixture(); defer { try? FileManager.default.removeItem(at:folder) }
        try await draft("one",plan:plan,db:db); try await db.queueTronSend(sendID:"one",plan:plan)
        let signed = try TronSendCrypto.sign(plan,privateKey:key)
        try await db.journalTronSignature(sendID:"one",signed:signed)
        try await db.settleTronSend(sendID:"one",receipt:.init(hash:signed.hash,outcome:.expired))
        let expired = try await db.send("one"); XCTAssertEqual(expired?.state,"failed"); XCTAssertEqual(expired?.failureCode,"expired")
        let targets = try await db.pendingSendBalanceRefreshTargets(); XCTAssertTrue(targets.isEmpty)
        try await draft("two",wallet:2,plan:plan,db:db); try await db.queueTronSend(sendID:"two",plan:plan)
        do { try await db.settleTronSend(sendID:"one",receipt:.init(hash:signed.hash,outcome:.failed,fee:12,block:101)); XCTFail("Conflicting terminal evidence") } catch { XCTAssertEqual(error as? StoreError,.invalidTransition) }
    }
}
