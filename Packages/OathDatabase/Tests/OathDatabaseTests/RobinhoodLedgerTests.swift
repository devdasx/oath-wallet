import XCTest
import OathAnkr
import GRDB
@testable import OathDatabase

@MainActor final class RobinhoodLedgerTests: XCTestCase {
    private let owner = "0x1111111111111111111111111111111111111111"
    private let other = "0x2222222222222222222222222222222222222222"
    private let token = "0x3333333333333333333333333333333333333333"
    private func fixture() async throws -> (OathDatabase,URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Robinhood-"+UUID().uuidString).appendingPathComponent("test.sqlite")
        let db = try await OathDatabase.open(at:url)
        try await db.seed(networks:[.init(id:"robinhood",name:"Robinhood Chain",family:"evm",symbol:"ETH",decimals:18,derivationPath:"m/44'/60'/0'/0/0",logo:"local",sortOrder:0)],
            assets:[.init(id:"robinhood:native",networkID:"robinhood",reference:"native",name:"Robinhood Chain",symbol:"ETH",decimals:18,logo:"local")])
        for id in ["wallet","second"] {
            try await db.importWalletIfNeeded(.init(id:id,name:id,kind:"hd",vaultReference:id,createdAt:1),
                accounts:[.init(id:id+":robinhood",walletID:id,networkID:"robinhood",address:owner,derivationPath:"m/44'/60'/0'/0/0")])
        }
        return (db,url)
    }
    private func inventory(amount:String? = "9007199254740993", complete:Bool = true, block:Int = 100) throws -> RobinhoodInventory {
        func holding(_ reference:String,_ units:String?,_ decimals:Int)->[String:Any] {
            ["token":["reference":reference,"name":reference == "native" ? "ETH":"Token","symbol":"TKN","decimals":decimals],"amount":units as Any? ?? NSNull()]
        }
        let data = try JSONSerialization.data(withJSONObject:["owner":owner,"block":block,"blockHash":"0x"+String(repeating:"a",count:64),
            "observedAt":Date().timeIntervalSinceReferenceDate,"holdings":[holding("native","1000000000000000000",18),holding(token,amount,6)],"complete":complete,"raw":Data("{\"index\":[]}".utf8).base64EncodedString()])
        return try JSONDecoder().decode(RobinhoodInventory.self,from:data)
    }
    func testPersistencePortfolioExactUnitsPricesAndWalletIsolation() async throws {
        let (db,url) = try await fixture(), ticket = try await db.beginRobinhoodSync(accountID:"wallet:robinhood")
        try await db.commitRobinhoodInventory(inventory(),ticket:ticket,catalog:.init(ids:[token:"fixture"]))
        try await db.savePrices([.init(assetID:"robinhood:native",currency:"USD",value:"2500",observedAt:Date().timeIntervalSince1970,source:"Coinbase")])
        let reopened = try await OathDatabase.open(at:url), snapshot = try await reopened.snapshot(walletID:"wallet",currency:"USD")
        XCTAssertEqual(snapshot.holdings.first{$0.reference == token}?.amountAtomic,"9007199254740993")
        XCTAssertEqual(snapshot.holdings.first{$0.reference == "native"}?.name,"Robinhood Chain")
        XCTAssertEqual(snapshot.totalFiat,2500)
        let second = try await reopened.snapshot(walletID:"second",currency:"USD")
        XCTAssertNil(second.holdings.first?.amountAtomic)
        let balance = try await reopened.balance(accountID:"wallet:robinhood",assetID:"robinhood:"+token)
        XCTAssertEqual(balance?.amountAtomic,"9007199254740993")
    }
    func testPartialInventoryPreservesCachedTokenAndSuccessfulZeroReplacesIt() async throws {
        let (db,_) = try await fixture()
        var ticket = try await db.beginRobinhoodSync(accountID:"wallet:robinhood")
        try await db.commitRobinhoodInventory(inventory(),ticket:ticket,catalog:.init(ids:[token:"fixture"]))
        ticket = try await db.beginRobinhoodSync(accountID:"wallet:robinhood")
        try await db.commitRobinhoodInventory(inventory(amount:nil,complete:false,block:101),ticket:ticket,catalog:.empty)
        var snapshot = try await db.snapshot(walletID:"wallet",currency:"USD")
        XCTAssertEqual(snapshot.holdings.first{$0.reference == token}?.amountAtomic,"9007199254740993")
        let complete = try await db.pool.read { try Int.fetchOne($0,sql:"SELECT complete FROM robinhoodSync WHERE accountID='wallet:robinhood'") }
        XCTAssertEqual(complete,0)
        ticket = try await db.beginRobinhoodSync(accountID:"wallet:robinhood")
        try await db.commitRobinhoodInventory(inventory(amount:"0",block:102),ticket:ticket,catalog:.init(ids:[token:"fixture"]))
        snapshot = try await db.snapshot(walletID:"wallet",currency:"USD")
        XCTAssertEqual(snapshot.holdings.first{$0.reference == token}?.amountAtomic,"0")
    }
    func testUnlistedTokenHiddenUnlessExplicitlyAddedAndStaleRunRejected() async throws {
        let (db,_) = try await fixture()
        let old = try await db.beginRobinhoodSync(accountID:"wallet:robinhood")
        let ticket = try await db.beginRobinhoodSync(accountID:"wallet:robinhood")
        do { try await db.commitRobinhoodInventory(inventory(),ticket:old,catalog:.empty); XCTFail() }
        catch { XCTAssertEqual(error as? StoreError,.staleSync) }
        try await db.commitRobinhoodInventory(inventory(),ticket:ticket,catalog:.empty)
        var snapshot = try await db.snapshot(walletID:"wallet",currency:"USD")
        XCTAssertFalse(snapshot.holdings.contains{$0.reference == token})
        let stored = try await db.asset(networkID:"robinhood",reference:token)
        let asset = try XCTUnwrap(stored)
        try await db.trackAsset(asset,walletID:"wallet")
        snapshot = try await db.snapshot(walletID:"wallet",currency:"USD")
        XCTAssertEqual(snapshot.holdings.first{$0.reference == token}?.amountAtomic,"9007199254740993")
    }
    func testHistoryCommitsCursorAndEventsTogetherThenResumesWithoutDuplicateActivity() async throws {
        let (db,url) = try await fixture(), ticket = try await db.beginRobinhoodSync(accountID:"wallet:robinhood")
        let cursors = try await db.robinhoodHistoryWork(ticket)
        let cursor = try XCTUnwrap(cursors.first{$0.stream == "transactions" && $0.lane == "recent"})
        let time = Date(timeIntervalSince1970:floor(cursor.endTime)-1).ISO8601Format(), hash = "0x"+String(repeating:"a",count:64)
        let row: [String:Any] = ["hash":hash,"block_number":100,"timestamp":time,"from":["hash":other],"to":["hash":owner],"status":"ok","value":"12345","fee":["value":"321"]]
        let raw = try JSONSerialization.data(withJSONObject:["items":[row],"next_page_params":["block_number":99]])
        let page = try RobinhoodClient.decodeHistory(raw,owner:owner,stream:.transactions,from:cursor.startTime,through:cursor.endTime)
        try await db.commitRobinhoodPage(page,cursor:cursor,ticket:ticket)
        let reopened = try await OathDatabase.open(at:url)
        let nextTicket = try await reopened.beginRobinhoodSync(accountID:"wallet:robinhood")
        let resumed = try await reopened.robinhoodHistoryWork(nextTicket)
        let next = try XCTUnwrap(resumed.first{$0.stream == "transactions" && $0.lane == "recent"})
        XCTAssertEqual(next.cursor,page.next); XCTAssertEqual(next.endTime,cursor.endTime)
        let final = try RobinhoodClient.decodeHistory(JSONSerialization.data(withJSONObject:["items":[row],"next_page_params":NSNull()]),owner:owner,stream:.transactions,from:next.startTime,through:next.endTime)
        try await reopened.commitRobinhoodPage(final,cursor:next,ticket:nextTicket)
        let history = try await reopened.assetHistory(walletID:"wallet",accountID:"wallet:robinhood",assetID:"robinhood:native")
        XCTAssertEqual(history.count,1); XCTAssertEqual(history.first?.amountAtomic,"12345")
        let counts = try await reopened.snapshot(walletID:"wallet",currency:"USD")
        XCTAssertEqual(counts.holdings.first?.transactionCount,1)
    }
    func testResetErasesRobinhoodWalletDataButPreservesPublicMarketCache() async throws {
        let (db,_) = try await fixture(), ticket = try await db.beginRobinhoodSync(accountID:"wallet:robinhood")
        try await db.commitRobinhoodInventory(inventory(),ticket:ticket,catalog:.init(ids:[token:"fixture"]))
        try await db.saveMarketCache(.init(key:"robinhood.catalog",source:"CoinGecko",payload:Data("{}".utf8),fetchedAt:Date().timeIntervalSince1970))
        let reset = try await db.beginWalletReset()
        try await db.eraseWalletData(resetID:reset); try await db.finishWalletReset(resetID:reset)
        let rows = try await db.pool.read { db in try ["robinhoodSync","robinhoodHoldings","robinhoodHistoryCursors","robinhoodEvents","robinhoodPages"].map { try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM \($0)") ?? -1 } }
        XCTAssertEqual(rows,[0,0,0,0,0])
        let cache = try await db.marketCache(key:"robinhood.catalog"); XCTAssertNotNil(cache)
    }

    func testExpiredCursorRestartsOnlyItsWindowAndRejectsStaleRun() async throws {
        let (db,_) = try await fixture(), ticket = try await db.beginRobinhoodSync(accountID:"wallet:robinhood")
        let initialWork = try await db.robinhoodHistoryWork(ticket)
        let initial = try XCTUnwrap(initialWork.first{$0.stream == "transfers" && $0.lane == "backfill"})
        let raw = try JSONSerialization.data(withJSONObject:["items":[],"next_page_params":["block_number":99]])
        let page = try RobinhoodClient.decodeHistory(raw,owner:owner,stream:.transfers,from:initial.startTime,through:initial.endTime)
        try await db.commitRobinhoodPage(page,cursor:initial,ticket:ticket)
        let continued = try await db.robinhoodHistoryWork(ticket)
        let saved = try XCTUnwrap(continued.first{$0.stream == initial.stream && $0.lane == initial.lane})
        XCTAssertNotNil(saved.cursor)
        try await db.restartRobinhoodHistory(saved,ticket:ticket)
        let restarted = try await db.robinhoodHistoryWork(ticket)
        let fresh = try XCTUnwrap(restarted.first{$0.stream == initial.stream && $0.lane == initial.lane})
        XCTAssertNil(fresh.cursor); XCTAssertEqual(fresh.startTime,initial.startTime); XCTAssertEqual(fresh.endTime,initial.endTime)
        XCTAssertEqual(restarted.filter{$0.stream != initial.stream}.map(\.cursor),initialWork.filter{$0.stream != initial.stream}.map(\.cursor))
        _ = try await db.beginRobinhoodSync(accountID:"wallet:robinhood")
        do { try await db.restartRobinhoodHistory(saved,ticket:ticket); XCTFail() }
        catch { XCTAssertEqual(error as? StoreError,.staleSync) }
    }

    func testLiveProductionSyncAndOfflineCache() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["OATH_ROBINHOOD_LIVE"] == "1" else { throw XCTSkip("Opt-in Robinhood public-account database test") }
        let config = try XCTUnwrap(environment["OATH_ANKR_CONFIG"])
        let secrets = try PropertyListSerialization.propertyList(from:Data(contentsOf:URL(fileURLWithPath:config)),format:nil) as! [String:String]
        struct Sample: Decodable { let owner:String; let tokens:[RobinhoodToken] }
        let sampleFile = try XCTUnwrap(environment["OATH_ROBINHOOD_SAMPLES"])
        let samples = try JSONDecoder().decode([Sample].self,from:Data(contentsOf:URL(fileURLWithPath:sampleFile)))
        let (db,url) = try await fixture()
        defer { try? FileManager.default.removeItem(at:url.deletingLastPathComponent()) }
        let service = try RobinhoodSynchronizer(database:db,apiKey:XCTUnwrap(secrets["AnkrAPIKey"]),blockscoutKey:secrets["BlockscoutAPIKey"])
        // Track only public fixture contracts. The same production synchronizer
        // performs pinned ANKR reads, price requests, and database writes.
        for (i,sample) in samples.enumerated() {
            let wallet = "public-\(i)"
            try await db.importWalletIfNeeded(.init(id:wallet,name:"Public fixture",kind:"watchOnly",vaultReference:wallet,createdAt:1),
                accounts:[.init(id:wallet+":robinhood",walletID:wallet,networkID:"robinhood",address:sample.owner,derivationPath:"")])
            for token in sample.tokens {
                try await db.trackAsset(.init(id:"robinhood:"+token.reference,networkID:"robinhood",reference:token.reference,
                    name:token.name,symbol:token.symbol,decimals:token.decimals),walletID:wallet)
            }
        }
        try await withThrowingTaskGroup(of:Void.self) { group in
            for i in samples.indices { group.addTask { try await service.refresh(accountID:"public-\(i):robinhood") } }
            try await group.waitForAll()
        }
        // Large account history is intentionally not drained by this bounded
        // balance/cache check. The separately gated index test checks history.
        await service.cancel()
        let reopened = try await OathDatabase.open(at:url)
        for (i,sample) in samples.enumerated() {
            let current = try await db.snapshot(walletID:"public-\(i)",currency:"USD")
            XCTAssertGreaterThanOrEqual(current.holdings.count,sample.tokens.count+1)
            for reference in ["native"] + sample.tokens.map(\.reference) {
                XCTAssertNotNil(current.holdings.first{$0.reference == reference}?.amountAtomic)
            }
            XCTAssertNotNil(current.holdings.first{$0.reference == "native"}?.usdPrice)
            XCTAssertTrue(current.holdings.contains{$0.reference != "native" && $0.amountAtomic != "0" && $0.usdPrice != nil})
            let offline = try await reopened.snapshot(walletID:"public-\(i)",currency:"USD")
            XCTAssertEqual(current.holdings,offline.holdings)
        }
        print("Robinhood production sync: \(samples.count) public accounts, \(samples.flatMap(\.tokens).count) sampled token balances, prices, and matching offline snapshots")
    }
}
