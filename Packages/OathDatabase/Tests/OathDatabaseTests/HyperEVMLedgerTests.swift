import XCTest
import OathAnkr
import GRDB
@testable import OathDatabase

@MainActor final class HyperEVMLedgerTests: XCTestCase {
    private let owner = "0x1111111111111111111111111111111111111111"
    private let other = "0x2222222222222222222222222222222222222222"
    private let token = "0x3333333333333333333333333333333333333333"
    private func fixture() async throws -> (OathDatabase,URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("HyperEVM-"+UUID().uuidString).appendingPathComponent("test.sqlite")
        let db = try await OathDatabase.open(at:url)
        try await db.seed(networks:[.init(id:"hyperevm",name:"HyperEVM",family:"evm",symbol:"HYPE",decimals:18,derivationPath:"m/44'/60'/0'/0/0",logo:"local",sortOrder:0)],
            assets:[.init(id:"hyperevm:native",networkID:"hyperevm",reference:"native",name:"HyperEVM",symbol:"HYPE",decimals:18,logo:"local")])
        for id in ["wallet","second"] {
            try await db.importWalletIfNeeded(.init(id:id,name:id,kind:"hd",vaultReference:id,createdAt:1),
                accounts:[.init(id:id+":hyperevm",walletID:id,networkID:"hyperevm",address:owner,derivationPath:"m/44'/60'/0'/0/0")])
        }
        return (db,url)
    }
    private func inventory(amount:String? = "9007199254740993", complete:Bool = true, block:Int = 100) throws -> HyperEVMInventory {
        func holding(_ reference:String,_ units:String?,_ decimals:Int)->[String:Any] {
            ["token":["reference":reference,"name":reference == "native" ? "HYPE":"Token","symbol":"TKN","decimals":decimals],"amount":units as Any? ?? NSNull()]
        }
        let data = try JSONSerialization.data(withJSONObject:["owner":owner,"block":block,"blockHash":"0x"+String(repeating:"a",count:64),
            "observedAt":Date().timeIntervalSinceReferenceDate,"holdings":[holding("native","1000000000000000000",18),holding(token,amount,6)],"complete":complete,"raw":Data("{\"index\":[]}".utf8).base64EncodedString()])
        return try JSONDecoder().decode(HyperEVMInventory.self,from:data)
    }
    func testPersistencePortfolioExactUnitsPricesAndWalletIsolation() async throws {
        let (db,url) = try await fixture(), ticket = try await db.beginHyperEVMSync(accountID:"wallet:hyperevm")
        try await db.commitHyperEVMInventory(inventory(),ticket:ticket,catalog:.init(ids:[token:"fixture"]))
        try await db.savePrices([.init(assetID:"hyperevm:native",currency:"USD",value:"2500",observedAt:Date().timeIntervalSince1970,source:"Coinbase")])
        let reopened = try await OathDatabase.open(at:url), snapshot = try await reopened.snapshot(walletID:"wallet",currency:"USD")
        XCTAssertEqual(snapshot.holdings.first{$0.reference == token}?.amountAtomic,"9007199254740993")
        XCTAssertEqual(snapshot.holdings.first{$0.reference == "native"}?.name,"HyperEVM")
        XCTAssertEqual(snapshot.totalFiat,2500)
        let second = try await reopened.snapshot(walletID:"second",currency:"USD")
        XCTAssertNil(second.holdings.first?.amountAtomic)
        let balance = try await reopened.balance(accountID:"wallet:hyperevm",assetID:"hyperevm:"+token)
        XCTAssertEqual(balance?.amountAtomic,"9007199254740993")
    }
    func testPartialInventoryPreservesCachedTokenAndSuccessfulZeroReplacesIt() async throws {
        let (db,_) = try await fixture()
        var ticket = try await db.beginHyperEVMSync(accountID:"wallet:hyperevm")
        try await db.commitHyperEVMInventory(inventory(),ticket:ticket,catalog:.init(ids:[token:"fixture"]))
        ticket = try await db.beginHyperEVMSync(accountID:"wallet:hyperevm")
        try await db.commitHyperEVMInventory(inventory(amount:nil,complete:false,block:101),ticket:ticket,catalog:.empty)
        var snapshot = try await db.snapshot(walletID:"wallet",currency:"USD")
        XCTAssertEqual(snapshot.holdings.first{$0.reference == token}?.amountAtomic,"9007199254740993")
        let complete = try await db.pool.read { try Int.fetchOne($0,sql:"SELECT complete FROM hyperevmSync WHERE accountID='wallet:hyperevm'") }
        XCTAssertEqual(complete,0)
        ticket = try await db.beginHyperEVMSync(accountID:"wallet:hyperevm")
        try await db.commitHyperEVMInventory(inventory(amount:"0",block:102),ticket:ticket,catalog:.init(ids:[token:"fixture"]))
        snapshot = try await db.snapshot(walletID:"wallet",currency:"USD")
        XCTAssertEqual(snapshot.holdings.first{$0.reference == token}?.amountAtomic,"0")
    }
    func testUnlistedTokenHiddenUnlessExplicitlyAddedAndStaleRunRejected() async throws {
        let (db,_) = try await fixture()
        let old = try await db.beginHyperEVMSync(accountID:"wallet:hyperevm")
        let ticket = try await db.beginHyperEVMSync(accountID:"wallet:hyperevm")
        do { try await db.commitHyperEVMInventory(inventory(),ticket:old,catalog:.empty); XCTFail() }
        catch { XCTAssertEqual(error as? StoreError,.staleSync) }
        try await db.commitHyperEVMInventory(inventory(),ticket:ticket,catalog:.empty)
        var snapshot = try await db.snapshot(walletID:"wallet",currency:"USD")
        XCTAssertFalse(snapshot.holdings.contains{$0.reference == token})
        let stored = try await db.asset(networkID:"hyperevm",reference:token)
        let asset = try XCTUnwrap(stored)
        try await db.trackAsset(asset,walletID:"wallet")
        snapshot = try await db.snapshot(walletID:"wallet",currency:"USD")
        XCTAssertEqual(snapshot.holdings.first{$0.reference == token}?.amountAtomic,"9007199254740993")
    }
    func testHistoryCommitsCursorAndEventsTogetherThenResumesWithoutDuplicateActivity() async throws {
        let (db,url) = try await fixture(), ticket = try await db.beginHyperEVMSync(accountID:"wallet:hyperevm")
        let cursors = try await db.hyperevmHistoryWork(ticket)
        let cursor = try XCTUnwrap(cursors.first{$0.stream == "transactions" && $0.lane == "recent"})
        let time = Date(timeIntervalSince1970:floor(cursor.endTime)-1).ISO8601Format(), hash = "0x"+String(repeating:"a",count:64)
        let row: [String:Any] = ["hash":hash,"block_number":100,"timestamp":time,"from":["hash":other],"to":["hash":owner],"status":"ok","value":"12345","fee":["value":"321"]]
        let raw = try JSONSerialization.data(withJSONObject:["items":[row],"next_page_params":["block_number":99]])
        let page = try HyperEVMClient.decodeHistory(raw,owner:owner,stream:.transactions,from:cursor.startTime,through:cursor.endTime)
        try await db.commitHyperEVMPage(page,cursor:cursor,ticket:ticket)
        let reopened = try await OathDatabase.open(at:url)
        let nextTicket = try await reopened.beginHyperEVMSync(accountID:"wallet:hyperevm")
        let resumed = try await reopened.hyperevmHistoryWork(nextTicket)
        let next = try XCTUnwrap(resumed.first{$0.stream == "transactions" && $0.lane == "recent"})
        XCTAssertEqual(next.cursor,page.next); XCTAssertEqual(next.endTime,cursor.endTime)
        let final = try HyperEVMClient.decodeHistory(JSONSerialization.data(withJSONObject:["items":[row],"next_page_params":NSNull()]),owner:owner,stream:.transactions,from:next.startTime,through:next.endTime)
        try await reopened.commitHyperEVMPage(final,cursor:next,ticket:nextTicket)
        let history = try await reopened.assetHistory(walletID:"wallet",accountID:"wallet:hyperevm",assetID:"hyperevm:native")
        XCTAssertEqual(history.count,1); XCTAssertEqual(history.first?.amountAtomic,"12345")
        let counts = try await reopened.snapshot(walletID:"wallet",currency:"USD")
        XCTAssertEqual(counts.holdings.first?.transactionCount,1)
    }
    func testResetErasesHyperEVMWalletDataButPreservesPublicMarketCache() async throws {
        let (db,_) = try await fixture(), ticket = try await db.beginHyperEVMSync(accountID:"wallet:hyperevm")
        try await db.commitHyperEVMInventory(inventory(),ticket:ticket,catalog:.init(ids:[token:"fixture"]))
        try await db.saveMarketCache(.init(key:"hyperevm.catalog",source:"CoinGecko",payload:Data("{}".utf8),fetchedAt:Date().timeIntervalSince1970))
        let reset = try await db.beginWalletReset()
        try await db.eraseWalletData(resetID:reset); try await db.finishWalletReset(resetID:reset)
        let rows = try await db.pool.read { db in try ["hyperevmSync","hyperevmHoldings","hyperevmHistoryCursors","hyperevmEvents","hyperevmPages"].map { try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM \($0)") ?? -1 } }
        XCTAssertEqual(rows,[0,0,0,0,0])
        let cache = try await db.marketCache(key:"hyperevm.catalog"); XCTAssertNotNil(cache)
    }

    func testExpiredCursorRestartsOnlyItsWindowAndRejectsStaleRun() async throws {
        let (db,_) = try await fixture(), ticket = try await db.beginHyperEVMSync(accountID:"wallet:hyperevm")
        let initialWork = try await db.hyperevmHistoryWork(ticket)
        let initial = try XCTUnwrap(initialWork.first{$0.stream == "transfers" && $0.lane == "backfill"})
        let raw = try JSONSerialization.data(withJSONObject:["items":[],"next_page_params":["block_number":99]])
        let page = try HyperEVMClient.decodeHistory(raw,owner:owner,stream:.transfers,from:initial.startTime,through:initial.endTime)
        try await db.commitHyperEVMPage(page,cursor:initial,ticket:ticket)
        let continued = try await db.hyperevmHistoryWork(ticket)
        let saved = try XCTUnwrap(continued.first{$0.stream == initial.stream && $0.lane == initial.lane})
        XCTAssertNotNil(saved.cursor)
        try await db.restartHyperEVMHistory(saved,ticket:ticket)
        let restarted = try await db.hyperevmHistoryWork(ticket)
        let fresh = try XCTUnwrap(restarted.first{$0.stream == initial.stream && $0.lane == initial.lane})
        XCTAssertNil(fresh.cursor); XCTAssertEqual(fresh.startTime,initial.startTime); XCTAssertEqual(fresh.endTime,initial.endTime)
        XCTAssertEqual(restarted.filter{$0.stream != initial.stream}.map(\.cursor),initialWork.filter{$0.stream != initial.stream}.map(\.cursor))
        _ = try await db.beginHyperEVMSync(accountID:"wallet:hyperevm")
        do { try await db.restartHyperEVMHistory(saved,ticket:ticket); XCTFail() }
        catch { XCTAssertEqual(error as? StoreError,.staleSync) }
    }

    func testUnknownMetadataLogIsDurableWithoutInventingAssetUnits() async throws {
        let (db,_) = try await fixture(), ticket = try await db.beginHyperEVMSync(accountID:"wallet:hyperevm")
        let work = try await db.hyperevmHistoryWork(ticket)
        let cursor = try XCTUnwrap(work.first{$0.stream == "transfers" && $0.lane == "recent"})
        let hash = "0x"+String(repeating:"a",count:64)
        let row:[String:Any] = ["transaction_hash":hash,"block_number":100,"timestamp":Date(timeIntervalSince1970:floor(cursor.endTime)-1).ISO8601Format(),
            "from":["hash":other],"to":["hash":owner],"token":["address_hash":token],"metadata_unavailable":true,"total":["value":"123"],"log_index":7]
        let raw = try JSONSerialization.data(withJSONObject:["items":[row],"next_page_params":NSNull()])
        let page = try HyperEVMClient.decodeHistory(raw,owner:owner,stream:.transfers,from:cursor.startTime,through:cursor.endTime)
        try await db.commitHyperEVMPage(page,cursor:cursor,ticket:ticket)
        let stored = try await db.pool.read { db in
            (try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM hyperevmEvents"),try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM activity"))
        }
        XCTAssertEqual(stored.0,1); XCTAssertEqual(stored.1,0)
        let remaining = try await db.hyperevmHistoryWork(ticket)
        XCTAssertFalse(remaining.contains{$0.stream == "transfers" && $0.lane == "recent"})
    }
    func testLiveSynchronizerPersistsRealPortfolioAndHistoryAcrossReopen() async throws {
        guard ProcessInfo.processInfo.environment["OATH_HYPEREVM_LIVE"] == "1" else { throw XCTSkip("Opt-in public mainnet read verification") }
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["OATH_ANKR_CONFIG"])
        let config = try PropertyListSerialization.propertyList(from:Data(contentsOf:URL(fileURLWithPath:path)),format:nil) as! [String:String]
        let (db,url) = try await fixture()
        try await db.pool.write { try $0.execute(sql:"UPDATE accounts SET address=? WHERE id='wallet:hyperevm'",arguments:["0x8109ea0f4f8b4a63b97781b5a2bc58ff7a1aa26d"]) }
        let service = try HyperEVMSynchronizer(database:db,apiKey:XCTUnwrap(config["AnkrAPIKey"]))
        do { try await service.refresh(accountID:"wallet:hyperevm") }
        catch { await service.cancel(); throw error }
        for _ in 0..<25 {
            let count = try await db.pool.read { try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM hyperevmEvents") ?? 0 }
            if count > 0 { break }
            try await Task.sleep(for:.milliseconds(200))
        }
        await service.cancel()
        let original = try await db.snapshot(walletID:"wallet",currency:"USD")
        let reopened = try await OathDatabase.open(at:url)
        let saved = try await reopened.snapshot(walletID:"wallet",currency:"USD")
        XCTAssertGreaterThan(saved.holdings.count,2); XCTAssertGreaterThan(saved.totalFiat,0)
        XCTAssertEqual(saved.totalFiat,original.totalFiat)
        XCTAssertEqual(saved.holdings.map(\.amountAtomic),original.holdings.map(\.amountAtomic))
        let counts = try await reopened.pool.read { db in
            (try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM hyperevmEvents") ?? 0,try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM hyperevmHistoryCursors") ?? 0)
        }
        XCTAssertGreaterThan(counts.0,0); XCTAssertEqual(counts.1,6)
        print("HyperEVM live storage: \(saved.holdings.count) portfolio assets, \(counts.0) durable events, six resumable history lanes")
    }

}
