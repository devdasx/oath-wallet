import Foundation
import XCTest
import GRDB
@testable import OathDatabase
@testable import OathAnkr

@MainActor final class TronLedgerTests: XCTestCase {
    let owner = "TJmmqjb1DK9TTZbQXzRQ2AuA94z4gKAPFh"
    let other = "TQguVRm3tDmZG7AeZ47Mk6qi6GTF1ZDqkZ"
    let usdt = TronIdentity.usdt
    var catalog: [String:TronMarketTokenInfo] { [usdt:.init(address:usdt,name:"Tether",symbol:"USDT",decimals:6,logo:nil)] }
    func fixture() async throws -> (OathDatabase, URL) {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("TronLedger-"+UUID().uuidString)
        let db=try await OathDatabase.open(at:folder.appendingPathComponent("wallet.sqlite"))
        try await db.seed(networks:[.init(id:"tron",name:"TRON",family:"account",symbol:"TRX",decimals:6,derivationPath:"m/44'/195'/0'/0/0",logo:"tron",sortOrder:0)],assets:[.init(id:"tron:native",networkID:"tron",reference:"native",name:"TRON",symbol:"TRX",decimals:6)])
        for i in 1...2 {
            try await db.importWalletIfNeeded(.init(id:"w\(i)",name:"Public fixture",kind:"hd",vaultReference:"test\(i)",createdAt:1),accounts:[.init(id:"a\(i)",walletID:"w\(i)",networkID:"tron",address:owner,derivationPath:"m/44'/195'/0'/0/0")])
        }
        return (db,folder)
    }
    func inventory(amount: String="9007199254740993", failed: Bool=false, time: Double=10) -> TronInventory {
        .init(owner:owner,holdings:[.init(token:.init(reference:"native",name:"TRON",symbol:"TRX",decimals:6),amount:"3577033")]
              + (failed ? [] : [.init(token:.init(reference:usdt,name:"Tether",symbol:"USDT",decimals:6),amount:amount), .init(token:.init(reference:"1002000",name:"Unverified fixture",symbol:"X",decimals:6),amount:"900")]),
              failedReferences:failed ? [usdt] : [],excludedNFTs:[],discoveryComplete:true,observedAt:Date(timeIntervalSince1970:time),raw:Data("{}".utf8))
    }
    func testLiveCompleteSmallPublicAccountHistoryAndReopen() async throws {
        guard let key=ProcessInfo.processInfo.environment["OATH_LIVE_TRON_DATABASE_KEY"],!key.isEmpty else { throw XCTSkip("Opt-in public account database test") }
        let (db,folder)=try await fixture();defer { try? FileManager.default.removeItem(at:folder) }
        let publicOwner="TUoHaVjx7n5xz8LwPRDckgFrDWhMhuSuJM" // Official TronGrid documentation example.
        try await db.pool.write { try $0.execute(sql:"UPDATE accounts SET address=? WHERE id='a1'",arguments:[publicOwner]) }
        let sync=try TronSynchronizer(database:db,apiKey:key)
        try await sync.refresh(accountID:"a1")
        await sync.waitForHistory(accountID:"a1")
        let snapshot=try await db.snapshot(walletID:"w1",currency:"USD")
        XCTAssertEqual(snapshot.holdings.first?.amountAtomic,"5")
        XCTAssertNotNil(snapshot.holdings.first?.usdPrice)
        let counts=try await db.pool.read { db in
            (try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM tronHistoryCursors WHERE accountID='a1' AND complete=1")!,
             try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM tronTransactions WHERE accountID='a1'")!,
             try String.fetchOne(db,sql:"SELECT historyFailure FROM tronSync WHERE accountID='a1'"))
        }
        XCTAssertEqual(counts.0,6);XCTAssertGreaterThanOrEqual(counts.1,5);XCTAssertNil(counts.2)
        let activity=try await db.assetHistory(walletID:"w1",accountID:"a1",assetID:"tron:native")
        XCTAssertGreaterThanOrEqual(activity.count,5)
        let reopened=try await OathDatabase.open(at:folder.appendingPathComponent("wallet.sqlite"))
        let cached=try await reopened.snapshot(walletID:"w1",currency:"USD")
        XCTAssertEqual(snapshot.holdings,cached.holdings)
        try await assertActivityDetails(db, walletID: "w1")
            print("TRON live database: \(counts.1) complete transaction receipts, \(activity.count) activities, all 6 cursors complete, prices and balances retained after reopen")
        await sync.cancel()
    }
    func testExactBalanceWhitelistPartialFailureAndOfflineReopen() async throws {
        let (db,folder)=try await fixture();defer { try? FileManager.default.removeItem(at:folder) }
        let ticket=try await db.beginTronSync(accountID:"a1")
        try await db.commitTronInventory(inventory(),ticket:ticket,catalog:catalog)
        var snapshot=try await db.snapshot(walletID:"w1",currency:"USD")
        XCTAssertEqual(snapshot.holdings.count,2)
        XCTAssertEqual(snapshot.holdings.first{$0.reference==usdt}?.amountAtomic,"9007199254740993")
        let direct=try await db.balance(accountID:"a1",assetID:"tron:"+usdt);XCTAssertEqual(direct?.amountAtomic,"9007199254740993")
        try await db.commitTronInventory(inventory(failed:true,time:20),ticket:ticket,catalog:catalog)
        snapshot=try await db.snapshot(walletID:"w1",currency:"USD")
        XCTAssertEqual(snapshot.holdings.first{$0.reference==usdt}?.amountAtomic,"9007199254740993")
        let second=try await db.snapshot(walletID:"w2",currency:"USD");XCTAssertNil(second.holdings.first?.amountAtomic)
        let reopened=try await OathDatabase.open(at:folder.appendingPathComponent("wallet.sqlite"))
        let restored=try await reopened.snapshot(walletID:"w1",currency:"USD");XCTAssertEqual(restored.holdings,snapshot.holdings)
    }
    func testStaleRunMissingPageAndResetCannotCommit() async throws {
        let (db,folder)=try await fixture();defer { try? FileManager.default.removeItem(at:folder) }
        let old=try await db.beginTronSync(accountID:"a1")
        let ticket=try await db.beginTronSync(accountID:"a1")
        do { try await db.commitTronInventory(inventory(),ticket:old,catalog:catalog);XCTFail() } catch { XCTAssertEqual(error as? StoreError,.staleSync) }
        let cursor=try await db.tronHistoryWork(ticket).first!
        let otherTicket=try await db.beginTronSync(accountID:"a2")
        let otherCursor=try await db.tronHistoryWork(otherTicket).first!
        do { try await db.commitTronPage(.init(hashes:[],cursor:nil,raw:Data()),transactions:[],tokens:[:],catalog:catalog,cursor:otherCursor,ticket:ticket);XCTFail("Reject a cursor from a different wallet") } catch { XCTAssertEqual(error as? StoreError,.staleSync) }
        do { try await db.commitTronPage(.init(hashes:[String(repeating:"a",count:64)],cursor:nil,raw:Data()),transactions:[],tokens:[:],catalog:catalog,cursor:cursor,ticket:ticket);XCTFail() } catch { }
        let after=try await db.tronHistoryWork(ticket).first!;XCTAssertEqual(after,cursor)
        let reset=try await db.beginWalletReset()
        do { try await db.commitTronInventory(inventory(),ticket:ticket,catalog:catalog);XCTFail() } catch { }
        try await db.eraseWalletData(resetID:reset);try await db.finishWalletReset(resetID:reset)
        let count=try await db.pool.read { try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM tronSync") };XCTAssertEqual(count,0)
    }
    func testIncompleteDiscoveryPreservesTokensAndUpdatesNative() async throws {
        let (db,folder)=try await fixture();defer { try? FileManager.default.removeItem(at:folder) }
        let ticket=try await db.beginTronSync(accountID:"a1")
        try await db.commitTronInventory(inventory(),ticket:ticket,catalog:catalog)
        let partial=TronInventory(owner:owner,holdings:[.init(token:.init(reference:"native",name:"TRON",symbol:"TRX",decimals:6),amount:"123")],failedReferences:[],excludedNFTs:[],discoveryComplete:false,observedAt:Date(timeIntervalSince1970:30),raw:Data())
        try await db.commitTronInventory(partial,ticket:ticket,catalog:catalog)
        let native=try await db.balance(accountID:"a1",assetID:"tron:native")
        let token=try await db.balance(accountID:"a1",assetID:"tron:"+usdt)
        XCTAssertEqual(native?.amountAtomic,"123");XCTAssertEqual(token?.amountAtomic,"9007199254740993")
    }
    func testCursorLoopAndExpiredFingerprintReplay() async throws {
        let (db,folder)=try await fixture();defer { try? FileManager.default.removeItem(at:folder) }
        let ticket=try await db.beginTronSync(accountID:"a1")
        var cursor=try await db.tronHistoryWork(ticket).first!
        for next in ["A","B"] {
            try await db.commitTronPage(.init(hashes:[],cursor:next,raw:Data()),transactions:[],tokens:[:],catalog:[:],cursor:cursor,ticket:ticket)
            cursor=try await db.tronHistoryWork(ticket).first{$0.stream==cursor.stream}!
        }
        do {
            try await db.commitTronPage(.init(hashes:[],cursor:"A",raw:Data()),transactions:[],tokens:[:],catalog:[:],cursor:cursor,ticket:ticket)
            XCTFail("Repeated page must not advance")
        } catch { XCTAssertEqual(error as? TronError,.paginationLoop) }
        let restarted=try await db.restartTronCursor(cursor,ticket:ticket)
        XCTAssertNil(restarted.cursor)
        try await db.commitTronPage(.init(hashes:[],cursor:"A",raw:Data()),transactions:[],tokens:[:],catalog:[:],cursor:restarted,ticket:ticket)
        let after=try await db.tronHistoryWork(ticket).first{$0.stream==cursor.stream}!
        XCTAssertEqual(after.cursor,"A")
    }
    func testFailedSolidReceiptRemovesPendingTransfers() async throws {
        let (db,folder)=try await fixture();defer { try? FileManager.default.removeItem(at:folder) }
        let ticket=try await db.beginTronSync(accountID:"a1")
        let hash=String(repeating:"b",count:64), cursors=try await db.tronHistoryWork(ticket)
        let pending=TronTransaction(hash:hash,block:123,timestamp:1000,failed:false,confirmed:false,fee:"100",payer:owner,events:[.init(index:1000,reference:usdt,from:owner,to:other,amount:"1")],raw:Data())
        let tokens=[usdt:TronToken(reference:usdt,name:"Tether",symbol:"USDT",decimals:6)]
        try await db.commitTronPage(.init(hashes:[hash],cursor:nil,raw:Data()),transactions:[pending],tokens:tokens,catalog:catalog,cursor:cursors[0],ticket:ticket)
        let failed=TronTransaction(hash:hash,block:124,timestamp:1001,failed:true,confirmed:true,fee:"200",payer:owner,events:[],raw:Data())
        try await db.commitTronPage(.init(hashes:[hash],cursor:nil,raw:Data()),transactions:[failed],tokens:[:],catalog:catalog,cursor:cursors[1],ticket:ticket)
        let tokenHistory=try await db.assetHistory(walletID:"w1",accountID:"a1",assetID:"tron:"+usdt)
        let nativeHistory=try await db.assetHistory(walletID:"w1",accountID:"a1",assetID:"tron:native")
        XCTAssertTrue(tokenHistory.isEmpty);XCTAssertEqual(nativeHistory.count,1)
        let transfers=try await db.pool.read{ try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM transfers WHERE transactionID=?",arguments:["tron:"+hash]) }
        XCTAssertEqual(transfers,0)
        let saved=try await db.tronTransaction(accountID:"a1",hash:hash);XCTAssertEqual(saved?.failed,true);XCTAssertEqual(saved?.confirmed,true);XCTAssertTrue(saved?.events.isEmpty == true)
    }
    func testReceiptDeduplicationAcrossStreamsAndInternalTransfers() async throws {
        let (db,folder)=try await fixture();defer { try? FileManager.default.removeItem(at:folder) }
        let ticket=try await db.beginTronSync(accountID:"a1")
        let tx=TronTransaction(hash:String(repeating:"a",count:64),block:123,timestamp:1000,failed:false,confirmed:true,fee:"100",payer:other,
            events:[.init(index:1000,reference:usdt,from:other,to:owner,amount:"1000000"),.init(index:1_000_000,reference:"native",from:other,to:owner,amount:"2000000")],raw:Data("{}".utf8))
        let tokens=[usdt:TronToken(reference:usdt,name:"Tether",symbol:"USDT",decimals:6),"native":TronToken(reference:"native",name:"TRON",symbol:"TRX",decimals:6)]
        for cursor in try await db.tronHistoryWork(ticket) {
            try await db.commitTronPage(.init(hashes:[tx.hash],cursor:nil,raw:Data("{}".utf8)),transactions:[tx],tokens:tokens,catalog:catalog,cursor:cursor,ticket:ticket)
        }
        let activity=try await db.assetHistory(walletID:"w1",accountID:"a1",assetID:"tron:"+usdt)
        XCTAssertEqual(activity.count,1);XCTAssertEqual(activity[0].amountAtomic,"1000000")
        let native=try await db.assetHistory(walletID:"w1",accountID:"a1",assetID:"tron:native")
        XCTAssertEqual(native.count,1);XCTAssertEqual(native[0].amountAtomic,"2000000")
    }
}
