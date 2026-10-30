import Foundation
import XCTest
import OathDiagnostics
@testable import OathDatabase
@testable import OathAnkr

private actor NearPriceScheduleTransport: AnkrTransport {
    let references: [String]
    let missing: Set<String>
    let zeroBalances: Bool
    let fallbackFails: Bool
    let stallPrimary: Bool
    var primaryCalls = 0, fallbackCalls = 0, primaryActive = 0, primaryMaximum = 0
    var sequence: [String] = []
    let blockHash = "HJcKVPta9MX2cZ2wQ9jZSRxa7f6WABptK6iv98DxA3U4"
    init(references: [String], missing: Set<String> = [], zeroBalances: Bool = false,
         fallbackFails: Bool = false, stallPrimary: Bool = false) {
        self.references = references; self.missing = missing; self.zeroBalances = zeroBalances
        self.fallbackFails = fallbackFails; self.stallPrimary = stallPrimary
    }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let url = request.url!
        func encode(_ json: NearJSON) throws -> (Data, Int) { (try JSONEncoder().encode(json), 200) }
        func result(_ json: NearJSON) throws -> (Data, Int) {
            try encode(.object(["jsonrpc": .string("2.0"), "id": .number("1"), "result": json]))
        }
        switch url.host {
        case "api.coinbase.com":
            return try encode(.object(["data": .object(["base": .string("NEAR"), "currency": .string("USD"), "amount": .string("5")])]))
        case "api.coingecko.com":
            primaryCalls += 1; primaryActive += 1; primaryMaximum = max(primaryMaximum, primaryActive)
            sequence.append("primary")
            defer { primaryActive -= 1 }
            try await Task.sleep(for: stallPrimary ? .seconds(60) : .milliseconds(10))
            let ids = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
                .first { $0.name == "ids" }!.value!.split(separator: ",").map(String.init)
            return try encode(.object(Dictionary(uniqueKeysWithValues: ids.filter { !missing.contains($0) }.map {
                ($0, .object(["usd": .number("2"), "last_updated_at": .number(String(Int(Date().timeIntervalSince1970)))]))
            })))
        case "prices.intear.tech":
            fallbackCalls += 1; sequence.append("fallback")
            if fallbackFails { throw AnkrError.transport }
            return try encode(.object(Dictionary(uniqueKeysWithValues: references.map {
                ($0, .object(["decimal": .number("24"), "price": .string("9")]))
            })))
        case "api.fastnear.com":
            return try encode(.object(["account_id": .string("root.near"), "tokens": .array(references.map {
                .object(["contract_id": .string($0), "balance": .string(zeroBalances ? "0" : "100")])
            })]))
        case "transfers.main.fastnear.com": return try encode(.object(["transfers": .array([])]))
        case "tx.main.fastnear.com": return try encode(.object(["account_txs": .array([])]))
        default: break
        }
        let body = try JSONDecoder().decode(NearJSON.self, from: request.httpBody!)
        switch body["method"].string {
        case "EXPERIMENTAL_genesis_config": return try result(.object(["chain_id": .string("mainnet")]))
        case "block":
            return try result(.object(["header": .object(["hash": .string(blockHash), "height": .number("123"),
                "timestamp_nanosec": .string(String(Int64(Date().timeIntervalSince1970) * 1_000_000_000))])]))
        case "query":
            let params = body["params"]
            var output: [String: NearJSON] = ["block_hash": .string(blockHash), "block_height": .number("123")]
            if params["request_type"].string == "view_account" {
                output.merge(["amount": .string("1000000000000000000000000"), "locked": .string("0"), "storage_usage": .number("123")]) { _, new in new }
            } else {
                let payload: NearJSON = params["method_name"].string == "ft_metadata"
                    ? .object(["spec": .string("ft-1.0.0"), "name": .string("Fixture Token"), "symbol": .string("TEST"), "decimals": .number("24")])
                    : .string(zeroBalances ? "0" : "100")
                output["result"] = .array(try JSONEncoder().encode(payload).map { .number(String($0)) })
            }
            return try result(.object(output))
        default: throw NearError.malformed
        }
    }
}

@MainActor final class NearPriceSchedulingTests: XCTestCase {
    fileprivate static func fixture(_ feed: any AnkrTransport, refs: [String], client: NearClient? = nil, markets: NearMarkets? = nil) async throws -> (OathDatabase, NearSynchronizer, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let db = try await OathDatabase.open(at: directory.appendingPathComponent("wallet.sqlite"))
        try await db.seed(networks: [.init(id: "near", name: "NEAR", family: "account", symbol: "NEAR", decimals: 24, derivationPath: "m/44'/397'/0'", logo: "near", sortOrder: 0)], assets: [.init(id: "near:native", networkID: "near", reference: "native", name: "NEAR", symbol: "NEAR", decimals: 24)])
        try await db.importWalletIfNeeded(.init(id: "fixture-wallet", name: "Fixture", kind: "watchOnly", vaultReference: "fixture", createdAt: 1), accounts: [.init(id: "fixture-account", walletID: "fixture-wallet", networkID: "near", address: "root.near", derivationPath: "")])
        let catalog = NearCatalog(ids: Dictionary(uniqueKeysWithValues: refs.map { ($0, $0) }))
        try await db.saveMarketCache(.init(key: "near.catalog", source: "fixture", payload: JSONEncoder().encode(catalog), fetchedAt: Date().timeIntervalSince1970))
        let client = try client ?? NearClient(endpoint: URL(string: "https://rpc.example.test")!, transport: feed)
        return (db, NearSynchronizer(database: db, client: client, markets: markets ?? NearMarkets(transport: feed)), directory)
    }

    func testNativeOnlyAndZeroTokenWalletsNeverRequestUnusedFallback() async throws {
        for refs in [[], ["zero.near"]] {
            let feed = NearPriceScheduleTransport(references: refs, zeroBalances: true, fallbackFails: true)
            let (db, sync, directory) = try await Self.fixture(feed, refs: refs)
            defer { try? FileManager.default.removeItem(at: directory) }
            try await sync.refresh(accountID: "fixture-account")
            await sync.cancel()
            let native = try await db.latestPrice(assetID: "near:native", currency: "USD")
            XCTAssertEqual(native?.value, "5")
            let fallbackCalls = await feed.fallbackCalls, primaryCalls = await feed.primaryCalls
            XCTAssertEqual(fallbackCalls, 0, "An unnecessary fallback outage must not delay an already priced wallet")
            XCTAssertEqual(primaryCalls, 0)
        }
    }

    func testCompletePrimaryQuotesAvoidFallbackAndKeepTwoBatchLimit() async throws {
        let refs = (0..<65).map { "t\($0).near" }
        let feed = NearPriceScheduleTransport(references: refs, fallbackFails: true)
        let (db, sync, directory) = try await Self.fixture(feed, refs: refs)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await sync.refresh(accountID: "fixture-account")
        await sync.cancel()
        for ref in refs {
            let price = try await db.latestPrice(assetID: "near:" + ref, currency: "USD")
            XCTAssertEqual(price?.value, "2")
            XCTAssertEqual(price?.source, "CoinGecko")
        }
        let fallbackCalls = await feed.fallbackCalls, primaryCalls = await feed.primaryCalls, maximum = await feed.primaryMaximum
        XCTAssertEqual(fallbackCalls, 0)
        XCTAssertEqual(primaryCalls, 3)
        XCTAssertLessThanOrEqual(maximum, 2)
    }

    func testOnlyMissingQuotesUseOneBulkFallbackAfterPrimaryBatches() async throws {
        let refs = (0..<65).map { "t\($0).near" }, missing: Set<String> = ["t1.near", "t32.near", "t64.near"]
        let feed = NearPriceScheduleTransport(references: refs, missing: missing)
        let (db, sync, directory) = try await Self.fixture(feed, refs: refs)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await sync.refresh(accountID: "fixture-account")
        await sync.cancel()
        for ref in refs {
            let price = try await db.latestPrice(assetID: "near:" + ref, currency: "USD")
            XCTAssertEqual(price?.value, missing.contains(ref) ? "9" : "2")
            XCTAssertEqual(price?.source, missing.contains(ref) ? "Intear" : "CoinGecko")
        }
        let sequence = await feed.sequence
        XCTAssertEqual(sequence.filter { $0 == "fallback" }.count, 1)
        XCTAssertEqual(sequence.last, "fallback", "Fallback must only run after primary coverage is known")
    }

    func testCancellationDuringPrimaryDoesNotLaunchFallback() async throws {
        let refs = ["token.near"], feed = NearPriceScheduleTransport(references: ["token.near"], stallPrimary: true)
        let (db, sync, directory) = try await Self.fixture(feed, refs: refs)
        defer { try? FileManager.default.removeItem(at: directory) }
        let work = Task { try await sync.refresh(accountID: "fixture-account") }
        for _ in 0..<200 {
            if await feed.primaryCalls > 0 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let started = await feed.primaryCalls
        XCTAssertEqual(started, 1)
        await sync.cancel()
        do { try await work.value; XCTFail("Cancelled refresh succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        let fallbacks = await feed.fallbackCalls
        XCTAssertEqual(fallbacks, 0)
        let price = try await db.latestPrice(assetID: "near:token.near", currency: "USD")
        XCTAssertNil(price)
    }
}

@MainActor final class NearPriceSchedulingDiagnosticsTests: XCTestCase {
    func testUnusedFallbackIsQuietAndRequiredOutagePreservesPriceWithoutAvailabilityReports() async throws {
        // The production outbox is configured once per process. Reuse the
        // suite's sink and isolate by operation, including full/parallel runs.
        let reports = DatabaseDiagnosticProbe.shared
        await reports.configure()
        let quietID = UUID(), failureID = UUID()
        let unused = NearPriceScheduleTransport(references: [], fallbackFails: true)
        let (_, nativeSync, nativeDirectory) = try await NearPriceSchedulingTests.fixture(unused, refs: [])
        defer { try? FileManager.default.removeItem(at: nativeDirectory) }
        try await OathDiagnostics.$operationID.withValue(quietID) {
            try await nativeSync.refresh(accountID: "fixture-account")
        }
        await nativeSync.waitForHistory(accountID: "fixture-account")
        await nativeSync.cancel()
        await OathDiagnostics.flush()
        let quiet = await reports.events().filter { $0.operationID == quietID }
        XCTAssertTrue(quiet.isEmpty)

        let feed = NearPriceScheduleTransport(references: ["token.near"], missing: ["token.near"], fallbackFails: true)
        let (db, sync, directory) = try await NearPriceSchedulingTests.fixture(feed, refs: ["token.near"])
        defer { try? FileManager.default.removeItem(at: directory) }
        try await db.saveAsset(.init(id: "near:token.near", networkID: "near", reference: "token.near", name: "Fixture Token", symbol: "TEST", decimals: 24))
        let previous = PriceRecord(assetID: "near:token.near", currency: "USD", value: "7", observedAt: 100, source: "saved")
        try await db.savePrices([previous])
        try await OathDiagnostics.$operationID.withValue(failureID) {
            try await sync.refresh(accountID: "fixture-account")
        }
        await sync.waitForHistory(accountID: "fixture-account")
        await sync.cancel()
        let saved = try await db.latestPrice(assetID: "near:token.near", currency: "USD")
        XCTAssertEqual(saved?.value, previous.value)
        XCTAssertEqual(saved?.observedAt, previous.observedAt)
        XCTAssertEqual(saved?.source, previous.source)
        let balance = try await db.balance(accountID: "fixture-account", assetID: "near:token.near")
        XCTAssertEqual(balance?.amountAtomic, "100", "Price failures must not undo verified balances")
        let fallbackCalls = await feed.fallbackCalls
        XCTAssertEqual(fallbackCalls, 1, "The required fallback must actually be attempted")
        // Availability failures are deliberately excluded before reporter admission.
        // Preserve the verified balance and cached price, without expecting events
        // that the current diagnostics policy explicitly rejects.
        await OathDiagnostics.flush()
        let events = await reports.events().filter { $0.operationID == failureID }
        XCTAssertTrue(events.isEmpty)

    }
}

private actor LiveNearSchedulingTransport: AnkrTransport {
    let live = AnkrHTTPTransport()
    var fallbackReads = 0
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        if request.url?.host == "api.coingecko.com" { return (Data(), 429) }
        if request.url?.host == "prices.intear.tech" { fallbackReads += 1 }
        return try await live.send(request)
    }
}

@MainActor final class NearPriceSchedulingLiveTests: XCTestCase {
    func testReadOnlyProductionSyncWithPrimaryTokenQuotesUnavailable() async throws {
        guard ProcessInfo.processInfo.environment["OATH_NEAR_PRICE_SCHEDULING_LIVE"] == "1" else {
            throw XCTSkip("Opt-in public NEAR account sync and real fallback quotes; no signing or broadcast")
        }
        let feed = LiveNearSchedulingTransport()
        let client = try NearClient(endpoint: URL(string: "https://rpc.mainnet.near.org")!)
        let (db, sync, directory) = try await NearPriceSchedulingTests.fixture(feed, refs: ["wrap.near"], client: client, markets: NearMarkets(transport: feed))
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try await sync.refresh(accountID: "fixture-account")
            await sync.cancel()
            let savedInventory = try await db.nearInventory(accountID: "fixture-account")
            let inventory = try XCTUnwrap(savedInventory)
            let eligible = inventory.holdings.filter { $0.reference != "native" && $0.amount != nil && $0.amount != "0" && $0.token != nil }
            XCTAssertFalse(eligible.isEmpty, "Live account must exercise token price fallback")
            var recovered = 0
            for holding in eligible {
                if let quote = try await db.latestPrice(assetID: "near:" + holding.reference, currency: "USD"), quote.source == "Intear" {
                    XCTAssertGreaterThan(Decimal(string: quote.value) ?? 0, 0)
                    XCTAssertLessThan(Date().timeIntervalSince1970 - quote.observedAt, 120)
                    recovered += 1
                }
            }
            XCTAssertGreaterThan(recovered, 0)
            let reads = await feed.fallbackReads
            XCTAssertTrue((1...2).contains(reads), "At most one token fallback; a native Coinbase outage can use the shared source too")
            let reopened = try await OathDatabase.open(at: directory.appendingPathComponent("wallet.sqlite"))
            let offline = try await reopened.nearInventory(accountID: "fixture-account")
            XCTAssertEqual(offline?.holdings, inventory.holdings)
            print("NEAR_PRICE_SCHEDULING_LIVE eligibleTokens=\(eligible.count) recoveredQuotes=\(recovered) bulkFallbackReads=\(reads) offlineInventoryMatched=true")
        } catch { await sync.cancel(); throw error }
    }
}
