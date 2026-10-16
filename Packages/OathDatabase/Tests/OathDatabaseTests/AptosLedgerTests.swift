import Foundation
import XCTest
import GRDB
@testable import OathDatabase
@testable import OathAnkr

@MainActor final class AptosLedgerTests:XCTestCase {
    let owner=try! AptosIdentity.address("0x1234")
    let ref=try! AptosIdentity.reference("0xabcd")
    var token:AptosToken {.init(reference:ref,name:"Example",symbol:"EX",decimals:6,logo:nil,verified:false)}
    var catalog:AptosCatalog {.init(tokens:[ref:.init(reference:ref,name:"Example",symbol:"EX",decimals:6,logo:nil,verified:true)],aliases:[:])}
    func fixture() async throws -> (OathDatabase,URL) {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("AptosLedger-"+UUID().uuidString)
        let db=try await OathDatabase.open(at:folder.appendingPathComponent("wallet.sqlite"))
        try await db.seed(networks:[.init(id:"aptos",name:"Aptos",family:"account",symbol:"APT",decimals:8,derivationPath:"m/44'/637'/0'/0'/0'",logo:"aptos",sortOrder:0)],assets:[.init(id:"aptos:native",networkID:"aptos",reference:"native",name:"Aptos",symbol:"APT",decimals:8)])
        for i in 1...2 {try await db.importWalletIfNeeded(.init(id:"w\(i)",name:"Test",kind:"hd",vaultReference:"test\(i)",createdAt:1),accounts:[.init(id:"a\(i)",walletID:"w\(i)",networkID:"aptos",address:owner,derivationPath:"m/44'/637'/0'/0'/0'")])}
        return(db,folder)
    }
    func inventory(time:Double=100,complete:Bool=true,failed:Bool=false,empty:Bool=false) -> AptosInventory {
        .init(owner:owner,holdings:[.init(token:.native,amount:"9007199254740993")]+(failed || empty ? []:[.init(token:token,amount:"12345678901234567890")]),failedReferences:failed ? [ref]:[],discoveryComplete:complete,ledgerVersion:Int64(time),observedAt:Date(timeIntervalSince1970:time),raw:Data("{}".utf8))
    }
    func tx(_ version:Int64)->AptosTransaction {
        .init(hash:"0x"+String(format:"%064llx",version),version:version,timestamp:Double(version),failed:false,fee:"10",sender:owner,events:[.init(index:0,token:token,owner:owner,direction:"incoming",amount:"1234")],raw:Data("{}".utf8))
    }
    func page(_ versions:[Int64],next:Int64?=nil)->AptosHistoryPage {
        .init(transactions:versions.map(tx),next:next,head:versions.max(),raw:Data("{}".utf8))
    }
    func testInventoryCommitsBeforeHistoryUsesSharedIndexerQuota() async throws {
        let(db,folder)=try await fixture();defer{try? FileManager.default.removeItem(at:folder)}
        let transport=AptosOrderingTransport(database:db)
        let client=AptosClient(testTransport:transport)
        let sync=AptosSynchronizer(database:db,client:client,markets:AptosMarkets(transport:transport))
        try await sync.refresh(accountID:"a1");await sync.waitForHistory(accountID:"a1")
        let state=await transport.result()
        XCTAssertTrue(state.0);XCTAssertTrue(state.1);XCTAssertEqual(state.2,5)
        await sync.cancel()
    }
    func testOnChainCoinFAMappingUnifiesHistoryBeyondVerifiedCatalog() async throws {
        let(db,folder)=try await fixture();defer{try? FileManager.default.removeItem(at:folder)}
        let ticket=try await db.beginAptosSync(accountID:"a1")
        let coin="0xabc::coin::Example",legacy=token.replacingReference("0xabc::coin::Example")
        let value=AptosInventory(owner:owner,holdings:[.init(token:.native,amount:"1"),.init(token:legacy,amount:"10")],failedReferences:[],discoveryComplete:true,ledgerVersion:100,observedAt:Date(timeIntervalSince1970:100),raw:Data(),pairedReferences:[ref:coin])
        try await db.commitAptosInventory(value,ticket:ticket,catalog:.empty)
        let cursor=try await db.aptosHistoryWork(ticket).first!
        let first=tx(100)
        let second=AptosTransaction(hash:"0x"+String(format:"%064llx",90),version:90,timestamp:90,failed:false,fee:"1",sender:owner,events:[.init(index:0,token:legacy,owner:owner,direction:"incoming",amount:"1")],raw:Data())
        try await db.commitAptosPage(.init(transactions:[first,second],next:nil,head:100,raw:Data()),cursor:cursor,ticket:ticket,catalog:.empty)
        let history=try await db.assetHistory(walletID:"w1",accountID:"a1",assetID:"aptos:"+coin)
        XCTAssertTrue(history.isEmpty, "On-chain alias mapping is not token verification")
        let retained=try await db.pool.read{try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM activity WHERE accountID='a1' AND assetID=?",arguments:["aptos:"+coin])}
        XCTAssertEqual(retained,2)
        let faAsset=try await db.asset(networkID:"aptos",reference:ref);XCTAssertNil(faAsset)
        try await db.commitAptosInventory(inventory(time:200,empty:true),ticket:ticket,catalog:.empty)
        let alias=try await db.marketCache(key:"aptos.alias."+ref)
        XCTAssertEqual(alias.flatMap{String(data:$0.payload,encoding:.utf8)},coin)
    }
    func testCanonicalAliasesCannotSilentlyOverwriteBalances() async throws {
        let(db,folder)=try await fixture();defer{try? FileManager.default.removeItem(at:folder)}
        let ticket=try await db.beginAptosSync(accountID:"a1")
        let alias="0xabc::test::Coin"
        let duplicate=AptosToken(reference:alias,name:"Example",symbol:"EX",decimals:6,logo:nil,verified:false)
        let value=AptosInventory(owner:owner,holdings:[.init(token:.native,amount:"1"),.init(token:token,amount:"10"),.init(token:duplicate,amount:"20")],failedReferences:[],discoveryComplete:true,ledgerVersion:100,observedAt:.now,raw:Data())
        let catalog=AptosCatalog(tokens:[:],aliases:[alias:ref])
        do {try await db.commitAptosInventory(value,ticket:ticket,catalog:catalog);XCTFail("Aliased amounts must not overwrite")}
        catch {XCTAssertEqual(error as? StoreError,.conflictingIdentity)}
        let saved=try await db.aptosInventory(accountID:"a1");XCTAssertNil(saved)
    }
    func testLiveSynchronizationAndOfflineReopen() async throws {
        guard let key=ProcessInfo.processInfo.environment["OATH_LIVE_APTOS_DATABASE_KEY"] else {throw XCTSkip("Opt-in mainnet database test")}
        let(db,folder)=try await fixture();defer{try? FileManager.default.removeItem(at:folder)}
        let address=ProcessInfo.processInfo.environment["OATH_LIVE_APTOS_DATABASE_OWNER"] ?? "0x041972b6755d06cc9129ab6b6a772aaca1061c8585ef3c15bddbc144bd05a63c"
        try await db.pool.write{try $0.execute(sql:"UPDATE accounts SET address=? WHERE id='a1'",arguments:[address])}
        let sync=try AptosSynchronizer(database:db,apiKey:key,indexerKey:ProcessInfo.processInfo.environment["OATH_LIVE_APTOS_INDEXER_KEY"])
        do {
            try await sync.refresh(accountID:"a1")
            // Exercise an actual committed history page without downloading an
            // exchange's entire lifetime of activity as part of a test.
            let deadline=Date().addingTimeInterval(45)
            var count=0
            repeat {
                count=try await db.pool.read{try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM aptosTransactions WHERE accountID='a1'")!}
                if count>0 {break}
                try await Task.sleep(for:.seconds(1))
            } while Date()<deadline
            await sync.cancel()
            XCTAssertGreaterThan(count,0)
            let snapshot=try await db.snapshot(walletID:"w1",currency:"USD")
            XCTAssertGreaterThan(snapshot.holdings.count,1)
            XCTAssertNotNil(snapshot.holdings.first{$0.reference=="native"}?.usdPrice)
            let inventory=try await db.aptosInventory(accountID:"a1");XCTAssertTrue(inventory?.discoveryComplete==true)
            let native=try await db.assetHistory(walletID:"w1",accountID:"a1",assetID:"aptos:native",limit:100)
            XCTAssertFalse(native.isEmpty)
            let reopened=try await OathDatabase.open(at:folder.appendingPathComponent("wallet.sqlite"))
            let cached=try await reopened.snapshot(walletID:"w1",currency:"USD");XCTAssertEqual(snapshot.holdings,cached.holdings)
            try await assertActivityDetails(db, walletID: "w1")
            print("APTOS_LIVE_DATABASE holdings=\(snapshot.holdings.count) transactions=\(count) pricesAndBalancesSurvivedReopen=true")
        } catch {
            let saved=try? await db.aptosInventory(accountID:"a1")
            print("APTOS_LIVE_DATABASE discovery=\(saved?.discoveryFailure ?? "none") complete=\(saved?.discoveryComplete ?? false) failedTokens=\(saved?.failedReferences.count ?? 0)")
            await sync.cancel();throw error
        }
    }
    func testExactPortfolioOfflineReopenAndAccountIsolation() async throws {
        let(db,folder)=try await fixture();defer{try? FileManager.default.removeItem(at:folder)}
        let ticket=try await db.beginAptosSync(accountID:"a1")
        try await db.commitAptosInventory(inventory(),ticket:ticket,catalog:catalog)
        try await db.savePrices([.init(assetID:"aptos:native",currency:"USD",value:"0.90",observedAt:100,source:"test")])
        let value=try await db.snapshot(walletID:"w1",currency:"USD")
        XCTAssertEqual(value.holdings.count,2)
        XCTAssertEqual(value.holdings.first{$0.reference==ref}?.amountAtomic,"12345678901234567890")
        XCTAssertEqual(value.holdings.first{$0.reference=="native"}?.amountAtomic,"9007199254740993")
        let other=try await db.snapshot(walletID:"w2",currency:"USD");XCTAssertNil(other.holdings.first?.amountAtomic)
        let reopened=try await OathDatabase.open(at:folder.appendingPathComponent("wallet.sqlite"))
        let offline=try await reopened.snapshot(walletID:"w1",currency:"USD");XCTAssertEqual(offline.holdings,value.holdings)
    }
    func testIncompleteDiscoveryOldVersionsAndFailedTokensCannotErase() async throws {
        let(db,folder)=try await fixture();defer{try? FileManager.default.removeItem(at:folder)}
        let ticket=try await db.beginAptosSync(accountID:"a1")
        try await db.commitAptosInventory(inventory(),ticket:ticket,catalog:catalog)
        try await db.commitAptosInventory(inventory(time:200,complete:false,empty:true),ticket:ticket,catalog:catalog)
        try await db.commitAptosInventory(inventory(time:300,failed:true),ticket:ticket,catalog:catalog)
        var amount=try await db.balance(accountID:"a1",assetID:"aptos:"+ref);XCTAssertEqual(amount?.amountAtomic,"12345678901234567890")
        do {try await db.commitAptosInventory(inventory(time:250),ticket:ticket,catalog:catalog);XCTFail()}catch{XCTAssertEqual(error as? StoreError,.staleSync)}
        try await db.commitAptosInventory(inventory(time:400,empty:true),ticket:ticket,catalog:catalog)
        amount=try await db.balance(accountID:"a1",assetID:"aptos:"+ref);XCTAssertEqual(amount?.amountAtomic,"0")
    }
    func testCursorResumeNewPagesDedupeAndReset() async throws {
        let(db,folder)=try await fixture();defer{try? FileManager.default.removeItem(at:folder)}
        var ticket=try await db.beginAptosSync(accountID:"a1")
        var cursor=try await db.aptosHistoryWork(ticket).first!
        try await db.commitAptosPage(page([100],next:100),cursor:cursor,ticket:ticket,catalog:catalog)
        cursor=try await db.aptosHistoryWork(ticket).first!;XCTAssertEqual(cursor.lane,"backfill")
        try await db.commitAptosPage(page([90]),cursor:cursor,ticket:ticket,catalog:catalog)
        ticket=try await db.beginAptosSync(accountID:"a1")
        cursor=try await db.aptosHistoryWork(ticket).first!
        try await db.commitAptosPage(page([200],next:200),cursor:cursor,ticket:ticket,catalog:catalog)
        ticket=try await db.beginAptosSync(accountID:"a1")
        cursor=try await db.aptosHistoryWork(ticket).first!;XCTAssertEqual(cursor.beforeVersion,200)
        try await db.commitAptosPage(page([150,100],next:100),cursor:cursor,ticket:ticket,catalog:catalog)
        let history=try await db.assetHistory(walletID:"w1",accountID:"a1",assetID:"aptos:"+ref)
        XCTAssertEqual(history.count,4)
        let remaining=try await db.aptosHistoryWork(ticket);XCTAssertTrue(remaining.isEmpty)
        let stale=ticket;ticket=try await db.beginAptosSync(accountID:"a1")
        do{try await db.commitAptosInventory(inventory(),ticket:stale,catalog:catalog);XCTFail()}catch{XCTAssertEqual(error as? StoreError,.staleSync)}
        let reset=try await db.beginWalletReset()
        do{try await db.commitAptosInventory(inventory(),ticket:ticket,catalog:catalog);XCTFail()}catch{}
        try await db.eraseWalletData(resetID:reset);try await db.finishWalletReset(resetID:reset)
        let count=try await db.pool.read{try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM aptosTransactions")};XCTAssertEqual(count,0)
    }
}

private actor AptosOrderingTransport:AnkrTransport {
    let database:OathDatabase
    var sawHistory=false,balanceWasCommitted=false,historyLimit:UInt64=0
    init(database:OathDatabase){self.database=database}
    func result()->(Bool,Bool,UInt64){(sawHistory,balanceWasCommitted,historyLimit)}
    func send(_ request:URLRequest) async throws -> (Data,Int) {
        let body=(try? JSONDecoder().decode(AptosJSON.self,from:request.httpBody ?? Data())) ?? .null
        var value:AptosJSON
        if request.url!.path.hasSuffix("graphql") {
            let query=body["query"].string ?? ""
            if query.contains("account_transactions") {
                sawHistory=true;balanceWasCommitted=try await database.aptosInventory(accountID:"a1") != nil
                historyLimit=body["variables"]["limit"].integer ?? 0
                value = .object(["data":.object(["account_transactions":.array([])])])
            } else if query.contains("processor_status") {
                value = .object(["data":.object(["ledger_infos":.array([.object(["chain_id":.number("1")])]),"processor_status":.array([.object(["last_success_version":.number("1000")])])])])
            } else {value = .object(["data":.object(["current_fungible_asset_balances":.array([])])])}
        } else if request.url!.path.hasSuffix("view") {
            try await Task.sleep(for:.milliseconds(15));value = .array([.string("10")])
        } else if request.url!.host=="raw.githubusercontent.com" {
            value = .array([.object(["chainId":.number("1"),"panoraTags":.array([.string("Verified")]),"tokenAddress":.string(AptosIdentity.coin),"faAddress":.string("0xa"),"decimals":.number("8"),"name":.string("Aptos"),"symbol":.string("APT")])])
        } else if request.url!.host=="api.coinbase.com" {
            value = .object(["data":.object(["base":.string("APT"),"currency":.string("USD"),"amount":.string("1")])])
        } else {value = .object(["chain_id":.number("1"),"ledger_version":.string("1000")])}
        return (try JSONEncoder().encode(value),200)
    }
}
