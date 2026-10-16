import XCTest
import GRDB
@testable import OathAnkr
@testable import OathDatabase

@MainActor final class SuiSendJournalTests: XCTestCase {
    let key = Data(repeating:7,count:32)
    func fixture() async throws -> (OathDatabase,URL,SuiSendPlan) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SuiSend-"+UUID().uuidString)
        let db = try await OathDatabase.open(at:folder.appendingPathComponent("wallet.sqlite"))
        let owner = try SuiSendCrypto.address(privateKey:key)
        try await db.seed(networks:[.init(id:"sui",name:"Sui",family:"account",symbol:"SUI",decimals:9,derivationPath:"m/44'/784'/0'/0'/0'",logo:"sui",sortOrder:0)],assets:[.init(id:"sui:native",networkID:"sui",reference:"native",name:"Sui",symbol:"SUI",decimals:9)])
        for i in 1...2 { try await db.importWalletIfNeeded(.init(id:"w\(i)",name:"Test",kind:"hd",vaultReference:"test\(i)",createdAt:1),accounts:[.init(id:"a\(i)",walletID:"w\(i)",networkID:"sui",address:owner,derivationPath:"m/44'/784'/0'/0'/0'")]) }
        let funds = SuiSendFunds(coins:[],addressBalance:1_000_000_000)
        let plan = try SuiSendPlan.make(network:.mainnet,sender:owner,recipient:"0xabc",reference:"native",amount:1_000_000,
            native:funds,asset:funds,gasPrice:1000,gasBudget:5_000_000,estimatedFee:2_000_000,epoch:1000)
        return (db,folder,plan)
    }
    func draft(_ id:String, wallet:Int = 1, plan:SuiSendPlan, db:OathDatabase) async throws {
        try await db.saveDraft(.init(id:id,walletID:"w\(wallet)",accountID:"a\(wallet)",networkID:"sui",assetID:"sui:native",idempotencyKey:id,
            recipient:plan.recipient,amountAtomic:String(plan.amount),state:"draft",createdAt:Date.now.timeIntervalSince1970,updatedAt:Date.now.timeIntervalSince1970))
    }
    func testCrossWalletReservationAndCancelledAuthenticationReleasesOnlyUnsigned() async throws {
        let (db,folder,plan) = try await fixture(); defer { try? FileManager.default.removeItem(at:folder) }
        try await draft("one",plan:plan,db:db); try await draft("two",wallet:2,plan:plan,db:db)
        try await db.queueSuiSend(sendID:"one",plan:plan)
        do { try await db.queueSuiSend(sendID:"two",plan:plan); XCTFail("Shared address double reservation") } catch { XCTAssertEqual(error as? SuiSendError,.busy) }
        _ = try await db.transitionSend("one",from:"queued",to:"cancelled")
        try await db.queueSuiSend(sendID:"two",plan:plan)
        let signed = try SuiSendCrypto.sign(plan,privateKey:key)
        try await db.journalSuiSignature(sendID:"two",signed:signed)
        do { _ = try await db.transitionSend("two",from:"signed",to:"cancelled"); XCTFail("Signed send released") } catch { XCTAssertEqual(error as? StoreError,.invalidTransition) }
    }
    func testExactSignedBytesSurviveReopenAndUnknownBroadcastReservesSender() async throws {
        let (db,folder,plan) = try await fixture(); defer { try? FileManager.default.removeItem(at:folder) }
        try await draft("one",plan:plan,db:db); try await db.queueSuiSend(sendID:"one",plan:plan)
        let signed = try SuiSendCrypto.sign(plan,privateKey:key)
        try await db.journalSuiSignature(sendID:"one",signed:signed)
        _ = try await db.transitionSend("one",from:"signed",to:"broadcast")
        let reopened = try await OathDatabase.open(at:folder.appendingPathComponent("wallet.sqlite"))
        let fetched = try await reopened.send("one")
        let stored = try XCTUnwrap(fetched)
        XCTAssertEqual(try JSONDecoder().decode(SuiSignedSend.self,from:XCTUnwrap(stored.signedPayload)),signed)
        try await reopened.settleSuiSend(sendID:"one",receipt:.init(digest:signed.digest,outcome:.unknown,fee:nil))
        let pending = try await reopened.send("one"); XCTAssertEqual(pending?.state,"broadcast")
        try await draft("two",wallet:2,plan:plan,db:reopened)
        do { try await reopened.queueSuiSend(sendID:"two",plan:plan); XCTFail("Unknown broadcast released") } catch { XCTAssertEqual(error as? SuiSendError,.busy) }
        try await reopened.settleSuiSend(sendID:"one",receipt:.init(digest:signed.digest,outcome:.confirmed,fee:2_500_000))
        let confirmed = try await reopened.send("one"); XCTAssertEqual(confirmed?.state,"confirmed")
        try await reopened.queueSuiSend(sendID:"two",plan:plan)
        let targets = try await reopened.pendingSendBalanceRefreshTargets(); XCTAssertEqual(targets.count,1)
    }
    func testTamperedSignedTransactionAndTestnetPlanRejectedBeforeJournal() async throws {
        let (db,folder,plan) = try await fixture(); defer { try? FileManager.default.removeItem(at:folder) }
        try await draft("one",plan:plan,db:db); try await db.queueSuiSend(sendID:"one",plan:plan)
        let signed = try SuiSendCrypto.sign(plan,privateKey:key)
        var badBytes = signed.bytes; badBytes[20] ^= 1
        do { try await db.journalSuiSignature(sendID:"one",signed:.init(bytes:badBytes,signature:signed.signature,digest:signed.digest)); XCTFail("Tampered payload") } catch { XCTAssertEqual(error as? SuiSendError,.changed) }
        let funds = SuiSendFunds(coins:[],addressBalance:1_000_000_000)
        let testnet = try SuiSendPlan.make(network:.testnet,sender:plan.sender,recipient:plan.recipient,reference:"native",amount:plan.amount,native:funds,asset:funds,gasPrice:1000,gasBudget:5_000_000,epoch:1000)
        do { try await db.queueSuiSend(sendID:"one",plan:testnet); XCTFail("Testnet in production ledger") } catch { XCTAssertEqual(error as? SuiSendError,.wrongNetwork) }
    }
    func testFailedExecutionSettlesAsFailureAndNeverSuccess() async throws {
        let (db,folder,plan) = try await fixture(); defer { try? FileManager.default.removeItem(at:folder) }
        try await draft("one",plan:plan,db:db); try await db.queueSuiSend(sendID:"one",plan:plan)
        let signed = try SuiSendCrypto.sign(plan,privateKey:key)
        try await db.journalSuiSignature(sendID:"one",signed:signed)
        try await db.settleSuiSend(sendID:"one",receipt:.init(digest:signed.digest,outcome:.failed,fee:1_000_000))
        let failed = try await db.send("one"); XCTAssertEqual(failed?.state,"failed")
        do { try await db.settleSuiSend(sendID:"one",receipt:.init(digest:signed.digest,outcome:.confirmed,fee:1_000_000)); XCTFail("Conflicting result") } catch { XCTAssertEqual(error as? StoreError,.invalidTransition) }
        let targets = try await db.pendingSendBalanceRefreshTargets(); XCTAssertEqual(targets.count,1)
    }
}
