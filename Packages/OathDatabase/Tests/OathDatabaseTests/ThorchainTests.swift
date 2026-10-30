import Foundation
import XCTest
import GRDB
@testable import OathDatabase
@testable import OathAnkr

private actor ThorchainTransport:AnkrTransport {
    var responses:[(String,Int)]
    var urls:[URL] = []
    init(_ responses:[String]) { self.responses=responses.map{($0,200)} }
    init(statuses:[(String,Int)]) { self.responses=statuses }
    func send(_ request:URLRequest) async throws -> (Data,Int) {
        urls.append(request.url!)
        guard !responses.isEmpty else { throw ThorchainError.transport }
        let r=responses.removeFirst(); return (Data(r.0.utf8),r.1)
    }
}

private actor ThorchainRefreshTransport: AnkrTransport {
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let url = try XCTUnwrap(request.url)
        let json: SolanaJSON
        switch url.path {
        case let path where path.hasSuffix("/blocks/latest"):
            json = .object(["block": .object(["header": .object(["chain_id": .string("thorchain-1"), "height": .string("123")])])])
        case let path where path.contains("/balances/"):
            json = .object(["balances": .array([
                .object(["denom": .string("rune"), "amount": .string("456")]),
                .object(["denom": .string("x/metadata-fixture"), "amount": .string("1000000")])
            ]), "pagination": .object([:])])
        case let path where path.hasSuffix("/txs"):
            json = .object(["total": .string("0"), "tx_responses": .array([])])
        case let path where path.hasSuffix("/denoms_metadata"):
            json = .object(["metadatas": .array([.object([
                "base": .string("x/metadata-fixture"), "name": .string("Old"), "symbol": .string("OLD"),
                "denom_units": .array([
                    .object(["denom": .string("x/metadata-fixture"), "exponent": .number("0")]),
                    .object(["denom": .string("fixture"), "exponent": .number("8")])
                ])
            ])]), "pagination": .object([:])])
        case let path where path.hasSuffix("/pools") || path.hasSuffix("/securedassets"):
            json = .array([])
        case let path where path.hasSuffix("/stats"):
            json = .object(["runePriceUSD": .string("1")])
        default:
            guard url.host == "api.rujira.network" else { throw AnkrError.invalidResponse }
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "query" }?.value ?? ""
            if query.contains("strategies") {
                json = .object(["data": .object(["rujira": .object(["strategies": .object(["edges": .array([]), "pageInfo": .object(["hasNextPage": .bool(false)])])])])])
            } else {
                let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                json = .object(["data": .object(["nodes": .array(["THOR.RUNE", "THOR.TCY", "X/RUJI"].map {
                    .object(["asset": .string($0), "price": .object(["current": .string("1000000000000"), "timestamp": .string(formatter.string(from: .now))])])
                })])])
            }
        }
        return (try JSONEncoder().encode(json), 200)
    }
}
private actor ThorchainLaggingHeightTransport: AnkrTransport {
    private var heights: [Int64]
    private let namedAvailable: Bool
    private let fallback = ThorchainRefreshTransport()
    private(set) var heightReads = 0
    private(set) var bankHeights: [String?] = []
    private(set) var historyQueries: [String] = []
    init(heights: [Int64], namedAvailable: Bool = false) { self.heights = heights; self.namedAvailable = namedAvailable }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        if request.url?.path.hasSuffix("/blocks/latest") == true {
            heightReads += 1
            let height = heights.count > 1 ? heights.removeFirst() : heights[0]
            return (Data("{\"block\":{\"header\":{\"chain_id\":\"thorchain-1\",\"height\":\"\(height)\"}}}".utf8), 200)
        }
        if request.url?.path.contains("/blocks/") == true {
            guard namedAvailable, let requested = request.url?.lastPathComponent else { return (Data("{}".utf8), 404) }
            return (Data("{\"block\":{\"header\":{\"chain_id\":\"thorchain-1\",\"height\":\"\(requested)\"}}}".utf8), 200)
        }
        if request.url?.path.contains("/balances/") == true {
            bankHeights.append(request.value(forHTTPHeaderField: "x-cosmos-block-height"))
        }
        if let url = request.url, url.path.hasSuffix("/txs") {
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "query" }?.value
            historyQueries.append(try XCTUnwrap(query))
        }
        return try await fallback.send(request)
    }
}
private actor ThorchainInterruptedRefreshTransport: AnkrTransport {
    private let fallback = ThorchainRefreshTransport()
    private let suffix: String
    private let persistent: Bool
    private(set) var failedReads = 0
    init(suffix: String, persistent: Bool = false) { self.suffix = suffix; self.persistent = persistent }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        if request.url?.path.contains(suffix) == true, persistent || failedReads == 0 {
            failedReads += 1
            throw AnkrError.transport
        }
        return try await fallback.send(request)
    }
}
private actor ThorchainHeldMarketTransport: AnkrTransport {
    private let fallback = ThorchainRefreshTransport()
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var marketStarted = false
    private(set) var bankReads = 0
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        if request.url?.path.hasSuffix("/denoms_metadata") == true {
            marketStarted = true
            await withCheckedContinuation { continuation = $0 }
        }
        if request.url?.path.contains("/balances/") == true { bankReads += 1 }
        return try await fallback.send(request)
    }
    func releaseMarket() { continuation?.resume(); continuation = nil }
}
private actor ThorchainLiveRefreshTransport: AnkrTransport {
    private let transport = AnkrHTTPTransport()
    private(set) var heightReads = 0
    private(set) var bankHeights: [String] = []
    private(set) var historyQueries: [String] = []
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let url = try XCTUnwrap(request.url)
        if url.path.hasSuffix("/blocks/latest") { heightReads += 1 }
        if url.path.contains("/balances/"), let height = request.value(forHTTPHeaderField: "x-cosmos-block-height") {
            bankHeights.append(height)
        }
        if url.path.hasSuffix("/txs") {
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "query" }?.value
            historyQueries.append(try XCTUnwrap(query))
        }
        return try await transport.send(request)
    }
}
@MainActor final class ThorchainTests:XCTestCase {
    let owner="thor172egzpvhpe4pgd69ql4fjr6sjrlrftkgat79m2"
    let other="thor1g3mlm0r5xtv8e4z2yu66gpuefpslfyn799e8ya"
    func json(_ text:String) throws -> SolanaJSON { try JSONDecoder().decode(SolanaJSON.self,from:Data(text.utf8)) }
    func fixture() async throws -> (OathDatabase,URL) {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("Thorchain-"+UUID().uuidString)
        let db=try await OathDatabase.open(at:folder.appendingPathComponent("wallet.sqlite"))
        try await db.seed(networks:[.init(id:"thorchain",name:"THORChain",family:"account",symbol:"RUNE",decimals:8,derivationPath:"m/44'/931'/0'/0/0",logo:"network-thorchain",sortOrder:0)],assets:[.init(id:"thorchain:native",networkID:"thorchain",reference:"native",name:"THORChain",symbol:"RUNE",decimals:8)])
        for i in 1...2 { try await db.importWalletIfNeeded(.init(id:"w\(i)",name:"Test",kind:"hd",vaultReference:"test\(i)",createdAt:1),accounts:[.init(id:"a\(i)",walletID:"w\(i)",networkID:"thorchain",address:owner,derivationPath:"m/44'/931'/0'/0/0")]) }
        return (db,folder)
    }
    func testRefreshRetriesOlderNodeHeightBeforeFetchingInventory() async throws {
        let (db, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ticket = try await db.beginThorchainSync(accountID: "a1")
        try await db.commitThorchainInventory(.init(owner: owner, holdings: [.init(reference: "native", amount: "123")],
            observedAt: Date(timeIntervalSince1970: 200), height: 200), ticket: ticket, catalog: .init())
        let transport = ThorchainLaggingHeightTransport(heights: [199, 201])
        let sync = ThorchainSynchronizer(database: db, client: ThorchainClient(transport: transport))
        try await sync.refresh(accountID: "a1")
        await sync.waitForHistory(accountID: "a1")
        let heights = await transport.bankHeights
        XCTAssertEqual(heights, ["201"], "Never fetch or relabel an older inventory")
        let balance = try await db.balance(accountID: "a1", assetID: "thorchain:native")
        XCTAssertEqual(balance?.amountAtomic, "456")
        let savedHeight = try await db.pool.read { try Int64.fetchOne($0, sql: "SELECT height FROM thorchainSync WHERE accountID='a1'") }
        XCTAssertEqual(savedHeight, 201)
        await sync.cancel()
    }

    func testHistoryUsesValidatedRefreshHeightWhenAnotherReplicaWouldLag() async throws {
        let (db, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ticket = try await db.beginThorchainSync(accountID: "a1")
        try await db.commitThorchainInventory(.init(owner: owner, holdings: [.init(reference: "native", amount: "123")],
            observedAt: Date(timeIntervalSince1970: 200), height: 200), ticket: ticket, catalog: .init())
        // The first response validates the refresh's block. An unnecessary
        // second latest-block lookup would land on a persistently older replica.
        let transport = ThorchainLaggingHeightTransport(heights: [201, 199])
        let sync = ThorchainSynchronizer(database: db, client: ThorchainClient(transport: transport))
        try await sync.refresh(accountID: "a1")
        await sync.waitForHistory(accountID: "a1")
        let heightReads = await transport.heightReads
        let bankHeights = await transport.bankHeights
        let queries = await transport.historyQueries
        XCTAssertEqual(heightReads, 1, "History must reuse the refresh's validated height")
        XCTAssertEqual(bankHeights, ["201"])
        XCTAssertEqual(queries.count, 6, "All three history indexes must complete their recent and backfill lanes")
        XCTAssertTrue(queries.allSatisfy { $0.contains("tx.height<=201") })
        let cursors = try await db.pool.read { try ThorchainCursor.fetchAll($0, sql: "SELECT * FROM thorchainHistory WHERE accountID='a1'") }
        XCTAssertEqual(cursors.count, 6)
        XCTAssertTrue(cursors.allSatisfy { $0.complete && $0.height == 201 })
        let balance = try await db.balance(accountID: "a1", assetID: "thorchain:native")
        XCTAssertEqual(balance?.amountAtomic, "456")
        await sync.cancel()
    }

    func testLiveRefreshSharesOneValidatedHeightWithAllHistoryStreams() async throws {
        guard ProcessInfo.processInfo.environment["OATH_THORCHAIN_SYNC_LIVE"] == "1" else {
            throw XCTSkip("Opt-in public account refresh; no signing or broadcast")
        }
        let (db, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let transport = ThorchainLiveRefreshTransport()
        let sync = ThorchainSynchronizer(database: db, client: ThorchainClient(transport: transport))
        try await sync.refresh(accountID: "a1")
        await sync.waitForHistory(accountID: "a1")
        let heightReads = await transport.heightReads
        let bankHeights = await transport.bankHeights
        let queries = await transport.historyQueries
        XCTAssertEqual(heightReads, 1)
        let pin = try XCTUnwrap(bankHeights.first)
        XCTAssertTrue(bankHeights.allSatisfy { $0 == pin })
        XCTAssertGreaterThanOrEqual(queries.count, 6)
        XCTAssertTrue(queries.allSatisfy { $0.contains("tx.height<=\(pin)") })
        let cursors = try await db.pool.read { try ThorchainCursor.fetchAll($0, sql: "SELECT * FROM thorchainHistory WHERE accountID='a1'") }
        XCTAssertEqual(cursors.count, 6)
        XCTAssertTrue(cursors.allSatisfy { String($0.height) == pin })
        let balance = try await db.balance(accountID: "a1", assetID: "thorchain:native")
        XCTAssertNotNil(balance)
        let history = try await db.history(walletID: "w1")
        XCTAssertFalse(history.isEmpty, "Real public transactions must reach the history store")
        await sync.cancel()
        print("LIVE THORChain refresh: one latest-height read, six history lanes sharing the bank pin, persisted balance and public transactions")
    }

    func testTransientNodeReadsDoNotAbortRefreshAndPersistRecoveredInventory() async throws {
        for suffix in ["/blocks/latest", "/balances/", "/txs"] {
            let (db, folder) = try await fixture()
            defer { try? FileManager.default.removeItem(at: folder) }
            let transport = ThorchainInterruptedRefreshTransport(suffix: suffix)
            let sync = ThorchainSynchronizer(database: db, client: ThorchainClient(transport: transport))
            try await sync.refresh(accountID: "a1")
            await sync.waitForHistory(accountID: "a1")
            let failures = await transport.failedReads
            XCTAssertEqual(failures, 1)
            let balance = try await db.balance(accountID: "a1", assetID: "thorchain:native")
            XCTAssertEqual(balance?.amountAtomic, "456")
            let reopened = try await OathDatabase.open(at: folder.appendingPathComponent("wallet.sqlite"))
            let persisted = try await reopened.balance(accountID: "a1", assetID: "thorchain:native")
            XCTAssertEqual(persisted, balance)
            await sync.cancel()
        }
    }

    func testPersistentNodeFailurePreservesExistingInventoryAndStillFails() async throws {
        let (db, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ticket = try await db.beginThorchainSync(accountID: "a1")
        try await db.commitThorchainInventory(.init(owner: owner, holdings: [.init(reference: "native", amount: "789")],
            observedAt: Date(timeIntervalSince1970: 1), height: 100), ticket: ticket, catalog: .init())
        let transport = ThorchainInterruptedRefreshTransport(suffix: "/balances/", persistent: true)
        let sync = ThorchainSynchronizer(database: db, client: ThorchainClient(transport: transport))
        do { try await sync.refresh(accountID: "a1"); XCTFail("Persistent failure must not claim a refreshed balance") }
        catch { XCTAssertEqual(error as? ThorchainError, .transport) }
        await sync.waitForHistory(accountID: "a1")
        let failures = await transport.failedReads
        XCTAssertEqual(failures, 2)
        let balance = try await db.balance(accountID: "a1", assetID: "thorchain:native")
        XCTAssertEqual(balance?.amountAtomic, "789")
        XCTAssertEqual(balance?.observedAt, 1)
        await sync.cancel()
    }
    func testPersistentNodeLagKeepsSavedInventoryAndObservationTime() async throws {
        let (db, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ticket = try await db.beginThorchainSync(accountID: "a1")
        XCTAssertEqual(ticket.minimumHeight, 1)
        try await db.commitThorchainInventory(.init(owner: owner, holdings: [.init(reference: "native", amount: "123")],
            observedAt: Date(timeIntervalSince1970: 200), height: 200), ticket: ticket, catalog: .init())
        let reopened = try await OathDatabase.open(at: folder.appendingPathComponent("wallet.sqlite"))
        let continued = try await reopened.beginThorchainSync(accountID: "a1")
        let other = try await reopened.beginThorchainSync(accountID: "a2")
        XCTAssertEqual(continued.minimumHeight, 200)
        XCTAssertEqual(other.minimumHeight, 1, "Height floors belong to each account")
        let original = try await reopened.balance(accountID: "a1", assetID: "thorchain:native")
        let transport = ThorchainLaggingHeightTransport(heights: [199])
        let sync = ThorchainSynchronizer(database: reopened, client: ThorchainClient(transport: transport))
        do { try await sync.refresh(accountID: "a1"); XCTFail("Stale provider became a successful refresh") }
        catch { XCTAssertEqual(error as? ThorchainError, .staleHeight) }
        let requests = await transport.heightReads, banks = await transport.bankHeights
        XCTAssertEqual(requests, 3)
        XCTAssertTrue(banks.isEmpty)
        let after = try await reopened.balance(accountID: "a1", assetID: "thorchain:native")
        XCTAssertEqual(after?.amountAtomic, original?.amountAtomic)
        XCTAssertEqual(after?.observedAt, original?.observedAt)
        let height = try await reopened.pool.read { try Int64.fetchOne($0, sql: "SELECT height FROM thorchainSync WHERE accountID='a1'") }
        XCTAssertEqual(height, 200)
        await sync.cancel()
    }

    func testNamedHeightRecoveryReadsNewBankDataAndPersistsSameNonregressingFloor() async throws {
        let (db, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ticket = try await db.beginThorchainSync(accountID: "a1")
        try await db.commitThorchainInventory(.init(owner: owner, holdings: [.init(reference: "native", amount: "123")],
            observedAt: Date(timeIntervalSince1970: 200), height: 200), ticket: ticket, catalog: .init())
        let transport = ThorchainLaggingHeightTransport(heights: [199], namedAvailable: true)
        let sync = ThorchainSynchronizer(database: db, client: ThorchainClient(transport: transport))
        try await sync.refresh(accountID: "a1")
        await sync.waitForHistory(accountID: "a1")
        let banks = await transport.bankHeights
        XCTAssertEqual(banks, ["200"], "Fresh bank read must use the verified floor")
        let balance = try await db.balance(accountID: "a1", assetID: "thorchain:native")
        XCTAssertEqual(balance?.amountAtomic, "456", "The cached 123 must not be relabeled as freshly read")
        XCTAssertGreaterThan(balance?.observedAt ?? 0, 200)
        let reopened = try await OathDatabase.open(at: folder.appendingPathComponent("wallet.sqlite"))
        let restored = try await reopened.balance(accountID: "a1", assetID: "thorchain:native")
        XCTAssertEqual(restored?.amountAtomic, "456")
        let continued = try await reopened.beginThorchainSync(accountID: "a1")
        XCTAssertEqual(continued.minimumHeight, 200)
        await sync.cancel()
    }

    func testCancelStopsHeightRecoveryBeforeInventoryOrHistoryStarts() async throws {
        let (db, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ticket = try await db.beginThorchainSync(accountID: "a1")
        try await db.commitThorchainInventory(.init(owner: owner, holdings: [.init(reference: "native", amount: "123")],
            observedAt: Date(timeIntervalSince1970: 200), height: 200), ticket: ticket, catalog: .init())
        let transport = ThorchainLaggingHeightTransport(heights: [199, 201])
        let sync = ThorchainSynchronizer(database: db, client: ThorchainClient(transport: transport))
        let task = Task { try await sync.refresh(accountID: "a1") }
        for _ in 0..<100 {
            if await transport.heightReads > 0 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        await sync.cancel()
        do { try await task.value; XCTFail("Cancelled refresh returned") } catch is CancellationError { }
        let requests = await transport.heightReads, banks = await transport.bankHeights
        XCTAssertEqual(requests, 1)
        XCTAssertTrue(banks.isEmpty)
        let balance = try await db.balance(accountID: "a1", assetID: "thorchain:native")
        XCTAssertEqual(balance?.amountAtomic, "123")
        XCTAssertEqual(balance?.observedAt, 200)
    }
    func testSynchronizerCancellationDoesNotWaitForAnotherWalletsCatalog() async throws {
        let (db, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let transport = ThorchainHeldMarketTransport()
        let client = ThorchainClient(transport: transport)
        let otherConsumer = Task { try await client.catalog() }
        for _ in 0..<200 {
            if await transport.marketStarted { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let sync = ThorchainSynchronizer(database: db, client: client)
        let refresh = Task { try await sync.refresh(accountID: "a1") }
        for _ in 0..<200 {
            if await transport.bankReads > 0 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let stopped = expectation(description: "Refresh cancellation is independent of the shared market request")
        let cancellation = Task { await sync.cancel(); stopped.fulfill() }
        await fulfillment(of: [stopped], timeout: 1)
        await transport.releaseMarket()
        await cancellation.value
        do { try await refresh.value; XCTFail("Cancelled refresh succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        let catalog = try await otherConsumer.value
        XCTAssertEqual(catalog.prices["native"], "1")
        // A new account can immediately use the retained catalog and commit
        // its own exact inventory after cancellation of the previous account.
        try await sync.refresh(accountID: "a2")
        await sync.waitForHistory(accountID: "a2")
        let balance = try await db.balance(accountID: "a2", assetID: "thorchain:native")
        XCTAssertEqual(balance?.amountAtomic, "456")
        await sync.cancel()
    }
    func testAddressChecksumAndExactDenominations() throws {
        XCTAssertEqual(try ThorchainIdentity.address(owner),owner)
        XCTAssertThrowsError(try ThorchainIdentity.address(String(owner.dropLast())+"q"))
        XCTAssertThrowsError(try ThorchainIdentity.address(owner.uppercased()))
        XCTAssertThrowsError(try ThorchainIdentity.address("bc1q7cx62nq69tzwtl7fp080trqxrxwzf5pnzjrd7n"))
        XCTAssertEqual(try ThorchainIdentity.bankDenom(asset:"ETH-USDC-0XABCD"),"eth-usdc-0xabcd")
        XCTAssertEqual(try ThorchainIdentity.bankDenom(asset:"X/RUJI"),"x/ruji")
        XCTAssertNil(try ThorchainIdentity.bankDenom(asset:"ETH~USDC-0XABCD"))
        XCTAssertNil(try ThorchainIdentity.bankDenom(asset:"ETH.USDC-0XABCD"))
    }
    func testBalancePaginationPreservesLargeIntegers() async throws {
        let transport=ThorchainTransport([#"{"balances":[{"denom":"rune","amount":"9007199254740993"}],"pagination":{"next_key":"a+/="}}"#,#"{"balances":[{"denom":"x/ruji","amount":"12345678901234567890123"}],"pagination":{"next_key":null}}"#])
        let value=try await ThorchainClient(transport:transport).inventory(owner:owner)
        XCTAssertEqual(value.holdings.first{$0.reference == "native"}?.amount,"9007199254740993")
        XCTAssertEqual(value.holdings.first{$0.reference == "x/ruji"}?.amount,"12345678901234567890123")
        let urls=await transport.urls
        XCTAssertEqual(URLComponents(url:urls[1],resolvingAgainstBaseURL:false)?.queryItems?.first{$0.name == "pagination.key"}?.value,"a+/=")
    }
    func testEmptyAddressAndPaginationLoop() async throws {
        let empty=try await ThorchainClient(transport:ThorchainTransport([#"{"balances":[],"pagination":{"next_key":null}}"#])).inventory(owner:owner)
        XCTAssertEqual(empty.holdings,[.init(reference:"native",amount:"0")])
        let repeatPage=#"{"balances":[],"pagination":{"next_key":"loop"}}"#
        do { _ = try await ThorchainClient(transport:ThorchainTransport([repeatPage,repeatPage])).inventory(owner:owner); XCTFail("loop accepted") }
        catch { XCTAssertEqual(error as? ThorchainError,.paginationLoop) }
    }
    func testTransientProviderRetryAndFailureNeverBecomeZeroBalance() async throws {
        let valid=#"{"balances":[{"denom":"rune","amount":"123"}],"pagination":{"next_key":null}}"#
        let retry=ThorchainTransport(statuses:[("",503),(valid,200)])
        let inventory=try await ThorchainClient(transport:retry).inventory(owner:owner)
        XCTAssertEqual(inventory.holdings,[.init(reference:"native",amount:"123")])
        let retriedURLs=await retry.urls
        XCTAssertEqual(retriedURLs.count,2)
        for status in [403,503] {
            let failing=ThorchainTransport(statuses:[("",status),("",status)])
            do {
                _ = try await ThorchainClient(transport:failing).inventory(owner:owner)
                XCTFail("Provider failure must not become a zero balance")
            } catch { XCTAssertEqual(error as? ThorchainError,.http(status)) }
            let urls=await failing.urls
            XCTAssertEqual(urls.count,status == 503 ? 2:1,"Retries must remain bounded")
        }
    }
    func testSecuredSharesAndNativeUnitsNeverUseExternalDecimals() throws {
        let pools=try json(#"[{"asset":"BTC.BTC","assetPriceUSD":"60000","status":"available","nativeDecimal":"8"},{"asset":"ETH.ETH","assetPriceUSD":"3000","status":"available","nativeDecimal":"18"}]"#)
        let catalog=try ThorchainClient.decodeCatalog(pools:pools,stats:json(#"{"runePriceUSD":"0.65"}"#),secured:json(#"[{"asset":"BTC-BTC","supply":"100","depth":"150"},{"asset":"ETH-ETH","supply":"0","depth":"1"}]"#))
        XCTAssertEqual(catalog.prices["native"],"0.65")
        XCTAssertEqual(catalog.prices["btc-btc"],"90000")
        XCTAssertEqual(catalog.prices["eth/eth"],"3000")
        XCTAssertNil(catalog.prices["eth-eth"])
        XCTAssertEqual(catalog.token("eth-eth").decimals,8)
    }
    func testVaultSharePricesRequireExactDenomFreshnessAndMetadata() throws {
        var catalog=ThorchainCatalog()
        catalog.prices["native"]="2"
        catalog.tokens["x/ghost-vault/rune"] = .init(reference:"x/ghost-vault/rune",name:"RUNE Lend Shares",symbol:"LEND-RUNE")
        let row=try json(#"{"asset":{"variants":{"native":{"denom":"rune"}}},"status":{"depositPool":{"ratio":"1250000000000","shares":"100"},"lastUpdated":"2026-10-14T12:00:00.000Z"}}"#)
        try ThorchainClient.applyVaultMarkets([row],to:&catalog,now:Date(timeIntervalSince1970:1791979200))
        XCTAssertEqual(catalog.prices["x/ghost-vault/rune"],"2.5")
        catalog.prices.removeValue(forKey:"x/ghost-vault/rune")
        try ThorchainClient.applyVaultMarkets([row],to:&catalog,now:Date(timeIntervalSince1970:1791986400))
        XCTAssertNil(catalog.prices["x/ghost-vault/rune"])
        catalog.tokens.removeAll()
        try ThorchainClient.applyVaultMarkets([row],to:&catalog,now:Date(timeIntervalSince1970:1791979200))
        XCTAssertNil(catalog.prices["x/ghost-vault/rune"])
    }
    func testOracleQuotesAreExactFreshAndPreferredOverPoolImbalance() throws {
        let now=Date(timeIntervalSince1970:1791979200)
        let row=try json(#"{"asset":"DOGE.DOGE","price":{"current":"80000000000","timestamp":"2026-10-14T12:00:00.000Z"}}"#)
        let quotes=try ThorchainClient.decodeOracle([row],expected:["DOGE.DOGE"],now:now)
        XCTAssertEqual(quotes["DOGE.DOGE"],"0.08")
        XCTAssertThrowsError(try ThorchainClient.decodeOracle([row],expected:["ETH.ETH"],now:now))
        XCTAssertTrue(try ThorchainClient.decodeOracle([row],expected:["DOGE.DOGE"],now:now.addingTimeInterval(901)).isEmpty)
        let catalog=try ThorchainClient.decodeCatalog(pools:json(#"[{"asset":"DOGE.DOGE","assetPriceUSD":"0.09","status":"available"}]"#),stats:.null,secured:json(#"[{"asset":"DOGE-DOGE","supply":"100","depth":"150"}]"#),oracle:quotes)
        XCTAssertEqual(catalog.prices["doge-doge"],"0.12")
    }
    func testFeeEventsAreNotInventedTransfersAndFailedCallsRemainVisible() throws {
        let reserve="thor1dheycdevq39qlkxs2a6wuuzyn4aqxhve4qxtxt"
        let receipt="""
        {"total":"1","tx_responses":[{"txhash":"\(String(repeating:"B",count:64))","height":"100","timestamp":"2026-10-14T12:00:00Z","code":0,"events":[
        {"type":"transfer","attributes":[{"key":"sender","value":"\(owner)"},{"key":"recipient","value":"\(reserve)"},{"key":"amount","value":"2000000rune"}]},
        {"type":"transfer","attributes":[{"key":"sender","value":"\(owner)"},{"key":"recipient","value":"\(owner)"},{"key":"amount","value":"1rune"},{"key":"msg_index","value":"0"}]}
        ]}]}
        """
        let page=try ThorchainClient.decodeTransactions(json(receipt),owner:owner)
        XCTAssertEqual(page.events.count,1); XCTAssertEqual(page.events.first?.amount,"1")
        XCTAssertEqual(page.events.first?.fee,"2000000"); XCTAssertEqual(page.events.first?.direction,"self")
        guard case var .object(tx) = try json(receipt)["tx_responses"].array?.first else { return XCTFail("missing transaction") }
        tx["code"] = .number("5"); tx["events"] = .array([try json(receipt)["tx_responses"].array![0]["events"].array![0]])
        let failure=try ThorchainClient.decodeTransactions(.object(["total":.string("1"),"tx_responses":.array([.object(tx)])]),owner:owner)
        XCTAssertEqual(failure.events.count,1); XCTAssertEqual(failure.events.first?.state,"failed"); XCTAssertEqual(failure.events.first?.amount,"0")
    }
    func testResetAndDeletedWalletRejectLateWrites() async throws {
        let (db,folder)=try await fixture(); defer { try? FileManager.default.removeItem(at:folder) }
        let ticket=try await db.beginThorchainSync(accountID:"a1")
        let inventory=ThorchainInventory(owner:owner,holdings:[.init(reference:"native",amount:"100")])
        let reset=try await db.beginWalletReset()
        do { try await db.commitThorchainInventory(inventory,ticket:ticket,catalog:.init()); XCTFail("reset accepted stale balance") } catch {}
        do { _ = try await db.beginThorchainSync(accountID:"a1"); XCTFail("reset accepted new work") } catch {}
        try await db.eraseWalletData(resetID:reset); try await db.finishWalletReset(resetID:reset)
        let count=try await db.pool.read { try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM thorchainSync") }
        XCTAssertEqual(count,0)
        do { try await db.commitThorchainInventory(inventory,ticket:ticket,catalog:.init()); XCTFail("deleted wallet resurrected") } catch { XCTAssertEqual(error as? StoreError,.staleSync) }
    }
    func testUnknownTokenUnitsAndHistoryWaitForMetadataThenRecover() async throws {
        let (db,folder)=try await fixture(); defer { try? FileManager.default.removeItem(at:folder) }
        let ticket=try await db.beginThorchainSync(accountID:"a1")
        let ref="x/six-decimal-test"
        try await db.commitThorchainInventory(.init(owner:owner,holdings:[.init(reference:"native",amount:"10"),.init(reference:ref,amount:"1000000")]),ticket:ticket,catalog:.init())
        let before=try await db.asset(networkID:"thorchain",reference:ref)
        XCTAssertNil(before,"Missing metadata must not create a guessed 8-decimal asset")
        let cursor=try await db.thorchainCursor(ticket:ticket,stream:"transfer.recipient",lane:"backfill",height:200)
        let event=ThorchainEvent(id:"units",hash:String(repeating:"C",count:64),reference:ref,amount:"1000000",direction:"incoming",counterparty:other,state:"confirmed",height:100,timestamp:1,fee:nil)
        try await db.commitThorchainHistory(.init(owner:owner,events:[event],next:nil,rawCount:1),cursor:cursor,ticket:ticket,catalog:.init())
        let reopened=try await OathDatabase.open(at:folder.appendingPathComponent("wallet.sqlite"))
        var metadata=ThorchainCatalog()
        metadata.tokens[ref] = .init(reference:ref,name:"Six Decimals",symbol:"SIX",decimals:6); metadata.prices[ref]="2"
        try await reopened.commitThorchainCatalog(metadata,ticket:ticket)
        let restored=try await reopened.snapshot(walletID:"w1",currency:"USD")
        XCTAssertEqual(restored.holdings.first{$0.reference == ref}?.amountAtomic,"1000000")
        XCTAssertEqual(restored.holdings.first{$0.reference == ref}?.decimals,6)
        let history=try await reopened.history(walletID:"w1")
        XCTAssertEqual(history.first?.amountAtomic,"1000000")
        let pending=try await reopened.pool.read { try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM thorchainPendingEvents") }
        XCTAssertEqual(pending,0)
    }
    func history(_ recipient:String? = nil, code:Int = 0, next:Bool = false) throws -> ThorchainHistoryPage {
        let to=recipient ?? owner
        return try ThorchainClient.decodeTransactions(json("""
        {"total":"\(next ? 51:1)","tx_responses":[{"txhash":"\(String(repeating:"A",count:64))","height":"100","timestamp":"2026-10-14T12:00:00Z","code":\(code),"events":[{"type":"transfer","attributes":[{"key":"sender","value":"\(other)"},{"key":"recipient","value":"\(to)"},{"key":"amount","value":"123rune,456x/ruji"}]}]}]}
        """),owner:owner)
    }
    func testHistoryRejectsForeignOwnerAndKeepsTokenTransfers() throws {
        let page=try history()
        XCTAssertEqual(page.events.map(\.reference),["native","x/ruji"])
        XCTAssertEqual(page.events.map(\.amount),["123","456"])
        XCTAssertTrue(page.events.allSatisfy{$0.direction == "incoming" && $0.state == "confirmed"})
        XCTAssertThrowsError(try history(other))
        XCTAssertEqual(try history(next:true).next,"2")
        XCTAssertEqual(try history(code:5).events.first?.state,"failed")
    }
    func testPersistenceIsolationAndStaleResponses() async throws {
        let (db,folder)=try await fixture(); defer { try? FileManager.default.removeItem(at:folder) }
        let ticket=try await db.beginThorchainSync(accountID:"a1")
        let inventory=ThorchainInventory(owner:owner,holdings:[.init(reference:"native",amount:"123456789"),.init(reference:"x/ruji",amount:"9007199254740993")])
        var catalog=ThorchainCatalog(); catalog.prices=["native":"0.65","x/ruji":"0.20"]
        try await db.commitThorchainInventory(inventory,ticket:ticket,catalog:catalog)
        try await db.commitThorchainCatalog(catalog,ticket:ticket)
        let snapshot=try await db.snapshot(walletID:"w1",currency:"USD")
        XCTAssertEqual(snapshot.holdings.count,2)
        XCTAssertEqual(snapshot.holdings.first{$0.reference == "x/ruji"}?.amountAtomic,"9007199254740993")
        let otherSnapshot=try await db.snapshot(walletID:"w2",currency:"USD")
        XCTAssertNil(otherSnapshot.holdings.first?.amountAtomic)
        let reopened=try await OathDatabase.open(at:folder.appendingPathComponent("wallet.sqlite"))
        let saved=try await reopened.snapshot(walletID:"w1",currency:"USD")
        XCTAssertEqual(saved.holdings,snapshot.holdings)
        _ = try await db.beginThorchainSync(accountID:"a1")
        do { try await db.commitThorchainInventory(inventory,ticket:ticket,catalog:catalog); XCTFail("stale accepted") } catch { XCTAssertEqual(error as? StoreError,.staleSync) }
    }
    func testRefreshWithOlderSharedCatalogKeepsNewerCacheAndFreshBalance() async throws {
        let (db, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let client = ThorchainClient(transport: ThorchainRefreshTransport())
        let cachedByClient = try await client.catalog()
        var newer = cachedByClient
        newer.observedAt = cachedByClient.observedAt.addingTimeInterval(1)
        newer.prices["native"] = "2"
        newer.tokens["x/metadata-fixture"] = .init(reference: "x/metadata-fixture", name: "Current", symbol: "NEW", decimals: 6)
        newer.prices["x/metadata-fixture"] = "2"
        let ticket = try await db.beginThorchainSync(accountID: "a1")
        try await db.commitThorchainCatalog(newer, ticket: ticket)
        let winner = MarketCacheEntry(key: "thorchain.catalog", source: "THORChain",
                                     payload: try JSONEncoder().encode(newer), fetchedAt: newer.observedAt.timeIntervalSince1970)
        try await db.saveMarketCache(winner)

        // A new balance read can legitimately share a public catalog that was
        // fetched before another consumer updated the persistent catalog.
        let sync = ThorchainSynchronizer(database: db, client: client)
        try await sync.refresh(accountID: "a1")
        await sync.waitForHistory(accountID: "a1")
        let balance = try await db.balance(accountID: "a1", assetID: "thorchain:native")
        XCTAssertEqual(balance?.amountAtomic, "456")
        let cache = try await db.marketCache(key: "thorchain.catalog")
        XCTAssertEqual(cache, winner, "A successful refresh must retain the newer public observation")
        let price = try await db.pool.read {
            try PriceRecord.fetchOne($0, sql: "SELECT * FROM prices WHERE assetID='thorchain:native' ORDER BY observedAt DESC LIMIT 1")
        }
        XCTAssertEqual(price?.value, "2")
        let token = try await db.asset(networkID: "thorchain", reference: "x/metadata-fixture")
        XCTAssertEqual(token?.decimals, 6)
        XCTAssertEqual(token?.name, "Current")
        let tokenBalance = try await db.balance(accountID: "a1", assetID: "thorchain:x/metadata-fixture")
        XCTAssertEqual(tokenBalance?.amountAtomic, "1000000")
        let reopened = try await OathDatabase.open(at: folder.appendingPathComponent("wallet.sqlite"))
        let persisted = try await reopened.marketCache(key: "thorchain.catalog")
        XCTAssertEqual(persisted, winner)
        await sync.cancel()
    }
    func testResumableHistoryIdempotencyAndZeroBalance() async throws {
        let (db,folder)=try await fixture(); defer { try? FileManager.default.removeItem(at:folder) }
        let ticket=try await db.beginThorchainSync(accountID:"a1")
        let cursor=try await db.thorchainCursor(ticket:ticket,stream:"transfer.recipient",lane:"backfill",height:200)
        try await db.commitThorchainHistory(history(next:true),cursor:cursor,ticket:ticket,catalog:ThorchainCatalog())
        let resumed=try await db.thorchainCursor(ticket:ticket,stream:cursor.stream,lane:cursor.lane,height:300)
        XCTAssertEqual(resumed.height,200); XCTAssertEqual(resumed.page,2)
        let sent=try await db.thorchainCursor(ticket:ticket,stream:"message.sender",lane:"backfill",height:200)
        try await db.commitThorchainHistory(history(),cursor:sent,ticket:ticket,catalog:ThorchainCatalog())
        let entries=try await db.history(walletID:"w1")
        XCTAssertEqual(entries.count,2)
        try await db.commitThorchainInventory(.init(owner:owner,holdings:[.init(reference:"native",amount:"99"),.init(reference:"x/ruji",amount:"50")],observedAt:Date(timeIntervalSince1970:1)),ticket:ticket,catalog:ThorchainCatalog())
        try await db.commitThorchainInventory(.init(owner:owner,holdings:[.init(reference:"native",amount:"0")],observedAt:Date(timeIntervalSince1970:2)),ticket:ticket,catalog:ThorchainCatalog())
        let balance=try await db.balance(accountID:"a1",assetID:"thorchain:x/ruji")
        XCTAssertEqual(balance?.amountAtomic,"0")
    }
    func testLivePublicWalletBalancesTokensHistoryAndPrices() async throws {
        guard ProcessInfo.processInfo.environment["OATH_THORCHAIN_LIVE"] == "1" else { throw XCTSkip("Opt-in public mainnet reads") }
        let client=ThorchainClient(), owner=self.owner
        async let balance=client.inventory(owner:owner)
        async let catalog=client.catalog()
        let height=try await client.latestHeight()
        async let history=client.history(owner:owner,stream:"transfer.recipient",height:height)
        let (value,markets,page)=try await (balance,catalog,history)
        XCTAssertTrue(value.holdings.contains{$0.reference == "x/ruji" && $0.amount != "0"})
        XCTAssertNotNil(markets.prices["native"]); XCTAssertNotNil(markets.prices["tcy"]); XCTAssertNotNil(markets.prices["x/ruji"])
        XCTAssertFalse(page.events.isEmpty)
        // Ordinary public wallet, not a protocol module or exchange ledger.
        let many=try await client.inventory(owner:"thor1m4mkgn97q9zj07qzan66n9hz7ddzsnks6efhac")
        XCTAssertGreaterThan(many.holdings.count,10)
        XCTAssertTrue(many.holdings.contains{$0.reference == "btc-btc"})
        XCTAssertTrue(many.holdings.contains{$0.reference == "tcy"})
        XCTAssertTrue(many.holdings.contains{$0.reference == "x/ruji"})
        for holding in many.holdings { XCTAssertNotNil(markets.prices[holding.reference],"Missing quote for \(holding.reference)") }
        // Re-query the public oracle separately from the catalog pipeline.
        // A small tolerance permits different observation times and markets.
        let priceReferences=many.holdings.map(\.reference).filter{!$0.hasPrefix("x/ghost-vault/")}
        let ids=priceReferences.map { ref in
            Data(("Asset:"+(ref == "native" ? "THOR.RUNE":ref == "tcy" ? "THOR.TCY":ref.uppercased())).utf8).base64EncodedString()
        }
        let literal=String(decoding:try JSONEncoder().encode(ids),as:UTF8.self)
        var oracleURL=URLComponents(string:"https://api.rujira.network/api/graphql")!
        oracleURL.queryItems=[.init(name:"query",value:"{nodes(ids:\(literal)){... on Asset {asset price {current}}}}")]
        var oracleRequest=URLRequest(url:oracleURL.url!); oracleRequest.setValue("OathWallet/1.0",forHTTPHeaderField:"User-Agent")
        let (oracleData,_)=try await URLSession.shared.data(for:oracleRequest)
        let oracle=try JSONDecoder().decode(SolanaJSON.self,from:oracleData)
        let quotes=try XCTUnwrap(oracle["data"]["nodes"].array)
        XCTAssertEqual(quotes.count,priceReferences.count)
        var compared=0
        for (ref,row) in zip(priceReferences,quotes) {
            guard let raw=row["price"]["current"].text.flatMap({Decimal(string:$0)}) else { continue }
            let expected=raw/1_000_000_000_000
            let actual=try XCTUnwrap(markets.prices[ref].flatMap{Decimal(string:$0)})
            XCTAssertLessThan(abs(actual-expected)/expected,Decimal(string:"0.05")!,ref)
            compared += 1
        }
        XCTAssertEqual(compared,15)
        for inventory in [value,many] {
            var request=URLRequest(url:URL(string:"https://api.viewblock.io/thorchain/addresses/"+inventory.owner)!)
            request.setValue("Mozilla/5.0",forHTTPHeaderField:"User-Agent")
            request.setValue("https://runescan.io",forHTTPHeaderField:"Origin")
            let (data,response)=try await URLSession.shared.data(for:request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode,200)
            let explorer=try JSONDecoder().decode(SolanaJSON.self,from:data)
            var expected:[String:Decimal]=["native":try XCTUnwrap(explorer["rune"].text.flatMap{Decimal(string:$0)})]
            for token in try XCTUnwrap(explorer["balances"].array) {
                let ref=try XCTUnwrap(ThorchainIdentity.bankDenom(asset:try XCTUnwrap(token["asset"].string)))
                expected[ref]=try XCTUnwrap(token["amount"].text.flatMap{Decimal(string:$0)})
            }
            XCTAssertEqual(Set(inventory.holdings.map(\.reference)),Set(expected.keys))
            for holding in inventory.holdings {
                let units=try XCTUnwrap(Decimal(string:holding.amount))/pow(Decimal(10),markets.token(holding.reference).decimals)
                XCTAssertEqual(units,expected[holding.reference],holding.reference)
            }
            if inventory.owner == owner {
                let hashes=Set(try XCTUnwrap(explorer["txs"]["docs"].array).compactMap{$0["hash"].string?.uppercased()})
                XCTAssertFalse(hashes.isEmpty)
                XCTAssertTrue(Set(page.events.map(\.hash)).isSubset(of:hashes))
            }
        }
        print("THORChain live: \(value.holdings.count) holdings; \(page.events.count) history events; \(many.holdings.count) multi-asset holdings; \(markets.prices.count) quotes")
    }
    func testLiveSynchronizerPersistsPricesHistoryAndOfflinePortfolio() async throws {
        guard ProcessInfo.processInfo.environment["OATH_THORCHAIN_LIVE"] == "1" else { throw XCTSkip("Opt-in public mainnet reads") }
        let (db,folder)=try await fixture(); defer { try? FileManager.default.removeItem(at:folder) }
        let sync=ThorchainSynchronizer(database:db)
        try await sync.refresh(accountID:"a1"); await sync.waitForHistory(accountID:"a1")
        let snapshot=try await db.snapshot(walletID:"w1",currency:"USD")
        XCTAssertEqual(snapshot.holdings.count,2)
        let records=try await db.history(walletID:"w1"); XCTAssertFalse(records.isEmpty)
        let quote=try await db.latestPrice(assetID:"thorchain:x/ruji",currency:"USD")
        XCTAssertNotNil(quote)
        let reopened=try await OathDatabase.open(at:folder.appendingPathComponent("wallet.sqlite"))
        let offline=try await reopened.snapshot(walletID:"w1",currency:"USD")
        XCTAssertEqual(snapshot.holdings,offline.holdings)
        try await db.pool.write { try $0.execute(sql:"UPDATE accounts SET address=? WHERE id='a2'",arguments:["thor1m4mkgn97q9zj07qzan66n9hz7ddzsnks6efhac"]) }
        try await sync.refresh(accountID:"a2"); await sync.waitForHistory(accountID:"a2")
        let many=try await db.snapshot(walletID:"w2",currency:"USD")
        XCTAssertGreaterThanOrEqual(many.holdings.filter{$0.amountAtomic != nil && $0.amountAtomic != "0"}.count,17)
        let historyCount=try await db.pool.read { try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM visibleActivity WHERE accountID='a2'")! }
        XCTAssertGreaterThan(historyCount,50)
        try await assertActivityDetails(reopened, walletID: "w1")
        try await assertActivityDetails(db, walletID: "w2")
        let incomplete=try await db.pool.read { try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM thorchainHistory WHERE accountID='a2' AND complete=0") }
        XCTAssertEqual(incomplete,0,"The public wallet should fit this bounded history pass")
        print("THORChain persisted multi-asset wallet: \(historyCount) visible history entries")
        await sync.cancel()
    }
}
