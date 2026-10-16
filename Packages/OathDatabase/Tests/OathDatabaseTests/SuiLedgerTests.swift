import Foundation
import XCTest
import GRDB
@testable import OathDatabase
@testable import OathAnkr

@MainActor final class SuiLedgerTests:XCTestCase {
    let owner = try! SuiIdentity.address("0x1234")
    let ref = "0xab::coin::COIN"
    var token:SuiToken { .init(reference:ref,name:"Example",symbol:"EX",decimals:6,logo:nil,description:"Example metadata") }
    var catalog:SuiCatalog { .init(ids:[ref:"example","native":"sui"]) }
    func fixture() async throws -> (OathDatabase,URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SuiLedger-"+UUID().uuidString)
        let db = try await OathDatabase.open(at:folder.appendingPathComponent("wallet.sqlite"))
        try await db.seed(networks:[.init(id:"sui",name:"Sui",family:"account",symbol:"SUI",decimals:9,derivationPath:"m/44'/784'/0'/0'/0'",logo:"sui",sortOrder:0)],assets:[.init(id:"sui:native",networkID:"sui",reference:"native",name:"Sui",symbol:"SUI",decimals:9)])
        for i in 1...2 { try await db.importWalletIfNeeded(.init(id:"w\(i)",name:"Test",kind:"hd",vaultReference:"test\(i)",createdAt:1),accounts:[.init(id:"a\(i)",walletID:"w\(i)",networkID:"sui",address:owner,derivationPath:"m/44'/784'/0'/0'/0'")]) }
        try await db.saveMarketCache(.init(key:"sui.catalog",source:"fixture verified catalog",payload:JSONEncoder().encode(catalog),fetchedAt:1))
        return (db,folder)
    }
    func inventory(time:Double = 100, metadata:Bool = true, empty:Bool = false) -> SuiInventory {
        .init(owner:owner,holdings:[.init(reference:"native",token:.native,amount:"9007199254740993",coinBalance:"0",addressBalance:"9007199254740993")]+(empty ? []:[.init(reference:ref,token:metadata ? token:nil,amount:"12345678901234567890",coinBalance:"12345678901234567890",addressBalance:"0")]),checkpoint:Int64(time),observedAt:Date(timeIntervalSince1970:time),raw:Data("{}".utf8))
    }
    func tx(_ cp:Int64, hash:String? = nil, metadata:Bool = true) -> SuiTransaction {
        .init(hash:hash ?? "tx\(cp)",checkpoint:cp,timestamp:Double(cp),failed:false,fee:nil,netGas:"5",sender:owner,owner:owner,movements:[.init(reference:ref,token:metadata ? token:nil,direction:"incoming",amount:"1234")],raw:Data("{}".utf8))
    }
    func page(_ cps:[Int64], next:String? = nil, metadata:Bool = true) -> SuiHistoryPage {
        let txs = cps.map{tx($0,metadata:metadata)}
        return .init(transactions:txs,next:next,head:txs.first?.hash,raw:Data("{}".utf8))
    }
    func testExactBalancesOfflinePersistenceFilteringAndAccountIsolation() async throws {
        let (db,folder) = try await fixture(); defer { try? FileManager.default.removeItem(at:folder) }
        let ticket = try await db.beginSuiSync(accountID:"a1")
        try await db.commitSuiInventory(inventory(),ticket:ticket,catalog:catalog)
        try await db.savePrices([.init(assetID:"sui:native",currency:"USD",value:"1.12",observedAt:100,source:"test")])
        let value = try await db.snapshot(walletID:"w1",currency:"USD")
        XCTAssertEqual(value.holdings.count,2)
        XCTAssertEqual(value.holdings.first{$0.reference == ref}?.amountAtomic,"12345678901234567890")
        XCTAssertEqual(value.holdings.first{$0.reference == "native"}?.amountAtomic,"9007199254740993")
        let other = try await db.snapshot(walletID:"w2",currency:"USD"); XCTAssertNil(other.holdings.first?.amountAtomic)
        let reopened = try await OathDatabase.open(at:folder.appendingPathComponent("wallet.sqlite"))
        let offline = try await reopened.snapshot(walletID:"w1",currency:"USD"); XCTAssertEqual(offline.holdings,value.holdings)
        try await db.commitSuiInventory(inventory(time:200),ticket:ticket,catalog:.empty)
        let hidden = try await db.snapshot(walletID:"w1",currency:"USD"); XCTAssertEqual(hidden.holdings.count,1)
    }
    func testUnknownMetadataPersistsWithoutFakeDecimalsAndReprojectsHistory() async throws {
        let (db,folder) = try await fixture(); defer { try? FileManager.default.removeItem(at:folder) }
        let ticket = try await db.beginSuiSync(accountID:"a1")
        try await db.commitSuiInventory(inventory(metadata:false),ticket:ticket,catalog:catalog)
        let raw = try await db.suiInventory(accountID:"a1")
        XCTAssertEqual(raw?.holdings.first{$0.reference == ref}?.amount,"12345678901234567890")
        let asset = try await db.asset(networkID:"sui",reference:ref); XCTAssertNil(asset)
        let cursor = try await db.suiHistoryWork(ticket).first!
        try await db.commitSuiPage(page([100],metadata:false),cursor:cursor,ticket:ticket)
        var history = try await db.assetHistory(walletID:"w1",accountID:"a1",assetID:"sui:"+ref); XCTAssertTrue(history.isEmpty)
        try await db.commitSuiInventory(inventory(time:200),ticket:ticket,catalog:catalog)
        history = try await db.assetHistory(walletID:"w1",accountID:"a1",assetID:"sui:"+ref); XCTAssertEqual(history.count,1)
        try await db.commitSuiInventory(inventory(time:300,metadata:false),ticket:ticket,catalog:catalog)
        let current = try await db.balance(accountID:"a1",assetID:"sui:"+ref); XCTAssertEqual(current?.amountAtomic,"12345678901234567890")
    }
    func testStaleFailedAndWrongOwnerRefreshesCannotDestroyCache() async throws {
        let (db,folder) = try await fixture(); defer { try? FileManager.default.removeItem(at:folder) }
        let old = try await db.beginSuiSync(accountID:"a1")
        try await db.commitSuiInventory(inventory(),ticket:old,catalog:catalog)
        try await db.failSuiSync(old,history:false,code:"transport")
        var amount = try await db.balance(accountID:"a1",assetID:"sui:"+ref); XCTAssertEqual(amount?.amountAtomic,"12345678901234567890")
        let latest = try await db.beginSuiSync(accountID:"a1")
        do { try await db.commitSuiInventory(inventory(time:200,empty:true),ticket:old,catalog:catalog); XCTFail() } catch { XCTAssertEqual(error as? StoreError,.staleSync) }
        do { try await db.commitSuiInventory(inventory(time:50),ticket:latest,catalog:catalog); XCTFail() } catch { XCTAssertEqual(error as? StoreError,.staleSync) }
        try await db.commitSuiInventory(inventory(time:200,empty:true),ticket:latest,catalog:catalog)
        amount = try await db.balance(accountID:"a1",assetID:"sui:"+ref); XCTAssertEqual(amount?.amountAtomic,"0")
    }
    func testResumableRecentBackfillAndSameCheckpointTransactions() async throws {
        let (db,folder) = try await fixture(); defer { try? FileManager.default.removeItem(at:folder) }
        var ticket = try await db.beginSuiSync(accountID:"a1")
        var cursor = try await db.suiHistoryWork(ticket).first!
        let txs = [tx(100,hash:"b"),tx(100,hash:"a")]
        try await db.commitSuiPage(.init(transactions:txs,next:"older",head:"b",raw:Data()),cursor:cursor,ticket:ticket)
        cursor = try await db.suiHistoryWork(ticket).first!; XCTAssertEqual(cursor.lane,"backfill"); XCTAssertEqual(cursor.beforeCursor,"older")
        ticket = try await db.beginSuiSync(accountID:"a1")
        cursor = try await db.suiHistoryWork(ticket).first!; XCTAssertEqual(cursor.lane,"recent")
        let updated = [tx(110),tx(100,hash:"b")]
        try await db.commitSuiPage(.init(transactions:updated,next:"recentOlder",head:"tx110",raw:Data()),cursor:cursor,ticket:ticket)
        cursor = try await db.suiHistoryWork(ticket).first!; XCTAssertEqual(cursor.beforeCursor,"older")
        try await db.restartSuiHistory(cursor,ticket:ticket)
        cursor = try await db.suiHistoryWork(ticket).first!; XCTAssertNil(cursor.beforeCursor); XCTAssertEqual(cursor.upperCheckpoint,101)
        try await db.commitSuiPage(page([90,80]),cursor:cursor,ticket:ticket)
        let work = try await db.suiHistoryWork(ticket); XCTAssertTrue(work.isEmpty)
        let history = try await db.assetHistory(walletID:"w1",accountID:"a1",assetID:"sui:"+ref); XCTAssertEqual(history.count,5)
    }
    func testResetErasesPrivateLedgerButKeepsMarketCacheAndFencesLateWrites() async throws {
        let (db,folder) = try await fixture(); defer { try? FileManager.default.removeItem(at:folder) }
        let ticket = try await db.beginSuiSync(accountID:"a1")
        try await db.commitSuiInventory(inventory(),ticket:ticket,catalog:catalog)
        let cursor = try await db.suiHistoryWork(ticket).first!
        try await db.commitSuiPage(page([100]),cursor:cursor,ticket:ticket)
        let reset = try await db.beginWalletReset()
        do { try await db.commitSuiInventory(inventory(time:200),ticket:ticket,catalog:catalog); XCTFail() } catch {}
        try await db.eraseWalletData(resetID:reset); try await db.finishWalletReset(resetID:reset)
        let cache = try await db.marketCache(key:"sui.token."+ref); XCTAssertNotNil(cache)
        let count = try await db.pool.read{try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM suiTransactions")!}; XCTAssertEqual(count,0)
        do { try await db.commitSuiPage(page([90]),cursor:cursor,ticket:ticket); XCTFail() } catch { XCTAssertEqual(error as? StoreError,.staleSync) }
    }
    func testLiveProductionSyncPricesHistoryAndOfflineReopen() async throws {
        guard let key = ProcessInfo.processInfo.environment["OATH_LIVE_SUI_DATABASE_KEY"] else { throw XCTSkip("Opt-in production sync mainnet test") }
        let (db,folder) = try await fixture(); defer { try? FileManager.default.removeItem(at:folder) }
        let publicOwner = "0x42960e77d87a60d0a0599757beb320147510933c5e63a6ccfec3fdd54aa796fc"
        try await db.pool.write{try $0.execute(sql:"UPDATE accounts SET address=? WHERE id='a1'",arguments:[publicOwner])}
        let sync = try SuiSynchronizer(database:db,apiKey:key)
        do {
            try await sync.refresh(accountID:"a1")
            let deadline = Date().addingTimeInterval(30)
            var count = 0
            repeat {
                count = try await db.pool.read{try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM suiTransactions WHERE accountID='a1'")!}
                if count > 0 { break }; try await Task.sleep(for:.milliseconds(100))
            } while Date() < deadline
            await sync.cancel()
            XCTAssertGreaterThan(count,0)
            let value = try await db.snapshot(walletID:"w1",currency:"USD")
            XCTAssertGreaterThan(value.holdings.count,1)
            XCTAssertNotNil(value.holdings.first{$0.reference == "native"}?.usdPrice)
            let history = try await db.assetHistory(walletID:"w1",accountID:"a1",assetID:"sui:native")
            XCTAssertFalse(history.isEmpty)
            let reopened = try await OathDatabase.open(at:folder.appendingPathComponent("wallet.sqlite"))
            let offline = try await reopened.snapshot(walletID:"w1",currency:"USD"); XCTAssertEqual(offline.holdings,value.holdings)
            try await assertActivityDetails(db, walletID: "w1")
            print("SUI_LIVE_DATABASE visibleHoldings=\(value.holdings.count) receipts=\(count) offlineReopenMatched=true")
        } catch { await sync.cancel(); throw error }
    }
}
