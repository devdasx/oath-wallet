import Foundation
import XCTest
import GRDB
@testable import OathDatabase
@testable import OathAnkr

@MainActor final class NearLedgerTests:XCTestCase {
    let owner = "root.near", ref = "wrap.near"
    var token:NearToken { .init(reference:ref,name:"Wrapped NEAR",symbol:"wNEAR",decimals:24,logo:nil) }
    var catalog:NearCatalog { .init(ids:[ref:"wrapped-near","native":"near"]) }
    func fixture() async throws -> (OathDatabase,URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NearLedger-"+UUID().uuidString)
        let db = try await OathDatabase.open(at:folder.appendingPathComponent("wallet.sqlite"))
        try await db.seed(networks:[.init(id:"near",name:"NEAR",family:"account",symbol:"NEAR",decimals:24,derivationPath:"m/44'/397'/0'",logo:"near",sortOrder:0)],assets:[.init(id:"near:native",networkID:"near",reference:"native",name:"NEAR Protocol",symbol:"NEAR",decimals:24)])
        for i in 1...2 { try await db.importWalletIfNeeded(.init(id:"w\(i)",name:"Test",kind:"hd",vaultReference:"test\(i)",createdAt:1),accounts:[.init(id:"a\(i)",walletID:"w\(i)",networkID:"near",address:owner,derivationPath:"m/44'/397'/0'")]) }
        try await db.saveMarketCache(.init(key:"near.catalog",source:"fixture verified catalog",payload:JSONEncoder().encode(catalog),fetchedAt:1))
        return (db,folder)
    }
    func inventory(time:Double = 100, metadata:Bool = true, amount:String? = "123456789012345678901234567890") -> NearInventory {
        .init(owner:owner,block:.init(hash:"block",height:Int64(time),timestamp:time),exists:true,liquid:"9007199254740993",locked:"0",storageBytes:123,
              holdings:[.init(reference:"native",token:.native,amount:"9007199254740993",indexedAmount:nil,failure:nil),.init(reference:ref,token:metadata ? token:nil,amount:amount,indexedAmount:nil,failure:amount == nil ? "contractRead":nil)],observedAt:Date(timeIntervalSince1970:time),raw:Data("{}".utf8))
    }
    func event(_ id:String, hash:String = "tx", ref:String? = "wrap.near", metadata:Bool = true, amount:String = "12345678901234567890") -> NearEvent {
        .init(id:id,owner:owner,hash:hash,receipt:"receipt",reference:ref,token:metadata ? (ref == "native" ? .native:token):nil,amount:amount,counterparty:"other.near",blockHeight:100,timestamp:100,raw:Data("{}".utf8))
    }
    func page(_ ids:[String], next:String? = nil, metadata:Bool = true) -> NearHistoryPage {
        let rows = ids.map{event($0,metadata:metadata)}
        return .init(events:rows,executions:[],next:next,head:ids.first,raw:Data("{}".utf8))
    }
    func testExactBalancesOfflineAndWhitelistAccountIsolation() async throws {
        let (db,folder) = try await fixture(); defer { try? FileManager.default.removeItem(at:folder) }
        let ticket = try await db.beginNearSync(accountID:"a1")
        try await db.commitNearInventory(inventory(),ticket:ticket,catalog:catalog)
        try await db.savePrices([.init(assetID:"near:native",currency:"USD",value:"5.75",observedAt:100,source:"test")])
        let value = try await db.snapshot(walletID:"w1",currency:"USD")
        XCTAssertEqual(value.holdings.count,2); XCTAssertEqual(value.holdings.first{$0.reference == ref}?.amountAtomic,"123456789012345678901234567890")
        let other = try await db.snapshot(walletID:"w2",currency:"USD"); XCTAssertNil(other.holdings.first?.amountAtomic)
        let reopened = try await OathDatabase.open(at:folder.appendingPathComponent("wallet.sqlite"))
        let offline = try await reopened.snapshot(walletID:"w1",currency:"USD"); XCTAssertEqual(offline.holdings,value.holdings)
        try await db.commitNearInventory(inventory(time:200),ticket:ticket,catalog:.empty)
        let hidden = try await db.snapshot(walletID:"w1",currency:"USD"); XCTAssertEqual(hidden.holdings.count,1)
    }
    func testContractFailureKeepsBalanceTimestampAndRealZeroClearsIt() async throws {
        let (db,folder) = try await fixture(); defer { try? FileManager.default.removeItem(at:folder) }
        let ticket = try await db.beginNearSync(accountID:"a1")
        try await db.commitNearInventory(inventory(),ticket:ticket,catalog:catalog)
        try await db.commitNearInventory(inventory(time:200,amount:nil),ticket:ticket,catalog:catalog)
        var current = try await db.balance(accountID:"a1",assetID:"near:"+ref)
        XCTAssertEqual(current?.amountAtomic,"123456789012345678901234567890"); XCTAssertEqual(current?.observedAt,100)
        try await db.commitNearInventory(inventory(time:300,amount:"0"),ticket:ticket,catalog:catalog)
        current = try await db.balance(accountID:"a1",assetID:"near:"+ref); XCTAssertEqual(current?.amountAtomic,"0"); XCTAssertEqual(current?.observedAt,300)
        let known = try await db.nearKnownReferences(accountID:"a1"); XCTAssertTrue(known.contains(ref))
    }
    func testUnknownMetadataRetainsUnitsAndReprojectsEvents() async throws {
        let (db,folder) = try await fixture(); defer { try? FileManager.default.removeItem(at:folder) }
        let ticket = try await db.beginNearSync(accountID:"a1")
        try await db.commitNearInventory(inventory(metadata:false),ticket:ticket,catalog:catalog)
        let raw = try await db.nearInventory(accountID:"a1"); XCTAssertEqual(raw?.holdings.last?.amount,"123456789012345678901234567890")
        var cursor = try await db.nearHistoryWork(ticket,stream:"transfers")!
        try await db.commitNearPage(page(["100:1"],metadata:false),cursor:cursor,ticket:ticket)
        var history = try await db.assetHistory(walletID:"w1",accountID:"a1",assetID:"near:"+ref); XCTAssertTrue(history.isEmpty)
        try await db.commitNearInventory(inventory(time:200),ticket:ticket,catalog:catalog)
        history = try await db.assetHistory(walletID:"w1",accountID:"a1",assetID:"near:"+ref); XCTAssertEqual(history.count,1)
        // Execution arrival before/after native effects yields one native row.
        cursor = try await db.nearHistoryWork(ticket,stream:"transactions")!
        let execution = NearExecution(owner:owner,hash:"tx",blockHeight:100,timestamp:100,failed:false,fee:"123",raw:Data())
        try await db.commitNearPage(.init(events:[],executions:[execution],next:nil,head:"tx",raw:Data()),cursor:cursor,ticket:ticket)
        let nextTicket = try await db.beginNearSync(accountID:"a1")
        cursor = try await db.nearHistoryWork(nextTicket,stream:"transfers")!
        let native = event("101:2",ref:"native",amount:"-9007199254740993")
        try await db.commitNearPage(.init(events:[native],executions:[],next:nil,head:native.id,raw:Data()),cursor:cursor,ticket:nextTicket)
        history = try await db.assetHistory(walletID:"w1",accountID:"a1",assetID:"near:native"); XCTAssertEqual(history.count,1)
    }
    func testResumableHistorySameBlockTransfersAreNotLost() async throws {
        let (db,folder) = try await fixture(); defer { try? FileManager.default.removeItem(at:folder) }
        var ticket = try await db.beginNearSync(accountID:"a1")
        var cursor = try await db.nearHistoryWork(ticket,stream:"transfers")!
        try await db.commitNearPage(page(["100:9","100:8"],next:"older"),cursor:cursor,ticket:ticket)
        cursor = try await db.nearHistoryWork(ticket,stream:"transfers")!; XCTAssertEqual(cursor.lane,"backfill"); XCTAssertEqual(cursor.beforeCursor,"older")
        ticket = try await db.beginNearSync(accountID:"a1")
        cursor = try await db.nearHistoryWork(ticket,stream:"transfers")!; XCTAssertEqual(cursor.lane,"recent")
        try await db.commitNearPage(page(["101:1","100:9"],next:"recentOlder"),cursor:cursor,ticket:ticket)
        cursor = try await db.nearHistoryWork(ticket,stream:"transfers")!; XCTAssertEqual(cursor.beforeCursor,"older")
        try await db.commitNearPage(page(["100:7","99:1"]),cursor:cursor,ticket:ticket)
        let work = try await db.nearHistoryWork(ticket,stream:"transfers"); XCTAssertNil(work)
        let count = try await db.pool.read{try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM nearEvents")!}; XCTAssertEqual(count,5)
        let history = try await db.assetHistory(walletID:"w1",accountID:"a1",assetID:"near:"+ref); XCTAssertEqual(history.count,5)
    }
    func testStaleWritesResetAndMarketRetention() async throws {
        let (db,folder) = try await fixture(); defer { try? FileManager.default.removeItem(at:folder) }
        let old = try await db.beginNearSync(accountID:"a1")
        try await db.commitNearInventory(inventory(),ticket:old,catalog:catalog)
        let current = try await db.beginNearSync(accountID:"a1")
        do { try await db.commitNearInventory(inventory(time:200),ticket:old,catalog:catalog); XCTFail() } catch { XCTAssertEqual(error as? StoreError,.staleSync) }
        do { try await db.commitNearInventory(inventory(time:50),ticket:current,catalog:catalog); XCTFail() } catch { XCTAssertEqual(error as? StoreError,.staleSync) }
        let reset = try await db.beginWalletReset()
        do { try await db.commitNearInventory(inventory(time:300),ticket:current,catalog:catalog); XCTFail() } catch {}
        try await db.eraseWalletData(resetID:reset); try await db.finishWalletReset(resetID:reset)
        let cache = try await db.marketCache(key:"near.token."+ref); XCTAssertNotNil(cache)
        let count = try await db.pool.read{try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM nearHoldings")!}; XCTAssertEqual(count,0)
    }
    func testLiveProductionSyncAndOfflineReopen() async throws {
        guard let key = ProcessInfo.processInfo.environment["OATH_LIVE_NEAR_DATABASE_KEY"] else { throw XCTSkip("Opt-in production sync mainnet test") }
        let (db,folder) = try await fixture(); defer { try? FileManager.default.removeItem(at:folder) }
        try await db.pool.write{try $0.execute(sql:"UPDATE accounts SET address='here.tg' WHERE id='a1'")}
        let sync = try NearSynchronizer(database:db,apiKey:key)
        do {
            try await sync.refresh(accountID:"a1")
            let deadline = Date().addingTimeInterval(30)
            var events = 0, transactions = 0
            repeat {
                (events,transactions) = try await db.pool.read { db in
                    (try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM nearEvents WHERE accountID='a1'")!,try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM nearTransactions WHERE accountID='a1'")!)
                }
                if events > 0 && transactions > 0 { break }; try await Task.sleep(for:.milliseconds(100))
            } while Date() < deadline
            await sync.cancel(); XCTAssertGreaterThan(events,0); XCTAssertGreaterThan(transactions,0)
            let value = try await db.snapshot(walletID:"w1",currency:"USD")
            XCTAssertGreaterThan(value.holdings.count,1); XCTAssertNotNil(value.holdings.first{$0.reference == "native"}?.usdPrice)
            let history = try await db.assetHistory(walletID:"w1",accountID:"a1",assetID:"near:native"); XCTAssertFalse(history.isEmpty)
            let reopened = try await OathDatabase.open(at:folder.appendingPathComponent("wallet.sqlite"))
            let offline = try await reopened.snapshot(walletID:"w1",currency:"USD"); XCTAssertEqual(offline.holdings,value.holdings)
            try await assertActivityDetails(db, walletID: "w1")
            print("NEAR_LIVE_DATABASE visibleHoldings=\(value.holdings.count) events=\(events) executions=\(transactions) offlineReopenMatched=true")
        } catch { await sync.cancel(); throw error }
    }
}
