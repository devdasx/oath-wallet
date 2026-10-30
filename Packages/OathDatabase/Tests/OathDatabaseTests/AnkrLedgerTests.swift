import XCTest
import GRDB
import OathAnkr
@testable import OathDatabase

private let address = "0x1111111111111111111111111111111111111111"
private let other = "0x2222222222222222222222222222222222222222"
private let token = "0x3333333333333333333333333333333333333333"
private struct PageTransport: AnkrTransport {
    let data: Data
    func send(_ request: URLRequest) async throws -> (Data,Int) { (data,200) }
}

@MainActor final class AnkrLedgerTests: XCTestCase {
    private func fixture(allChains: Bool = false) async throws -> (OathDatabase,URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("AnkrLedger-"+UUID().uuidString).appendingPathComponent("test.sqlite")
        let db = try await OathDatabase.open(at:url)
        let chains = allChains ? AnkrChain.allCases : [.eth]
        try await db.seed(networks: chains.enumerated().map { i,c in
            .init(id:c.networkID,name:c.networkID,family:"evm",symbol:"ETH",decimals:18,derivationPath:"m/44'/60'/0'/0/0",logo:"local",sortOrder:i)
        }, assets: chains.map { .init(id:$0.networkID+":native",networkID:$0.networkID,reference:"native",name:"Native branding",symbol:"ETH",decimals:18,logo:"local") })
        for wallet in ["wallet","second"] {
            try await db.importWalletIfNeeded(.init(id:wallet,name:wallet,kind:"hd",vaultReference:wallet,createdAt:1),
                accounts:chains.map { .init(id:wallet+":"+$0.networkID,walletID:wallet,networkID:$0.networkID,address:address,derivationPath:"m/44'/60'/0'/0/0") })
        }
        return (db,url)
    }
    private func envelope(_ result: [String:Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject:["jsonrpc":"2.0","id":1,"result":result,"futureField":["preserve":true]])
    }
    private func asset(native: Bool = false, atomic: String = "9007199254740993", price: String = "", usd: String = "") -> [String:Any] {
        ["blockchain":"eth","tokenName":"Provider name","tokenSymbol":"TKN","tokenDecimals":native ? 18 : 6,
         "tokenType":native ? "NATIVE" : "ERC20","contractAddress":native ? "0x"+String(repeating:"0",count:40) : token,
         "holderAddress":address,"balanceRawInteger":atomic,"balance":"9007199254.740993","balanceUsd":usd,
         "tokenPrice":price,"thumbnail":"https://example.invalid/logo.png","unknownField":"retained"]
    }
    private func balances(_ assets: [[String:Any]], next: String? = nil, total: Int? = nil, stamp: Int = 100) async throws -> AnkrPage<AnkrBalanceResult> {
        var result: [String:Any] = ["assets":assets,"totalBalanceUsd":"12.345","totalCount":total ?? assets.count,
                                  "syncStatus":["status":"synced","timestamp":stamp,"blockNumber":100]]
        if let next { result["nextPageToken"] = next }
        return try await AnkrClient(apiKey:"test",transport:PageTransport(data:envelope(result))).balances(chain:.eth,address:address)
    }
    private func transaction(_ number: Int, status: String = "0x1", timestamp: Int = 100) -> [String:Any] {
        ["blockchain":"eth","hash":"0x"+String(format:"%064x",number),"from":address,"to":other,"value":"0x20000000000001",
         "blockNumber":"0xa","timestamp":String(timestamp),"status":status,"gasUsed":"0x5208","gasPrice":"0x3b9aca00",
         "logs":[["futureEvent":"raw retained"]],"input":"0x12345678","nonce":"0x7"]
    }

    func testFullInventoryKeepsWhitelistEvidenceSeparateAndRejectsIncompleteVerification() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var selection = PortfolioFilter(); selection.hidesUnverifiedTokens = false
        try await db.savePortfolioFilter(selection, walletID: "wallet")
        let native = try await balances([asset(native: true)])
        let full = try await balances([asset(native: true), asset()])
        let ticket = try await db.beginAnkrSync(accountID: "wallet:ethereum", stream: "balances")
        try await db.commitAnkrBalances([full], ticket: ticket, onlyWhitelisted: false, verificationPages: [native])
        let shown = try await db.snapshot(walletID: "wallet", currency: "USD")
        XCTAssertEqual(shown.holdings.count, 2)
        let verified = try await db.pool.read {
            try Int.fetchOne($0, sql: "SELECT onlyWhitelisted FROM ankrAssets WHERE accountID='wallet:ethereum' AND assetID=?", arguments: ["ethereum:" + token])
        }
        XCTAssertEqual(verified, 0)
        let next = try await db.beginAnkrSync(accountID: "wallet:ethereum", stream: "balances")
        let partial = try await balances([], next: "unfinished", total: 1)
        do {
            try await db.commitAnkrBalances([full], ticket: next, onlyWhitelisted: false, verificationPages: [partial])
            XCTFail("Incomplete verification must retain the previous inventory")
        } catch AnkrError.incompleteInventory { }
        let retained = try await db.snapshot(walletID: "wallet", currency: "USD")
        XCTAssertEqual(retained.holdings, shown.holdings)
        try await db.savePortfolioFilter(.init(), walletID: "wallet")
        let hidden = try await db.snapshot(walletID: "wallet", currency: "USD")
        XCTAssertEqual(hidden.holdings.count, 1)
        let other = try await db.snapshot(walletID: "second", currency: "USD")
        XCTAssertEqual(other.holdings.count, 1)
    }
    private func transactions(_ items: [[String:Any]], next: String? = nil) async throws -> AnkrPage<AnkrTransactionResult> {
        var result: [String:Any] = ["transactions":items,"syncStatus":["status":"synced","timestamp":200]]
        if let next { result["nextPageToken"] = next }
        return try await AnkrClient(apiKey:"test",transport:PageTransport(data:envelope(result))).transactions(chain:.eth,address:address)
    }
    func testRepeatedConfirmedEvidenceDoesNotRewriteUnchangedConflictIndex() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let ticket = try await db.beginAnkrSync(accountID: "wallet:ethereum", stream: "transactions")
        try await db.commitAnkrTransactions(try await transactions([transaction(1)]), ticket: ticket, cursor: nil)
        let changes = try await db.pool.write { db in
            let tx = try XCTUnwrap(TransactionRecord.fetchOne(db, key: "ethereum:0x" + String(format: "%064x", 1)))
            let before = db.totalChangesCount
            for _ in 0..<20 {
                try OathDatabase.saveTransactionEvidence(accountID: "wallet:ethereum", tx: tx,
                    keys: [address + ":7"], returnsToWallet: false, db: db)
            }
            return db.totalChangesCount - before
        }
        XCTAssertEqual(changes, 0, "Re-reading confirmed history must not rewrite identical evidence and conflict keys")
    }

    func testRepeatedHistoryDoesNotRewriteIdenticalTransferAndActivityRows() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let first = try await db.beginAnkrSync(accountID: "wallet:ethereum", stream: "transactions")
        let page = try await transactions([transaction(1)])
        try await db.commitAnkrTransactions(page, ticket: first, cursor: nil)
        try await db.pool.write { db in
            try db.execute(sql: "CREATE TABLE historyWriteAudit (tableName TEXT NOT NULL)")
            for table in ["transactions", "transfers", "activity"] {
                try db.execute(sql: "CREATE TRIGGER audit_\(table) AFTER UPDATE ON \(table) BEGIN INSERT INTO historyWriteAudit VALUES ('\(table)'); END")
            }
        }
        let next = try await db.beginAnkrSync(accountID: "wallet:ethereum", stream: "transactions")
        try await db.commitAnkrTransactions(page, ticket: next, cursor: nil)
        try await db.pool.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM historyWriteAudit"), 0,
                "Replaying the same page must preserve records without emitting redundant row updates")
        }
        // A new observation must still advance freshness, and a receipt change
        // must still update the transaction and derived activity atomically.
        let failed = try await db.beginAnkrSync(accountID: "wallet:ethereum", stream: "transactions")
        let changed = try await transactions([transaction(1, status: "0x0", timestamp: 101)])
        try await db.commitAnkrTransactions(changed, ticket: failed, cursor: nil)
        try await db.pool.read { db in
            let tx = try XCTUnwrap(TransactionRecord.fetchOne(db, key: "ethereum:0x" + String(format: "%064x", 1)))
            XCTAssertEqual(tx.state, "failed")
            XCTAssertEqual(tx.updatedAt, changed.fetchedAt.timeIntervalSince1970)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT amountAtomic FROM transfers"), "0")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT amountAtomic FROM activity"), "0")
            XCTAssertEqual(try Double.fetchOne(db, sql: "SELECT timestamp FROM activity"), 101)
            for table in ["transactions", "transfers", "activity"] {
                XCTAssertGreaterThan(try Int.fetchOne(db, sql: "SELECT count(*) FROM historyWriteAudit WHERE tableName=?", arguments: [table]) ?? 0, 0)
            }
        }
    }

    func testRepeatedTokenHistoryPreservesReceiptAndAvoidsUnchangedUpdates() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let receipt = try await db.beginAnkrSync(accountID: "wallet:ethereum", stream: "transactions")
        try await db.commitAnkrTransactions(try await transactions([transaction(1)]), ticket: receipt, cursor: nil)
        let first = try await db.beginAnkrSync(accountID: "wallet:ethereum", stream: "transfers", now: Date(timeIntervalSince1970: 200))
        try await db.commitAnkrTransfers(try await transfers(indexes: [1, 2]), ticket: first, cursor: nil)
        try await db.pool.write { db in
            try db.execute(sql: "CREATE TABLE historyWriteAudit (tableName TEXT NOT NULL)")
            for table in ["transactions", "transfers", "activity"] {
                try db.execute(sql: "CREATE TRIGGER audit_\(table) AFTER UPDATE ON \(table) BEGIN INSERT INTO historyWriteAudit VALUES ('\(table)'); END")
            }
        }
        for _ in 0..<3 {
            let next = try await db.beginAnkrSync(accountID: "wallet:ethereum", stream: "transfers", now: Date(timeIntervalSince1970: 200))
            try await db.commitAnkrTransfers(try await transfers(indexes: [1, 2]), ticket: next, cursor: nil)
        }
        try await db.pool.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM historyWriteAudit"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM activity"), 3)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT feeAtomic FROM transactions"), "21000000000000")
        }
        // Reconciliation must still remove a disappeared event on the next full scan.
        let reorg = try await db.beginAnkrSync(accountID: "wallet:ethereum", stream: "transfers", now: Date(timeIntervalSince1970: 200))
        try await db.commitAnkrTransfers(try await transfers(indexes: [1]), ticket: reorg, cursor: nil)
        try await db.pool.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM activity"), 2)
        }
    }

    func testChangedEvidenceUpdatesExactKeysAndPreservesOtherAccounts() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        for account in ["wallet:ethereum", "second:ethereum"] {
            let ticket = try await db.beginAnkrSync(accountID: account, stream: "transactions")
            try await db.commitAnkrTransactions(try await transactions([transaction(1)]), ticket: ticket, cursor: nil)
        }
        try await db.pool.write { db in
            let tx = try XCTUnwrap(TransactionRecord.fetchOne(db, key: "ethereum:0x" + String(format: "%064x", 1)))
            let keys: Set<String> = [address + ":8", address + ":9"]
            try OathDatabase.saveTransactionEvidence(accountID: "wallet:ethereum", tx: tx,
                keys: keys, returnsToWallet: true, db: db)
            let actual = Set(try String.fetchAll(db,
                sql: "SELECT conflictKey FROM transactionConflictKeys WHERE accountID=? AND transactionID=?",
                arguments: ["wallet:ethereum", tx.id]))
            XCTAssertEqual(actual, keys)
            let other = try String.fetchAll(db,
                sql: "SELECT conflictKey FROM transactionConflictKeys WHERE accountID=? AND transactionID=?",
                arguments: ["second:ethereum", tx.id])
            XCTAssertEqual(other, [address + ":7"])
            XCTAssertEqual(try Bool.fetchOne(db,
                sql: "SELECT returnsToWallet FROM transactionEvidence WHERE accountID=? AND transactionID=?",
                arguments: ["wallet:ethereum", tx.id]), true)
            let before = db.totalChangesCount
            for _ in 0..<20 {
                try OathDatabase.saveTransactionEvidence(accountID: "wallet:ethereum", tx: tx,
                    keys: Set(keys.reversed()), returnsToWallet: true, db: db)
            }
            XCTAssertEqual(db.totalChangesCount, before, "Set iteration order must not cause new writes")
            try OathDatabase.saveTransactionEvidence(accountID: "wallet:ethereum", tx: tx,
                keys: [], returnsToWallet: false, db: db)
            XCTAssertEqual(try Int.fetchOne(db,
                sql: "SELECT count(*) FROM transactionConflictKeys WHERE accountID=? AND transactionID=?",
                arguments: ["wallet:ethereum", tx.id]), 0)
        }
    }

    private func transfers(indexes: [Int], to: String = address) async throws -> AnkrPage<AnkrTransferResult> {
        let values: [[String:Any]] = indexes.map { i in
            ["blockchain":"eth","transactionHash":"0x"+String(format:"%064x",1),"fromAddress":other,"toAddress":to,
             "contractAddress":token,"value":"1","valueRawInteger":"1000000","tokenName":"Token","tokenSymbol":"TKN",
             "tokenDecimals":6,"blockHeight":10,"timestamp":100,"logIndex":i,"direction":"in"]
        }
        return try await AnkrClient(apiKey:"test",transport:PageTransport(data:envelope(["transfers":values]))).transfers(chain:.eth,address:address)
    }
    func testPendingNonceConflictAndFailedReplacementThroughProductionDecoder() async throws {
        for (cancel, failed) in [(false, false), (true, false), (true, true)] {
            let (db, url) = try await fixture()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            var pending = transaction(101)
            pending["blockNumber"] = NSNull(); pending["status"] = NSNull()
            let first = try await db.beginAnkrSync(accountID: "wallet:ethereum", stream: "transactions")
            try await db.commitAnkrTransactions(try await transactions([pending]), ticket: first, cursor: nil)
            var replacement = transaction(102, status: failed ? "0x0" : "0x1", timestamp: 200)
            if cancel { replacement["to"] = address; replacement["value"] = "0x0"; replacement["input"] = "0x" }
            let second = try await db.beginAnkrSync(accountID: "wallet:ethereum", stream: "transactions")
            try await db.commitAnkrTransactions(try await transactions([replacement]), ticket: second, cursor: nil)
            let rows = try await db.history(walletID: "wallet")
            let original = try XCTUnwrap(rows.first { $0.hash == pending["hash"] as? String })
            XCTAssertEqual(original.state, cancel && !failed ? "canceled" : "replaced")
            XCTAssertEqual(original.timestamp, 200)
            let detail = try await db.transactionDetails(accountID: "wallet:ethereum", transactionID: original.transactionID)
            XCTAssertEqual(detail?.replacementHash, replacement["hash"] as? String)
        }
    }
    func testTokenPagePreservesFailedReceiptWithoutFee() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var failed = transaction(1, status: "0x0")
        failed.removeValue(forKey: "gasUsed"); failed.removeValue(forKey: "gasPrice")
        let receiptTicket = try await db.beginAnkrSync(accountID: "wallet:ethereum", stream: "transactions")
        try await db.commitAnkrTransactions(try await transactions([failed]), ticket: receiptTicket, cursor: nil)
        let eventsTicket = try await db.beginAnkrSync(accountID: "wallet:ethereum", stream: "transfers")
        try await db.commitAnkrTransfers(try await transfers(indexes: [1]), ticket: eventsTicket, cursor: nil)
        let rows = try await db.history(walletID: "wallet")
        XCTAssertTrue(rows.allSatisfy { $0.state == "failed" })
    }
    func testExactBalancesUnknownPricesFullRawPayloadBrandingAndWalletIsolation() async throws {
        let (db,url) = try await fixture()
        let page = try await balances([asset(),asset(native:true,atomic:"1000000000000000000",price:"12.345",usd:"12.345")])
        let ticket = try await db.beginAnkrSync(accountID:"wallet:ethereum",stream:"balances")
        try await db.commitAnkrBalances([page],ticket:ticket)
        let reopened = try await OathDatabase.open(at:url)
        let snapshot = try await reopened.snapshot(walletID:"wallet",currency:"USD")
        XCTAssertEqual(snapshot.holdings.first { $0.reference == token }?.amountAtomic,"9007199254740993")
        XCTAssertNil(snapshot.holdings.first { $0.reference == token }?.usdPrice)
        XCTAssertEqual(snapshot.holdings.first { $0.reference == "native" }?.name,"Native branding")
        XCTAssertEqual(snapshot.totalFiat,Decimal(string:"12.345"))
        XCTAssertFalse(snapshot.valuationComplete)
        let raw = try await reopened.ankrResponse(accountID:"wallet:ethereum",stream:"balances",pageKey:"0")
        XCTAssertEqual(raw,page.raw)
        let detail = try await reopened.ankrAssetDetails(accountID:"wallet:ethereum",assetID:"ethereum:"+token)
        XCTAssertEqual(detail?.details.balanceRawInteger,"9007199254740993")
        XCTAssertEqual(detail?.details.tokenPrice,"")
        let archive = try await reopened.ankrResponsePages(accountID:"wallet:ethereum",stream:"balances")
        XCTAssertEqual(archive.map(\.pageKey),["0"])
        XCTAssertEqual(archive.first?.byteCount,page.raw.count)
        let second = try await reopened.snapshot(walletID:"second",currency:"USD")
        XCTAssertNil(second.holdings.first?.amountAtomic)
        XCTAssertEqual(snapshot.accountSync.first?.totalBalanceUsd,"12.345")
    }
    func testOnlyCompleteInventoryCanZeroBalancesAndMissingTokenPricesPreserveQuotes() async throws {
        let (db,_) = try await fixture()
        let page = try await balances([asset(price:"2",usd:"18014398509.481986")])
        var ticket = try await db.beginAnkrSync(accountID:"wallet:ethereum",stream:"balances")
        try await db.commitAnkrBalances([page],ticket:ticket)
        ticket = try await db.beginAnkrSync(accountID:"wallet:ethereum",stream:"balances")
        let incomplete = try await balances([],next:"next",total:1)
        do { try await db.commitAnkrBalances([incomplete],ticket:ticket); XCTFail() }
        catch { XCTAssertEqual(error as? AnkrError,.incompleteInventory) }
        var snapshot = try await db.snapshot(walletID:"wallet",currency:"USD")
        XCTAssertEqual(snapshot.holdings.first { $0.reference == token }?.amountAtomic,"9007199254740993")
        let unpriced = try await balances([asset()])
        try await db.commitAnkrBalances([unpriced],ticket:ticket)
        snapshot = try await db.snapshot(walletID:"wallet",currency:"USD")
        XCTAssertEqual(snapshot.holdings.first { $0.reference == token }?.usdPrice,"2")
        ticket = try await db.beginAnkrSync(accountID:"wallet:ethereum",stream:"balances")
        let empty = try await balances([])
        try await db.commitAnkrBalances([empty],ticket:ticket)
        snapshot = try await db.snapshot(walletID:"wallet",currency:"USD")
        XCTAssertTrue(snapshot.holdings.allSatisfy { $0.amountAtomic == "0" })
    }
    func testExistingTrackedContractKeepsIdentityAndFilteredOutBalanceStaysUnknown() async throws {
        let (db,_) = try await fixture()
        let saved = try await db.trackAsset(.init(id:"legacy-token-id",networkID:"ethereum",reference:token,
            name:"Verified custom token",symbol:"CUSTOM",decimals:6),walletID:"wallet")
        var ticket = try await db.beginAnkrSync(accountID:"wallet:ethereum",stream:"balances")
        try await db.commitAnkrBalances(try await [balances([asset()])],ticket:ticket)
        var snapshot = try await db.snapshot(walletID:"wallet",currency:"USD")
        XCTAssertEqual(snapshot.holdings.filter { $0.reference == token }.count,1)
        XCTAssertEqual(snapshot.holdings.first { $0.reference == token }?.assetID,saved.id)
        XCTAssertEqual(snapshot.holdings.first { $0.reference == token }?.name,"Verified custom token")
        let another = try await db.trackAsset(.init(id:"newly-tracked",networkID:"ethereum",
            reference:"0x4444444444444444444444444444444444444444",name:"Unfunded",symbol:"NONE",decimals:18),walletID:"wallet")
        ticket = try await db.beginAnkrSync(accountID:"wallet:ethereum",stream:"balances")
        try await db.commitAnkrBalances(try await [balances([])],ticket:ticket)
        snapshot = try await db.snapshot(walletID:"wallet",currency:"USD")
        XCTAssertTrue(snapshot.holdings.contains { $0.assetID == another.id })
        XCTAssertTrue(snapshot.holdings.contains { $0.assetID == saved.id })
        // The whitelist cannot distinguish an unlisted token from an unfunded
        // one. Explicit additions remain visible without a fabricated balance.
        XCTAssertNil(snapshot.holdings.first { $0.assetID == another.id }?.amountAtomic)
        XCTAssertNil(snapshot.holdings.first { $0.assetID == saved.id }?.amountAtomic)
    }
    func testWhitelistedRefreshRemovesExcludedTokensAndHistoryCannotResurrectThem() async throws {
        let (db,url) = try await fixture()
        let full = try await balances([asset(price:"2",usd:"18014398509.481986")])
        for account in ["wallet:ethereum","second:ethereum"] {
            let ticket = try await db.beginAnkrSync(accountID:account,stream:"balances")
            try await db.commitAnkrBalances([full],ticket:ticket)
        }
        let pending = try await db.beginAnkrSync(accountID:"wallet:ethereum",stream:"balances")
        do {
            try await db.commitAnkrBalances(try await [balances([],next:"next",total:1)],ticket:pending)
            XCTFail("Partial whitelist must not remove cached holdings")
        } catch { XCTAssertEqual(error as? AnkrError,.incompleteInventory) }
        try await db.failAnkrSync(pending,code:"transport")
        let cached = try await db.snapshot(walletID:"wallet",currency:"USD")
        XCTAssertTrue(cached.holdings.contains { $0.reference == token })
        XCTAssertGreaterThan(cached.totalFiat,0)

        let refresh = try await db.beginAnkrSync(accountID:"wallet:ethereum",stream:"balances")
        try await db.commitAnkrBalances(try await [balances([])],ticket:refresh)
        let history = try await db.beginAnkrSync(accountID:"wallet:ethereum",stream:"transfers")
        try await db.commitAnkrTransfers(try await transfers(indexes:[0]),ticket:history,cursor:nil)
        let reopened = try await OathDatabase.open(at:url)
        let snapshot = try await reopened.snapshot(walletID:"wallet",currency:"USD")
        XCTAssertEqual(snapshot.holdings.map(\.reference),["native"])
        XCTAssertEqual(snapshot.totalFiat,0)
        let balance = try await db.pool.read { try BalanceRecord.fetchOne($0,key:["accountID":"wallet:ethereum","assetID":"ethereum:"+token]) }
        XCTAssertNil(balance)
        let activity = try await db.assetHistory(walletID:"wallet",accountID:"wallet:ethereum",assetID:"ethereum:"+token)
        XCTAssertEqual(activity.count,1,"Filtering holdings must not delete transaction history")
        let otherWallet = try await reopened.snapshot(walletID:"second",currency:"USD")
        XCTAssertTrue(otherWallet.holdings.contains { $0.reference == token })
        XCTAssertGreaterThan(otherWallet.totalFiat,0)
    }
    func testV11MigrationHidesUnfilteredCacheUntilWhitelistRefreshSucceeds() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Ankr-v11-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let url = folder.appendingPathComponent("test.sqlite")
        let old = try DatabaseQueue(path:url.path)
        try Schema.migrator.migrate(old,upTo:"v11_ankr_account_sync")
        let raw = try await balances([asset()]).raw
        try await old.write { db in
            try NetworkRecord(id:"ethereum",name:"Ethereum",family:"evm",symbol:"ETH",decimals:18,derivationPath:"m/44'/60'/0'/0/0",logo:"local",sortOrder:0).insert(db)
            try AssetRecord(id:"ethereum:native",networkID:"ethereum",reference:"native",name:"Ethereum",symbol:"ETH",decimals:18).insert(db)
            try AssetRecord(id:"ethereum:"+token,networkID:"ethereum",reference:token,name:"Previously discovered",symbol:"TOKEN",decimals:6).insert(db)
            try db.execute(sql: "INSERT INTO wallets(id,name,kind,vaultReference,createdAt,backedUp) VALUES(?,?,?,?,?,?)", arguments: ["wallet", "Existing", "hd", "test", 1, false])
            try AccountRecord(id:"wallet:ethereum",walletID:"wallet",networkID:"ethereum",address:address,derivationPath:"m/44'/60'/0'/0/0").insert(db)
            try BalanceRecord(accountID:"wallet:ethereum",assetID:"ethereum:native",networkID:"ethereum",amountAtomic:"1000000000000000000",observedAt:1,source:"ankr").insert(db)
            try BalanceRecord(accountID:"wallet:ethereum",assetID:"ethereum:"+token,networkID:"ethereum",amountAtomic:"1000000",observedAt:1,source:"ankr").insert(db)
            // A token having a quote is not evidence of whitelist membership.
            try PriceRecord(assetID:"ethereum:"+token,currency:"USD",value:"999",observedAt:1,source:"ankr").insert(db)
            try db.execute(sql:"INSERT INTO ankrAssets(accountID,assetID,detail,balanceUsd,fetchedAt) VALUES(?,?,?,?,?)",
                arguments:["wallet:ethereum","ethereum:"+token,raw,"999",1])
            try SettingRecord(key:"currency",value:"USD",updatedAt:1).insert(db)
        }
        try old.close()
        let db = try await OathDatabase.open(at:url)
        var snapshot = try await db.snapshot(walletID:"wallet",currency:"USD")
        XCTAssertEqual(snapshot.holdings.map(\.reference),["native"])
        XCTAssertEqual(snapshot.holdings.first?.amountAtomic,"1000000000000000000")
        XCTAssertEqual(snapshot.totalFiat,0)
        XCTAssertEqual(snapshot.wallet.name,"Existing")
        let failed = try await db.beginAnkrSync(accountID:"wallet:ethereum",stream:"balances")
        try await db.failAnkrSync(failed,code:"transport")
        snapshot = try await db.snapshot(walletID:"wallet",currency:"USD")
        XCTAssertFalse(snapshot.holdings.contains { $0.reference == token })
        let refreshed = try await db.beginAnkrSync(accountID:"wallet:ethereum",stream:"balances")
        try await db.commitAnkrBalances(try await [balances([asset(atomic:"1000000",price:"2",usd:"2")])],ticket:refreshed)
        let reopened = try await OathDatabase.open(at:url)
        snapshot = try await reopened.snapshot(walletID:"wallet",currency:"USD")
        XCTAssertEqual(snapshot.holdings.first { $0.reference == token }?.amountAtomic,"1000000")
        XCTAssertEqual(snapshot.totalFiat,2)
    }
    func testHistoryResumesAfterFailureWithoutLosingEarlierPagesAndReconcilesCompletedWindow() async throws {
        let (db,_) = try await fixture()
        let first = try await transactions([transaction(1)],next:"page-two")
        let initial = try await db.beginAnkrSync(accountID:"wallet:ethereum",stream:"transactions",now:Date(timeIntervalSince1970:200))
        try await db.commitAnkrTransactions(first,ticket:initial,cursor:nil)
        try await db.failAnkrSync(initial,code:"transport")
        let resumed = try await db.beginAnkrSync(accountID:"wallet:ethereum",stream:"transactions",now:Date(timeIntervalSince1970:300))
        XCTAssertEqual(resumed.state.cursor,"page-two"); XCTAssertEqual(resumed.state.scanID,initial.state.scanID)
        XCTAssertEqual(resumed.state.windowEnd,200)
        try await db.commitAnkrTransactions(try await transactions([transaction(2,status:"0x0")]),ticket:resumed,cursor:"page-two")
        let history = try await db.assetHistory(walletID:"wallet",accountID:"wallet:ethereum",assetID:"ethereum:native")
        XCTAssertEqual(history.count,2)
        XCTAssertEqual(history.first { $0.state == "failed" }?.amountAtomic,"0")
        XCTAssertEqual(history.first { $0.state == "confirmed" }?.amountAtomic,"9007199254740993")
        let receipt = try await db.pool.read { try TransactionRecord.fetchOne($0,key:"ethereum:0x"+String(format:"%064x",1)) }
        XCTAssertEqual(receipt?.feeAtomic,"21000000000000")
        let fresh = try await db.beginAnkrSync(accountID:"wallet:ethereum",stream:"transactions",now:Date(timeIntervalSince1970:400))
        try await db.commitAnkrTransactions(try await transactions([transaction(2)]),ticket:fresh,cursor:nil)
        let reconciled = try await db.assetHistory(walletID:"wallet",accountID:"wallet:ethereum",assetID:"ethereum:native")
        XCTAssertEqual(reconciled.count,1); XCTAssertEqual(reconciled[0].state,"confirmed")
    }
    func testTransferEventsRemainDistinctAndDoNotEraseTransactionReceipt() async throws {
        let (db,_) = try await fixture()
        let txTicket = try await db.beginAnkrSync(accountID:"wallet:ethereum",stream:"transactions")
        try await db.commitAnkrTransactions(try await transactions([transaction(1)]),ticket:txTicket,cursor:nil)
        let eventTicket = try await db.beginAnkrSync(accountID:"wallet:ethereum",stream:"transfers")
        try await db.commitAnkrTransfers(try await transfers(indexes:[0,1]),ticket:eventTicket,cursor:nil)
        let history = try await db.assetHistory(walletID:"wallet",accountID:"wallet:ethereum",assetID:"ethereum:"+token)
        XCTAssertTrue(history.isEmpty, "Unlisted transfer history is hidden, but the ledger must retain both events")
        let rawEvents = try await db.pool.read { try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM activity WHERE accountID='wallet:ethereum' AND assetID=?",arguments:["ethereum:"+token]) }
        XCTAssertEqual(rawEvents,2)
        let receipt = try await db.pool.read { try TransactionRecord.fetchOne($0,key:"ethereum:0x"+String(format:"%064x",1)) }
        XCTAssertEqual(receipt?.feeAtomic,"21000000000000")
    }
    func testStaleTicketsAndResetPreventLateBalanceResurrection() async throws {
        let (db,_) = try await fixture()
        let page = try await balances([asset()])
        let old = try await db.beginAnkrSync(accountID:"wallet:ethereum",stream:"balances")
        let current = try await db.beginAnkrSync(accountID:"wallet:ethereum",stream:"balances")
        do { try await db.commitAnkrBalances([page],ticket:old); XCTFail() }
        catch { XCTAssertEqual(error as? StoreError,.staleSync) }
        try await db.commitAnkrBalances([page],ticket:current)
        let pending = try await db.beginAnkrSync(accountID:"wallet:ethereum",stream:"balances")
        let reset = try await db.beginWalletReset()
        do { try await db.commitAnkrBalances([page],ticket:pending); XCTFail() } catch { }
        try await db.eraseWalletData(resetID:reset); try await db.finishWalletReset(resetID:reset)
        do { try await db.commitAnkrBalances([page],ticket:pending); XCTFail() } catch { }
        let counts = try await db.pool.read { db in try ["ankrSync","ankrResponses","ankrAssets","ankrActivity"].map {
            try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM \($0)")! } }
        XCTAssertEqual(counts,[0,0,0,0])
    }
    func testResetCancelsEveryAnkrWriterBeforeSQLTriggersAndPreservesState() async throws {
        let (db, _) = try await fixture()
        var tickets: [AnkrSyncTicket] = []
        for stream in ["balances", "transactions", "transfers"] {
            tickets.append(try await db.beginAnkrSync(accountID: "wallet:ethereum", stream: stream))
        }
        let before = try await db.ankrStatus(accountID: "wallet:ethereum")
        let reset = try await db.beginWalletReset()
        for ticket in tickets {
            do {
                _ = try await db.beginAnkrSync(accountID: ticket.account.id, stream: ticket.state.stream)
                XCTFail("Reset accepted a new sync")
            } catch { XCTAssertTrue(error is CancellationError) }
            do {
                _ = try await db.restartAnkrWindow(ticket)
                XCTFail("Reset accepted a window restart")
            } catch { XCTAssertTrue(error is CancellationError) }
            do {
                switch ticket.state.stream {
                case "balances": try await db.commitAnkrBalances([balances([asset()])], ticket: ticket)
                case "transactions": try await db.commitAnkrTransactions(transactions([transaction(1)]), ticket: ticket, cursor: nil)
                default: try await db.commitAnkrTransfers(transfers(indexes: [0]), ticket: ticket, cursor: nil)
                }
                XCTFail("Reset accepted a late response")
            } catch { XCTAssertTrue(error is CancellationError, "Expected typed cancellation, got \(type(of: error))") }
            try await db.failAnkrSync(ticket, code: "storage")
        }
        let after = try await db.ankrStatus(accountID: "wallet:ethereum")
        XCTAssertEqual(after, before, "Neither late responses nor failure handling may mutate reset-owned data")
        try await db.eraseWalletData(resetID: reset)
        try await db.finishWalletReset(resetID: reset)
        for ticket in tickets {
            do { _ = try await db.restartAnkrWindow(ticket); XCTFail("Deleted account accepted an old ticket") }
            catch { XCTAssertEqual(error as? StoreError, .staleSync) }
        }
    }
    func testV10MigrationPreservesWalletPreferencesAndExistingBalance() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Ankr-v10-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let url = folder.appendingPathComponent("test.sqlite")
        let old = try DatabaseQueue(path:url.path)
        try Schema.migrator.migrate(old,upTo:"v10_bitcoin_discovery")
        try await old.write { db in
            try NetworkRecord(id:"ethereum",name:"Ethereum",family:"evm",symbol:"ETH",decimals:18,derivationPath:"m/44'/60'/0'/0/0",logo:"local",sortOrder:0).insert(db)
            try AssetRecord(id:"ethereum:native",networkID:"ethereum",reference:"native",name:"Ethereum",symbol:"ETH",decimals:18).insert(db)
            try db.execute(sql: "INSERT INTO wallets(id,name,kind,vaultReference,createdAt,backedUp) VALUES(?,?,?,?,?,?)", arguments: ["existing", "Existing", "hd", "test", 1, false])
            try AccountRecord(id:"existing:ethereum",walletID:"existing",networkID:"ethereum",address:address,derivationPath:"m/44'/60'/0'/0/0").insert(db)
            try BalanceRecord(accountID:"existing:ethereum",assetID:"ethereum:native",networkID:"ethereum",amountAtomic:"123456789012345678",observedAt:1,source:"cache").insert(db)
            try SettingRecord(key:"currency",value:"JOD",updatedAt:1).insert(db)
        }
        try old.close()
        let db = try await OathDatabase.open(at:url)
        let snapshot = try await db.snapshot(walletID:"existing",currency:"USD")
        XCTAssertEqual(snapshot.currency,"JOD")
        XCTAssertEqual(snapshot.holdings.first?.amountAtomic,"123456789012345678")
        XCTAssertTrue(snapshot.accountSync.isEmpty)
        let ticket = try await db.beginAnkrSync(accountID:"existing:ethereum",stream:"balances")
        XCTAssertNotNil(ticket.state.runID)
    }
    func testDelayedIndexerBoundsNextWindowAndCannotReplaceNewerBalances() async throws {
        let (db,_) = try await fixture()
        let initial = try await db.beginAnkrSync(accountID:"wallet:ethereum",stream:"transactions",now:Date(timeIntervalSince1970:200_000))
        try await db.commitAnkrTransactions(try await transactions([]),ticket:initial,cursor:nil)
        // The provider is only indexed to timestamp 200, despite the request
        // ending at 200,000. A refresh cannot skip that unindexed interval.
        let next = try await db.beginAnkrSync(accountID:"wallet:ethereum",stream:"transactions",now:Date(timeIntervalSince1970:300_000))
        XCTAssertEqual(next.state.windowStart,0)
        var ticket = try await db.beginAnkrSync(accountID:"wallet:ethereum",stream:"balances")
        try await db.commitAnkrBalances(try await [balances([asset()],stamp:200)],ticket:ticket)
        ticket = try await db.beginAnkrSync(accountID:"wallet:ethereum",stream:"balances")
        do { try await db.commitAnkrBalances(try await [balances([],stamp:100)],ticket:ticket); XCTFail() }
        catch { XCTAssertEqual(error as? StoreError,.staleSync) }
        let snapshot = try await db.snapshot(walletID:"wallet",currency:"USD")
        XCTAssertEqual(snapshot.holdings.first { $0.reference == token }?.amountAtomic,"9007199254740993")
    }
    func testNewNetworksReuseExistingEVMPublicIdentityExactlyOnce() async throws {
        let (db,_) = try await fixture(allChains:true)
        try await db.pool.write { try $0.execute(sql:"DELETE FROM accounts WHERE walletID='wallet' AND networkID IN ('fantom','flare','somnia','story'); DELETE FROM accounts WHERE walletID='second' AND networkID<>'ethereum'") }
        // Missing even one of the original full-scope EVM chains preserves
        // the chosen scope, including an explicit import that excludes Arc.
        try await db.enrollAnkrNetworks(walletID:"wallet")
        let narrowed = try await db.accounts(walletID:"wallet")
        XCTAssertEqual(narrowed.count,13)
        try await db.pool.write { db in
            try NetworkRecord(id:"arc",name:"Arc",family:"evm",symbol:"USDC",decimals:18,derivationPath:"m/44'/60'/0'/0/0",logo:"local",sortOrder:20).insert(db)
            try AccountRecord(id:"wallet:arc",walletID:"wallet",networkID:"arc",address:address,derivationPath:"m/44'/60'/0'/0/0").insert(db)
        }
        try await db.seed(networks:[.init(id:"robinhood",name:"Robinhood Chain",family:"evm",symbol:"ETH",decimals:18,derivationPath:"m/44'/60'/0'/0/0",logo:"local",sortOrder:21),
            .init(id:"hyperevm",name:"HyperEVM",family:"evm",symbol:"HYPE",decimals:18,derivationPath:"m/44'/60'/0'/0/0",logo:"local",sortOrder:22),
            .init(id:"celo",name:"Celo",family:"evm",symbol:"CELO",decimals:18,derivationPath:"m/44'/60'/0'/0/0",logo:"local",sortOrder:23),
            .init(id:"chiliz",name:"Chiliz",family:"evm",symbol:"CHZ",decimals:18,derivationPath:"m/44'/60'/0'/0/0",logo:"local",sortOrder:24),
            .init(id:"zerog",name:"0G",family:"evm",symbol:"0G",decimals:18,derivationPath:"m/44'/60'/0'/0/0",logo:"local",sortOrder:25),
            .init(id:"iotex",name:"IoTeX",family:"evm",symbol:"IOTX",decimals:18,derivationPath:"m/44'/60'/0'/0/0",logo:"local",sortOrder:26)], assets:[])
        try await db.enrollAnkrNetworks(walletID:"wallet"); try await db.enrollAnkrNetworks(walletID:"wallet")
        try await db.enrollAnkrNetworks(walletID:"second")
        let accounts = try await db.accounts(walletID:"wallet")
        XCTAssertEqual(accounts.count,24)
        XCTAssertEqual(accounts.filter { $0.networkID == "iotex" }.count,1)
        XCTAssertEqual(accounts.filter { $0.networkID == "zerog" }.count,1)
        XCTAssertEqual(accounts.filter { $0.networkID == "chiliz" }.count,1)
        XCTAssertEqual(accounts.filter { $0.networkID == "celo" }.count,1)
        XCTAssertEqual(accounts.filter { $0.networkID == "hyperevm" }.count,1)
        XCTAssertEqual(accounts.filter { $0.networkID == "robinhood" }.count,1)
        XCTAssertTrue(accounts.allSatisfy { $0.address == address && $0.derivationPath == "m/44'/60'/0'/0/0" })
        let scoped = try await db.accounts(walletID:"second")
        XCTAssertEqual(scoped.count,1)
    }
    func testProductionPublicResponseFilesRoundTripInRealDatabase() async throws {
        guard let directory = ProcessInfo.processInfo.environment["OATH_ANKR_RESPONSES"] else { throw XCTSkip("Opt-in captured public response integration") }
        let (db,_) = try await fixture(allChains:true)
        let publicWallet = "0xF977814e90dA44bFA03b6295A0616a897441aceC"
        try await db.pool.write { try $0.execute(sql:"UPDATE accounts SET address=? WHERE walletID='wallet'",arguments:[publicWallet]) }
        for chain in AnkrChain.allCases {
            let base = URL(fileURLWithPath:directory)
            let raw = try Data(contentsOf:base.appendingPathComponent(chain.rawValue+"-ankr_getAccountBalance.json"))
            let page = try await AnkrClient(apiKey:"fixture",transport:PageTransport(data:raw)).balances(chain:chain,address:publicWallet)
            let ticket = try await db.beginAnkrSync(accountID:"wallet:"+chain.networkID,stream:"balances")
            try await db.commitAnkrBalances([page],ticket:ticket)
            let stored = try await db.ankrResponse(accountID:ticket.account.id,stream:"balances",pageKey:"0")
            XCTAssertEqual(stored,raw)
            let count = try await db.pool.read { try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM ankrAssets WHERE accountID=?",arguments:[ticket.account.id]) }
            XCTAssertEqual(count,page.value.assets.count,chain.rawValue)
            for stream in ["transactions","transfers"] {
                let method = stream == "transactions" ? "ankr_getTransactionsByAddress" : "ankr_getTokenTransfers"
                let bytes = try Data(contentsOf:base.appendingPathComponent(chain.rawValue+"-"+method+".json"))
                let client = try AnkrClient(apiKey:"fixture",transport:PageTransport(data:bytes))
                let h = try await db.beginAnkrSync(accountID:ticket.account.id,stream:stream)
                if stream == "transactions" { try await db.commitAnkrTransactions(try await client.transactions(chain:chain,address:publicWallet),ticket:h,cursor:nil) }
                else { try await db.commitAnkrTransfers(try await client.transfers(chain:chain,address:publicWallet),ticket:h,cursor:nil) }
            }
        }
        let snap = try await db.snapshot(walletID:"wallet",currency:"USD")
        XCTAssertEqual(snap.accounts.count,17)
        XCTAssertTrue(snap.holdings.count > 20_000)
        XCTAssertTrue(snap.accountSync.contains( where: \.isDelayed ))
        print("Recorded live public payloads: \(snap.holdings.count) holdings persisted across all 17 mainnets")
    }
}
