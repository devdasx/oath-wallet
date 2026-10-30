import Foundation
import XCTest
import OathDiagnostics
@testable import OathAnkr

private actor NearIndexTransport: AnkrTransport {
    let replies: [String: Data]
    let failingPath: String
    let failure: Int
    let persistent: Bool
    var requests: [URLRequest] = []
    var failed = false
    init(replies: [String: Data], path: String, failure: Int = -1005, persistent: Bool = false) {
        self.replies = replies; failingPath = path; self.failure = failure; self.persistent = persistent
    }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        requests.append(request)
        let path = request.url!.path
        if path == failingPath && (!failed || persistent) {
            failed = true
            if failure < 0 { throw URLError(URLError.Code(rawValue: failure)) }
            return (Data(), failure)
        }
        if request.url?.host == "rpc.ankr.com" {
            let method = try JSONDecoder().decode(NearJSON.self, from: XCTUnwrap(request.httpBody))["method"].string
            let result:NearJSON = method == "EXPERIMENTAL_genesis_config"
                ? .object(["chain_id":.string("mainnet")])
                : .object(["header":.object(["hash":.string(NearTests.blockHash),"height":.number("123"),"timestamp_nanosec":.string("1700000000000000000")])])
            return (try JSONEncoder().encode(NearTests.result(result)),200)
        }
        return (try XCTUnwrap(replies[path]), 200)
    }
}

final class NearIndexRecoveryTests: XCTestCase, @unchecked Sendable {
    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/Near")))
    }

    func testConnectionLossRecoversSameTransferCursorAndExactAmounts() async throws {
        let data = try fixture("transfers")
        let transport = NearIndexTransport(replies: ["/v0/transfers": data], path: "/v0/transfers")
        let client = try NearClient(apiKey: "test", transport: transport)
        let page = try await client.history(owner: "root.near", stream: "transfers", before: "saved-cursor", limit: 5)
        let expected = try NearDecoding.history(JSONDecoder().decode(NearJSON.self, from: data), owner: "root.near", stream: "transfers", raw: data)
        XCTAssertEqual(page.ids, expected.ids)
        XCTAssertEqual(page.next, expected.next)
        XCTAssertEqual(page.events.map(\.amount), expected.events.map(\.amount))
        let requests = await transport.requests.filter { $0.url?.path == "/v0/transfers" }
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.first?.url, requests.last?.url)
        XCTAssertEqual(requests.first?.httpBody, requests.last?.httpBody)
        let body = try JSONDecoder().decode(NearJSON.self, from: XCTUnwrap(requests.last?.httpBody))
        XCTAssertEqual(body["resume_token"].string, "saved-cursor")
    }

    func testHistoryAndDetailReadsRecoverIndependentlyWithoutRepeatingCompletedPage() async throws {
        let index = try fixture("tx"), details = try fixture("tx-details")
        for path in ["/v0/account", "/v0/transactions"] {
            let transport = NearIndexTransport(replies: ["/v0/account": index, "/v0/transactions": details], path: path, failure: 503)
            let page = try await NearClient(apiKey: "test", transport: transport).history(owner: "root.near", stream: "transactions")
            XCTAssertEqual(page.executions.count, 5)
            XCTAssertTrue(page.executions.allSatisfy { $0.fee != nil && $0.fee != "0" })
            let requests = await transport.requests
            XCTAssertEqual(requests.filter { $0.url?.path == path }.count, 2)
            XCTAssertEqual(requests.filter { $0.url?.path != path }.count, 1)
            let repeated = requests.filter { $0.url?.path == path }
            XCTAssertEqual(repeated.first?.httpBody, repeated.last?.httpBody)
        }
    }

    func testPersistentFailureIsBoundedAndRateLimitsAreNotImmediatelyRetried() async throws {
        for failure in [-1005, -1001, -1004, 408, 500, 502, 503, 504, 429, 401, 403, 404, -1200, -999] {
            let transport = NearIndexTransport(replies: [:], path: "/v0/transfers", failure: failure, persistent: true)
            do {
                _ = try await NearClient(apiKey: "test", transport: transport).history(owner: "root.near", stream: "transfers")
                XCTFail("Persistent failure must not produce a successful page")
            } catch {
                if failure == -999 { XCTAssertTrue(error is CancellationError) }
                else if failure > 0 { XCTAssertEqual(error as? NearError, .http(failure)) }
                else { XCTAssertEqual(error as? NearError, .transport) }
            }
            let requests = await transport.requests
            let expected = [-1005, -1001, -1004, 408, 500, 502, 503, 504].contains(failure) ? 2 : 1
            XCTAssertEqual(requests.count, expected, "Failure \(failure)")
        }
    }

    func testCancellationDuringBackoffStopsRetryAndReleasesPermits() async throws {
        let transport = NearIndexTransport(replies: ["/v1/account/root.near/ft": Data(#"{"account_id":"root.near","tokens":[]}"#.utf8)], path: "/v0/transfers", persistent: true)
        let client = try NearClient(apiKey: "test", transport: transport)
        let jobs = (0..<6).map { _ in Task { try await client.history(owner: "root.near", stream: "transfers") } }
        for _ in 0..<100 {
            if await transport.requests.count >= 6 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        for job in jobs { job.cancel() }
        for job in jobs {
            do { _ = try await job.value; XCTFail() }
            catch { XCTAssertTrue(error is CancellationError) }
        }
        let result = try await client.discovery(owner: "root.near")
        XCTAssertEqual(result["tokens"].array?.count, 0)
        let attempts = await transport.requests.filter { $0.url?.path == "/v0/transfers" }.count
        XCTAssertEqual(attempts, 6)
    }

    func testMalformedAndWrongOwnerPagesAreNeverRetried() async throws {
        for data in [Data("not-json".utf8), Data(String(decoding: try fixture("transfers"), as: UTF8.self).replacingOccurrences(of: "root.near", with: "other.near").utf8)] {
            let transport = NearIndexTransport(replies: ["/v0/transfers": data], path: "/unused")
            do { _ = try await NearClient(apiKey: "test", transport: transport).history(owner: "root.near", stream: "transfers"); XCTFail() }
            catch { XCTAssertTrue(error is DecodingError || error as? NearError == .wrongOwner) }
            let requests = await transport.requests
            XCTAssertEqual(requests.count, 1)
        }
    }

    func testDiscoveryRecoversTransientConnectionFailure() async throws {
        let path = "/v1/account/root.near/ft"
        let transport = NearIndexTransport(replies: [path: Data(#"{"account_id":"root.near","tokens":[]}"#.utf8)], path: path)
        let result = try await NearClient(apiKey: "test", transport: transport).discovery(owner: "root.near")
        XCTAssertEqual(result["account_id"].string, "root.near")
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.first?.url, requests.last?.url)
    }
}

private actor NearIndexReports: DiagnosticTransport {
    var events: [DiagnosticEvent] = []
    func upload(_ events: [DiagnosticEvent]) async throws { self.events += events }
}

final class NearIndexDiagnosticsTests: XCTestCase, @unchecked Sendable {
    func testOriginalFailuresAreCorrelatedAndNeverContainAccountOrCursor() async throws {
        let reports = NearIndexReports()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        OathDiagnostics.configure(file: file, transport: reports)
        let correlation = UUID()
        let transport = NearIndexTransport(replies: [:], path: "/v0/transfers", persistent: true)
        do {
            _ = try await OathDiagnostics.$operationID.withValue(correlation) {
                try await NearClient(apiKey: "FixtureNearKey", transport: transport).history(owner: "root.near", stream: "transfers", before: "private-fixture-cursor")
            }
            XCTFail()
        } catch { XCTAssertEqual(error as? NearError, .transport) }
        for _ in 0..<100 {
            if await reports.events.count == 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let events = await reports.events
        XCTAssertEqual(events.count, 2)
        XCTAssertTrue(events.allSatisfy { $0.operationID == correlation && $0.context["chain"] == "near" && $0.context["stage"] == "transfers" })
        XCTAssertEqual(Set(events.compactMap { $0.context["attempt"] }), ["1", "2"])
        XCTAssertTrue(events.allSatisfy { $0.error.code == NSURLErrorNetworkConnectionLost && $0.context["host"] == "transfers.main.fastnear.com" })
        let encoded = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        for excluded in ["FixtureNearKey", "root.near", "private-fixture-cursor", "resume_token", "account_id"] {
            XCTAssertFalse(encoded.contains(excluded))
        }
    }
}
