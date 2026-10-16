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

private actor MarketDiagnosticCapture: DiagnosticTransport {
    var events: [DiagnosticEvent] = []
    func upload(_ events: [DiagnosticEvent]) async throws { self.events += events }
}

private struct MissingOrMalformedMarket: MarketTransport {
    let malformed: Bool
    func data(from url: URL) async throws -> Data {
        if malformed && url.path.hasSuffix("/candles") { return Data("[[1,2,3]]".utf8) }
        throw MarketDataError.notListed
    }
}

@MainActor final class MarketRecoveryTests: XCTestCase {
    func testMissingOptionalDataStaysQuietWhileMalformedDataRemainsCorrelated() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let capture = MarketDiagnosticCapture()
        OathDiagnostics.configure(file: folder.appendingPathComponent("diagnostics.json"), transport: capture)
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
            if await capture.events.contains(where: { $0.operationID == correlation }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(100))
        let events = await capture.events.filter { $0.operationID == correlation }
        XCTAssertEqual(events.count, 1, "Only the malformed response is a failure; no missing listing or stats reports")
        XCTAssertEqual(events.first?.context["chain"], "ethereum")
        XCTAssertEqual(events.first?.error.message, "invalidResponse")
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
