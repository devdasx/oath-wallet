import XCTest
import GRDB
import OathAnkr
@testable import OathDatabase

private let syncAddress = "0x1111111111111111111111111111111111111111"
private actor ScriptedAnkrTransport: AnkrTransport {
    struct Request: Sendable {
        let method: String
        let chain: String
        let cursor: String?
        let start: Int?
        let end: Int?
        let onlyWhitelisted: Bool?
    }
    enum Mode { case empty, hold, paginated, expiredCursor, deniedCursor, deniedEthereum, unavailableEthereum, balancePages }
    private var mode: Mode
    private var rejected = false
    private(set) var requests: [Request] = []
    init(_ mode: Mode) { self.mode = mode }
    func set(_ mode: Mode) { self.mode = mode }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let object = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let params = object["params"] as! [String: Any]
        let call = Request(method: object["method"] as! String,
            chain: (params["blockchain"] as! [String])[0], cursor: params["pageToken"] as? String,
            start: params["fromTimestamp"] as? Int, end: params["toTimestamp"] as? Int,
            onlyWhitelisted: params["onlyWhitelisted"] as? Bool)
        requests.append(call)
        for _ in 0..<3_000 {
            guard mode == .hold else { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        if mode == .deniedEthereum && call.chain == "eth" { return (Data(), 401) }
        if mode == .unavailableEthereum && call.chain == "eth" { return (Data(), 503) }
        if mode == .deniedCursor && call.cursor != nil { return (Data(), 401) }
        if mode == .expiredCursor && call.cursor != nil && !rejected {
            rejected = true
            return (try JSONSerialization.data(withJSONObject: ["jsonrpc":"2.0", "id":1,
                "error":["code":-32602, "message":"Expired opaque page token"]]), 200)
        }
        var result: [String: Any]
        if call.method == "ankr_getAccountBalance" {
            result = ["assets":[], "totalBalanceUsd":"0", "totalCount":0]
            if mode == .balancePages {
                let native = call.cursor == nil
                let asset: [String: Any] = ["blockchain":call.chain, "tokenName":"Fixture", "tokenSymbol":"TEST", "tokenDecimals":native ? 18 : 6,
                    "tokenType":native ? "NATIVE" : "ERC20", "contractAddress":"0x" + String(repeating: native ? "0" : "3", count:40),
                    "holderAddress":syncAddress, "balanceRawInteger":"1000000", "balance":"1", "balanceUsd":"", "tokenPrice":""]
                result = ["assets":[asset], "totalBalanceUsd":"", "totalCount":call.onlyWhitelisted == true ? 1 : 2]
                if call.onlyWhitelisted == false, native { result["nextPageToken"] = "full-page-two" }
            }
        } else if call.method == "ankr_getTokenTransfers" {
            result = ["transfers":[]]
        } else if [.paginated, .expiredCursor, .deniedCursor].contains(mode) {
            let number = call.cursor == nil ? 1 : 2
            result = ["transactions":[["blockchain":call.chain, "hash":"0x"+String(format:"%064x", number),
                "from":syncAddress, "to":"0x2222222222222222222222222222222222222222", "value":"0x1",
                "blockNumber":"0xa", "timestamp":"100", "status":"0x1"]]]
            if call.cursor == nil { result["nextPageToken"] = "page-two" }
        } else { result = ["transactions":[]] }
        result["syncStatus"] = ["status":"synced", "timestamp":200, "blockNumber":10]
        return (try JSONSerialization.data(withJSONObject: ["jsonrpc":"2.0", "id":1, "result":result]), 200)
    }
}

private struct UnavailableCatalogTransport: AnkrTransport {
    func send(_ request: URLRequest) async throws -> (Data, Int) { throw URLError(.notConnectedToInternet) }
}

// Hold the first cancellation handler open after releasing its request. This
// gives queued callers time to acquire that permit while cancel() is still
// marking the other worker tasks. No provider or network is involved.
private final class CancellationWindowTransport: AnkrTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var firstCancellation = true
    private var respond = false
    private var count = 0
    private let admittedAfterCancellation = DispatchSemaphore(value: 0)

    var requests: Int { lock.withLock { count } }
    func finishHolding() { lock.withLock { respond = true } }

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let holding = lock.withLock {
            count += 1
            if !firstCancellation { admittedAfterCancellation.signal() }
            return !respond
        }
        if holding {
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    lock.withLock {
                        if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                        else { waiters[id] = continuation }
                    }
                }
            } onCancel: {
                let continuation = self.lock.withLock {
                    self.firstCancellation = false
                    return self.waiters.removeValue(forKey: id)
                }
                continuation?.resume(throwing: CancellationError())
                _ = self.admittedAfterCancellation.wait(timeout: .now() + 0.1)
            }
        }
        let call = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        var result: [String: Any]
        switch call["method"] as? String {
        case "ankr_getAccountBalance": result = ["assets": [], "totalBalanceUsd": "0", "totalCount": 0]
        case "ankr_getTokenTransfers": result = ["transfers": []]
        default: result = ["transactions": []]
        }
        result["syncStatus"] = ["status": "synced", "timestamp": 200, "blockNumber": 10]
        return (try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "result": result]), 200)
    }
}

private actor RateLimitedCatalogTransport: AnkrTransport {
    private let pool = PublicMarketRequests(spacing: .zero)
    private(set) var hosts: [String] = []
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let result = try await pool.send(request) { await self.response(request) }
        return (result.data, result.status)
    }
    private func response(_ request: URLRequest) -> PublicMarketRequests.Response {
        hosts.append(request.url!.host!)
        if request.url!.host == "tokens.coingecko.com" { return .init(data: Data(), status: 429) }
        let body = "[{\"platforms\":{\"story\":\"\(syncAddress)\",\"telos\":\"\(syncAddress)\",\"x-layer\":\"\(syncAddress)\"}}]"
        return .init(data: Data(body.utf8), status: 200)
    }
}

@MainActor final class AnkrSynchronizerTests: XCTestCase {
    func testRateLimitedCatalogsRecoverPersistAndShareOneDirectoryAcrossChains() async throws {
        let chains: [AnkrChain] = [.story, .telos, .xlayer]
        let db = try await fixture(chains)
        let catalogTransport = RateLimitedCatalogTransport()
        let sync = AnkrSynchronizer(database: db,
            client: try AnkrClient(apiKey: "fixture", transport: ScriptedAnkrTransport(.empty)),
            catalogTransport: catalogTransport)
        let outcomes = try await sync.refresh(walletID: "wallet")
        XCTAssertEqual(outcomes.count, 9)
        XCTAssertTrue(outcomes.allSatisfy(\.success))
        for chain in chains {
            let saved = try await db.marketCache(key: "evm.verified." + chain.networkID)
            let catalog = try JSONDecoder().decode(VerifiedEVMTokenCatalog.self, from: XCTUnwrap(saved).payload)
            XCTAssertEqual(catalog.networkID, chain.networkID)
            XCTAssertEqual(catalog.referencesWithoutDecimals, [syncAddress])
        }
        let hosts = await catalogTransport.hosts
        XCTAssertEqual(hosts.filter { $0 == "tokens.coingecko.com" }.count, 1)
        XCTAssertEqual(hosts.filter { $0 == "api.coingecko.com" }.count, 1)
        let second = AnkrSynchronizer(database: db,
            client: try AnkrClient(apiKey: "fixture", transport: ScriptedAnkrTransport(.empty)),
            catalogTransport: catalogTransport)
        _ = try await second.refresh(walletID: "wallet")
        let after = await catalogTransport.hosts
        XCTAssertEqual(after, hosts, "Persisted verification prevents another download after recreating the synchronizer")
    }

    func testOptInDuringRefreshWaitsForOldFlightThenFetchesAllPagesWithoutPromotingTokens() async throws {
        let db = try await fixture()
        let transport = ScriptedAnkrTransport(.hold)
        let sync = AnkrSynchronizer(database: db, client: try AnkrClient(apiKey:"test",transport:transport), catalogTransport: UnavailableCatalogTransport())
        let initial = Task { try await sync.refresh(walletID: "wallet") }
        try await waitForRequests(3, transport: transport)
        var filter = PortfolioFilter(); filter.hidesUnverifiedTokens = false
        try await db.savePortfolioFilter(filter, walletID: "wallet")
        let reveal = Task { try await sync.refreshBalances(walletID: "wallet") }
        await transport.set(.balancePages)
        _ = try await initial.value
        let result = try await reveal.value
        XCTAssertTrue(result.allSatisfy(\.success))
        let requests = await transport.requests.filter { $0.method == "ankr_getAccountBalance" }
        XCTAssertTrue(requests.contains { $0.onlyWhitelisted == false && $0.cursor == nil })
        XCTAssertTrue(requests.contains { $0.onlyWhitelisted == false && $0.cursor == "full-page-two" })
        XCTAssertGreaterThanOrEqual(requests.filter { $0.onlyWhitelisted == true }.count, 2)
        let shown = try await db.snapshot(walletID: "wallet", currency: "USD")
        XCTAssertEqual(shown.holdings.count, 2)
        try await db.savePortfolioFilter(.init(), walletID: "wallet")
        let hidden = try await db.snapshot(walletID: "wallet", currency: "USD")
        XCTAssertEqual(hidden.holdings.count, 1)
    }
    private func fixture(_ chains: [AnkrChain] = [.eth]) async throws -> OathDatabase {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("AnkrSync-"+UUID().uuidString).appendingPathComponent("test.sqlite")
        let db = try await OathDatabase.open(at: url)
        try await db.seed(networks: chains.enumerated().map { i,c in
            .init(id:c.networkID, name:c.networkID, family:"evm", symbol:"ETH", decimals:18,
                  derivationPath:"m/44'/60'/0'/0/0", logo:"local", sortOrder:i)
        }, assets: chains.map {
            .init(id:$0.networkID+":native", networkID:$0.networkID, reference:"native", name:"Native", symbol:"ETH", decimals:18)
        })
        try await db.importWalletIfNeeded(.init(id:"wallet", name:"Test", kind:"hd", vaultReference:"test", createdAt:1),
            accounts:chains.map { .init(id:$0.networkID, walletID:"wallet", networkID:$0.networkID,
                address:syncAddress, derivationPath:"m/44'/60'/0'/0/0") })
        return db
    }
    private func waitForRequests(_ count: Int, transport: ScriptedAnkrTransport) async throws {
        for _ in 0..<100 {
            if await transport.requests.count >= count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Requests did not reach the transport")
    }
    func testOverlappingRefreshesCoalesceAndCancelReleasesEveryPermit() async throws {
        let db = try await fixture([.eth,.bsc,.base,.arbitrum,.polygon,.scroll])
        let transport = ScriptedAnkrTransport(.hold)
        let sync = AnkrSynchronizer(database: db, client: try AnkrClient(apiKey:"test", transport:transport), catalogTransport: UnavailableCatalogTransport())
        let first = Task { try await sync.refresh(walletID:"wallet") }
        try await waitForRequests(4, transport:transport)
        let second = Task { try await sync.refresh(walletID:"wallet") }
        try await Task.sleep(for:.milliseconds(50))
        let before = await transport.requests.count
        XCTAssertEqual(before,4,"One shared four-request limit across both refreshes and all streams")
        await sync.cancel()
        for task in [first, second] {
            do { _ = try await task.value; XCTFail("Canceled refresh must throw cancellation, not return a provider failure") }
            catch is CancellationError { }
        }
        let cancelled = await transport.requests.count
        XCTAssertEqual(cancelled,4,"Queued pre-cancellation work must never start afterwards")
        await transport.set(.empty)
        let fresh = try await sync.refresh(walletID:"wallet")
        XCTAssertEqual(fresh.count,18); XCTAssertTrue(fresh.allSatisfy(\.success))
        let after = await transport.requests.count
        XCTAssertEqual(after,22,"All permits and flights can be reused after cancellation")
    }
    func testCancellationClosesQueuedAdmissionBeforeIndividualWorkersUnwind() async throws {
        let db = try await fixture([.eth,.bsc,.base,.arbitrum,.polygon,.scroll])
        let transport = CancellationWindowTransport()
        let sync = AnkrSynchronizer(database: db,
            client: try AnkrClient(apiKey: "fixture", transport: transport),
            catalogTransport: UnavailableCatalogTransport())
        let pending = Task { try await sync.refresh(walletID: "wallet") }
        for _ in 0..<200 {
            if transport.requests == 4 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(transport.requests, 4)
        // Let all streams enqueue behind the four held requests. Cancellation
        // must close admission as one operation, not one worker at a time.
        try await Task.sleep(for: .milliseconds(50))
        await sync.cancel()
        do { _ = try await pending.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        XCTAssertEqual(transport.requests, 4, "No old queued request may enter the transport during cancellation")
        transport.finishHolding()
        let fresh = try await sync.refresh(walletID: "wallet")
        XCTAssertEqual(fresh.count, 18)
        XCTAssertTrue(fresh.allSatisfy(\.success))
        XCTAssertEqual(transport.requests, 22, "Fresh work must reuse every released permit")
    }
    func testLateResponsesDuringResetStopWithoutFailureWrites() async throws {
        let db = try await fixture()
        let transport = ScriptedAnkrTransport(.hold)
        let sync = AnkrSynchronizer(database: db, client: try AnkrClient(apiKey: "test", transport: transport),
            catalogTransport: UnavailableCatalogTransport())
        let pending = Task { try await sync.refresh(walletID: "wallet") }
        try await waitForRequests(3, transport: transport)
        let before = try await db.ankrStatus(accountID: "ethereum")
        let reset = try await db.beginWalletReset()
        await transport.set(.empty)
        let outcomes = try await pending.value
        XCTAssertEqual(outcomes.count, 3)
        XCTAssertTrue(outcomes.allSatisfy { !$0.success })
        let after = try await db.ankrStatus(accountID: "ethereum")
        XCTAssertEqual(after, before, "Late reset responses must not become storage failures")
        try await db.eraseWalletData(resetID: reset)
        try await db.finishWalletReset(resetID: reset)
    }
    func testCanceledCallerDoesNotReportEmptySuccessOrCancelSharedRefresh() async throws {
        let db = try await fixture()
        let transport = ScriptedAnkrTransport(.hold)
        let sync = AnkrSynchronizer(database: db, client: try AnkrClient(apiKey: "test", transport: transport), catalogTransport: UnavailableCatalogTransport())
        let first = Task { try await sync.refresh(walletID: "wallet") }
        try await waitForRequests(3, transport: transport)
        let canceled = Task { try await sync.refresh(walletID: "wallet") }
        try await Task.sleep(for: .milliseconds(50))
        canceled.cancel()
        // Finish the shared requests promptly without canceling their owner.
        await transport.set(.empty)
        let outcomes = try await first.value
        XCTAssertEqual(outcomes.count, 3)
        XCTAssertTrue(outcomes.allSatisfy(\.success))
        do { _ = try await canceled.value; XCTFail("Canceled caller must stay canceled") }
        catch is CancellationError { }
        let requests = await transport.requests.count
        XCTAssertEqual(requests, 3, "Cancellation of one waiter must not restart or cancel shared work")
    }
    func testAlreadyCanceledRefreshMakesNoProviderRequests() async throws {
        let db = try await fixture()
        let transport = ScriptedAnkrTransport(.empty)
        let sync = AnkrSynchronizer(database: db, client: try AnkrClient(apiKey: "test", transport: transport), catalogTransport: UnavailableCatalogTransport())
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await sync.refresh(walletID: "wallet")
        }
        do { _ = try await task.value; XCTFail("Canceled refresh must not succeed with zero outcomes") }
        catch is CancellationError { }
        let requests = await transport.requests.count
        XCTAssertEqual(requests, 0)
    }
    func testExpiredCursorRestartsSameWindowOnceWithoutDuplicateHistory() async throws {
        let db = try await fixture()
        let transport = ScriptedAnkrTransport(.expiredCursor)
        let sync = AnkrSynchronizer(database:db, client:try AnkrClient(apiKey:"test", transport:transport), catalogTransport: UnavailableCatalogTransport())
        let results = try await sync.refresh(walletID:"wallet")
        XCTAssertTrue(results.allSatisfy(\.success))
        let calls = await transport.requests.filter { $0.method == "ankr_getTransactionsByAddress" }
        XCTAssertEqual(calls.map(\.cursor),[nil,"page-two",nil,"page-two"])
        XCTAssertEqual(Set(calls.compactMap(\.start)).count,1)
        XCTAssertEqual(Set(calls.compactMap(\.end)).count,1)
        let items = try await db.assetHistory(walletID:"wallet",accountID:"ethereum",assetID:"ethereum:native")
        XCTAssertEqual(items.count,2)
        let states = try await db.ankrStatus(accountID:"ethereum")
        XCTAssertTrue(states.allSatisfy { $0.complete && $0.cursor == nil && $0.failure == nil })
    }
    func testPageFailureKeepsHistoryAndResumesAfterRestart() async throws {
        let db = try await fixture()
        let transport = ScriptedAnkrTransport(.deniedCursor)
        let first = AnkrSynchronizer(database:db,client:try AnkrClient(apiKey:"test",transport:transport), catalogTransport: UnavailableCatalogTransport())
        let results = try await first.refresh(walletID:"wallet")
        XCTAssertEqual(results.filter { !$0.success }.map(\.stream),["transactions"])
        let partial = try await db.assetHistory(walletID:"wallet",accountID:"ethereum",assetID:"ethereum:native")
        XCTAssertEqual(partial.count,1)
        let state = try await db.ankrStatus(accountID:"ethereum").first { $0.stream == "transactions" }
        XCTAssertEqual(state?.cursor,"page-two"); XCTAssertFalse(state!.complete)
        await transport.set(.paginated)
        let second = AnkrSynchronizer(database:db,client:try AnkrClient(apiKey:"test",transport:transport), catalogTransport: UnavailableCatalogTransport())
        let resumed = try await second.refresh(walletID:"wallet")
        XCTAssertTrue(resumed.allSatisfy(\.success))
        let calls = await transport.requests.filter { $0.method == "ankr_getTransactionsByAddress" }
        XCTAssertEqual(calls.map(\.cursor),[nil,"page-two","page-two"])
        let complete = try await db.assetHistory(walletID:"wallet",accountID:"ethereum",assetID:"ethereum:native")
        XCTAssertEqual(complete.count,2)
    }
    func testFailedChainDoesNotCancelOtherNetworksOrTurnFailureIntoEmptySuccess() async throws {
        let db = try await fixture([.eth,.base])
        let transport = ScriptedAnkrTransport(.deniedEthereum)
        let sync = AnkrSynchronizer(database:db,client:try AnkrClient(apiKey:"test",transport:transport), catalogTransport: UnavailableCatalogTransport())
        let results = try await sync.refresh(walletID:"wallet")
        XCTAssertEqual(results.filter(\.success).map(\.accountID),["base","base","base"])
        XCTAssertTrue(results.filter { !$0.success }.allSatisfy { ($0.failure as? AnkrError) == .http(401) },
                      "The original provider rejection must survive concurrent aggregation")
        XCTAssertTrue(results.filter(\.success).allSatisfy { $0.failure == nil })
        let snapshot = try await db.snapshot(walletID:"wallet",currency:"USD")
        XCTAssertEqual(snapshot.holdings.first { $0.networkID == "base" }?.amountAtomic,"0")
        XCTAssertNil(snapshot.holdings.first { $0.networkID == "ethereum" }?.amountAtomic)
        XCTAssertTrue(snapshot.accountSync.filter { $0.accountID == "ethereum" }.allSatisfy { $0.failure != nil && !$0.complete })
    }
    func testAvailabilityFailureKeepsOriginalCauseAndOtherChainSuccess() async throws {
        let db = try await fixture([.eth, .base])
        let transport = ScriptedAnkrTransport(.unavailableEthereum)
        let sync = AnkrSynchronizer(database: db, client: try AnkrClient(apiKey: "test", transport: transport),
                                    catalogTransport: UnavailableCatalogTransport())
        let results = try await sync.refresh(walletID: "wallet")
        XCTAssertEqual(results.filter(\.success).count, 3)
        let failed = results.filter { !$0.success }
        XCTAssertEqual(failed.count, 3)
        XCTAssertTrue(failed.allSatisfy { ($0.failure as? AnkrError) == .http(503) })
        let balanceResults = try await sync.refreshBalances(walletID: "wallet")
        XCTAssertEqual(balanceResults.filter(\.success).count, 1)
        XCTAssertEqual(balanceResults.first { !$0.success }?.failure as? AnkrError, .http(503))
        await transport.set(.empty)
        let recovered = try await sync.refresh(walletID: "wallet")
        XCTAssertTrue(recovered.allSatisfy { $0.success && $0.failure == nil })
    }
    func testLivePublicAccountCompletesServiceAndPersistsEmptyInventories() async throws {
        guard ProcessInfo.processInfo.environment["OATH_ANKR_LIVE"] == "1" else { throw XCTSkip("Opt-in public read-only sync") }
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["OATH_ANKR_CONFIG"])
        let config = try PropertyListSerialization.propertyList(from:Data(contentsOf:URL(fileURLWithPath:path)),format:nil) as! [String:Any]
        let db = try await fixture([.somnia,.story,.telos])
        // Widely published exchange address, empty on these three chains at
        // the time of the probe. No installed wallet or secret material read.
        try await db.pool.write { try $0.execute(sql:"UPDATE accounts SET address=?",arguments:["0xF977814e90dA44bFA03b6295A0616a897441aceC"]) }
        let sync = try AnkrSynchronizer(database:db,apiKey:XCTUnwrap(config["AnkrAPIKey"] as? String))
        let outcomes = try await sync.refresh(walletID:"wallet")
        XCTAssertEqual(outcomes.count,9); XCTAssertTrue(outcomes.allSatisfy(\.success))
        let snapshot = try await db.snapshot(walletID:"wallet",currency:"USD")
        XCTAssertTrue(snapshot.accountSync.allSatisfy { $0.complete && $0.lastSuccess != nil && $0.failure == nil })
        XCTAssertTrue(snapshot.holdings.allSatisfy { $0.amountAtomic != nil })
        let pages = try await db.ankrResponsePages(accountID:"story",stream:"balances")
        XCTAssertFalse(pages.isEmpty)
    }
}
