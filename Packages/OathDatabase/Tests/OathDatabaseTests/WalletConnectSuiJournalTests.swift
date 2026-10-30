import XCTest
@testable import OathAnkr
@testable import OathDatabase

@MainActor final class WalletConnectSuiJournalTests: XCTestCase {
    let key = Data(repeating:7,count:32)
    func fixture() async throws -> (OathDatabase,URL,SuiSendPlan,WalletConnectSuiReview,SuiSignedSend) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("WCSui-"+UUID().uuidString)
        let db = try await OathDatabase.open(at:folder.appendingPathComponent("wallet.sqlite"))
        let owner = try SuiSendCrypto.address(privateKey:key)
        try await db.seed(networks:[.init(id:"sui",name:"Sui",family:"account",symbol:"SUI",decimals:9,derivationPath:"m/44'/784'/0'/0'/0'",logo:"sui",sortOrder:0)],assets:[.init(id:"sui:native",networkID:"sui",reference:"native",name:"Sui",symbol:"SUI",decimals:9)])
        for i in 1...2 { try await db.importWalletIfNeeded(.init(id:"w\(i)",name:"Test",kind:"hd",vaultReference:"test\(i)",createdAt:1),accounts:[.init(id:"a\(i)",walletID:"w\(i)",networkID:"sui",address:owner,derivationPath:"m/44'/784'/0'/0'/0'")]) }
        let funds = SuiSendFunds(coins:[],addressBalance:1_000_000_000)
        let plan = try SuiSendPlan.make(network:.mainnet,sender:owner,recipient:"0xabc",reference:"native",amount:1_000_000,native:funds,asset:funds,gasPrice:1000,gasBudget:5_000_000,estimatedFee:2_000_000,epoch:1000)
        let params = try JSONEncoder().encode(["address":owner,"transaction":plan.transactionBytes().base64EncodedString()])
        let request = try WalletConnectSuiRequest(method:"sui_signAndExecuteTransaction",chain:"sui:mainnet",account:owner,params:params)
        let review = WalletConnectSuiReview(request:request,changes:[],details:[],gasOwner:owner,gasBudget:5_000_000,estimatedFee:2_000_000,createdAt:.now)
        return (db,folder,plan,review,try request.sign(privateKey:key,review:review).transaction!)
    }
    func draft(db:OathDatabase,plan:SuiSendPlan) async throws {
        try await db.saveDraft(.init(id:"send",walletID:"w2",accountID:"a2",networkID:"sui",assetID:"sui:native",idempotencyKey:"send",recipient:plan.recipient,amountAtomic:String(plan.amount),state:"draft",createdAt:Date.now.timeIntervalSince1970,updatedAt:Date.now.timeIntervalSince1970))
    }
    func testRestartIdempotencyAndUnknownReservation() async throws {
        let (db,folder,plan,review,signed) = try await fixture(); defer { try? FileManager.default.removeItem(at:folder) }
        let stored = try await db.journalWalletConnectSui(id:"r1",walletID:"w1",accountID:"a1",plan:review,signed:signed)
        let duplicate = try await db.journalWalletConnectSui(id:"r1",walletID:"w1",accountID:"a1",plan:review,signed:signed)
        XCTAssertEqual(duplicate.signedData,stored.signedData)
        let reopened = try await OathDatabase.open(at:folder.appendingPathComponent("wallet.sqlite"))
        let fetched = try await reopened.walletConnectSuiSubmission("r1")
        XCTAssertEqual(try XCTUnwrap(fetched).decoded().1,signed)
        try await reopened.settleWalletConnectSui("r1",outcome:.unknown)
        try await draft(db:reopened,plan:plan)
        do { try await reopened.queueSuiSend(sendID:"send",plan:plan); XCTFail("Released pending sender") } catch { XCTAssertEqual(error as? SuiSendError,.busy) }
        do { _ = try await reopened.journalWalletConnectSui(id:"r2",walletID:"w2",accountID:"a2",plan:review,signed:signed); XCTFail("Double reservation") } catch { XCTAssertEqual(error as? SuiSendError,.busy) }
        try await reopened.settleWalletConnectSui("r1",outcome:.confirmed)
        try await reopened.settleWalletConnectSui("r1",outcome:.unknown)
        let settled = try await reopened.walletConnectSuiSubmission("r1"); XCTAssertEqual(settled?.state,"confirmed")
        try await reopened.queueSuiSend(sendID:"send",plan:plan)
    }
    func testOrdinaryTransferBlocksWalletConnect() async throws {
        let (db,folder,plan,review,signed) = try await fixture(); defer { try? FileManager.default.removeItem(at:folder) }
        try await draft(db:db,plan:plan); try await db.queueSuiSend(sendID:"send",plan:plan)
        do { _ = try await db.journalWalletConnectSui(id:"r1",walletID:"w1",accountID:"a1",plan:review,signed:signed); XCTFail("Ordinary send ignored") } catch { XCTAssertEqual(error as? SuiSendError,.busy) }
    }
    func testTamperingAndCrossWalletReplayRejected() async throws {
        let (db,folder,_,review,signed) = try await fixture(); defer { try? FileManager.default.removeItem(at:folder) }
        var signature = signed.signature; signature[1] ^= 1
        do { _ = try await db.journalWalletConnectSui(id:"r1",walletID:"w1",accountID:"a1",plan:review,signed:.init(bytes:signed.bytes,signature:signature,digest:signed.digest)); XCTFail("Forged signature") } catch { XCTAssertEqual(error as? SuiSendError,.signing) }
        _ = try await db.journalWalletConnectSui(id:"r1",walletID:"w1",accountID:"a1",plan:review,signed:signed)
        do { _ = try await db.journalWalletConnectSui(id:"r1",walletID:"w2",accountID:"a2",plan:review,signed:signed); XCTFail("Cross wallet replay") } catch { XCTAssertEqual(error as? SuiSendError,.changed) }
        try await db.settleWalletConnectSui("r1",outcome:.failed)
        try await db.settleWalletConnectSui("r1",outcome:.confirmed)
        let stored = try await db.walletConnectSuiSubmission("r1"); XCTAssertEqual(stored?.state,"failed")
    }
}
