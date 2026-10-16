import XCTest
import OathAnkr
import GRDB
@testable import OathDatabase

@MainActor final class IndexedEVMLedgerTests: XCTestCase {
    private let owner = "0x1111111111111111111111111111111111111111"
    private let other = "0x2222222222222222222222222222222222222222"
    private let token = "0x3333333333333333333333333333333333333333"
    private func fixture(chain: IndexedEVMChain = .unichain) async throws -> (OathDatabase,URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("IndexedEVM-"+UUID().uuidString).appendingPathComponent("test.sqlite")
        let db = try await OathDatabase.open(at:url)
        try await db.seed(networks:[.init(id:chain.rawValue,name:chain.name,family:"evm",symbol:chain.symbol,decimals:18,derivationPath:"m/44'/60'/0'/0/0",logo:"local",sortOrder:0)],
            assets:[.init(id:chain.rawValue+":native",networkID:chain.rawValue,reference:"native",name:chain.name,symbol:chain.symbol,decimals:18,logo:"local")])
        for id in ["wallet","second"] {
            try await db.importWalletIfNeeded(.init(id:id,name:id,kind:"hd",vaultReference:id,createdAt:1),
                accounts:[.init(id:id+":"+chain.rawValue,walletID:id,networkID:chain.rawValue,address:owner,derivationPath:"m/44'/60'/0'/0/0")])
        }
        return (db,url)
    }
    func testMonadSchedulesOnlySupportedStreamsAfterReopening() async throws {
        let (db, url) = try await fixture(chain: .monad)
        _ = try await db.beginIndexedEVMSync(accountID: "wallet:monad")
        try await db.pool.write { sql in
            try sql.execute(sql: "INSERT INTO indexedEVMHistoryCursors(accountID,stream,lane,startTime,endTime) VALUES('wallet:monad','internal-transactions','recent',0,1)")
        }
        let reopened = try await OathDatabase.open(at: url)
        let ticket = try await reopened.beginIndexedEVMSync(accountID: "wallet:monad")
        let work = try await reopened.indexedEVMHistoryWork(ticket)
        XCTAssertEqual(work.count, 4)
        XCTAssertEqual(Set(work.map(\.stream)), ["transactions", "transfers"])
        let legacyComplete = try await reopened.pool.read { try Bool.fetchOne($0, sql: "SELECT complete FROM indexedEVMHistoryCursors WHERE accountID='wallet:monad' AND stream='internal-transactions'") }
        XCTAssertEqual(legacyComplete, false, "Unsupported history must not be falsely marked complete")
    }
    private func inventory(amount:String? = "9007199254740993", complete:Bool = true, block:Int = 100) throws -> IndexedEVMInventory {
        func holding(_ reference:String,_ units:String?,_ decimals:Int)->[String:Any] {
            ["token":["reference":reference,"name":reference == "native" ? "ETH":"Token","symbol":"TKN","decimals":decimals],"amount":units as Any? ?? NSNull()]
        }
        let data = try JSONSerialization.data(withJSONObject:["chain":"unichain","owner":owner,"block":block,"blockHash":"0x"+String(repeating:"a",count:64),
            "observedAt":Date().timeIntervalSinceReferenceDate,"holdings":[holding("native","1000000000000000000",18),holding(token,amount,6)],"complete":complete,"raw":Data("{\"index\":[]}".utf8).base64EncodedString()])
        return try JSONDecoder().decode(IndexedEVMInventory.self,from:data)
    }
    func testPersistencePortfolioExactUnitsPricesAndWalletIsolation() async throws {
        let (db,url) = try await fixture(), ticket = try await db.beginIndexedEVMSync(accountID:"wallet:unichain")
        try await db.commitIndexedEVMInventory(inventory(),ticket:ticket,catalog:.init(chain:.unichain,ids:[token:"fixture"]))
        try await db.savePrices([.init(assetID:"unichain:native",currency:"USD",value:"2500",observedAt:Date().timeIntervalSince1970,source:"Coinbase")])
        let reopened = try await OathDatabase.open(at:url), snapshot = try await reopened.snapshot(walletID:"wallet",currency:"USD")
        XCTAssertEqual(snapshot.holdings.first{$0.reference == token}?.amountAtomic,"9007199254740993")
        XCTAssertEqual(snapshot.holdings.first{$0.reference == "native"}?.name,"Unichain")
        XCTAssertEqual(snapshot.totalFiat,2500)
        let second = try await reopened.snapshot(walletID:"second",currency:"USD")
        XCTAssertNil(second.holdings.first?.amountAtomic)
        let balance = try await reopened.balance(accountID:"wallet:unichain",assetID:"unichain:"+token)
        XCTAssertEqual(balance?.amountAtomic,"9007199254740993")
    }
    func testPartialInventoryPreservesCachedTokenAndSuccessfulZeroReplacesIt() async throws {
        let (db,_) = try await fixture()
        var ticket = try await db.beginIndexedEVMSync(accountID:"wallet:unichain")
        try await db.commitIndexedEVMInventory(inventory(),ticket:ticket,catalog:.init(chain:.unichain,ids:[token:"fixture"]))
        ticket = try await db.beginIndexedEVMSync(accountID:"wallet:unichain")
        try await db.commitIndexedEVMInventory(inventory(amount:nil,complete:false,block:101),ticket:ticket,catalog:.empty(.unichain))
        var snapshot = try await db.snapshot(walletID:"wallet",currency:"USD")
        XCTAssertEqual(snapshot.holdings.first{$0.reference == token}?.amountAtomic,"9007199254740993")
        let complete = try await db.pool.read { try Int.fetchOne($0,sql:"SELECT complete FROM indexedEVMSync WHERE accountID='wallet:unichain'") }
        XCTAssertEqual(complete,0)
        ticket = try await db.beginIndexedEVMSync(accountID:"wallet:unichain")
        try await db.commitIndexedEVMInventory(inventory(amount:"0",block:102),ticket:ticket,catalog:.init(chain:.unichain,ids:[token:"fixture"]))
        snapshot = try await db.snapshot(walletID:"wallet",currency:"USD")
        XCTAssertEqual(snapshot.holdings.first{$0.reference == token}?.amountAtomic,"0")
    }
    func testUnlistedTokenHiddenUnlessExplicitlyAddedAndStaleRunRejected() async throws {
        let (db,_) = try await fixture()
        let old = try await db.beginIndexedEVMSync(accountID:"wallet:unichain")
        let ticket = try await db.beginIndexedEVMSync(accountID:"wallet:unichain")
        do { try await db.commitIndexedEVMInventory(inventory(),ticket:old,catalog:.empty(.unichain)); XCTFail() }
        catch { XCTAssertEqual(error as? StoreError,.staleSync) }
        try await db.commitIndexedEVMInventory(inventory(),ticket:ticket,catalog:.empty(.unichain))
        var snapshot = try await db.snapshot(walletID:"wallet",currency:"USD")
        XCTAssertFalse(snapshot.holdings.contains{$0.reference == token})
        let stored = try await db.asset(networkID:"unichain",reference:token)
        let asset = try XCTUnwrap(stored)
        try await db.trackAsset(asset,walletID:"wallet")
        snapshot = try await db.snapshot(walletID:"wallet",currency:"USD")
        XCTAssertEqual(snapshot.holdings.first{$0.reference == token}?.amountAtomic,"9007199254740993")
    }
    func testHistoryCommitsCursorAndEventsTogetherThenResumesWithoutDuplicateActivity() async throws {
        let (db,url) = try await fixture(), ticket = try await db.beginIndexedEVMSync(accountID:"wallet:unichain")
        let cursors = try await db.indexedEVMHistoryWork(ticket)
        let cursor = try XCTUnwrap(cursors.first{$0.stream == "transactions" && $0.lane == "recent"})
        let time = Date(timeIntervalSince1970:floor(cursor.endTime)-1).ISO8601Format(), hash = "0x"+String(repeating:"a",count:64)
        let row: [String:Any] = ["hash":hash,"block_number":100,"timestamp":time,"from":["hash":other],"to":["hash":owner],"status":"ok","value":"12345","fee":["value":"321"]]
        let raw = try JSONSerialization.data(withJSONObject:["items":[row],"next_page_params":["block_number":99]])
        let page = try IndexedEVMClient.decodeHistory(raw,chain:.unichain,owner:owner,stream:.transactions,from:cursor.startTime,through:cursor.endTime)
        try await db.commitIndexedEVMPage(page,cursor:cursor,ticket:ticket)
        let reopened = try await OathDatabase.open(at:url)
        let nextTicket = try await reopened.beginIndexedEVMSync(accountID:"wallet:unichain")
        let resumed = try await reopened.indexedEVMHistoryWork(nextTicket)
        let next = try XCTUnwrap(resumed.first{$0.stream == "transactions" && $0.lane == "recent"})
        XCTAssertEqual(next.cursor,page.next); XCTAssertEqual(next.endTime,cursor.endTime)
        let final = try IndexedEVMClient.decodeHistory(JSONSerialization.data(withJSONObject:["items":[row],"next_page_params":NSNull() ]),chain:.unichain,owner:owner,stream:.transactions,from:next.startTime,through:next.endTime)
        try await reopened.commitIndexedEVMPage(final,cursor:next,ticket:nextTicket)
        let history = try await reopened.assetHistory(walletID:"wallet",accountID:"wallet:unichain",assetID:"unichain:native")
        XCTAssertEqual(history.count,1); XCTAssertEqual(history.first?.amountAtomic,"12345")
        let counts = try await reopened.snapshot(walletID:"wallet",currency:"USD")
        XCTAssertEqual(counts.holdings.first?.transactionCount,1)
    }
    func testResetErasesIndexedEVMWalletDataButPreservesPublicMarketCache() async throws {
        let (db,_) = try await fixture(), ticket = try await db.beginIndexedEVMSync(accountID:"wallet:unichain")
        try await db.commitIndexedEVMInventory(inventory(),ticket:ticket,catalog:.init(chain:.unichain,ids:[token:"fixture"]))
        try await db.saveMarketCache(.init(key:"unichain.catalog",source:"CoinGecko",payload:Data("{}".utf8),fetchedAt:Date().timeIntervalSince1970))
        let reset = try await db.beginWalletReset()
        try await db.eraseWalletData(resetID:reset); try await db.finishWalletReset(resetID:reset)
        let rows = try await db.pool.read { db in try ["indexedEVMSync","indexedEVMHoldings","indexedEVMHistoryCursors","indexedEVMEvents","indexedEVMPages"].map { try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM \($0)") ?? -1 } }
        XCTAssertEqual(rows,[0,0,0,0,0])
        let cache = try await db.marketCache(key:"unichain.catalog"); XCTAssertNotNil(cache)
    }

    func testExpiredCursorRestartsOnlyItsWindowAndRejectsStaleRun() async throws {
        let (db,_) = try await fixture(), ticket = try await db.beginIndexedEVMSync(accountID:"wallet:unichain")
        let initialWork = try await db.indexedEVMHistoryWork(ticket)
        let initial = try XCTUnwrap(initialWork.first{$0.stream == "transfers" && $0.lane == "backfill"})
        let raw = try JSONSerialization.data(withJSONObject:["items":[],"next_page_params":["block_number":99]])
        let page = try IndexedEVMClient.decodeHistory(raw,chain:.unichain,owner:owner,stream:.transfers,from:initial.startTime,through:initial.endTime)
        try await db.commitIndexedEVMPage(page,cursor:initial,ticket:ticket)
        let continued = try await db.indexedEVMHistoryWork(ticket)
        let saved = try XCTUnwrap(continued.first{$0.stream == initial.stream && $0.lane == initial.lane})
        XCTAssertNotNil(saved.cursor)
        try await db.restartIndexedEVMHistory(saved,ticket:ticket)
        let restarted = try await db.indexedEVMHistoryWork(ticket)
        let fresh = try XCTUnwrap(restarted.first{$0.stream == initial.stream && $0.lane == initial.lane})
        XCTAssertNil(fresh.cursor); XCTAssertEqual(fresh.startTime,initial.startTime); XCTAssertEqual(fresh.endTime,initial.endTime)
        XCTAssertEqual(restarted.filter{$0.stream != initial.stream}.map(\.cursor),initialWork.filter{$0.stream != initial.stream}.map(\.cursor))
        _ = try await db.beginIndexedEVMSync(accountID:"wallet:unichain")
        do { try await db.restartIndexedEVMHistory(saved,ticket:ticket); XCTFail() }
        catch { XCTAssertEqual(error as? StoreError,.staleSync) }
    }

    func testUnknownMetadataLogIsDurableWithoutInventingAssetUnits() async throws {
        let (db,_) = try await fixture(), ticket = try await db.beginIndexedEVMSync(accountID:"wallet:unichain")
        let work = try await db.indexedEVMHistoryWork(ticket)
        let cursor = try XCTUnwrap(work.first{$0.stream == "transfers" && $0.lane == "recent"})
        let hash = "0x"+String(repeating:"a",count:64)
        let row:[String:Any] = ["transaction_hash":hash,"block_number":100,"timestamp":Date(timeIntervalSince1970:floor(cursor.endTime)-1).ISO8601Format(),
            "from":["hash":other],"to":["hash":owner],"token":["address_hash":token],"metadata_unavailable":true,"total":["value":"123"],"log_index":7]
        let raw = try JSONSerialization.data(withJSONObject:["items":[row],"next_page_params":NSNull()])
        let page = try IndexedEVMClient.decodeHistory(raw,chain:.unichain,owner:owner,stream:.transfers,from:cursor.startTime,through:cursor.endTime)
        try await db.commitIndexedEVMPage(page,cursor:cursor,ticket:ticket)
        let stored = try await db.pool.read { db in
            (try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM indexedEVMEvents"),try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM activity"))
        }
        XCTAssertEqual(stored.0,1); XCTAssertEqual(stored.1,0)
        let remaining = try await db.indexedEVMHistoryWork(ticket)
        XCTAssertFalse(remaining.contains{$0.stream == "transfers" && $0.lane == "recent"})
    }
    func testLiveSynchronizerPersistsRealPortfolioAndHistoryAcrossReopen() async throws {
        guard ProcessInfo.processInfo.environment["OATH_UNICHAIN_LIVE"] == "1" else { throw XCTSkip("Opt-in public mainnet read verification") }
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["OATH_ANKR_CONFIG"])
        let config = try PropertyListSerialization.propertyList(from:Data(contentsOf:URL(fileURLWithPath:path)),format:nil) as! [String:String]
        let (db,url) = try await fixture()
        try await db.pool.write { try $0.execute(sql:"UPDATE accounts SET address=? WHERE id='wallet:unichain'",arguments:["0xbeeb9c168ab8bd17e342abb0770c90855ed13221"]) }
        let service = try IndexedEVMSynchronizer(database:db,chain:.unichain,apiKey:XCTUnwrap(config["AnkrAPIKey"]))
        do { try await service.refresh(accountID:"wallet:unichain") }
        catch { await service.cancel(); throw error }
        for _ in 0..<25 {
            let count = try await db.pool.read { try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM indexedEVMEvents") ?? 0 }
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
            (try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM indexedEVMEvents") ?? 0,try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM indexedEVMHistoryCursors") ?? 0)
        }
        XCTAssertGreaterThan(counts.0,0); XCTAssertEqual(counts.1,6)
        print("IndexedEVM live storage: \(saved.holdings.count) portfolio assets, \(counts.0) durable events, six resumable history lanes")
    }
    func testCrossNetworkInventoryCatalogAndPageAreRejected() async throws {
        let (db,_) = try await fixture(), ticket = try await db.beginIndexedEVMSync(accountID:"wallet:unichain")
        do { try await db.commitIndexedEVMInventory(inventory(),ticket:ticket,catalog:.empty(.monad)); XCTFail() }
        catch { XCTAssertEqual(error as? StoreError,.conflictingIdentity) }
        let work = try await db.indexedEVMHistoryWork(ticket)
        let cursor = try XCTUnwrap(work.first)
        let page = try IndexedEVMClient.decodeHistory(Data("{\"items\":[],\"next_page_params\":null}".utf8),chain:.monad,owner:owner,stream:.transfers)
        do { try await db.commitIndexedEVMPage(page,cursor:cursor,ticket:ticket); XCTFail() }
        catch { XCTAssertNotNil(error as? AnkrError) }
    }

}
