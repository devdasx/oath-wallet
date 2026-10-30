import XCTest
import OathDatabase
import OathDiagnostics
@testable import OathMarketData

private actor EmptyTradingHistory: MarketTransport {
    let now: Date
    var paths: [String] = []
    init(now: Date) { self.now = now }
    func data(from url: URL) async throws -> Data {
        paths.append(url.path)
        if url.host == "api.exchange.coinbase.com" {
            if url.path.hasSuffix("/stats") { throw MarketDataError.notListed }
            return Data("[]".utf8)
        }
        return try JSONSerialization.data(withJSONObject: ["prices": [
            [(now.timeIntervalSince1970 - 3600) * 1000, 2.0],
            [now.timeIntervalSince1970 * 1000, 2.2]
        ]])
    }
}

private struct MissingOrMalformedMarket: MarketTransport {
    let malformed: Bool
    func data(from url: URL) async throws -> Data {
        if malformed && url.path.hasSuffix("/candles") { return Data("[[1,2,3]]".utf8) }
        throw MarketDataError.notListed
    }
}

private actor CancelledProviderReportsRateLimit: MarketTransport {
    let started: XCTestExpectation
    var calls = 0
    init(started: XCTestExpectation) { self.started = started }
    func data(from url: URL) async throws -> Data {
        calls += 1
        if calls == 1 {
            started.fulfill()
            do { try await Task.sleep(for: .seconds(5)) }
            catch { throw MarketDataError.rateLimited } // Deliberately uncooperative provider teardown.
            throw MarketDataError.unavailable
        }
        return Data(#"{"id":"ethereum","name":"Ethereum","symbol":"eth","description":{"en":"Network"},"links":{},"image":{}}"#.utf8)
    }
}

@MainActor final class MarketRecoveryTests: XCTestCase {
    func testMissingOptionalDataStaysQuietWhileMalformedDataRemainsCorrelated() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let capture = MarketTestDiagnostics.shared
        let db = try await OathDatabase.open(at: folder.appendingPathComponent("test.sqlite"))
        let asset = MarketAsset(id: "ethereum:native", networkID: "ethereum", reference: "native", decimals: 18)
        let correlation = UUID()
        await OathDiagnostics.$chain.withValue("ethereum") {
            await OathDiagnostics.$operationID.withValue(correlation) {
                let absent = MarketDataService(database: db, transport: MissingOrMalformedMarket(malformed: false))
                for _ in 0..<2 {
                    do { _ = try await absent.chart(for: asset, force: true); XCTFail("Invented chart") }
                    catch { XCTAssertEqual(error as? MarketDataError, .notListed) }
                }
                let invalid = MarketDataService(database: db, transport: MissingOrMalformedMarket(malformed: true))
                do { _ = try await invalid.chart(for: asset); XCTFail("Invalid chart accepted") }
                catch { XCTAssertEqual(error as? MarketDataError, .invalidResponse) }
            }
        }
        for _ in 0..<100 {
            if await !capture.events(for: correlation).isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(100))
        let events = await capture.events(for: correlation)
        XCTAssertEqual(events.count, 1, "Only the malformed response is a failure; no missing listing or stats reports")
        XCTAssertEqual(events.first?.context["chain"], "ethereum")
        XCTAssertEqual(events.first?.error.message, "invalidResponse")

        let recoveryID = UUID(), now = Date()
        let rune = MarketAsset(id: "thorchain:native", networkID: "thorchain", reference: "native", decimals: 8)
        _ = try await OathDiagnostics.$chain.withValue("thorchain") {
            try await OathDiagnostics.$operationID.withValue(recoveryID) {
                try await MarketDataService(database: db, transport: RuneInformationTransport(now: now)).information(for: rune)
            }
        }
        var recovery: [DiagnosticEvent] = []
        for _ in 0..<100 {
            recovery = await capture.events(for: recoveryID)
            if recovery.contains(where: { $0.operation == "information_fallback" }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let fallback = try XCTUnwrap(recovery.first { $0.operation == "information_fallback" })
        XCTAssertEqual(fallback.component, "prices")
        XCTAssertEqual(fallback.error.message, "rateLimited")
        XCTAssertEqual(fallback.context, ["chain": "thorchain", "source": "CoinGecko"])
        let encoded = String(decoding: try JSONEncoder().encode(recovery), as: UTF8.self)
        for excluded in ["https://", "rune-thorchain", "217810156", "415000571", "liquidity network"] {
            XCTAssertFalse(encoded.contains(excluded))
        }

        struct ThrottledInformation: MarketTransport {
            func data(from url: URL) async throws -> Data { throw MarketDataError.rateLimited }
        }
        let throttledID = UUID()
        let throttled = MarketDataService(database: db, transport: ThrottledInformation())
        await OathDiagnostics.$operationID.withValue(throttledID) {
            for _ in 0..<5 {
                do { _ = try await throttled.information(for: asset, force: true); XCTFail("Throttled response accepted") }
                catch { XCTAssertEqual(error as? MarketDataError, .rateLimited) }
            }
        }
        for _ in 0..<100 {
            if await !capture.events(for: throttledID).isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(100))
        let throttledEvents = await capture.events(for: throttledID)
        XCTAssertEqual(throttledEvents.count, 1, "The original failure reports once; reading its cached backoff is not a new failure")
        XCTAssertEqual(throttledEvents.first?.error.message, "rateLimited")

        let chartID = UUID()
        let doge = MarketAsset(id: "dogecoin:native", networkID: "dogecoin", reference: "native", decimals: 8)
        let unavailable = UnavailableExchangeChart(URLError(.timedOut), date: now)
        _ = try await OathDiagnostics.$operationID.withValue(chartID) {
            try await MarketDataService(database: db, transport: unavailable, now: { now }).chart(for: doge)
        }
        for _ in 0..<100 {
            if await !capture.events(for: chartID).isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(100))
        let chartEvents = await capture.events(for: chartID)
        XCTAssertEqual(chartEvents.count, 1, "Recovery retains the original timeout without duplicate fallback reports")
        XCTAssertEqual(chartEvents.first?.error.domain, NSURLErrorDomain)
        XCTAssertEqual(chartEvents.first?.error.code, URLError.timedOut.rawValue)

        let interruptedID = UUID()
        do {
            _ = try await OathDiagnostics.$operationID.withValue(interruptedID) {
                try await ParallelMarketPrice.first([
                    .init(source: "task-cancel", fetch: { throw CancellationError() }),
                    .init(source: "http-cancel", fetch: { throw URLError(.cancelled) })
                ], network: "dogecoin", timeout: .milliseconds(300))
            }
            XCTFail("Interrupted reads succeeded")
        } catch { XCTAssertTrue(error is CancellationError) }
        try await Task.sleep(for: .milliseconds(100))
        let interruptedEvents = await capture.events(for: interruptedID)
        XCTAssertTrue(interruptedEvents.isEmpty, "Provider cancellation is expected control flow, not a failure")

        let closingID = UUID(), started = expectation(description: "Closing screen starts its provider")
        let closingFeed = CancelledProviderReportsRateLimit(started: started)
        let closingService = MarketDataService(database: db, transport: closingFeed)
        let closing = Task {
            try await OathDiagnostics.$operationID.withValue(closingID) {
                try await closingService.information(for: asset, force: true)
            }
        }
        await fulfillment(of: [started], timeout: 2)
        closing.cancel()
        do { _ = try await closing.value; XCTFail("Closed screen returned data") }
        catch { XCTAssertTrue(error is CancellationError) }
        let recovered = try await closingService.information(for: asset, force: true)
        XCTAssertEqual(recovered.value.name, "Ethereum")
        try await Task.sleep(for: .milliseconds(100))
        let closingEvents = await capture.events(for: closingID)
        XCTAssertTrue(closingEvents.isEmpty, "Already-cancelled producer teardown must not invent an outage")
        let closingCalls = await closingFeed.calls
        XCTAssertEqual(closingCalls, 2, "Closing a screen must not put its next load in outage backoff")
    }

    func testEmptyTradingWindowsAreAbsentDataButMalformedRowsStayFailures() throws {
        let now = Date()
        XCTAssertThrowsError(try MarketDecoding.chart(Data("[]".utf8), stats: nil, now: now)) {
            XCTAssertEqual($0 as? MarketDataError, .notListed)
        }
        XCTAssertThrowsError(try MarketDecoding.geckoChart(Data(#"{"prices":[]}"#.utf8), now: now)) {
            XCTAssertEqual($0 as? MarketDataError, .notListed)
        }
        for bytes in ["[[1,2,3]]", "[[1,2,3,4,-1,6]]"] {
            XCTAssertThrowsError(try MarketDecoding.chart(Data(bytes.utf8), stats: nil, now: now)) {
                XCTAssertEqual($0 as? MarketDataError, .invalidResponse)
            }
        }
        XCTAssertThrowsError(try MarketDecoding.geckoChart(Data(#"{"prices":[[1,-1],[2,2]]}"#.utf8), now: now)) {
            XCTAssertEqual($0 as? MarketDataError, .invalidResponse)
        }
    }

    func testEmptyExchangeHistoryFallsBackAndSurvivesReopen() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("test.sqlite"), now = Date()
        let db = try await OathDatabase.open(at: url)
        let feed = EmptyTradingHistory(now: now)
        let asset = MarketAsset(id: "ethereum:native", networkID: "ethereum", reference: "native", decimals: 18)
        let service = MarketDataService(database: db, transport: feed, now: { now })
        let chart = try await service.chart(for: asset)
        XCTAssertEqual(chart.value.points.count, 2)
        XCTAssertEqual(chart.value.changePercent!, 10, accuracy: 0.00001)
        let second = try await service.chart(for: asset)
        XCTAssertEqual(second.value, chart.value)
        let paths = await feed.paths
        XCTAssertEqual(paths.filter { $0.hasSuffix("/candles") }.count, 1)
        XCTAssertEqual(paths.filter { $0.hasSuffix("/market_chart") }.count, 1)
        let reopened = try await OathDatabase.open(at: url)
        let offline = MarketDataService(database: reopened, transport: feed)
        let saved = try await offline.cachedChart(for: asset)
        XCTAssertEqual(saved?.value, chart.value)
        XCTAssertEqual(saved?.fetchedAt, chart.fetchedAt)
    }

    func testAmbiguousOrInvalidDirectoryIdentityIsNotAnAbsentListing() throws {
        let asset = MarketAsset(id: "public-test-token", networkID: "ethereum", reference: "0xabc", decimals: 6)
        for entries in [
            #"[{"id":"ONE","supported_networks":[{"id":"ethereum","contract_address":"0xabc"}]},{"id":"TWO","supported_networks":[{"id":"ethereum","contract_address":"0xabc"}]}]"#,
            #"[{"id":"invalid-code","supported_networks":[{"id":"ethereum","contract_address":"0xabc"}]}]"#
        ] {
            XCTAssertThrowsError(try MarketDecoding.tokenCode(for: asset, directory: Data(entries.utf8))) {
                XCTAssertEqual($0 as? MarketDataError, .invalidResponse)
            }
        }
        XCTAssertThrowsError(try MarketDecoding.tokenCode(for: asset, directory: Data(#"[{"id":"OTHER","supported_networks":[]}]"#.utf8))) {
            XCTAssertEqual($0 as? MarketDataError, .notListed)
        }
    }

    func testLiveDelistedExchangeTokenUsesExactContractChartAndPersists() async throws {
        guard ProcessInfo.processInfo.environment["OATH_MARKET_RECOVERY_LIVE"] == "1" else {
            throw XCTSkip("Opt-in public market API test")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("test.sqlite")
        let db = try await OathDatabase.open(at: url)
        // SNT is listed in Coinbase's contract directory but its current candle
        // window is empty. The independent API must receive this exact contract.
        let asset = MarketAsset(id: "ethereum:snt", networkID: "ethereum",
            reference: "0x744d70fdbe2ba4cf95131626614a1763df805b9e", decimals: 18)
        let service = MarketDataService(database: db)
        let result = try await service.chart(for: asset)
        XCTAssertGreaterThan(result.value.points.count, 2)
        XCTAssertTrue(result.value.points.allSatisfy { $0.close > 0 && $0.close.isFinite })
        XCTAssertTrue(result.value.points.last!.time > Date().addingTimeInterval(-3600).timeIntervalSince1970)
        let entries = try await db.marketCache(key: "v1.chart." + asset.cacheIdentity)
        XCTAssertEqual(entries?.source, "CoinGecko")
        let reopened = try await OathDatabase.open(at: url)
        let saved = try await MarketDataService(database: reopened).cachedChart(for: asset)
        XCTAssertEqual(saved?.value, result.value)
        XCTAssertEqual(saved?.fetchedAt, result.fetchedAt)
        print("OATH_MARKET_RECOVERY_LIVE exact SNT contract: \(result.value.points.count) chart points; persisted and reopened")
    }

    func testLiveAffectedMetadataAndExplicitMissingListings() async throws {
        guard ProcessInfo.processInfo.environment["OATH_MARKET_RECOVERY_LIVE"] == "1" else {
            throw XCTSkip("Opt-in public market API test")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try await OathDatabase.open(at: folder.appendingPathComponent("test.sqlite"))
        let service = MarketDataService(database: db)
        for (network, decimals, providerID) in [("bitcoin", 8, "bitcoin"), ("aptos", 8, "aptos"), ("xrpl", 6, "ripple")] {
            let asset = MarketAsset(id: network + ":native", networkID: network, reference: "native", decimals: decimals)
            let value = try await service.information(for: asset)
            XCTAssertEqual(value.value.providerID, providerID)
            XCTAssertFalse(value.value.name.isEmpty)
            XCTAssertGreaterThan(try XCTUnwrap(value.value.marketCaps?["usd"]), .zero)
            let cached = try await service.cachedInformation(for: asset)
            XCTAssertEqual(cached?.value, value.value)
            print("OATH_MARKET_RECOVERY_LIVE \(network) information and market statistics validated")
        }
        let transport = URLSessionMarketTransport()
        for url in [
            "https://api.exchange.coinbase.com/products/NOTLISTEDOATH-USD/candles?granularity=3600",
            "https://api.coinbase.com/v2/prices/NOTLISTEDOATH-USD/spot",
            "https://api.coingecko.com/api/v3/coins/ethereum/contract/0x0000000000000000000000000000000000000001"
        ] {
            do { _ = try await transport.data(from: URL(string: url)!); XCTFail("Invented missing listing") }
            catch { XCTAssertEqual(error as? MarketDataError, .notListed) }
        }
        print("OATH_MARKET_RECOVERY_LIVE three explicit missing listing envelopes classified")
    }
}
