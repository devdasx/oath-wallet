import Foundation
import XCTest
import GRDB
@testable import OathDatabase
@testable import OathAnkr

@MainActor final class TonLedgerTests: XCTestCase {
    let owner = "0:23fa979918f1fe702db9100bf843e87c7015eccd39a4721e9b6bac170bc04ce3"
    let other = "0:f8b8635d0786b77f9da660e65fd31d670a675dd4302facba692f46b571eb5360"
    var token: TonToken { .init(reference:TonIdentity.usdt,name:"Tether USD",symbol:"USD₮",decimals:6,verified:true) }
    func fixture() async throws -> (OathDatabase,URL) {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("TonLedger-"+UUID().uuidString)
        let db=try await OathDatabase.open(at:folder.appendingPathComponent("wallet.sqlite"))
        try await db.seed(networks:[.init(id:"ton",name:"Gram",family:"account",symbol:"GRAM",decimals:9,derivationPath:"m/44'/607'/0'",logo:"ton",sortOrder:0)],assets:[.init(id:"ton:native",networkID:"ton",reference:"native",name:"Gram",symbol:"GRAM",decimals:9)])
        for i in 1...2 { try await db.importWalletIfNeeded(.init(id:"w\(i)",name:"Public fixture",kind:"hd",vaultReference:"test\(i)",createdAt:1),accounts:[.init(id:"a\(i)",walletID:"w\(i)",networkID:"ton",address:try TonIdentity.friendly(owner,bounceable:i==1),derivationPath:"m/44'/607'/0'")]) }
        return (db,folder)
    }
    func inventory(complete: Bool=true, failed: Bool=false, time: Double=10) -> TonInventory {
        .init(owner:owner,holdings:[.init(token:.native,wallet:nil,amount:"59570010157331145")]+(failed ? [] : [.init(token:token,wallet:other,amount:"879187990649145"),.init(token:.init(reference:other,name:"Unverified",symbol:"X",decimals:9),wallet:other,amount:"10000")]),prices:[],failedReferences:failed ? [TonIdentity.usdt] : [],discoveryComplete:complete,observedAt:Date(timeIntervalSince1970:time),raw:Data("{}".utf8))
    }
    func tx(lt: Int64, native: Bool=false, failed: Bool=false) -> TonTransaction {
        .init(hash:String(format:"%064llx",lt),lt:lt,timestamp:Double(lt),failed:failed,fee:native ? "58" : nil,events:[.init(index:native ? 0 : 1_000_000,token:native ? .native : token,from:other,to:owner,amount:native ? "1" : "5000000")],raw:Data("{}".utf8))
    }
    func page(_ transactions: [TonTransaction], next: Int64?=nil) -> TonHistoryPage {
        .init(transactions:transactions,next:next,head:transactions.map(\.lt).max(),raw:Data("{}".utf8))
    }
    func testExactInventoryWhitespaceFreeIdentitySpamVisibilityAndOfflineCache() async throws {
        let (db,folder)=try await fixture();defer{try? FileManager.default.removeItem(at:folder)}
        let ticket=try await db.beginTonSync(accountID:"a1")
        try await db.commitTonInventory(inventory(),ticket:ticket)
        try await db.savePrices([.init(assetID:"ton:native",currency:"USD",value:"1.45",observedAt:1,source:"fixture")])
        let snapshot=try await db.snapshot(walletID:"w1",currency:"USD")
        XCTAssertEqual(snapshot.holdings.count,2)
        XCTAssertEqual(snapshot.holdings.first{$0.reference=="native"}?.amountAtomic,"59570010157331145")
        XCTAssertNotNil(snapshot.holdings.first{$0.reference=="native"}?.fiatDisplayValue)
        XCTAssertEqual(snapshot.holdings.first{$0.reference==TonIdentity.usdt}?.amountAtomic,"879187990649145")
        let others=try await db.snapshot(walletID:"w2",currency:"USD");XCTAssertNil(others.holdings.first?.amountAtomic)
        let reopened=try await OathDatabase.open(at:folder.appendingPathComponent("wallet.sqlite"))
        let offline=try await reopened.snapshot(walletID:"w1",currency:"USD");XCTAssertEqual(offline.holdings,snapshot.holdings)
    }
    func testFailedDiscoveryAndIndividualFailureNeverEraseBalances() async throws {
        let (db,folder)=try await fixture();defer{try? FileManager.default.removeItem(at:folder)}
        let ticket=try await db.beginTonSync(accountID:"a1")
        try await db.commitTonInventory(inventory(),ticket:ticket)
        try await db.commitTonInventory(inventory(complete:false,failed:true,time:20),ticket:ticket)
        var balance=try await db.balance(accountID:"a1",assetID:"ton:"+TonIdentity.usdt);XCTAssertEqual(balance?.amountAtomic,"879187990649145")
        try await db.commitTonInventory(inventory(failed:true,time:30),ticket:ticket)
        balance=try await db.balance(accountID:"a1",assetID:"ton:"+TonIdentity.usdt);XCTAssertEqual(balance?.amountAtomic,"879187990649145")
        let empty=TonInventory(owner:owner,holdings:[.init(token:.native,wallet:nil,amount:"0")],prices:[],failedReferences:[],discoveryComplete:true,observedAt:Date(timeIntervalSince1970:40),raw:Data())
        try await db.commitTonInventory(empty,ticket:ticket)
        balance=try await db.balance(accountID:"a1",assetID:"ton:"+TonIdentity.usdt);XCTAssertEqual(balance?.amountAtomic,"0")
    }
    func testRecentGapBackfillPaginationAndIdempotence() async throws {
        let (db,folder)=try await fixture();defer{try? FileManager.default.removeItem(at:folder)}
        var ticket=try await db.beginTonSync(accountID:"a1")
        var cursor=try await db.tonHistoryWork(ticket).first{$0.stream=="jettons"}!
        try await db.commitTonPage(page([tx(lt:100)],next:100),cursor:cursor,ticket:ticket)
        cursor=try await db.tonHistoryWork(ticket).first{$0.stream=="jettons"}!
        XCTAssertEqual(cursor.lane,"backfill")
        XCTAssertEqual(cursor.beforeLT,100)
        ticket=try await db.beginTonSync(accountID:"a1")
        cursor=try await db.tonHistoryWork(ticket).first{$0.stream=="jettons"}!
        XCTAssertEqual(cursor.lane,"recent");XCTAssertEqual(cursor.stopLT,100)
        try await db.commitTonPage(page([tx(lt:200)],next:200),cursor:cursor,ticket:ticket)
        cursor=try await db.tonHistoryWork(ticket).first{$0.stream=="jettons"}!
        XCTAssertEqual(cursor.lane,"recent");XCTAssertEqual(cursor.beforeLT,200)
        // Interrupted recent pagination survives another refresh instead of
        // resetting the cursor and permanently skipping the middle pages.
        ticket=try await db.beginTonSync(accountID:"a1")
        cursor=try await db.tonHistoryWork(ticket).first{$0.stream=="jettons"}!
        XCTAssertEqual(cursor.beforeLT,200)
        try await db.commitTonPage(page([tx(lt:150),tx(lt:100)],next:100),cursor:cursor,ticket:ticket)
        cursor=try await db.tonHistoryWork(ticket).first{$0.stream=="jettons"}!
        XCTAssertEqual(cursor.lane,"backfill");XCTAssertEqual(cursor.beforeLT,100)
        try await db.commitTonPage(page([tx(lt:50)]),cursor:cursor,ticket:ticket)
        let activity=try await db.assetHistory(walletID:"w1",accountID:"a1",assetID:"ton:"+TonIdentity.usdt)
        XCTAssertEqual(activity.count,4)
        let remaining=try await db.tonHistoryWork(ticket);XCTAssertFalse(remaining.contains{$0.stream=="jettons"})
    }
    func testFailedNativeComputeAndTokenStreamKeepFeeAndIndependentMovements() async throws {
        let (db,folder)=try await fixture();defer{try? FileManager.default.removeItem(at:folder)}
        let ticket=try await db.beginTonSync(accountID:"a1"),work=try await db.tonHistoryWork(ticket)
        try await db.commitTonPage(page([tx(lt:100,native:true,failed:true)]),cursor:work.first{$0.stream=="native"}!,ticket:ticket)
        try await db.commitTonPage(page([tx(lt:100)]),cursor:work.first{$0.stream=="jettons"}!,ticket:ticket)
        let record=try await db.transaction("ton:"+tx(lt:100).hash)
        XCTAssertEqual(record?.feeAtomic,"58");XCTAssertEqual(record?.state,"failed")
        let native=try await db.assetHistory(walletID:"w1",accountID:"a1",assetID:"ton:native")
        let token=try await db.assetHistory(walletID:"w1",accountID:"a1",assetID:"ton:"+TonIdentity.usdt)
        XCTAssertEqual(native.count,1);XCTAssertEqual(token.count,1)
    }
    func testStaleTicketCursorLoopAndResetRejectLateWrites() async throws {
        let (db,folder)=try await fixture();defer{try? FileManager.default.removeItem(at:folder)}
        let old=try await db.beginTonSync(accountID:"a1"), ticket=try await db.beginTonSync(accountID:"a1")
        do{try await db.commitTonInventory(inventory(),ticket:old);XCTFail()}catch{XCTAssertEqual(error as? StoreError,.staleSync)}
        let cursor=try await db.tonHistoryWork(ticket).first!
        try await db.commitTonPage(page([tx(lt:100)],next:100),cursor:cursor,ticket:ticket)
        do{try await db.commitTonPage(page([tx(lt:100)]),cursor:cursor,ticket:ticket);XCTFail()}catch{XCTAssertEqual(error as? StoreError,.staleSync)}
        let backfill=try await db.tonHistoryWork(ticket).first{$0.stream==cursor.stream}!
        do{try await db.commitTonPage(page([tx(lt:100)],next:100),cursor:backfill,ticket:ticket);XCTFail()}catch{XCTAssertEqual(error as? TonError,.paginationLoop)}
        let reset=try await db.beginWalletReset()
        do{try await db.commitTonInventory(inventory(),ticket:ticket);XCTFail()}catch{}
        try await db.eraseWalletData(resetID:reset);try await db.finishWalletReset(resetID:reset)
        let count=try await db.pool.read{try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM tonSync")};XCTAssertEqual(count,0)
    }
    func testPreviouslyEmptyWalletDownloadsMultipleNewPagesAndKeepsHighWaterMark() async throws {
        let (db,folder)=try await fixture();defer{try? FileManager.default.removeItem(at:folder)}
        var ticket=try await db.beginTonSync(accountID:"a1")
        for cursor in try await db.tonHistoryWork(ticket) { try await db.commitTonPage(page([]),cursor:cursor,ticket:ticket) }
        ticket=try await db.beginTonSync(accountID:"a1")
        var cursor=try await db.tonHistoryWork(ticket).first{$0.stream=="jettons"}!
        try await db.commitTonPage(page([tx(lt:200)],next:200),cursor:cursor,ticket:ticket)
        cursor=try await db.tonHistoryWork(ticket).first{$0.stream=="jettons"}!
        XCTAssertEqual(cursor.lane,"recent");XCTAssertEqual(cursor.beforeLT,200)
        try await db.commitTonPage(page([tx(lt:100)]),cursor:cursor,ticket:ticket)
        ticket=try await db.beginTonSync(accountID:"a1")
        cursor=try await db.tonHistoryWork(ticket).first{$0.stream=="jettons"}!
        XCTAssertEqual(cursor.stopLT,200)
        try await db.commitTonPage(page([]),cursor:cursor,ticket:ticket)
        ticket=try await db.beginTonSync(accountID:"a1")
        cursor=try await db.tonHistoryWork(ticket).first{$0.stream=="jettons"}!
        XCTAssertEqual(cursor.stopLT,200)
    }
    func testLiveSmallFundedWalletCompleteHistoryAndOfflineReopen() async throws {
        guard let key=ProcessInfo.processInfo.environment["OATH_LIVE_TON_DATABASE_KEY"], !key.isEmpty else { throw XCTSkip("Opt-in live TON database test") }
        let (db,folder)=try await fixture();defer{try? FileManager.default.removeItem(at:folder)}
        // Funded public USDT holder, only two present Jettons.
        let publicOwner="0:8afbcb163358eb20be1ae9b610a2938038d84a1087e7f49cccbf8046f59c859f"
        try await db.pool.write{try $0.execute(sql:"UPDATE accounts SET address=? WHERE id='a1'",arguments:[publicOwner])}
        let sync=try TonSynchronizer(database:db,apiKey:key)
        try await sync.refresh(accountID:"a1");await sync.waitForHistory(accountID:"a1")
        let state=try await db.pool.read { db in
            (try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM tonHistoryCursors WHERE accountID='a1' AND complete=1")!,
             try Int.fetchOne(db,sql:"SELECT COUNT(DISTINCT hash) FROM tonTransactions WHERE accountID='a1'")!,
             try String.fetchOne(db,sql:"SELECT historyFailure FROM tonSync WHERE accountID='a1'"))
        }
        XCTAssertEqual(state.0,4);XCTAssertGreaterThan(state.1,0);XCTAssertNil(state.2)
        let snapshot=try await db.snapshot(walletID:"w1",currency:"USD")
        XCTAssertEqual(snapshot.holdings.count,2);XCTAssertTrue(snapshot.holdings.allSatisfy{$0.usdPrice != nil})
        let native=try await db.assetHistory(walletID:"w1",accountID:"a1",assetID:"ton:native",limit:500)
        let jetton=try await db.assetHistory(walletID:"w1",accountID:"a1",assetID:"ton:"+TonIdentity.usdt,limit:500)
        XCTAssertFalse(native.isEmpty);XCTAssertFalse(jetton.isEmpty)
        let reopened=try await OathDatabase.open(at:folder.appendingPathComponent("wallet.sqlite"))
        let cached=try await reopened.snapshot(walletID:"w1",currency:"USD");XCTAssertEqual(cached.holdings,snapshot.holdings)
        try await assertActivityDetails(db, walletID: "w1")
            print("TON live database: \(state.1) transactions; native \(native.count) and USDT \(jetton.count) activities; 4 completed history cursors; cached balances and USD prices survived reopen")
        await sync.cancel()
    }
}

private struct TonLedgerRecoveryTransport: AnkrTransport {
    let recover: Bool
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let host = request.url?.host
        if host == "rpc.ankr.com" { throw AnkrError.transport }
        if host == "toncenter.com" {
            guard recover else { throw AnkrError.transport }
            let call = try JSONDecoder().decode(TonJSON.self, from: XCTUnwrap(request.httpBody))
            let result: TonJSON
            switch call["method"].string {
            case "getMasterchainInfo": result = .object(["init": .object(["root_hash": .string(TonIdentity.genesis)])])
            case "getAddressInformation": result = .object(["state": .string("active"), "balance": .string("123456789012345")])
            default: throw TonError.configuration
            }
            return (try JSONEncoder().encode(TonJSON.object(["ok": .bool(true), "result": result])), 200)
        }
        if host == "tonapi.io" {
            if request.url!.path.hasSuffix("/jettons") { return (Data(#"{"balances":[]}"#.utf8), 200) }
            if request.url!.path.hasSuffix("/transactions") { return (Data(#"{"transactions":[]}"#.utf8), 200) }
            if request.url!.path.hasSuffix("/operations") { return (Data(#"{"operations":[]}"#.utf8), 200) }
        }
        // Prices are deliberately unavailable; their failure must not undo an
        // authoritative native inventory or erase previously cached balances.
        return (Data(), 400)
    }
}
extension TonLedgerTests {
    func testNodeRecoveryPersistsBalanceAndPersistentOutagePreservesCache() async throws {
        for recover in [true, false] {
            let (db, folder) = try await fixture()
            defer { try? FileManager.default.removeItem(at: folder) }
            let ticket = try await db.beginTonSync(accountID: "a1")
            try await db.commitTonInventory(inventory(), ticket: ticket)
            let transport = TonLedgerRecoveryTransport(recover: recover)
            let sync = TonSynchronizer(database: db, client: TonClient(testTransport: transport), markets: TonMarkets(transport: transport))
            do { try await sync.refresh(accountID: "a1"); XCTAssertTrue(recover) }
            catch { XCTAssertFalse(recover); XCTAssertEqual(error as? TonError, .transport) }
            await sync.cancel()
            let native = try await db.balance(accountID: "a1", assetID: "ton:native")
            XCTAssertEqual(native?.amountAtomic, recover ? "123456789012345" : "59570010157331145")
            let token = try await db.balance(accountID: "a1", assetID: "ton:" + TonIdentity.usdt)
            XCTAssertEqual(token?.amountAtomic, recover ? "0" : "879187990649145", "Only a complete successful discovery may zero an absent token")
            let other = try await db.snapshot(walletID: "w2", currency: "USD")
            XCTAssertNil(other.holdings.first?.amountAtomic)
            let reopened = try await OathDatabase.open(at: folder.appendingPathComponent("wallet.sqlite"))
            let offline = try await reopened.balance(accountID: "a1", assetID: "ton:native")
            XCTAssertEqual(offline?.amountAtomic, native?.amountAtomic)
        }
    }
}
