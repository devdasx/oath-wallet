import Foundation
import XCTest
import OathDiagnostics
@testable import OathAnkr

private actor ThorchainMarketFixture: AnkrTransport {
    static let bucket = #"{"errors":["# + Array(repeating:
        #"{"message":"rate bucket full (5000). bucket drains 500/s.\ncontact fixture@example.com to increase your limit.\n"}"#,
        count: 9).joined(separator: ",") + "]}"
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
                let start = query.range(of: "nodes(ids:")!.upperBound
                let end = query[start...].range(of: "){...")!.lowerBound
                let ids = try JSONDecoder().decode([String].self, from: Data(query[start..<end].utf8))
                let assets = ids.compactMap { Data(base64Encoded: $0).flatMap { String(data: $0, encoding: .utf8) }.map { String($0.dropFirst(6)) } }
                let rows = assets.map {
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
        } else if url.path.hasSuffix("/contracts") {
            response = #"{"infos":[]}"#
        } else if url.path.hasSuffix("/pools") || url.path.hasSuffix("/securedassets") {
            response = "[]"
        } else if url.path.hasSuffix("/stats") {
            response = #"{"runePriceUSD":"1"}"#
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
        XCTAssertEqual(catalog.prices["native"], "1")
        let count = await transport.oracleRequests
        XCTAssertEqual(count, 1, "A full bucket must fall back without retrying")
        let requests = await transport.requests.filter { $0.url?.host == "api.rujira.network" && $0.url?.query?.contains("nodes") == true }
        XCTAssertEqual(requests.count, 1)
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

    func testPersistentRateLimitIsBoundedAndReviewedUploadExclusionsRemainRespected() async throws {
        let reports = ThorchainMarketReports()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = directory.appendingPathComponent("reports.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        OathDiagnostics.configure(file: file, transport: reports)
        let transport = ThorchainMarketFixture(oracleReplies: Array(repeating: ThorchainMarketFixture.bucket, count: 3))
        let client = ThorchainClient(transport: transport, catalogRequests: ThorchainCatalogRequests())
        let operation = UUID()
        do {
            _ = try await OathDiagnostics.$operationID.withValue(operation) {
                try await OathDiagnostics.$chain.withValue("thorchain") {
                    try await client.readMarketGraphQL("{nodes(ids:[]){... on Asset {asset price {current timestamp}}}}", stage: "oracle")
                }
            }
            XCTFail("A still-full bucket must remain a failure")
        } catch { XCTAssertEqual(error as? ThorchainError, .rateLimited) }
        await OathDiagnostics.$operationID.withValue(operation) {
            await OathDiagnostics.$chain.withValue("thorchain") {
                for _ in 0..<3 {
                    let deferred = await OathDiagnostics.attempt("thorchain_oracle_prices") {
                        try await client.readMarketGraphQL("{nodes(ids:[])}", stage: "oracle")
                    }
                    XCTAssertNil(deferred)
                }
            }
        }
        let count = await transport.oracleRequests
        XCTAssertEqual(count, 1, "No retries of a full bucket")
        // These two exact rate-bucket reports were excluded at the user's
        // request on 2026-10-22. Verify that policy without a vacuous empty
        // capture: an unrelated control report must still reach this transport.
        OathDiagnostics.$operationID.withValue(operation) {
            OathDiagnostics.record(DiagnosticFailure("market_capture_control"),
                                   component: "test", operation: "market_capture_control")
        }
        for _ in 0..<100 {
            await OathDiagnostics.flush()
            if await reports.events.contains(where: { $0.operationID == operation && $0.operation == "market_capture_control" }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let events = await reports.events.filter { $0.operationID == operation }
        XCTAssertEqual(events.filter { $0.operation == "market_capture_control" }.count, 1)
        XCTAssertFalse(events.contains { $0.operation == "provider_response" })
        XCTAssertFalse(events.contains { $0.operation == "market_fallback" })
        XCTAssertFalse(events.contains { $0.operation == "thorchain_oracle_prices" },
                       "Local cooldown must stay distinct at outer best-effort boundaries")
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
            let client = ThorchainClient(transport: transport, catalogRequests: ThorchainCatalogRequests())
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

    func testSharedCooldownPreventsNextGraphQLRequest() async throws {
        let transport = ThorchainMarketFixture(oracleReplies: [ThorchainMarketFixture.bucket])
        let client = ThorchainClient(transport: transport)
        for attempt in 0..<3 {
            do { _ = try await client.readMarketGraphQL("{nodes(ids:[])}", stage: "oracle"); XCTFail() }
            catch {
                if attempt == 0 { XCTAssertEqual(error as? ThorchainError, .rateLimited) }
                else { XCTAssertEqual(error as? DiagnosticDeferral, .publicMarketCooldown) }
            }
        }
        let count = await transport.oracleRequests
        XCTAssertEqual(count, 1)
    }

    func testDeferredVaultStillUsesIndependentNodeFallback() async throws {
        let transport = ThorchainMarketFixture(oracleReplies: [ThorchainMarketFixture.bucket])
        let client = ThorchainClient(transport: transport)
        do { _ = try await client.readMarketGraphQL("{nodes(ids:[])}", stage: "oracle"); XCTFail() }
        catch { XCTAssertEqual(error as? ThorchainError, .rateLimited) }
        let vaults = try await client.recoverVaultMarkets()
        XCTAssertTrue(vaults.isEmpty)
        let requests = await transport.requests
        XCTAssertEqual(requests.filter { $0.url?.host == "api.rujira.network" }.count, 1)
        XCTAssertEqual(requests.filter { $0.url?.path.hasSuffix("/contracts") == true }.count, 1)
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
