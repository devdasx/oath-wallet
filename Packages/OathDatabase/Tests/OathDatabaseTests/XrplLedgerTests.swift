import Foundation
import XCTest
import GRDB
@testable import OathDatabase
@testable import OathAnkr

@MainActor final class XrplLedgerTests:XCTestCase {
    let owner = "r9cZA1mLK5R5Am25ArfXFmqgNwjZgnfk59"
    let ref = "USD.rMxCKbEDwqr76QuheSUMdEGf4B9xJ8m5De"
    var catalog:XrplCatalog { .init(ids:[ref:"fixture","native":"ripple"]) }
    func fixture(address:String? = nil) async throws -> (OathDatabase,URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("XrplLedger-"+UUID().uuidString)
        let db = try await OathDatabase.open(at:folder.appendingPathComponent("wallet.sqlite"))
        try await db.seed(networks:[.init(id:"xrpl",name:"XRP Ledger",family:"account",symbol:"XRP",decimals:6,derivationPath:"m/44'/144'/0'/0/0",logo:"xrpl",sortOrder:0)],assets:[.init(id:"xrpl:native",networkID:"xrpl",reference:"native",name:"XRP",symbol:"XRP",decimals:6)])
        for i in 1...2 { try await db.importWalletIfNeeded(.init(id:"w\(i)",name:"Test",kind:"hd",vaultReference:"fixture\(i)",createdAt:1),accounts:[.init(id:"a\(i)",walletID:"w\(i)",networkID:"xrpl",address:address ?? owner,derivationPath:"m/44'/144'/0'/0/0")]) }
        try await db.saveMarketCache(.init(key:"xrpl.catalog",source:"fixture verified catalog",payload:JSONEncoder().encode(catalog),fetchedAt:1))
        return (db,folder)
    }
    func inventory(time:Double = 100, amount:String = "1.234567890123456", includeToken:Bool = true) throws -> XrplInventory {
        let tokens:[XrplHolding] = includeToken ? [.init(reference:ref,token:try .issued(ref),amount:try XrplIdentity.issuedAmount(amount),raw:.null)]:[]
        return .init(owner:owner,ledger:.init(hash:String(repeating:"A",count:64),height:Int64(time),timestamp:time),exists:true,holdings:[.init(reference:"native",token:.native,amount:"12345678",raw:.null)]+tokens,observedAt:Date(timeIntervalSince1970:time),raw:Data("{}".utf8))
    }
    func tx(_ hash:String, height:Int64 = 100, reference:String? = nil, metadata:Bool = true) throws -> XrplTransaction {
        let r = reference ?? ref
        return .init(hash:hash,checkpoint:height,timestamp:100,failed:false,fee:"12",owner:owner,counterparty:nil,movements:[.init(reference:r,token:metadata ? try .issued(ref):nil,direction:"incoming",amount:try XrplIdentity.issuedAmount("0.1"))],raw:Data())
    }
    func page(_ hashes:[String], next:String? = nil, upper:Int64 = 100) throws -> XrplHistoryPage {
        .init(transactions:try hashes.map{try tx($0)},next:next,head:hashes.first,upperLedger:upper,raw:Data())
    }
    func testExactAmountsOfflineIsolationWhitelistAndLiability() async throws {
        let (db,folder) = try await fixture(); defer { try? FileManager.default.removeItem(at:folder) }
        let ticket = try await db.beginXrplSync(accountID:"a1")
        try await db.commitXrplInventory(inventory(),ticket:ticket,catalog:catalog)
        try await db.savePrices([.init(assetID:"xrpl:"+ref,currency:"USD",value:"2",observedAt:100,source:"fixture")])
        let value = try await db.snapshot(walletID:"w1",currency:"USD")
        let holding = try XCTUnwrap(value.holdings.first{$0.reference == ref})
        XCTAssertEqual(holding.decimals,96); XCTAssertEqual(holding.amountAtomic,try XrplIdentity.issuedAmount("1.234567890123456"))
        XCTAssertNotNil(holding.nativeDisplayValue)
        let other = try await db.snapshot(walletID:"w2",currency:"USD"); XCTAssertNil(other.holdings.first?.amountAtomic)
        let reopened = try await OathDatabase.open(at:folder.appendingPathComponent("wallet.sqlite"))
        let cached = try await reopened.snapshot(walletID:"w1",currency:"USD"); XCTAssertEqual(value.holdings,cached.holdings)
        try await db.commitXrplInventory(inventory(time:200,amount:"-5"),ticket:ticket,catalog:catalog)
        let balance = try await db.balance(accountID:"a1",assetID:"xrpl:"+ref); XCTAssertEqual(balance?.amountAtomic,"0")
        let raw = try await db.xrplInventory(accountID:"a1"); XCTAssertEqual(raw?.holdings.last?.amount,try XrplIdentity.issuedAmount("-5"))
        try await db.commitXrplInventory(inventory(time:300),ticket:ticket,catalog:.empty)
        let hidden = try await db.snapshot(walletID:"w1",currency:"USD"); XCTAssertEqual(hidden.holdings.count,1)
    }
    func testFailureRetainsBalancesCompleteEmptySnapshotClearsAndStaleRejected() async throws {
        let (db,folder) = try await fixture(); defer { try? FileManager.default.removeItem(at:folder) }
        let ticket = try await db.beginXrplSync(accountID:"a1")
        try await db.commitXrplInventory(inventory(),ticket:ticket,catalog:catalog)
        try await db.failXrplSync(ticket,history:false,code:"transport")
        var balance = try await db.balance(accountID:"a1",assetID:"xrpl:"+ref); XCTAssertEqual(balance?.observedAt,100)
        try await db.commitXrplInventory(inventory(time:200,includeToken:false),ticket:ticket,catalog:catalog)
        balance = try await db.balance(accountID:"a1",assetID:"xrpl:"+ref); XCTAssertEqual(balance?.amountAtomic,"0")
        do { try await db.commitXrplInventory(inventory(),ticket:ticket,catalog:catalog); XCTFail() } catch { XCTAssertEqual(error as? StoreError,.staleSync) }
        _ = try await db.beginXrplSync(accountID:"a1")
        do { try await db.commitXrplInventory(inventory(time:300),ticket:ticket,catalog:catalog); XCTFail() } catch { XCTAssertEqual(error as? StoreError,.staleSync) }
    }
    func testPinnedCursorRestartDedupeAndSameLedgerHistory() async throws {
        let (db,folder) = try await fixture(); defer { try? FileManager.default.removeItem(at:folder) }
        var ticket = try await db.beginXrplSync(accountID:"a1")
        var cursor = try await db.xrplHistoryWork(ticket).first!
        try await db.commitXrplPage(page(["a","b"],next:"one"),cursor:cursor,ticket:ticket)
        cursor = try await db.xrplHistoryWork(ticket).first!; XCTAssertEqual(cursor.lane,"backfill"); XCTAssertEqual(cursor.upperLedger,100)
        ticket = try await db.beginXrplSync(accountID:"a1"); cursor = try await db.xrplHistoryWork(ticket).first!
        try await db.commitXrplPage(page(["new","a"],next:"recent",upper:200),cursor:cursor,ticket:ticket)
        cursor = try await db.xrplHistoryWork(ticket).first!; XCTAssertEqual(cursor.beforeCursor,"one"); XCTAssertEqual(cursor.upperLedger,100)
        try await db.restartXrplHistory(cursor,ticket:ticket)
        cursor = try await db.xrplHistoryWork(ticket).first!; XCTAssertEqual(cursor.upperLedger,100); XCTAssertNil(cursor.beforeCursor)
        try await db.commitXrplPage(page(["a","b","c"],upper:100),cursor:cursor,ticket:ticket)
        let history = try await db.assetHistory(walletID:"w1",accountID:"a1",assetID:"xrpl:"+ref); XCTAssertEqual(history.count,4)
        let work = try await db.xrplHistoryWork(ticket); XCTAssertTrue(work.isEmpty)
    }
    func testWalletResetErasesXrplButKeepsPrices() async throws {
        let (db,folder) = try await fixture(); defer { try? FileManager.default.removeItem(at:folder) }
        let ticket = try await db.beginXrplSync(accountID:"a1")
        try await db.commitXrplInventory(inventory(),ticket:ticket,catalog:catalog)
        try await db.savePrices([.init(assetID:"xrpl:native",currency:"USD",value:"1.4",observedAt:100,source:"fixture")])
        let reset = try await db.beginWalletReset(); try await db.eraseWalletData(resetID:reset); try await db.finishWalletReset(resetID:reset)
        let raw = try await db.xrplInventory(accountID:"a1"); XCTAssertNil(raw)
        do { try await db.commitXrplInventory(inventory(time:200),ticket:ticket,catalog:catalog); XCTFail() } catch {}
        let count = try await db.pool.read{try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM prices")!}; XCTAssertEqual(count,1)
    }
    func testLiveProductionSyncAndOfflineRead() async throws {
        guard let key = ProcessInfo.processInfo.environment["OATH_XRPL_DATABASE_KEY"] else { throw XCTSkip("Opt-in live XRP database test") }
        let address = "rLxePHrWeHbkg8yy83fWxnxXmYbwmuMK9Q"
        let (db,folder) = try await fixture(address:address); defer { try? FileManager.default.removeItem(at:folder) }
        let service = try XrplSynchronizer(database:db,apiKey:key)
        try await service.refresh(accountID:"a1")
        // Bound the test to committed pages; cancellation retains the backfill cursor.
        try await Task.sleep(for:.seconds(2)); await service.cancel()
        let inventory = try await db.xrplInventory(accountID:"a1"); XCTAssertGreaterThan(try XCTUnwrap(inventory).holdings.count,1)
        let current = try await db.snapshot(walletID:"w1",currency:"USD")
        XCTAssertNotNil(current.holdings.first{$0.reference == "native"}?.usdPrice)
        let reopened = try await OathDatabase.open(at:folder.appendingPathComponent("wallet.sqlite"))
        let offline = try await reopened.snapshot(walletID:"w1",currency:"USD"); XCTAssertEqual(current.holdings,offline.holdings)
        let count = try await db.pool.read{try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM xrplTransactions WHERE accountID='a1'")!}; XCTAssertGreaterThan(count,0)
        try await assertActivityDetails(db, walletID: "w1")
            print("XRPL production persisted \(inventory!.holdings.count) holdings and \(count) transactions; offline snapshot matches")
    }
}
