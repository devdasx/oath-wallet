import XCTest
import OathAnkr
import GRDB
@testable import OathDatabase

@MainActor final class ArcLedgerTests: XCTestCase {
    private let owner = "0x1111111111111111111111111111111111111111"
    private let other = "0x2222222222222222222222222222222222222222"
    private let token = "0x3333333333333333333333333333333333333333"
    private func fixture() async throws -> (OathDatabase,URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Arc-"+UUID().uuidString).appendingPathComponent("test.sqlite")
        let db = try await OathDatabase.open(at:url)
        try await db.seed(networks:[.init(id:"arc",name:"USDC",family:"evm",symbol:"USDC",decimals:18,derivationPath:"m/44'/60'/0'/0/0",logo:"local",sortOrder:0)],
            assets:[.init(id:"arc:native",networkID:"arc",reference:"native",name:"USDC",symbol:"USDC",decimals:18,logo:"local")])
        for id in ["wallet","second"] {
            try await db.importWalletIfNeeded(.init(id:id,name:id,kind:"hd",vaultReference:id,createdAt:1),
                accounts:[.init(id:id+":arc",walletID:id,networkID:"arc",address:owner,derivationPath:"m/44'/60'/0'/0/0")])
        }
        return (db,url)
    }
    private func inventory(amount:String? = "9007199254740993", complete:Bool = true, block:Int = 100) throws -> ArcInventory {
        func holding(_ reference:String,_ units:String?,_ decimals:Int)->[String:Any] {
            ["token":["reference":reference,"name":reference == "native" ? "USDC":"Token","symbol":"TKN","decimals":decimals],"amount":units as Any? ?? NSNull()]
        }
        let data = try JSONSerialization.data(withJSONObject:["owner":owner,"block":block,"blockHash":"0x"+String(repeating:"a",count:64),
            "observedAt":Date().timeIntervalSinceReferenceDate,"holdings":[holding("native","1000000000000000000",18),holding(token,amount,6)],"complete":complete,"raw":Data("{\"index\":[]}".utf8).base64EncodedString()])
        return try JSONDecoder().decode(ArcInventory.self,from:data)
    }
    func testPersistencePortfolioExactUnitsPricesAndWalletIsolation() async throws {
        let (db,url) = try await fixture(), ticket = try await db.beginArcSync(accountID:"wallet:arc")
        try await db.commitArcInventory(inventory(),ticket:ticket,catalog:.init(ids:[token:"fixture"]))
        try await db.savePrices([.init(assetID:"arc:native",currency:"USD",value:"1",observedAt:Date().timeIntervalSince1970,source:"Coinbase")])
        let reopened = try await OathDatabase.open(at:url), snapshot = try await reopened.snapshot(walletID:"wallet",currency:"USD")
        XCTAssertEqual(snapshot.holdings.first{$0.reference == token}?.amountAtomic,"9007199254740993")
        XCTAssertEqual(snapshot.holdings.first{$0.reference == "native"}?.name,"USDC")
        XCTAssertEqual(snapshot.totalFiat,1)
        let second = try await reopened.snapshot(walletID:"second",currency:"USD")
        XCTAssertNil(second.holdings.first?.amountAtomic)
        let balance = try await reopened.balance(accountID:"wallet:arc",assetID:"arc:"+token)
        XCTAssertEqual(balance?.amountAtomic,"9007199254740993")
    }
    func testPartialInventoryPreservesCachedTokenAndSuccessfulZeroReplacesIt() async throws {
        let (db,_) = try await fixture()
        var ticket = try await db.beginArcSync(accountID:"wallet:arc")
        try await db.commitArcInventory(inventory(),ticket:ticket,catalog:.init(ids:[token:"fixture"]))
        ticket = try await db.beginArcSync(accountID:"wallet:arc")
        try await db.commitArcInventory(inventory(amount:nil,complete:false,block:101),ticket:ticket,catalog:.empty)
        var snapshot = try await db.snapshot(walletID:"wallet",currency:"USD")
        XCTAssertEqual(snapshot.holdings.first{$0.reference == token}?.amountAtomic,"9007199254740993")
        let complete = try await db.pool.read { try Int.fetchOne($0,sql:"SELECT complete FROM arcSync WHERE accountID='wallet:arc'") }
        XCTAssertEqual(complete,0)
        ticket = try await db.beginArcSync(accountID:"wallet:arc")
        try await db.commitArcInventory(inventory(amount:"0",block:102),ticket:ticket,catalog:.init(ids:[token:"fixture"]))
        snapshot = try await db.snapshot(walletID:"wallet",currency:"USD")
        XCTAssertEqual(snapshot.holdings.first{$0.reference == token}?.amountAtomic,"0")
    }
    func testUnlistedTokenHiddenUnlessExplicitlyAddedAndStaleRunRejected() async throws {
        let (db,_) = try await fixture()
        let old = try await db.beginArcSync(accountID:"wallet:arc")
        let ticket = try await db.beginArcSync(accountID:"wallet:arc")
        do { try await db.commitArcInventory(inventory(),ticket:old,catalog:.empty); XCTFail() }
        catch { XCTAssertEqual(error as? StoreError,.staleSync) }
        try await db.commitArcInventory(inventory(),ticket:ticket,catalog:.empty)
        var snapshot = try await db.snapshot(walletID:"wallet",currency:"USD")
        XCTAssertFalse(snapshot.holdings.contains{$0.reference == token})
        let stored = try await db.asset(networkID:"arc",reference:token)
        let asset = try XCTUnwrap(stored)
        try await db.trackAsset(asset,walletID:"wallet")
        snapshot = try await db.snapshot(walletID:"wallet",currency:"USD")
        XCTAssertEqual(snapshot.holdings.first{$0.reference == token}?.amountAtomic,"9007199254740993")
    }
    func testResetErasesArcWalletDataButPreservesPublicMarketCache() async throws {
        let (db,_) = try await fixture(), ticket = try await db.beginArcSync(accountID:"wallet:arc")
        try await db.commitArcInventory(inventory(),ticket:ticket,catalog:.init(ids:[token:"fixture"]))
        try await db.saveMarketCache(.init(key:"arc.catalog",source:"CoinGecko",payload:Data("{}".utf8),fetchedAt:Date().timeIntervalSince1970))
        let reset = try await db.beginWalletReset()
        try await db.eraseWalletData(resetID:reset); try await db.finishWalletReset(resetID:reset)
        let rows = try await db.pool.read { db in try ["arcSync","arcHoldings","arcHistoryCursors","arcEvents","arcPages"].map { try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM \($0)") ?? -1 } }
        XCTAssertEqual(rows,[0,0,0,0,0])
        let cache = try await db.marketCache(key:"arc.catalog"); XCTAssertNotNil(cache)
    }


    private func page(from:Int64,next:Int64,hashCharacter:String = "a",amount:String = "1234567890000000000") throws -> ArcHistoryPage {
        let hash = "0x" + String(repeating:hashCharacter,count:64), blockHash = "0x" + String(repeating:"b",count:64)
        let value = UInt64(amount)!
        let word = "0x" + String(repeating:"0",count:64-String(value,radix:16).count) + String(value,radix:16)
        let topic = { (address:String) in "0x" + String(repeating:"0",count:24) + address.dropFirst(2) }
        let row:[String:Any] = ["address":ArcIdentity.systemEmitter,"block_number":from,"block_hash":blockHash,"transaction_hash":hash,
            "log_index":0,"data":word,"topic0":ArcIdentity.transferTopic,"topic1":topic(other),"topic2":topic(owner),"topic3":NSNull()]
        let data = try JSONSerialization.data(withJSONObject:["next_block":next,"data":[[
            "blocks":[["number":from,"hash":blockHash,"timestamp":1_700_000_000]],
            "transactions":[["hash":hash,"block_number":from,"block_hash":blockHash,"from":other,"to":owner,"status":1,"gas_used":"21000","effective_gas_price":"1000000000"]],"logs":[row]]]])
        return try ArcClient.decodeHistory(data,owner:owner,from:from,through:next,tokens:[:])
    }
    func testHistoryResumesExactBlocksAndDoesNotLoseIntervalsOrDuplicateNativeUSDC() async throws {
        let (db,url) = try await fixture(), ticket = try await db.beginArcSync(accountID:"wallet:arc")
        try await db.prepareArcHistory(ticket,through:300_000)
        let work = try await db.arcHistoryWork(ticket), cursor = try XCTUnwrap(work.first{$0.lane == "recent"})
        XCTAssertEqual(cursor.nextBlock,100_000)
        try await db.commitArcPage(page(from:100_000,next:100_100),cursor:cursor,ticket:ticket)
        let reopened = try await OathDatabase.open(at:url), nextTicket = try await reopened.beginArcSync(accountID:"wallet:arc")
        try await reopened.prepareArcHistory(nextTicket,through:400_000)
        let resumed = try await reopened.arcHistoryWork(nextTicket), next = try XCTUnwrap(resumed.first{$0.lane == "recent"})
        XCTAssertEqual(next.nextBlock,100_100); XCTAssertEqual(next.endBlock,300_000)
        XCTAssertEqual(resumed.first{$0.lane == "backfill"}?.endBlock,100_000)
        do { try await db.commitArcPage(page(from:100_000,next:100_100),cursor:cursor,ticket:ticket); XCTFail() }
        catch { XCTAssertEqual(error as? StoreError,.staleSync) }
        try await reopened.commitArcPage(page(from:100_100,next:300_000,hashCharacter:"c"),cursor:next,ticket:nextTicket)
        let history = try await reopened.assetHistory(walletID:"wallet",accountID:"wallet:arc",assetID:"arc:native")
        XCTAssertEqual(history.count,2); XCTAssertTrue(history.allSatisfy{$0.amountAtomic == "1234567890000000000"})
        let newest = try await reopened.beginArcSync(accountID:"wallet:arc")
        try await reopened.prepareArcHistory(newest,through:400_000)
        let updated = try await reopened.arcHistoryWork(newest)
        XCTAssertEqual(updated.first{$0.lane == "recent"}?.startBlock,299_900)
        XCTAssertEqual(updated.first{$0.lane == "backfill"}?.nextBlock,0)
    }
    func testEmptyOwnedTokensDoNotPopulateWalletWithEntireCatalog() async throws {
        let (db,_) = try await fixture(), ticket = try await db.beginArcSync(accountID:"wallet:arc")
        try await db.commitArcInventory(inventory(amount:"0"),ticket:ticket,catalog:.init(ids:[token:"fixture"]))
        let snapshot = try await db.snapshot(walletID:"wallet",currency:"USD")
        XCTAssertEqual(snapshot.holdings.count,1)
        XCTAssertEqual(snapshot.holdings.first?.reference,"native")
    }
    func testNativeMirrorCannotBecomeSecondDatabaseBalance() async throws {
        let (db,_) = try await fixture(), ticket = try await db.beginArcSync(accountID:"wallet:arc")
        var json = try JSONSerialization.jsonObject(with:JSONEncoder().encode(inventory())) as! [String:Any]
        var holdings = json["holdings"] as! [[String:Any]], detail = holdings[1]["token"] as! [String:Any]
        detail["reference"] = ArcIdentity.usdc; detail["decimals"] = 6; holdings[1]["token"] = detail; json["holdings"] = holdings
        let malformed = try JSONDecoder().decode(ArcInventory.self,from:JSONSerialization.data(withJSONObject:json))
        do { try await db.commitArcInventory(malformed,ticket:ticket,catalog:.empty); XCTFail() }
        catch { XCTAssertEqual(error as? StoreError,.conflictingIdentity) }
        let count = try await db.pool.read { try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM arcHoldings") }
        XCTAssertEqual(count,0)
    }
    func testLiveProductionSyncAndCachedOfflinePortfolio() async throws {
        guard ProcessInfo.processInfo.environment["OATH_ARC_LIVE"] == "1" else { throw XCTSkip("Opt-in Arc production database sync") }
        let (db,url) = try await fixture()
        defer { try? FileManager.default.removeItem(at:url.deletingLastPathComponent()) }
        let publicOwner = "0x8f10b468b06c6fd214b65f87778827f7d113f996"
        try await db.importWalletIfNeeded(.init(id:"public",name:"Public fixture",kind:"watchOnly",vaultReference:"public",createdAt:1),
            accounts:[.init(id:"public:arc",walletID:"public",networkID:"arc",address:publicOwner,derivationPath:"")])
        let service = try ArcSynchronizer(database:db)
        try await service.refresh(accountID:"public:arc"); await service.waitForHistory(accountID:"public:arc")
        let current = try await db.snapshot(walletID:"public",currency:"USD")
        XCTAssertGreaterThan(current.holdings.count,2)
        XCTAssertNotNil(current.holdings.first{$0.reference == "native"}?.usdPrice)
        XCTAssertTrue(current.holdings.contains{$0.reference != "native" && $0.amountAtomic != "0" && $0.usdPrice != nil})
        let reopened = try await OathDatabase.open(at:url), cached = try await reopened.snapshot(walletID:"public",currency:"USD")
        XCTAssertEqual(current.holdings,cached.holdings); XCTAssertEqual(current.totalFiat,cached.totalFiat)
        let ticket = try await reopened.beginArcSync(accountID:"public:arc"), work = try await reopened.arcHistoryWork(ticket)
        XCTAssertTrue(work.allSatisfy{ !$0.complete && $0.failure == "configurationMissing" })
        print("Arc production sync: \(current.holdings.count) holdings; USD quotes \(current.holdings.filter{$0.usdPrice != nil}.count); offline portfolio matches")
    }
}
