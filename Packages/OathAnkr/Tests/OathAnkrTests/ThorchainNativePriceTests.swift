import Foundation
import XCTest
import OathDiagnostics
@testable import OathAnkr

private actor ThorchainNativePriceTransport: AnkrTransport {
    let stats: String
    let status: Int
    let oracleAvailable: Bool
    let ecosystemAvailable: Bool
    let liveStats: Bool
    private(set) var requests: [URLRequest] = []
    private(set) var oracleAssets: [String] = []
    private(set) var observedPrice: String?

    init(stats: String = #"{"runePriceUSD":"0.6299796287243207"}"#, status: Int = 200,
         oracleAvailable: Bool = true, ecosystemAvailable: Bool = false, liveStats: Bool = false) {
        self.stats = stats; self.status = status; self.oracleAvailable = oracleAvailable
        self.ecosystemAvailable = ecosystemAvailable; self.liveStats = liveStats
    }

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        requests.append(request)
        let url = try XCTUnwrap(request.url)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.httpBody)
        let reply: (Data, Int)
        switch url.path {
        case "/chain/thorchain_midgard/v2/network":
            // The old request cannot provide a price, even when it succeeds.
            reply = (Data(#"{"activeNodeCount":"111","totalPooledRune":"123"}"#.utf8), 200)
        case "/chain/thorchain_midgard/v2/stats":
            if liveStats {
                reply = try await AnkrHTTPTransport().send(request)
                if reply.1 == 200 {
                    observedPrice = TonMarkets.positive(try JSONDecoder().decode(SolanaJSON.self, from: reply.0)["runePriceUSD"])
                }
            } else { reply = (Data(stats.utf8), status) }
        case let path where path.hasSuffix("/denoms_metadata"):
            reply = (Data(#"{"metadatas":[],"pagination":{}}"#.utf8), 200)
        case let path where path.hasSuffix("/pools"):
            reply = (Data(#"[{"asset":"BTC.BTC","assetPriceUSD":"60000","status":"available"}]"#.utf8), 200)
        case let path where path.hasSuffix("/securedassets"):
            reply = (Data(#"[{"asset":"BTC-BTC","depth":"150","supply":"100"}]"#.utf8), 200)
        default:
            if url.host == "api.rujira.network" {
                let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "query" }?.value ?? ""
                if query.contains("strategies") {
                    reply = (Data(#"{"data":{"rujira":{"strategies":{"edges":[],"pageInfo":{"hasNextPage":false}}}}}"#.utf8), 200)
                } else {
                    let start = try XCTUnwrap(query.range(of: "nodes(ids:")?.upperBound)
                    let end = try XCTUnwrap(query[start...].range(of: "){...")?.lowerBound)
                    let ids = try JSONDecoder().decode([String].self, from: Data(query[start..<end].utf8))
                    let assets = try ids.map { id in
                        String(try XCTUnwrap(String(data: try XCTUnwrap(Data(base64Encoded: id)), encoding: .utf8)).dropFirst(6))
                    }
                    oracleAssets += assets
                    let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    let rows: [SolanaJSON] = assets.map { asset in
                        guard oracleAvailable else { return .null }
                        return .object(["asset": .string(asset), "price": .object([
                            "current": .string("1200000000000"), "timestamp": .string(formatter.string(from: .now))
                        ])])
                    }
                    reply = (try JSONEncoder().encode(SolanaJSON.object(["data": .object(["nodes": .array(rows)])])), 200)
                }
            } else if url.host == "api.coingecko.com" {
                let json: SolanaJSON = ecosystemAvailable ? .object([
                    "thorchain": .object(["usd": .number("0.75"), "last_updated_at": .number(String(Int(Date().timeIntervalSince1970)))])
                ]) : .object([:])
                reply = (try JSONEncoder().encode(json), 200)
            } else if url.host == "coins.llama.fi" {
                reply = (Data(#"{"coins":{}}"#.utf8), 200)
            } else { throw AnkrError.invalidResponse }
        }
        DiagnosticHTTP.response(reply.0, status: reply.1, request: request)
        return reply
    }
}

private actor ThorchainNativePriceReports: DiagnosticTransport {
    var events: [DiagnosticEvent] = []
    func upload(_ events: [DiagnosticEvent]) async throws { self.events += events }
}

final class ThorchainNativePriceTests: XCTestCase, @unchecked Sendable {
    func testPublishedStatsPriceAvoidsUnnecessaryNativeOracleAndEcosystemRequests() async throws {
        let transport = ThorchainNativePriceTransport()
        let catalog = try await ThorchainClient(transport: transport).catalog()
        XCTAssertEqual(catalog.prices["native"], "0.6299796287243207")
        XCTAssertEqual(catalog.prices["btc/btc"], "60000")
        XCTAssertEqual(catalog.prices["btc-btc"], "90000")
        let assets = await transport.oracleAssets
        XCTAssertEqual(Set(assets), ["THOR.TCY", "X/RUJI"])
        let requests = await transport.requests
        XCTAssertEqual(requests.filter { $0.url?.path.hasSuffix("/v2/stats") == true }.count, 1)
        XCTAssertFalse(requests.contains { $0.url?.path.hasSuffix("/v2/network") == true })
        XCTAssertFalse(requests.contains { ["api.coingecko.com", "coins.llama.fi"].contains($0.url?.host) })
    }

    func testValidStatsPriceSurvivesMissingOracleAndOtherMarketCoverage() async throws {
        let transport = ThorchainNativePriceTransport(oracleAvailable: false)
        let catalog = try await ThorchainClient(transport: transport).catalog()
        XCTAssertEqual(catalog.prices["native"], "0.6299796287243207")
        XCTAssertNil(catalog.prices["tcy"])
        let requests = await transport.requests
        let gecko = try XCTUnwrap(requests.first { $0.url?.host == "api.coingecko.com" }?.url)
        let ids = URLComponents(url: gecko, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "ids" }?.value
        XCTAssertEqual(ids, "rujira,tcy", "Never repeat the known RUNE price in the fallback request")
    }

    func testMissingInvalidAndLegacyFieldPricesUseFreshOracle() async throws {
        for stats in [#"{}"#, #"{"runePriceInUSD":"999"}"#, #"{"runePriceUSD":null}"#,
                      #"{"runePriceUSD":"0"}"#, #"{"runePriceUSD":"-1"}"#, #"{"runePriceUSD":"NaN"}"#,
                      #"{"runePriceUSD":true}"#, #"{"runePriceUSD":"1abc"}"#, "not json"] {
            let transport = ThorchainNativePriceTransport(stats: stats)
            let catalog = try await ThorchainClient(transport: transport).catalog()
            XCTAssertEqual(catalog.prices["native"], "1.2", stats)
            let assets = await transport.oracleAssets
            XCTAssertTrue(assets.contains("THOR.RUNE"), stats)
        }
    }

    func testUnavailableStatsRetainsBoundedRetryAndFreshFallback() async throws {
        for status in [429, 503, 401] {
            let transport = ThorchainNativePriceTransport(status: status)
            let catalog = try await ThorchainClient(transport: transport).catalog()
            XCTAssertEqual(catalog.prices["native"], "1.2")
            let requests = await transport.requests.filter { $0.url?.path.hasSuffix("/v2/stats") == true }
            XCTAssertEqual(requests.count, status == 401 ? 1 : 2)
            XCTAssertEqual(Set(requests.compactMap(\.url)).count, 1)
        }
    }

    func testEcosystemFallbackAndAllMissingNeverProduceFabricatedPrice() async throws {
        for available in [true, false] {
            let transport = ThorchainNativePriceTransport(stats: "{}", oracleAvailable: false, ecosystemAvailable: available)
            let catalog = try await ThorchainClient(transport: transport).catalog()
            XCTAssertEqual(catalog.prices["native"], available ? "0.75" : nil)
            XCTAssertEqual(catalog.prices["btc-btc"], "90000")
        }
    }

    func testFailedStatsRetainsOriginalDiagnosticWithoutResponseBody() async throws {
        let reports = ThorchainNativePriceReports()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        OathDiagnostics.configure(file: file, transport: reports)
        let operation = UUID()
        let transport = ThorchainNativePriceTransport(stats: "private-response-fixture@example.com", status: 503)
        let catalog = try await OathDiagnostics.withChain("thorchain") {
            try await OathDiagnostics.$operationID.withValue(operation) {
                try await ThorchainClient(transport: transport).catalog()
            }
        }
        XCTAssertEqual(catalog.prices["native"], "1.2")
        for _ in 0..<100 {
            await OathDiagnostics.flush()
            if await reports.events.contains(where: { $0.operationID == operation && $0.operation == "thorchain_native_price" }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let events = await reports.events.filter { $0.operationID == operation }
        XCTAssertTrue(events.contains { $0.error.domain == "Oath.HTTP" && $0.error.code == 503 })
        XCTAssertTrue(events.contains { $0.operation == "thorchain_native_price" && $0.error.message == "http(503)" })
        XCTAssertTrue(events.allSatisfy { $0.context["chain"] == "thorchain" })
        let encoded = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        XCTAssertFalse(encoded.contains("private-response"))
        XCTAssertFalse(encoded.contains("fixture@example.com"))
        XCTAssertFalse(encoded.contains("https://"))
    }

    func testLivePublishedStatsThroughCatalog() async throws {
        guard ProcessInfo.processInfo.environment["OATH_LIVE_THORCHAIN_PRICE_TEST"] == "1" else {
            throw XCTSkip("Opt-in public read-only Midgard request")
        }
        // Only /v2/stats is live; other catalog sources are controlled fixtures.
        let transport = ThorchainNativePriceTransport(oracleAvailable: false, liveStats: true)
        let catalog = try await ThorchainClient(transport: transport).catalog()
        let observed = await transport.observedPrice
        XCTAssertNotNil(observed)
        XCTAssertEqual(catalog.prices["native"], observed)
        let requests = await transport.requests
        XCTAssertFalse(requests.contains { $0.url?.path.hasSuffix("/v2/network") == true })
    }
}
