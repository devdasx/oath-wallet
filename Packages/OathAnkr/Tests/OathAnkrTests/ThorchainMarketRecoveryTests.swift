import Foundation
import XCTest
import OathDiagnostics
@testable import OathAnkr

private actor ThorchainMarketFixture: AnkrTransport {
    static let bucket = #"{"errors":[{"message":"rate bucket full (5000). bucket drains 500/s.\ncontact fixture@example.com to increase your limit.\n"}]}"#
    var oracleReplies: [String]
    private(set) var oracleRequests = 0
    private(set) var metadataRequests = 0
    private(set) var requests: [URLRequest] = []

    init(oracleReplies: [String] = []) { self.oracleReplies = oracleReplies }

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        requests.append(request)
        let url = try XCTUnwrap(request.url)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "query" }?.value ?? ""
        let response: String
        if query.contains("nodes(ids:") {
            oracleRequests += 1
            if !oracleReplies.isEmpty { response = oracleReplies.removeFirst() }
            else {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let rows = ["THOR.RUNE", "THOR.TCY", "X/RUJI"].map {
                    SolanaJSON.object(["asset": .string($0), "price": .object([
                        "current": .string("1000000000000"), "timestamp": .string(formatter.string(from: .now))
                    ])])
                }
                return (try JSONEncoder().encode(SolanaJSON.object(["data": .object(["nodes": .array(rows)])])), 200)
            }
        } else if query.contains("strategies") {
            response = #"{"data":{"rujira":{"strategies":{"edges":[],"pageInfo":{"hasNextPage":false}}}}}"#
        } else if url.path.hasSuffix("denoms_metadata") {
            metadataRequests += 1
            // Ensure concurrent callers overlap the real public catalog request.
            try await Task.sleep(for: .milliseconds(30))
            response = #"{"metadatas":[],"pagination":{}}"#
        } else if url.path.hasSuffix("/pools") || url.path.hasSuffix("/securedassets") {
            response = "[]"
        } else if url.path.hasSuffix("/network") {
            response = #"{"runePriceInUSD":"1"}"#
        } else if url.host == "api.coingecko.com" {
            response = "{}"
        } else { throw AnkrError.invalidResponse }
        let data = Data(response.utf8)
        DiagnosticHTTP.response(data, status: 200, request: request)
        return (data, 200)
    }
}

private actor ThorchainMarketReports: DiagnosticTransport {
    var events: [DiagnosticEvent] = []
    func upload(_ events: [DiagnosticEvent]) async throws { self.events += events }
}

final class ThorchainMarketRecoveryTests: XCTestCase, @unchecked Sendable {
    func testRateBucketResponseRecoversExactOracleRequest() async throws {
        let transport = ThorchainMarketFixture(oracleReplies: [ThorchainMarketFixture.bucket])
        let client = ThorchainClient(transport: transport)
        let catalog = try await client.catalog()
        XCTAssertEqual(catalog.prices["x/ruji"], "1")
        let count = await transport.oracleRequests
        XCTAssertEqual(count, 2, "An HTTP 200 rate-bucket response needs a bounded delayed retry")
        let requests = await transport.requests.filter { $0.url?.host == "api.rujira.network" && $0.url?.query?.contains("nodes") == true }
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.first?.url, requests.last?.url)
    }

    func testConcurrentWalletCatalogsShareOneReadAndShortLivedResult() async throws {
        let transport = ThorchainMarketFixture()
        let client = ThorchainClient(transport: transport)
        try await withThrowingTaskGroup(of: ThorchainCatalog.self) { group in
            for _ in 0..<20 { group.addTask { try await client.catalog() } }
            for try await catalog in group { XCTAssertEqual(catalog.prices["native"], "1") }
        }
        _ = try await client.catalog()
        let counts = await (transport.oracleRequests, transport.metadataRequests)
        XCTAssertEqual(counts.0, 1)
        XCTAssertEqual(counts.1, 1)
    }

    func testPersistentRateLimitIsBoundedAndOriginalProviderErrorRemainsPrivate() async throws {
        let reports = ThorchainMarketReports()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        OathDiagnostics.configure(file: file, transport: reports)
        let transport = ThorchainMarketFixture(oracleReplies: Array(repeating: ThorchainMarketFixture.bucket, count: 3))
        let client = ThorchainClient(transport: transport, catalogRequests: ThorchainCatalogRequests(),
            graphQLRetryWait: { delay in XCTAssertEqual(delay, .seconds(10)) })
        let operation = UUID()
        do {
            _ = try await OathDiagnostics.$operationID.withValue(operation) {
                try await OathDiagnostics.$chain.withValue("thorchain") {
                    try await client.readMarketGraphQL("{nodes(ids:[]){... on Asset {asset price {current timestamp}}}}", stage: "oracle")
                }
            }
            XCTFail("A still-full bucket must remain a failure")
        } catch { XCTAssertEqual(error as? ThorchainError, .rateLimited) }
        let count = await transport.oracleRequests
        XCTAssertEqual(count, 2, "No unbounded retries")
        for _ in 0..<100 {
            if await reports.events.filter({ $0.operationID == operation }).count >= 3 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let events = await reports.events.filter { $0.operationID == operation }
        XCTAssertEqual(events.filter { $0.operation == "provider_response" }.count, 2)
        XCTAssertEqual(events.filter { $0.operation == "market_retry" }.count, 1)
        XCTAssertTrue(events.allSatisfy { $0.context["chain"] == "thorchain" })
        XCTAssertTrue(events.contains { $0.error.message.contains("rate bucket full") && $0.context["http_status"] == "200" })
        let serialized = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        XCTAssertFalse(serialized.contains("fixture@example.com"))
        XCTAssertFalse(serialized.contains("nodes(ids:"))
        XCTAssertFalse(serialized.contains("malformed"))
    }

    func testOtherGraphQLErrorsAndMixedErrorsDoNotRetry() async throws {
        let other = #"{"errors":[{"message":"unknown field"}]}"#
        let mixed = #"{"errors":[{"message":"rate bucket full (5000). bucket drains 500/s."},{"message":"unknown field"}]}"#
        for response in [other, mixed] {
            let transport = ThorchainMarketFixture(oracleReplies: [response])
            let client = ThorchainClient(transport: transport, catalogRequests: ThorchainCatalogRequests(),
                graphQLRetryWait: { _ in XCTFail("Only the exact known rate envelope is retriable") })
            do { _ = try await client.readMarketGraphQL("{nodes(ids:[])}", stage: "oracle"); XCTFail() }
            catch { XCTAssertEqual(error as? ThorchainError, .graphql) }
            let count = await transport.oracleRequests
            XCTAssertEqual(count, 1)
        }
        for response in [
            #"{"errors":[]}"#, #"{"data":null}"#, #"{"errors":{}}"#,
            #"{"errors":[{"message":"prefix rate bucket full (5000). bucket drains 500/s."}]}"#,
            #"{"errors":[{"message":"rate bucket full (10). bucket drains 1/s."}]}"#
        ] {
            XCTAssertFalse(ThorchainClient.isMarketRateLimit(try JSONDecoder().decode(SolanaJSON.self, from: Data(response.utf8))))
        }
    }

    func testCancellationDuringRetryPreventsSecondRequest() async throws {
        let transport = ThorchainMarketFixture(oracleReplies: [ThorchainMarketFixture.bucket])
        let client = ThorchainClient(transport: transport, catalogRequests: ThorchainCatalogRequests(),
            graphQLRetryWait: { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                // A non-cooperative wait completing late must still be checked.
            })
        let task = Task { try await client.readMarketGraphQL("{nodes(ids:[])}", stage: "oracle") }
        do { _ = try await task.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        let count = await transport.oracleRequests
        XCTAssertEqual(count, 1)
    }

    func testCancelledConsumerCannotCancelOtherWalletCatalog() async throws {
        let transport = ThorchainMarketFixture()
        let client = ThorchainClient(transport: transport)
        let first = Task { try await client.catalog() }
        for _ in 0..<100 {
            if await transport.metadataRequests > 0 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        first.cancel()
        let second = try await client.catalog()
        XCTAssertEqual(second.prices["x/ruji"], "1")
        do { _ = try await first.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        let count = await transport.oracleRequests
        XCTAssertEqual(count, 1)
        let cancelledCacheRead = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.catalog()
        }
        do { _ = try await cancelledCacheRead.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testExpiredCatalogRefreshesAndFailedLoadsAreNotCached() async throws {
        let transport = ThorchainMarketFixture()
        let cache = ThorchainCatalogRequests(lifetime: .milliseconds(25))
        let client = ThorchainClient(transport: transport, catalogRequests: cache)
        do { _ = try await cache.value { throw ThorchainError.malformed }; XCTFail() }
        catch { XCTAssertEqual(error as? ThorchainError, .malformed) }
        _ = try await client.catalog()
        try await Task.sleep(for: .milliseconds(40))
        _ = try await client.catalog()
        let count = await transport.oracleRequests
        XCTAssertEqual(count, 2)
    }
}
