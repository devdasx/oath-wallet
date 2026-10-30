import Foundation
import XCTest
import GRDB
@testable import OathDatabase
@testable import OathAnkr

@MainActor final class StellarLedgerTests:XCTestCase {
    let owner = "GBEBCRCJ5VX7GERSGJ5XGJX7K2CHNVQB67K2KGCX7RFGMCBIIZQ5E4GY"
    let ref = "CB23WRDQWGSP6YPMY4UV5C4OW5CBTXKYN3XEATG7KJEZCXMJBYEHOUOV"
    var token:StellarToken { .init(reference:ref,name:"KALE",symbol:"KALE",decimals:7,logo:nil) }
    var catalog:StellarCatalog { .init(ids:[ref:"fixture","native":"stellar"]) }
    func fixture() async throws -> (OathDatabase,URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("StellarLedger-"+UUID().uuidString)
        let db = try await OathDatabase.open(at:folder.appendingPathComponent("wallet.sqlite"))
        try await db.seed(networks:[.init(id:"stellar",name:"Stellar",family:"account",symbol:"XLM",decimals:7,derivationPath:"m/44'/148'/0'",logo:"stellar",sortOrder:0)],assets:[.init(id:"stellar:native",networkID:"stellar",reference:"native",name:"Stellar",symbol:"XLM",decimals:7)])
        for i in 1...2 { try await db.importWalletIfNeeded(.init(id:"w\(i)",name:"Test",kind:"hd",vaultReference:"fixture\(i)",createdAt:1),accounts:[.init(id:"a\(i)",walletID:"w\(i)",networkID:"stellar",address:owner,derivationPath:"m/44'/148'/0'")]) }
        try await db.saveMarketCache(.init(key:"stellar.catalog",source:"fixture verified catalog",payload:JSONEncoder().encode(catalog),fetchedAt:1))
        return (db,folder)
    }
    func inventory(time:Double = 100,includeToken:Bool = true) -> StellarInventory {
        .init(owner:owner,ledger:.init(height:Int64(time),timestamp:time),exists:true,holdings:[.init(reference:"native",token:.native,amount:"19832570",raw:.null)]+(includeToken ? [.init(reference:ref,token:token,amount:"2909192447",raw:.null)]:[]),verified:[],prices:[],observedAt:Date(timeIntervalSince1970:time),raw:Data())
    }
    func event(_ id:String,hash:String = "tx",amount:String = "10",reference:String? = nil,metadata:Bool = true,kind:String = "mint",successful:Bool = true,direction:String = "incoming") -> StellarEvent {
        let r = reference ?? ref
        return .init(id:id,hash:hash,checkpoint:100,timestamp:100,reference:r,token:metadata ? (r == "native" ? .native:token):nil,amount:amount,direction:direction,kind:kind,successful:successful,counterparty:nil,raw:.null)
    }
    func page(_ events:[StellarEvent],cursor:StellarHistoryCursor,next:String? = nil,complete:Bool = false) -> StellarEventPage {
        .init(events:events,next:next,complete:complete,startLedger:cursor.startLedger,endLedger:cursor.endLedger,raw:Data())
    }
    func testBalancesExactOfflineWhitelistAndWalletIsolation() async throws {
        let (db,folder) = try await fixture(); defer { try? FileManager.default.removeItem(at:folder) }
        let ticket = try await db.beginStellarSync(accountID:"a1",latestLedger:200)
        try await db.commitStellarInventory(inventory(),ticket:ticket,catalog:catalog)
        try await db.savePrices([.init(assetID:"stellar:"+ref,currency:"USD",value:"0.01",observedAt:100,source:"fixture")])
        let snapshot = try await db.snapshot(walletID:"w1",currency:"USD")
        XCTAssertEqual(snapshot.holdings.first{$0.reference == ref}?.amountAtomic,"2909192447")
        let other = try await db.snapshot(walletID:"w2",currency:"USD"); XCTAssertNil(other.holdings.first?.amountAtomic)
        let reopened = try await OathDatabase.open(at:folder.appendingPathComponent("wallet.sqlite"))
        let cached = try await reopened.snapshot(walletID:"w1",currency:"USD"); XCTAssertEqual(snapshot.holdings,cached.holdings)
        try await db.commitStellarInventory(inventory(time:200),ticket:ticket,catalog:.empty)
        let hidden = try await db.snapshot(walletID:"w1",currency:"USD"); XCTAssertEqual(hidden.holdings.count,1)
    }
    func testFailureDoesNotEraseBalanceAndStaleRunRejected() async throws {
        let (db,folder) = try await fixture(); defer { try? FileManager.default.removeItem(at:folder) }
        let ticket = try await db.beginStellarSync(accountID:"a1",latestLedger:200)
        try await db.commitStellarInventory(inventory(),ticket:ticket,catalog:catalog)
        try await db.failStellarSync(ticket,history:false,code:"transport")
        let saved = try await db.balance(accountID:"a1",assetID:"stellar:"+ref); XCTAssertEqual(saved?.amountAtomic,"2909192447")
        try await db.commitStellarInventory(inventory(time:200,includeToken:false),ticket:ticket,catalog:catalog)
        let cleared = try await db.balance(accountID:"a1",assetID:"stellar:"+ref); XCTAssertEqual(cleared?.amountAtomic,"0")
        do { try await db.commitStellarInventory(inventory(),ticket:ticket,catalog:catalog); XCTFail() } catch { XCTAssertEqual(error as? StoreError,.staleSync) }
        _ = try await db.beginStellarSync(accountID:"a1",latestLedger:300)
        do { try await db.commitStellarInventory(inventory(time:300),ticket:ticket,catalog:catalog); XCTFail() } catch { XCTAssertEqual(error as? StoreError,.staleSync) }
    }
    func testSplitTransactionsAndEventReplayDoNotDoubleCount() async throws {
        let (db,folder) = try await fixture(); defer { try? FileManager.default.removeItem(at:folder) }
        let ticket = try await db.beginStellarSync(accountID:"a1",latestLedger:200)
        var cursor = try await db.stellarHistoryWork(ticket).first!
        try await db.commitStellarPage(page([event("1")],cursor:cursor,next:"1"),cursor:cursor,ticket:ticket)
        cursor = try await db.stellarHistoryWork(ticket).first!
        try await db.commitStellarPage(page([event("1"),event("2",amount:"20")],cursor:cursor,next:"2"),cursor:cursor,ticket:ticket)
        let history = try await db.assetHistory(walletID:"w1",accountID:"a1",assetID:"stellar:"+ref)
        XCTAssertEqual(history.count,1); XCTAssertEqual(history.first?.amountAtomic,"30")
        cursor = try await db.stellarHistoryWork(ticket).first!
        try await db.commitStellarPage(page([],cursor:cursor,next:"2",complete:true),cursor:cursor,ticket:ticket)
        let next = try await db.beginStellarSync(accountID:"a1",latestLedger:300)
        let fresh = try await db.stellarHistoryWork(next).first!
        XCTAssertEqual(fresh.startLedger,201); XCTAssertEqual(fresh.endLedger,300); XCTAssertNil(fresh.cursor)
    }
    func testUnresolvedMetadataReprojectsAndFeeOnlyFailure() async throws {
        let (db,folder) = try await fixture(); defer { try? FileManager.default.removeItem(at:folder) }
        let ticket = try await db.beginStellarSync(accountID:"a1",latestLedger:200)
        let cursor = try await db.stellarHistoryWork(ticket).first!
        let events = [event("1",metadata:false),event("2",hash:"failed",amount:"100",reference:"native",kind:"fee",successful:false,direction:"outgoing")]
        try await db.commitStellarPage(page(events,cursor:cursor,next:"2"),cursor:cursor,ticket:ticket)
        try await db.commitStellarInventory(inventory(),ticket:ticket,catalog:catalog)
        let history = try await db.assetHistory(walletID:"w1",accountID:"a1",assetID:"stellar:"+ref); XCTAssertEqual(history.count,1)
        let failure = try await db.pool.read{try TransactionRecord.fetchOne($0,key:"stellar:failed")}
        XCTAssertEqual(failure?.state,"failed"); XCTAssertEqual(failure?.feeAtomic,"100")
    }
    func testFeeRefundAndMemoAmountsStayExactAcrossPages() async throws {
        let (db,folder) = try await fixture(); defer { try? FileManager.default.removeItem(at:folder) }
        let ticket = try await db.beginStellarSync(accountID:"a1",latestLedger:200)
        var cursor = try await db.stellarHistoryWork(ticket).first!
        try await db.commitStellarPage(page([event("1",amount:"100",reference:"native",kind:"fee",direction:"outgoing"),event("2",amount:"1000")],cursor:cursor,next:"2"),cursor:cursor,ticket:ticket)
        cursor = try await db.stellarHistoryWork(ticket).first!
        try await db.commitStellarPage(page([event("3",amount:"-7",reference:"native",kind:"fee",direction:"outgoing")],cursor:cursor,next:"3"),cursor:cursor,ticket:ticket)
        let tx = try await db.pool.read{try TransactionRecord.fetchOne($0,key:"stellar:tx")}
        XCTAssertEqual(tx?.feeAtomic,"93")
        let history = try await db.assetHistory(walletID:"w1",accountID:"a1",assetID:"stellar:"+ref)
        XCTAssertEqual(history.first?.amountAtomic,"1000")
    }
    func testFeeOnlyFirstPageIsReplacedAndOtherWalletCannotEraseFee() async throws {
        let (db,folder) = try await fixture(); defer { try? FileManager.default.removeItem(at:folder) }
        let ticket = try await db.beginStellarSync(accountID:"a1",latestLedger:200)
        var cursor = try await db.stellarHistoryWork(ticket).first!
        try await db.commitStellarPage(page([event("1",amount:"100",reference:"native",kind:"fee",direction:"outgoing")],cursor:cursor,next:"1"),cursor:cursor,ticket:ticket)
        cursor = try await db.stellarHistoryWork(ticket).first!
        try await db.commitStellarPage(page([event("2",amount:"1000")],cursor:cursor,next:"2"),cursor:cursor,ticket:ticket)
        let history = try await db.assetHistory(walletID:"w1",accountID:"a1",assetID:"stellar:native")
        XCTAssertTrue(history.isEmpty)
        let other = try await db.beginStellarSync(accountID:"a2",latestLedger:200)
        let otherCursor = try await db.stellarHistoryWork(other).first!
        try await db.commitStellarPage(page([event("2",amount:"1000")],cursor:otherCursor,next:"2"),cursor:otherCursor,ticket:other)
        let tx = try await db.pool.read{try TransactionRecord.fetchOne($0,key:"stellar:tx")}
        XCTAssertEqual(tx?.feeAtomic,"100")
    }
    func testUpgradeFromV21PreservesExistingWalletAndSettings() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("StellarMigration-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:folder) }
        let url = folder.appendingPathComponent("wallet.sqlite"), old = try DatabaseQueue(path:folder.appendingPathComponent("wallet.sqlite").path)
        try Schema.migrator.migrate(old,upTo:"v21_xrpl_ledger")
        try await old.write { db in
            try db.execute(sql: "INSERT INTO wallets(id,name,kind,vaultReference,createdAt,backedUp) VALUES(?,?,?,?,?,?)", arguments: ["existing", "Existing", "hd", "fixture", 1, false])
            try SettingRecord(key:"currency",value:"JOD",updatedAt:1).insert(db)
        }
        let upgraded = try await OathDatabase.open(at:url)
        let wallet = try await upgraded.wallet("existing"); XCTAssertEqual(wallet?.name,"Existing")
        let saved = try await upgraded.pool.read { db in
            (try String.fetchOne(db,sql:"SELECT value FROM settings WHERE key='currency'"),try db.tableExists("stellarHoldings"))
        }
        XCTAssertEqual(saved.0,"JOD"); XCTAssertTrue(saved.1)
    }
    func testResetKeepsPricesAndRejectsLatePages() async throws {
        let (db,folder) = try await fixture(); defer { try? FileManager.default.removeItem(at:folder) }
        let ticket = try await db.beginStellarSync(accountID:"a1",latestLedger:200)
        try await db.commitStellarInventory(inventory(),ticket:ticket,catalog:catalog)
        let cursor = try await db.stellarHistoryWork(ticket).first!
        try await db.savePrices([.init(assetID:"stellar:native",currency:"USD",value:"0.2",observedAt:100,source:"fixture")])
        let reset = try await db.beginWalletReset(); try await db.eraseWalletData(resetID:reset); try await db.finishWalletReset(resetID:reset)
        do { try await db.commitStellarPage(page([event("1")],cursor:cursor,next:"1"),cursor:cursor,ticket:ticket); XCTFail() } catch {}
        let price = try await db.latestPrice(assetID:"stellar:native",currency:"USD"); XCTAssertEqual(price?.value,"0.2")
    }
    func testOlderProviderQuoteDoesNotFailTheNextWalletRefresh() async throws {
        let (db,folder) = try await fixture(); defer { try? FileManager.default.removeItem(at:folder) }
        try await StellarSynchronizer.save([.init(reference:"native",usd:"0.25",source:"Coinbase",fetchedAt:Date(timeIntervalSince1970:200))],database:db)
        try await StellarSynchronizer.save([.init(reference:"native",usd:"0.2",source:"ANKR Stellar",fetchedAt:Date(timeIntervalSince1970:100))],database:db)
        let price = try await db.latestPrice(assetID:"stellar:native",currency:"USD")
        XCTAssertEqual(price?.value,"0.25"); XCTAssertEqual(price?.source,"Coinbase")
    }
    func testLiveProductionSyncAndOfflineCache() async throws {
        guard let key = ProcessInfo.processInfo.environment["OATH_STELLAR_DATABASE_KEY"] else { throw XCTSkip("Opt-in Stellar production database test") }
        let (db,folder) = try await fixture(); defer { try? FileManager.default.removeItem(at:folder) }
        let service = try StellarSynchronizer(database:db,apiKey:key)
        try await service.refresh(accountID:"a1")
        try await Task.sleep(for:.seconds(2)); await service.cancel()
        let inventory = try await db.stellarInventory(accountID:"a1"); XCTAssertGreaterThan(try XCTUnwrap(inventory).holdings.count,1)
        let current = try await db.snapshot(walletID:"w1",currency:"USD"); XCTAssertNotNil(current.holdings.first{$0.reference == "native"}?.usdPrice)
        let reopened = try await OathDatabase.open(at:folder.appendingPathComponent("wallet.sqlite"))
        let offline = try await reopened.snapshot(walletID:"w1",currency:"USD"); XCTAssertEqual(current.holdings,offline.holdings)
        let count = try await db.pool.read{try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM stellarEvents WHERE accountID='a1'")!}; XCTAssertGreaterThan(count,0)
        try await assertActivityDetails(db, walletID: "w1")
            print("Stellar production persisted \(inventory!.holdings.count) holdings and \(count) events; offline snapshot matches")
        // A separate small public account drains both streams to their terminal
        // pages, rather than treating the cancelled large backfill as complete.
        try await db.importWalletIfNeeded(.init(id:"w3",name:"Public fixture",kind:"watchOnly",vaultReference:"public-fixture",createdAt:1),accounts:[.init(id:"a3",walletID:"w3",networkID:"stellar",address:"GA223H7O26KC7NWDEH6R4D5ITI35I4R7BH5VDLPFTSKMWH2RUZD474TJ",derivationPath:"")])
        try await service.refresh(accountID:"a3")
        await service.waitForHistory(accountID:"a3")
        let completion = try await db.pool.read { db in
            (try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM stellarHistoryCursors WHERE accountID='a3' AND complete=0")!,
             try String.fetchOne(db,sql:"SELECT historyFailure FROM stellarSync WHERE accountID='a3'"),
             try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM stellarEvents WHERE accountID='a3'")!)
        }
        XCTAssertEqual(completion.0,0); XCTAssertNil(completion.1); XCTAssertGreaterThan(completion.2,0)
        try await assertActivityDetails(db, walletID: "w3")
        let smallHistory = try await db.history(walletID: "w3", limit: 200)
        XCTAssertTrue(smallHistory.contains { $0.assetID == "stellar:native" })
        print("Stellar complete archived history: \(completion.2) events, both cursor streams exhausted")
    }
}

private actor StellarRefreshRetryTransport:AnkrTransport {
    let failsPersistently:Bool
    let owner:String
    var headCalls = 0
    init(owner:String,failsPersistently:Bool) { self.owner = owner; self.failsPersistently = failsPersistently }
    func send(_ request:URLRequest) async throws -> (Data,Int) {
        let body:Any
        if request.url?.host == "api.coinbase.com" { body = ["data":["base":"XLM","currency":"USD","amount":"0.2"]] }
        else if request.httpMethod == "POST" {
            let input = try JSONDecoder().decode(StellarJSON.self,from:request.httpBody!)
            if input["method"].string == "stellar_getEvents" {
                if input["params"]["limit"].text == "1" {
                    headCalls += 1
                    if failsPersistently || headCalls == 1 { throw AnkrError.transport }
                }
                body = ["result":["latestLedger":200,"events":NSNull()]]
            } else {
                XCTAssertEqual(input["method"].string,"stellar_getAccountBalance")
                body = ["result":["totalCount":1,"syncStatus":["blockNumber":200,"timestamp":200],"assets":[[
                    "blockchain":"stellar_soroban","holderAddress":owner,"contractAddress":StellarIdentity.nativeContract,
                    "tokenDecimals":7,"balanceRawInteger":"20000000","balance":"2"]]]]
            }
        } else if request.url?.path.contains("accounts/") == true {
            body = ["account_id":owner,"balances":[["asset_type":"native","balance":"2"]]]
        } else { body = ["network_passphrase":StellarIdentity.network,"history_latest_ledger":200,"history_latest_ledger_closed_at":"2026-10-25T00:00:00Z"] }
        return (try JSONSerialization.data(withJSONObject:body),200)
    }
}
extension StellarLedgerTests {
    func testRefreshRecoversFirstHeadFailureAndPersistentOutagePreservesCache() async throws {
        for persistent in [false,true] {
            let (db,_) = try await fixture()
            let ticket = try await db.beginStellarSync(accountID:"a1",latestLedger:200)
            try await db.commitStellarInventory(inventory(),ticket:ticket,catalog:catalog)
            try await db.saveMarketCache(.init(key:"stellar.catalog",source:"fixture",payload:JSONEncoder().encode(catalog),fetchedAt:Date().timeIntervalSince1970))
            let transport = StellarRefreshRetryTransport(owner:owner,failsPersistently:persistent)
            let service = StellarSynchronizer(database:db,client:try StellarClient(apiKey:"fixture",transport:transport),markets:StellarMarkets(transport:transport))
            do { try await service.refresh(accountID:"a1"); XCTAssertFalse(persistent) }
            catch { XCTAssertTrue(persistent); XCTAssertEqual(error as? StellarError,.transport) }
            await service.waitForHistory(accountID:"a1")
            let saved = try await db.stellarInventory(accountID:"a1")
            XCTAssertEqual(saved?.holdings.first { $0.reference == "native" }?.amount,persistent ? "19832570":"20000000")
            if persistent { XCTAssertEqual(saved?.holdings.first { $0.reference == ref }?.amount,"2909192447") }
            let calls = await transport.headCalls; XCTAssertEqual(calls,persistent ? 3:2)
            let other = try await db.stellarInventory(accountID:"a2"); XCTAssertNil(other)
            await service.cancel()
        }
    }
}
