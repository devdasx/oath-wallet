import Foundation
import XCTest
import GRDB
@testable import OathAnkr
@testable import OathDatabase

@MainActor final class NearSendBalanceFreshnessTests: XCTestCase {
    private let token = NearToken(reference:"wrap.near",name:"Wrapped NEAR",symbol:"wNEAR",decimals:24,logo:nil)
    private let catalog = NearCatalog(ids:["native":"near","wrap.near":"wrapped-near"])

    private func inventory(owner:String, time:Double, height:Int64, tokenAmount:String? = "900", nativeAmount:String? = "9000000000000000000000000") -> NearInventory {
        .init(owner:owner,block:.init(hash:String(repeating:"1",count:32),height:height,timestamp:time),exists:true,
              liquid:"9000000000000000000000000",locked:"0",storageBytes:123,
              holdings:[.init(reference:"native",token:.native,amount:nativeAmount,indexedAmount:nil,failure:nativeAmount == nil ? "accountRead":nil),
                        .init(reference:token.reference,token:token,amount:tokenAmount,indexedAmount:nil,failure:tokenAmount == nil ? "contractRead":nil)],
              observedAt:Date(timeIntervalSince1970:time),raw:Data("{}".utf8))
    }
    private func fixture(native:Bool = false) async throws -> (OathDatabase,URL,NearSyncTicket,SendRecord) {
        let base = NearSendJournalTests()
        let (db,folder,original) = try await base.fixture()
        let ticket = try await db.beginNearSync(accountID:"a1")
        try await db.commitNearInventory(inventory(owner:original.sender,time:50,height:100,tokenAmount:"1000"),ticket:ticket,catalog:catalog)
        var object = try JSONSerialization.jsonObject(with:JSONEncoder().encode(original)) as! [String:Any]
        if !native {
            object["reference"] = token.reference; object["amount"] = "100"; object["requestedAmount"] = "100"
            object["assetBalance"] = "1000"; object["gas"] = 50_000_000_000_000 as UInt64
            object["fee"] = "20000000000000000000000"
        }
        let plan = try JSONDecoder().decode(NearSendPlan.self,from:JSONSerialization.data(withJSONObject:object))
        try plan.validate()
        try await db.saveDraft(.init(id:"one",walletID:"w1",accountID:"a1",networkID:"near",assetID:"near:"+plan.reference,
            idempotencyKey:"one",recipient:plan.recipient,amountAtomic:plan.amount,state:"draft",createdAt:100,updatedAt:100))
        try await db.queueNearSend(sendID:"one",plan:plan)
        let signed = try NearSendCrypto.sign(plan,privateKey:base.key)
        try await db.journalNearSignature(sendID:"one",signed:signed)
        try await db.settleNearSend(sendID:"one",receipt:.init(hash:signed.hash,outcome:.confirmed,fee:"12",block:200))
        let loadedCursor = try await db.nearHistoryWork(ticket,stream:"transactions")
        let cursor = try XCTUnwrap(loadedCursor)
        let execution = NearExecution(owner:plan.sender,hash:signed.hash,blockHeight:200,timestamp:100,failed:false,fee:"12",raw:Data())
        try await db.commitNearPage(.init(events:[],executions:[execution],next:nil,head:signed.hash,raw:Data()),cursor:cursor,ticket:ticket)
        let stored = try await db.send("one")
        return (db,folder,ticket,try XCTUnwrap(stored))
    }
    func testFailedTokenReadCannotCompletePostSendRefresh() async throws {
        let (db,folder,ticket,send) = try await fixture();defer{try? FileManager.default.removeItem(at:folder)}
        try await db.commitNearInventory(inventory(owner:ticket.account.address,time:150,height:210,tokenAmount:nil),ticket:ticket,catalog:catalog)
        let retained = try await db.balance(accountID:"a1",assetID:"near:wrap.near")
        XCTAssertEqual(retained?.amountAtomic,"1000");XCTAssertEqual(retained?.observedAt,50)
        let current = try await db.nearSendBalanceIsCurrent(send)
        XCTAssertFalse(current,"Failed token refresh must retain its durable refresh work")
    }
    func testNewObservationFromBeforeExecutionBlockIsNotCurrent() async throws {
        let (db,folder,ticket,send) = try await fixture();defer{try? FileManager.default.removeItem(at:folder)}
        try await db.commitNearInventory(inventory(owner:ticket.account.address,time:150,height:150),ticket:ticket,catalog:catalog)
        let current = try await db.nearSendBalanceIsCurrent(send)
        XCTAssertFalse(current,"A fresh wall-clock read of an older block is still stale")
    }
    func testSuccessfulTokenAndFeeBalancesAtExecutionBlockAreCurrent() async throws {
        let (db,folder,ticket,send) = try await fixture();defer{try? FileManager.default.removeItem(at:folder)}
        try await db.commitNearInventory(inventory(owner:ticket.account.address,time:150,height:200),ticket:ticket,catalog:catalog)
        let current = try await db.nearSendBalanceIsCurrent(send);XCTAssertTrue(current)
    }
    func testSuccessfulZeroTokenBalanceCompletesRefresh() async throws {
        let (db,folder,ticket,send) = try await fixture();defer{try? FileManager.default.removeItem(at:folder)}
        try await db.commitNearInventory(inventory(owner:ticket.account.address,time:150,height:210,tokenAmount:"0"),ticket:ticket,catalog:catalog)
        let current = try await db.nearSendBalanceIsCurrent(send);XCTAssertTrue(current)
        let value = try await db.balance(accountID:"a1",assetID:"near:wrap.near");XCTAssertEqual(value?.amountAtomic,"0")
    }
    func testNativeSendRequiresExecutionHeightAndSuccessfulBalance() async throws {
        let (db,folder,ticket,send) = try await fixture(native:true);defer{try? FileManager.default.removeItem(at:folder)}
        try await db.commitNearInventory(inventory(owner:ticket.account.address,time:150,height:150),ticket:ticket,catalog:catalog)
        let old = try await db.nearSendBalanceIsCurrent(send);XCTAssertFalse(old)
        try await db.commitNearInventory(inventory(owner:ticket.account.address,time:160,height:200),ticket:ticket,catalog:catalog)
        let current = try await db.nearSendBalanceIsCurrent(send);XCTAssertTrue(current)
    }
    func testFailedTokenReadRecoversOnlyAfterSuccessfulNewRead() async throws {
        let (db,folder,ticket,send) = try await fixture();defer{try? FileManager.default.removeItem(at:folder)}
        try await db.commitNearInventory(inventory(owner:ticket.account.address,time:150,height:210,tokenAmount:nil),ticket:ticket,catalog:catalog)
        let failed = try await db.nearSendBalanceIsCurrent(send);XCTAssertFalse(failed)
        let reopened = try await OathDatabase.open(at:folder.appendingPathComponent("wallet.sqlite"))
        let newTicket = try await reopened.beginNearSync(accountID:"a1")
        let unchanged = try await reopened.nearSendBalanceIsCurrent(send);XCTAssertFalse(unchanged)
        try await reopened.commitNearInventory(inventory(owner:ticket.account.address,time:160,height:220),ticket:newTicket,catalog:catalog)
        let current = try await reopened.nearSendBalanceIsCurrent(send);XCTAssertTrue(current)
    }
}
