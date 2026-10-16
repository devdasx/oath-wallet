import Foundation
import XCTest
import GRDB
@testable import OathDatabase
@testable import OathAnkr

@MainActor final class SolanaLedgerTests: XCTestCase {
    let phantom = SolanaReceiveAddress(path:"m/44'/501'/0'/0'",address:"HAgk14JpMQLgt6rVgv7cBQFJWFto5Dqxi472uT3DKpqk")
    let trust = SolanaReceiveAddress(path:"m/44'/501'/0'",address:"GjJyeC1r2RgkuoCWMyPYkCWSGSGLcz266EaAkLA27AhL")
    let mint = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"
    let mint2022 = "So11111111111111111111111111111111111111112"
    let token1 = "H31vEBxSJk1nQdUN11qZgZyhScyShhscKhvhZZU3dQoU"
    let token2 = "CutAG7TzyTq6BNECcvLjm2FCxL19pPPQDqV2em91Qeom"
    var catalog: [String:SolanaTokenInfo] { [mint:.init(address:mint,name:"USD Coin",symbol:"USDC",decimals:6,logo:nil)] }
    func fixture() async throws -> (OathDatabase,URL) {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("SolanaLedger-"+UUID().uuidString)
        let db=try await OathDatabase.open(at:folder.appendingPathComponent("wallet.sqlite"))
        try await db.seed(networks:[.init(id:"solana",name:"Solana",family:"account",symbol:"SOL",decimals:9,derivationPath:phantom.path,logo:"solana",sortOrder:0)],assets:[.init(id:"solana:native",networkID:"solana",reference:"native",name:"Solana",symbol:"SOL",decimals:9)])
        for i in 1...2 {
            try await db.importWalletIfNeeded(.init(id:"w\(i)",name:"Public fixture",kind:"hd",vaultReference:"test\(i)",createdAt:1),accounts:[.init(id:"a\(i)",walletID:"w\(i)",networkID:"solana",address:trust.address,derivationPath:trust.path)])
            _=try await db.prepareSolanaReceive(accountID:"a\(i)",addresses:[phantom,trust],preferredPath:phantom.path)
        }
        return (db,folder)
    }
    func inventory(owner:String, slot:UInt64=100, tokens:Bool=true) -> SolanaInventory {
        .init(owner:owner,lamports:"1000000000",nativeSlot:slot,tokenSlot:slot,token2022Slot:slot,
            accounts:tokens ? [
                .init(address:token1,mint:mint,program:SolanaIdentity.tokenProgram,amount:"9007199254740993",decimals:6,frozen:false),
                .init(address:token2,mint:mint,program:SolanaIdentity.tokenProgram,amount:"7",decimals:6,frozen:true),
                .init(address:trust.address,mint:mint2022,program:SolanaIdentity.token2022Program,amount:"9",decimals:9,frozen:false)] : [],fetchedAt:Date(timeIntervalSince1970:Double(slot)),raw:Data("[]".utf8))
    }
    func testExactAggregationWhitelistAndOfflineAddressSwitching() async throws {
        let (db,folder)=try await fixture();defer { try? FileManager.default.removeItem(at:folder) }
        let ticket=try await db.beginSolanaSync(accountID:"a1")
        try await db.commitSolanaInventory(inventory(owner:phantom.address),ticket:ticket,catalog:catalog)
        let snapshot=try await db.snapshot(walletID:"w1",currency:"USD")
        XCTAssertEqual(snapshot.holdings.count,2,"Unverified automatic holdings stay hidden, raw inventory retains them")
        XCTAssertEqual(snapshot.holdings.first { $0.reference==mint }?.amountAtomic,"9007199254741000")
        let storedBalance = try await db.balance(accountID: "a1", assetID: "solana:" + mint)
        XCTAssertEqual(storedBalance?.amountAtomic, "9007199254741000")
        XCTAssertEqual(snapshot.holdings.first { $0.reference=="native" }?.address,phantom.address)
        let raw=try await db.solanaInventory(accountID:"a1");XCTAssertEqual(raw?.accounts.count,3)
        try await db.failSolanaSync(ticket,history:false)
        let retained=try await db.snapshot(walletID:"w1",currency:"USD");XCTAssertEqual(retained.holdings,snapshot.holdings)
        _=try await db.selectSolanaReceivePath(accountID:"a1",path:trust.path)
        let selected=try await db.snapshot(walletID:"w1",currency:"USD")
        XCTAssertEqual(selected.holdings.count,1);XCTAssertNil(selected.holdings[0].amountAtomic)
        XCTAssertEqual(selected.holdings[0].address,trust.address)
        let otherBalance = try await db.balance(accountID: "a1", assetID: "solana:" + mint)
        XCTAssertNil(otherBalance)
        let openDetail = snapshot.holdings.first { $0.reference == mint }!.withoutBalance(address: trust.address)
        XCTAssertNil(openDetail.amountAtomic)
        XCTAssertEqual(openDetail.address, trust.address)
        do { try await db.commitSolanaInventory(inventory(owner:phantom.address,slot:101),ticket:ticket,catalog:catalog);XCTFail("Stale path response committed") } catch { }
        _=try await db.selectSolanaReceivePath(accountID:"a1",path:phantom.path)
        do { try await db.commitSolanaInventory(inventory(owner:phantom.address,slot:102),ticket:ticket,catalog:catalog);XCTFail("ABA switch reused old ticket") } catch { }
        let restored=try await db.snapshot(walletID:"w1",currency:"USD");XCTAssertEqual(restored.holdings,snapshot.holdings)
        let other=try await db.snapshot(walletID:"w2",currency:"USD");XCTAssertNil(other.holdings[0].amountAtomic)
        let reopened=try await OathDatabase.open(at:folder.appendingPathComponent("wallet.sqlite"))
        let cached=try await reopened.snapshot(walletID:"w1",currency:"USD");XCTAssertEqual(cached.holdings,snapshot.holdings)
    }
    func testInventoryZeroesOnlyAfterCompleteSuccessAndRejectsOlderSlots() async throws {
        let (db,folder)=try await fixture();defer { try? FileManager.default.removeItem(at:folder) }
        let ticket=try await db.beginSolanaSync(accountID:"a1")
        try await db.commitSolanaInventory(inventory(owner:phantom.address),ticket:ticket,catalog:catalog)
        do { try await db.commitSolanaInventory(inventory(owner:phantom.address,slot:99,tokens:false),ticket:ticket,catalog:catalog);XCTFail() } catch { XCTAssertEqual(error as? SolanaError,.staleSlot) }
        try await db.commitSolanaInventory(inventory(owner:phantom.address,slot:101,tokens:false),ticket:ticket,catalog:catalog)
        let snapshot=try await db.snapshot(walletID:"w1",currency:"USD")
        XCTAssertEqual(snapshot.holdings.first { $0.reference==mint }?.amountAtomic,"0")
    }
    func transaction(signature:String, slot:UInt64 = 100) -> SolanaTransaction {
        .init(signature:signature,slot:slot,timestamp:1000,failed:false,fee:"5000",changes:[.init(mint:mint,decimals:6,amount:"1234567",direction:"incoming")],tokenAccounts:[token1],raw:Data("{}".utf8))
    }
    func testHistoryPaginationDedupeActivePathFilteringAndReset() async throws {
        let (db,folder)=try await fixture();defer { try? FileManager.default.removeItem(at:folder) }
        let ticket=try await db.beginSolanaSync(accountID:"a1")
        let first=try await db.solanaHistoryWork(ticket,since:1).first!
        let sig=String(repeating:"1",count:64),sig2=String(repeating:"2",count:64)
        let page=SolanaSignaturePage(signatures:[.init(signature:sig,slot:100,blockTime:1000,failed:false)],archival:true)
        try await db.commitSolanaHistory([transaction(signature:sig)],page:page,cursor:first,ticket:ticket,backfill:false,pageSize:1,catalog:catalog)
        let work=try await db.solanaHistoryWork(ticket,since:1);let cursor=work.first { $0.address==phantom.address }!
        XCTAssertEqual(cursor.head,sig);XCTAssertEqual(cursor.before,sig);XCTAssertFalse(cursor.complete)
        let older=SolanaSignaturePage(signatures:[.init(signature:sig2,slot:90,blockTime:999,failed:false)],archival:true)
        try await db.commitSolanaHistory([transaction(signature:sig2,slot:90)],page:older,cursor:cursor,ticket:ticket,backfill:true,pageSize:100,catalog:catalog)
        let entries=try await db.assetHistory(walletID:"w1",accountID:"a1",assetID:"solana:"+mint)
        XCTAssertEqual(entries.count,2);XCTAssertEqual(Set(entries.map(\.hash)),[sig,sig2])
        XCTAssertEqual(entries[0].amountAtomic,"1234567")
        let cache=try await db.cachedSolanaTransactions(ticket,signatures:[sig,sig2]);XCTAssertEqual(cache.count,2)
        _=try await db.selectSolanaReceivePath(accountID:"a1",path:trust.path)
        let other=try await db.assetHistory(walletID:"w1",accountID:"a1",assetID:"solana:"+mint);XCTAssertTrue(other.isEmpty)
        let otherChain = try await db.chainHistory(walletID: "w1", networkID: "solana", currency: "USD")
        XCTAssertTrue(otherChain.isEmpty)
        let all=try await db.history(walletID:"w1");XCTAssertTrue(all.isEmpty)
        _=try await db.selectSolanaReceivePath(accountID:"a1",path:phantom.path)
        let returned=try await db.assetHistory(walletID:"w1",accountID:"a1",assetID:"solana:"+mint);XCTAssertEqual(returned.count,2)
        let returnedChain = try await db.chainHistory(walletID: "w1", networkID: "solana", currency: "USD")
        XCTAssertEqual(returnedChain.count, 2)
        let reset=try await db.beginWalletReset()
        try await db.eraseWalletData(resetID:reset);try await db.finishWalletReset(resetID:reset)
        let history=try await db.history(walletID:"w1");XCTAssertTrue(history.isEmpty)
    }
    func testPrunedAndPartialHistoryNeverAdvancesCursor() async throws {
        let (db,folder)=try await fixture();defer { try? FileManager.default.removeItem(at:folder) }
        let ticket=try await db.beginSolanaSync(accountID:"a1")
        let cursor=try await db.solanaHistoryWork(ticket,since:1).first!
        do { try await db.commitSolanaHistory([],page:.init(signatures:[],archival:false),cursor:cursor,ticket:ticket,backfill:false,pageSize:100,catalog:catalog);XCTFail() }
        catch { XCTAssertEqual(error as? SolanaError,.incompleteHistory) }
        let stillPending=try await db.solanaHistoryWork(ticket,since:1).first!
        XCTAssertEqual(stillPending,cursor)
        let sig=String(repeating:"1",count:64)
        do { try await db.commitSolanaHistory([],page:.init(signatures:[.init(signature:sig,slot:100,blockTime:1000,failed:false)],archival:true),cursor:cursor,ticket:ticket,backfill:false,pageSize:100,catalog:catalog);XCTFail() } catch { }
        let unchanged=try await db.solanaHistoryWork(ticket,since:1).first!;XCTAssertEqual(unchanged,cursor)
    }

    func testSynchronizerPublishesBalancesPricesHistoryAndRetainsOfflineCache() async throws {
        let (db, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let transport = SolanaIntegrationTransport(owner: phantom.address, mint: mint, token: token1)
        let client = try SolanaClient(apiKey: "fixture", transport: transport)
        let sync = SolanaSynchronizer(database: db, client: client, markets: .init(transport: transport))
        try await sync.refresh(accountID: "a1")
        let snapshot = try await db.snapshot(walletID: "w1", currency: "USD")
        XCTAssertEqual(snapshot.holdings.count, 2)
        XCTAssertEqual(snapshot.holdings.first { $0.reference == "native" }?.amountAtomic, "2000000000")
        XCTAssertEqual(snapshot.holdings.first { $0.reference == mint }?.amountAtomic, "123454321")
        XCTAssertEqual(snapshot.holdings.first { $0.reference == mint }?.usdPrice, "1")
        XCTAssertEqual(snapshot.totalFiat, Decimal(string: "373.454321"))
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        var entries: [HistoryEntry] = []
        repeat {
            entries = try await db.assetHistory(walletID: "w1", accountID: "a1", assetID: "solana:" + mint)
            if !entries.isEmpty { break }
            try await Task.sleep(for: .milliseconds(25))
        } while ContinuousClock.now < deadline
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.amountAtomic, "500000")
        XCTAssertEqual(entries.first?.direction, "incoming")
        await sync.cancel()
        await transport.goOffline()
        do { try await sync.refresh(accountID: "a1"); XCTFail("Offline refresh must fail instead of replacing balances") }
        catch { }
        await sync.cancel()
        let retained = try await db.snapshot(walletID: "w1", currency: "USD")
        XCTAssertEqual(retained.totalFiat, snapshot.totalFiat)
        let quote = try await db.marketCache(key: "solana.price." + mint)
        XCTAssertNotNil(quote)
        let inventory = try await db.solanaInventory(accountID: "a1")
        XCTAssertEqual(inventory?.accounts.count, 1)
        _ = try await db.selectSolanaReceivePath(accountID: "a1", path: trust.path)
        let other = try await db.snapshot(walletID: "w1", currency: "USD")
        XCTAssertEqual(other.totalFiat, 0)
        XCTAssertNil(other.holdings.first?.amountAtomic)
    }

    func testOverlappingRefreshesCoalesceAndCancellationAllowsFreshWork() async throws {
        let (db, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let transport = SolanaIntegrationTransport(owner: phantom.address, mint: mint, token: token1)
        await transport.setHeld(true)
        let sync = SolanaSynchronizer(database: db, client: try .init(apiKey: "fixture", transport: transport),
                                      markets: .init(transport: transport))
        let first = Task { try await sync.refresh(accountID: "a1") }
        for _ in 0..<100 {
            if await transport.requestCount >= 3 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let requests = await transport.requestCount
        XCTAssertEqual(requests, 3, "Inventory, catalog and SOL quote overlap")
        let second = Task { try await sync.refresh(accountID: "a1") }
        try await Task.sleep(for: .milliseconds(50))
        let joined = await transport.requestCount
        XCTAssertEqual(joined, requests, "An overlapping refresh reuses the same work")
        await sync.cancel()
        do { try await first.value; XCTFail() } catch { }
        do { try await second.value; XCTFail() } catch { }
        let unchanged = try await db.snapshot(walletID: "w1", currency: "USD")
        XCTAssertNil(unchanged.holdings.first?.amountAtomic)
        await transport.setHeld(false)
        try await sync.refresh(accountID: "a1")
        let refreshed = try await db.snapshot(walletID: "w1", currency: "USD")
        XCTAssertEqual(refreshed.totalFiat, Decimal(string: "373.454321"))
        await sync.cancel()
    }

    func testIncrementalHistoryResumesWithoutSkippingPageAfterRestart() async throws {
        let (db, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ticket = try await db.beginSolanaSync(accountID: "a1")
        let cursor = try await db.solanaHistoryWork(ticket, since: 1).first!
        let old = String(repeating: "1", count: 64), latest = String(repeating: "2", count: 64)
        try await db.commitSolanaHistory([transaction(signature: old)],
            page: .init(signatures: [.init(signature: old, slot: 100, blockTime: 1000, failed: false)], archival: true),
            cursor: cursor, ticket: ticket, backfill: false, pageSize: 20, catalog: catalog)
        let since = Date().timeIntervalSince1970 + 1
        let next = try await db.solanaHistoryWork(ticket, since: since).first { $0.address == phantom.address }!
        XCTAssertTrue(next.complete)
        try await db.commitSolanaHistory([transaction(signature: latest, slot: 101)],
            page: .init(signatures: [.init(signature: latest, slot: 101, blockTime: 1001, failed: false)], archival: true),
            cursor: next, ticket: ticket, backfill: false, pageSize: 1, catalog: catalog)
        let restarted = try await db.beginSolanaSync(accountID: "a1")
        let pending = try await db.solanaHistoryWork(restarted, since: since).first { $0.address == phantom.address }!
        XCTAssertEqual(pending.head, old, "The inclusive refresh boundary stays old until every new page commits")
        XCTAssertEqual(pending.pendingHead, latest)
        XCTAssertEqual(pending.pendingBefore, latest)
        try await db.commitSolanaHistory([], page: .init(signatures: [], archival: true), cursor: pending,
            ticket: restarted, backfill: false, pageSize: 1, catalog: catalog)
        let completed = try await db.solanaHistoryWork(restarted, since: since).first { $0.address == phantom.address }!
        XCTAssertEqual(completed.head, latest)
        XCTAssertNil(completed.pendingBefore)
        let entries = try await db.assetHistory(walletID: "w1", accountID: "a1", assetID: "solana:" + mint)
        XCTAssertEqual(entries.count, 2)
    }

    func testParallelHistoryDiscoveryCanPromoteAnInFlightCursor() async throws {
        let (db, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ticket = try await db.beginSolanaSync(accountID: "a1")
        try await db.commitSolanaInventory(inventory(owner: phantom.address), ticket: ticket, catalog: [:])
        let cursor = try await db.solanaHistoryWork(ticket, since: 1).first { $0.address == token1 }!
        XCTAssertEqual(cursor.priority, 2)
        let ownerCursor = try await db.solanaHistoryWork(ticket, since: 1).first { $0.address == phantom.address }!
        let signature = String(repeating: "1", count: 64)
        let page = SolanaSignaturePage(signatures: [.init(signature: signature, slot: 100, blockTime: 1000, failed: false)], archival: true)
        // Owner history discovers the same token account while its page is fetching.
        try await db.commitSolanaHistory([transaction(signature: signature)], page: page, cursor: ownerCursor,
            ticket: ticket, backfill: false, pageSize: 20, catalog: catalog)
        try await db.commitSolanaHistory([transaction(signature: signature)], page: page, cursor: cursor,
            ticket: ticket, backfill: false, pageSize: 20, catalog: catalog)
        let updated = try await db.solanaHistoryWork(ticket, since: Date().timeIntervalSince1970 + 1).first { $0.address == token1 }!
        XCTAssertEqual(updated.priority, 1)
        XCTAssertTrue(updated.complete)
        let history = try await db.assetHistory(walletID: "w1", accountID: "a1", assetID: "solana:" + mint)
        XCTAssertEqual(history.count, 1)
    }

    /// End-to-end production synchronizer/SQLite check, enabled explicitly.
    /// Public explorer address only; the fixture has no vault or signing keys.
    func testLiveSolanaSyncPersistsCompletePublicWalletHistory() async throws {
        guard let key = ProcessInfo.processInfo.environment["OATH_LIVE_SOLANA_KEY"], !key.isEmpty else {
            throw XCTSkip("Opt-in public Solana API and database test")
        }
        let (db, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let owner = "CutAG7TzyTq6BNECcvLjm2FCxL19pPPQDqV2em91Qeom"
        try await db.importWalletIfNeeded(.init(id: "public-live", name: "Public fixture", kind: "hd", vaultReference: "no-keys", createdAt: 1),
            accounts: [.init(id: "public-live-account", walletID: "public-live", networkID: "solana", address: owner, derivationPath: phantom.path)])
        let sync = SolanaSynchronizer(database: db, client: try SolanaClient(apiKey: key, transport: LiveSolanaAuditTransport()))
        do {
            try await sync.refresh(accountID: "public-live-account")
            let snapshot = try await db.snapshot(walletID: "public-live", currency: "USD")
            let inventory = try await db.solanaInventory(accountID: "public-live-account")
            XCTAssertNotNil(inventory)
            XCTAssertEqual(snapshot.holdings.first { $0.reference == "native" }?.amountAtomic, inventory?.lamports)
            XCTAssertGreaterThan(snapshot.holdings.filter { $0.usdPrice != nil }.count, 3)
            XCTAssertGreaterThan(snapshot.totalFiat, 0)
            let deadline = ContinuousClock.now.advanced(by: .seconds(120))
            var pending = 1
            repeat {
                pending = try await db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM solanaHistoryCursors WHERE accountID='public-live-account' AND (complete=0 OR pendingBefore IS NOT NULL)")! }
                if pending == 0 { break }
                let failure = try await db.pool.read { try String.fetchOne($0, sql: "SELECT historyFailure FROM solanaSync WHERE accountID='public-live-account'") }
                if let failure { print("SOLANA_LIVE_DB historyFailure=\(failure)"); break }
                try await Task.sleep(for: .milliseconds(100))
            } while ContinuousClock.now < deadline
            let entries = try await db.history(walletID: "public-live", limit: 500)
            XCTAssertFalse(entries.isEmpty)
            XCTAssertTrue(entries.contains { $0.assetID == "solana:native" })
            XCTAssertTrue(entries.contains { $0.assetID != "solana:native" })
            XCTAssertEqual(pending, 0, "Every owner and token-account archive cursor must finish")
            let transactionCount = try await db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM solanaTransactions WHERE accountID='public-live-account'")! }
            let cursorCount = try await db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM solanaHistoryCursors WHERE accountID='public-live-account'")! }
            try await assertActivityDetails(db, walletID: "public-live")
            print("SOLANA_LIVE_DB pricedHoldings=\(snapshot.holdings.filter { $0.usdPrice != nil }.count) transactions=\(transactionCount) activity=\(entries.count) archiveCursors=\(cursorCount) pending=\(pending)")
            await sync.cancel()
            let reopened = try await OathDatabase.open(at: folder.appendingPathComponent("wallet.sqlite"))
            let restored = try await reopened.snapshot(walletID: "public-live", currency: "USD")
            XCTAssertEqual(restored.totalFiat, snapshot.totalFiat)
            let persisted = try await reopened.history(walletID: "public-live", limit: 500)
            XCTAssertEqual(persisted.count, entries.count)
        } catch {
            await sync.cancel()
            throw error
        }
    }
}

private struct LiveSolanaAuditTransport: AnkrTransport {
    private let transport = AnkrHTTPTransport()
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let input = try JSONDecoder().decode(SolanaJSON.self, from: request.httpBody!)
        let calls = input.array ?? [input]
        let provider = request.url?.host == "rpc.ankr.com" ? "ankr" : "archive"
        let data: Data, status: Int
        do { (data, status) = try await transport.send(request) }
        catch {
            print("SOLANA_LIVE_RPC provider=\(provider) method=\(calls.first?["method"].string ?? "unknown") batch=\(calls.count) transportFailure=true")
            throw error
        }
        let output = try? JSONDecoder().decode(SolanaJSON.self, from: data)
        let replies = output?.array ?? output.map { [$0] } ?? []
        let errors = replies.compactMap { value -> String? in
            if case .number(let code) = value["error"]["code"] { return code }; return nil
        }
        print("SOLANA_LIVE_RPC provider=\(provider) method=\(calls.first?["method"].string ?? "unknown") batch=\(calls.count) status=\(status) errors=\(errors.joined(separator: ",")) nulls=\(replies.filter { $0["result"].isNull }.count)")
        return (data, status)
    }
}

private actor SolanaIntegrationTransport: AnkrTransport {
    let owner: String
    let mint: String
    let token: String
    var offline = false
    var held = false
    private(set) var requestCount = 0
    init(owner: String, mint: String, token: String) { self.owner = owner; self.mint = mint; self.token = token }
    func goOffline() { offline = true }
    func setHeld(_ value: Bool) { held = value }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        requestCount += 1
        if held { try await Task.sleep(for: .seconds(30)) }
        if offline { return (Data(), 503) }
        func data(_ string: String) -> Data { Data(string.utf8) }
        switch request.url?.host {
        case "tokens.coingecko.com":
            return (data("""
                {"tokens":[{"chainId":null,"address":"\(mint)","name":"USD Coin","symbol":"USDC","decimals":6}]}
                """), 200)
        case "api.coinbase.com":
            return (data(#"{"data":{"base":"SOL","currency":"USD","amount":"125"}}"#), 200)
        case "api.dexscreener.com":
            return (data("""
                [{"chainId":"solana","baseToken":{"address":"\(mint)"},"priceUsd":"1","liquidity":{"usd":500000}}]
                """), 200)
        default: break
        }
        let requestValue = try JSONDecoder().decode(SolanaJSON.self, from: request.httpBody!)
        let calls = requestValue.array ?? [requestValue]
        let signature = String(repeating: "1", count: 64)
        func json(_ string: String) throws -> SolanaJSON { try JSONDecoder().decode(SolanaJSON.self, from: data(string)) }
        let results = try calls.map { call -> SolanaJSON in
            let result: SolanaJSON
            switch call["method"].string {
            case "getGenesisHash": result = .string(SolanaIdentity.genesis)
            case "getBalance": result = try json(#"{"context":{"slot":123},"value":2000000000}"#)
            case "getTokenAccountsByOwner":
                if call["params"].array?[1]["programId"].string == SolanaIdentity.token2022Program {
                    result = try json(#"{"context":{"slot":123},"value":[]}"#)
                } else {
                    result = try json("""
                        {"context":{"slot":123},"value":[{"pubkey":"\(token)","account":{"owner":"\(SolanaIdentity.tokenProgram)","data":{"parsed":{"type":"account","info":{"owner":"\(owner)","mint":"\(mint)","state":"initialized","tokenAmount":{"amount":"123454321","decimals":6}}}}}}]}
                        """)
                }
            case "getSignaturesForAddress":
                result = try json("""
                    [{"signature":"\(signature)","slot":122,"blockTime":1700000000,"err":null}]
                    """)
            case "getTransaction":
                result = try json("""
                    {"slot":122,"blockTime":1700000000,"transaction":{"signatures":["\(signature)"],"message":{"accountKeys":[{"pubkey":"\(owner)"},{"pubkey":"\(token)"}]}},"meta":{"err":null,"fee":5000,"preBalances":[1005000,2039280],"postBalances":[1000000,2039280],"preTokenBalances":[{"accountIndex":1,"mint":"\(mint)","owner":"\(owner)","uiTokenAmount":{"amount":"1000000","decimals":6}}],"postTokenBalances":[{"accountIndex":1,"mint":"\(mint)","owner":"\(owner)","uiTokenAmount":{"amount":"1500000","decimals":6}}]}}
                    """)
            default: throw SolanaError.malformed
            }
            return .object(["jsonrpc": .string("2.0"), "id": call["id"], "result": result])
        }
        return (try JSONEncoder().encode(requestValue.array == nil ? results[0] : .array(results.reversed())), 200)
    }
}
