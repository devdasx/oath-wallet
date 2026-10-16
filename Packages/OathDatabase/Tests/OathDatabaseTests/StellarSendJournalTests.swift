import XCTest
import GRDB
@testable import OathAnkr
@testable import OathDatabase

@MainActor final class StellarSendJournalTests: XCTestCase {
    let key = Data(repeating:7,count:32)
    func fixture() async throws -> (OathDatabase,URL,StellarSendPlan) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("StellarSend-"+UUID().uuidString)
        let db = try await OathDatabase.open(at:folder.appendingPathComponent("wallet.sqlite"))
        let owner = try StellarSendCrypto.address(privateKey:key)
        try await db.seed(networks:[.init(id:"stellar",name:"Stellar",family:"account",symbol:"XLM",decimals:7,derivationPath:"m/44'/148'/0'",logo:"stellar",sortOrder:0)],assets:[.init(id:"stellar:native",networkID:"stellar",reference:"native",name:"Stellar",symbol:"XLM",decimals:7)])
        for i in 1...2 { try await db.importWalletIfNeeded(.init(id:"w\(i)",name:"Test",kind:"hd",vaultReference:"test\(i)",createdAt:1),accounts:[.init(id:"a\(i)",walletID:"w\(i)",networkID:"stellar",address:owner,derivationPath:"m/44'/148'/0'")]) }
        let plan = StellarSendPlan(network:.mainnet,sender:owner,recipient:try StellarSendCrypto.address(privateKey:Data(repeating:8,count:32)),reference:"native",
            requestedAmount:"1000000",amount:"1000000",assetBalance:"100000000",nativeBalance:100000000,
            reserve:1000000,fee:12,sequence:42,firstLedger:100,lastLedger:120,maxTime:UInt64(Date.now.timeIntervalSince1970)+120)
        return (db,folder,plan)
    }
    func draft(_ id:String, wallet:Int = 1, plan:StellarSendPlan, db:OathDatabase) async throws {
        try await db.saveDraft(.init(id:id,walletID:"w\(wallet)",accountID:"a\(wallet)",networkID:"stellar",assetID:"stellar:native",idempotencyKey:id,
            recipient:plan.recipient,amountAtomic:String(plan.amount),state:"draft",createdAt:Date.now.timeIntervalSince1970,updatedAt:Date.now.timeIntervalSince1970))
    }
    func testCrossWalletReservationAndCancelledAuthenticationReleasesOnlyUnsigned() async throws {
        let (db,folder,plan) = try await fixture(); defer { try? FileManager.default.removeItem(at:folder) }
        try await draft("one",plan:plan,db:db); try await draft("two",wallet:2,plan:plan,db:db)
        try await db.queueStellarSend(sendID:"one",plan:plan)
        do { try await db.queueStellarSend(sendID:"two",plan:plan); XCTFail("Shared address double reservation") } catch { XCTAssertEqual(error as? StellarSendError,.busy) }
        _ = try await db.transitionSend("one",from:"queued",to:"cancelled")
        try await db.queueStellarSend(sendID:"two",plan:plan)
        let signed = try StellarSendCrypto.sign(plan,privateKey:key)
        try await db.journalStellarSignature(sendID:"two",signed:signed)
        do { _ = try await db.transitionSend("two",from:"signed",to:"cancelled"); XCTFail("Signed send released") } catch { XCTAssertEqual(error as? StoreError,.invalidTransition) }
    }
    func testExactSignedBytesSurviveReopenAndUnknownBroadcastReservesSender() async throws {
        let (db,folder,plan) = try await fixture(); defer { try? FileManager.default.removeItem(at:folder) }
        try await draft("one",plan:plan,db:db); try await db.queueStellarSend(sendID:"one",plan:plan)
        let signed = try StellarSendCrypto.sign(plan,privateKey:key)
        try await db.journalStellarSignature(sendID:"one",signed:signed)
        _ = try await db.transitionSend("one",from:"signed",to:"broadcast")
        try await db.settleStellarSend(sendID:"one",receipt:.init(hash:signed.hash,outcome:.accepted))
        let acknowledged = try await db.pool.read { try Double.fetchOne($0,sql:"SELECT submittedAt FROM stellarSendPlans WHERE sendID='one'") }
        XCTAssertNotNil(acknowledged)
        let checking = try await db.pool.read { try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM sendStatusChecks WHERE sendID='one'") }
        XCTAssertEqual(checking,1,"Acknowledgement must retain durable finality tracking")
        let reopened = try await OathDatabase.open(at:folder.appendingPathComponent("wallet.sqlite"))
        let fetched = try await reopened.send("one")
        let stored = try XCTUnwrap(fetched)
        XCTAssertEqual(try JSONDecoder().decode(StellarSignedSend.self,from:XCTUnwrap(stored.signedPayload)),signed)
        try await reopened.settleStellarSend(sendID:"one",receipt:.init(hash:signed.hash,outcome:.unknown,fee:nil))
        let pending = try await reopened.send("one"); XCTAssertEqual(pending?.state,"broadcast")
        try await draft("two",wallet:2,plan:plan,db:reopened)
        do { try await reopened.queueStellarSend(sendID:"two",plan:plan); XCTFail("Unknown broadcast released") } catch { XCTAssertEqual(error as? StellarSendError,.busy) }
        try await reopened.settleStellarSend(sendID:"one",receipt:.init(hash:signed.hash,outcome:.confirmed,fee:12,ledger:101))
        let confirmed = try await reopened.send("one"); XCTAssertEqual(confirmed?.state,"confirmed")
        try await reopened.queueStellarSend(sendID:"two",plan:plan)
        let targets = try await reopened.pendingSendBalanceRefreshTargets(); XCTAssertEqual(targets.count,1)
    }
    func testTamperedSignedTransactionAndTestnetPlanRejectedBeforeJournal() async throws {
        let (db,folder,plan) = try await fixture(); defer { try? FileManager.default.removeItem(at:folder) }
        try await draft("one",plan:plan,db:db); try await db.queueStellarSend(sendID:"one",plan:plan)
        let signed = try StellarSendCrypto.sign(plan,privateKey:key)
        var badBytes = signed.bytes; badBytes[20] ^= 1
        do { try await db.journalStellarSignature(sendID:"one",signed:.init(bytes:badBytes,publicKey:signed.publicKey,signature:signed.signature,hash:signed.hash)); XCTFail("Tampered payload") } catch { XCTAssertEqual(error as? StellarSendError,.signing) }
        let testnet = StellarSendPlan(network:.testnet,sender:plan.sender,recipient:plan.recipient,reference:"native",
            requestedAmount:plan.amount,amount:plan.amount,assetBalance:plan.assetBalance,nativeBalance:plan.nativeBalance,
            reserve:plan.reserve,fee:plan.fee,sequence:plan.sequence,firstLedger:plan.firstLedger,lastLedger:plan.lastLedger,maxTime:plan.maxTime)
        do { try await db.queueStellarSend(sendID:"one",plan:testnet); XCTFail("Testnet in production ledger") } catch { XCTAssertEqual(error as? StellarSendError,.wrongNetwork) }
    }
    func testFailedExecutionSettlesAsFailureAndNeverSuccess() async throws {
        let (db,folder,plan) = try await fixture(); defer { try? FileManager.default.removeItem(at:folder) }
        try await draft("one",plan:plan,db:db); try await db.queueStellarSend(sendID:"one",plan:plan)
        let signed = try StellarSendCrypto.sign(plan,privateKey:key)
        try await db.journalStellarSignature(sendID:"one",signed:signed)
        try await db.settleStellarSend(sendID:"one",receipt:.init(hash:signed.hash,outcome:.failed,fee:12,ledger:101))
        let failed = try await db.send("one"); XCTAssertEqual(failed?.state,"failed")
        do { try await db.settleStellarSend(sendID:"one",receipt:.init(hash:signed.hash,outcome:.confirmed,fee:12,ledger:101)); XCTFail("Conflicting result") } catch { XCTAssertEqual(error as? StoreError,.invalidTransition) }
        let targets = try await db.pendingSendBalanceRefreshTargets(); XCTAssertEqual(targets.count,1)
        do { try await db.settleStellarSend(sendID:"one",receipt:.init(hash:signed.hash,outcome:.expired)); XCTFail("Expiry overwrote fee-consuming failure") } catch { XCTAssertEqual(error as? StoreError,.invalidTransition) }
    }
    func testProvenExpiryReleasesSenderWithoutClaimingFeeOrBalanceRefresh() async throws {
        let (db,folder,plan) = try await fixture(); defer { try? FileManager.default.removeItem(at:folder) }
        try await draft("one",plan:plan,db:db); try await db.queueStellarSend(sendID:"one",plan:plan)
        let signed = try StellarSendCrypto.sign(plan,privateKey:key)
        try await db.journalStellarSignature(sendID:"one",signed:signed)
        try await db.settleStellarSend(sendID:"one",receipt:.init(hash:signed.hash,outcome:.expired))
        let expired = try await db.send("one"); XCTAssertEqual(expired?.state,"failed"); XCTAssertEqual(expired?.failureCode,"expired")
        let targets = try await db.pendingSendBalanceRefreshTargets(); XCTAssertTrue(targets.isEmpty)
        try await draft("two",wallet:2,plan:plan,db:db); try await db.queueStellarSend(sendID:"two",plan:plan)
        do { try await db.settleStellarSend(sendID:"one",receipt:.init(hash:signed.hash,outcome:.failed,fee:12,ledger:101)); XCTFail("Conflicting terminal evidence") } catch { XCTAssertEqual(error as? StoreError,.invalidTransition) }
    }
}
