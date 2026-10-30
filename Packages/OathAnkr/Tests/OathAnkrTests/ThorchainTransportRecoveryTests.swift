import Foundation
import XCTest
import OathDiagnostics
@testable import OathAnkr

private actor ThorchainInterruptedRead: AnkrTransport {
    enum Reply: Sendable {
        case response(String, Int), failure(AnkrError), url(URLError.Code), deferred(DiagnosticDeferral), cancel
    }
    private var replies: [Reply]
    private(set) var requests: [URLRequest] = []
    init(_ replies: [Reply]) { self.replies = replies }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        requests.append(request)
        guard !replies.isEmpty else { throw AnkrError.invalidResponse }
        switch replies.removeFirst() {
        case let .response(body, status): return (Data(body.utf8), status)
        case let .failure(error): throw error
        case let .url(code): throw URLError(code)
        case let .deferred(error): throw error
        case .cancel: throw CancellationError()
        }
    }
}

private actor ThorchainRetryReports: DiagnosticTransport {
    var events: [DiagnosticEvent] = []
    func upload(_ events: [DiagnosticEvent]) async throws { self.events += events }
}

private final class ThorchainRecoveringHTTPProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var calls = 0
    static func reset() { lock.withLock { calls = 0 } }
    static func count() -> Int { lock.withLock { calls } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let count = Self.lock.withLock { Self.calls += 1; return Self.calls }
        if count == 1 {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
        } else {
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"{"block":{"header":{"chain_id":"thorchain-1","height":"200"}}}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { }
}

private actor ThorchainInterruptedLiveRead: AnkrTransport {
    private let live = AnkrHTTPTransport()
    private var interrupted = false
    private(set) var attempts = 0
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        guard request.url?.host == ThorchainClient.node.host, request.httpMethod == "GET", request.httpBody == nil,
              request.url?.path.contains("/balances/") == true,
              request.value(forHTTPHeaderField: "x-cosmos-block-height") != nil else { throw AnkrError.invalidResponse }
        attempts += 1
        if !interrupted { interrupted = true; throw AnkrError.transport }
        return try await live.send(request)
    }
}

final class ThorchainTransportRecoveryTests: XCTestCase, @unchecked Sendable {
    private let owner = "thor1dheycdevq39qlkxs2a6wuuzyn4aqxhve4qxtxt" // Public protocol reserve.
    private let first = #"{"balances":[{"denom":"rune","amount":"123"}],"pagination":{"next_key":"fixture-page-2"}}"#
    private let second = #"{"balances":[{"denom":"tcy","amount":"456"}],"pagination":{"next_key":null}}"#
    private let block = #"{"block":{"header":{"chain_id":"thorchain-1","height":"200"}}}"#

    func testPinnedSecondPageRecoversWithoutRepeatingOrMixingPages() async throws {
        for failure in [ThorchainInterruptedRead.Reply.failure(.transport), .url(.timedOut), .url(.networkConnectionLost), .url(.cannotConnectToHost)] {
            let transport = ThorchainInterruptedRead([.response(first, 200), failure, .response(second, 200)])
            let inventory = try await ThorchainClient(transport: transport).inventory(owner: owner, height: 200)
            XCTAssertEqual(inventory.height, 200)
            XCTAssertEqual(Dictionary(uniqueKeysWithValues: inventory.holdings.map { ($0.reference, $0.amount) }), ["native":"123", "tcy":"456"])
            let requests = await transport.requests
            XCTAssertEqual(requests.count, 3)
            XCTAssertEqual(requests[1], requests[2], "Retry must preserve the cursor, height and all headers")
            XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "x-cosmos-block-height") == "200" && $0.httpBody == nil })
            XCTAssertNotEqual(requests[0].url, requests[1].url)
        }
    }

    func testLatestHeightAndHistoryReadRecoverOnce() async throws {
        let transport = ThorchainInterruptedRead([.failure(.transport), .response(block, 200), .failure(.transport),
            .response(#"{"tx_responses":[],"total":"0"}"#, 200)])
        let client = ThorchainClient(transport: transport)
        let height = try await client.latestHeight(atLeast: 199)
        XCTAssertEqual(height, 200)
        let history = try await client.history(owner: owner, stream: "transfer.sender", height: 200, lowerHeight: 100)
        XCTAssertTrue(history.events.isEmpty)
        XCTAssertNil(history.next)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 4)
        XCTAssertEqual(requests[0], requests[1])
        XCTAssertEqual(requests[2], requests[3])
    }

    func testActualHTTPTransportCanRecoverItsWrappedConnectionFailure() async throws {
        ThorchainRecoveringHTTPProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ThorchainRecoveringHTTPProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = ThorchainClient(transport: AnkrHTTPTransport(session: session))
        let height = try await client.latestHeight()
        XCTAssertEqual(height, 200)
        XCTAssertEqual(ThorchainRecoveringHTTPProtocol.count(), 2)
    }

    func testLivePinnedBankSnapshotRecoversAfterInjectedInterruption() async throws {
        guard ProcessInfo.processInfo.environment["OATH_THORCHAIN_TRANSPORT_LIVE"] == "1" else {
            throw XCTSkip("Opt in to the public read-only THORChain bank check")
        }
        let client = ThorchainClient()
        let height = try await client.latestHeight()
        let expected = try await client.inventory(owner: owner, height: height)
        let transport = ThorchainInterruptedLiveRead()
        let actual = try await ThorchainClient(transport: transport).inventory(owner: owner, height: height)
        XCTAssertEqual(actual.height, height)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: actual.holdings.map { ($0.reference, $0.amount) }),
                       Dictionary(uniqueKeysWithValues: expected.holdings.map { ($0.reference, $0.amount) }))
        let attempts = await transport.attempts
        XCTAssertGreaterThanOrEqual(attempts, 2)
        print("THORChain live pinned snapshot matched: height \(height), \(actual.holdings.count) holdings; injected interruption recovered. Read only.")
    }

    func testRepeatedFailureStopsAfterOneRetryAndHTTPRetriesShareTheBudget() async throws {
        for initial in [ThorchainInterruptedRead.Reply.failure(.transport), .response("{}", 503)] {
            let transport = ThorchainInterruptedRead([initial, .failure(.transport), .response(block, 200)])
            do { _ = try await ThorchainClient(transport: transport).latestHeight(); XCTFail("Persistent failure must not return invented height") }
            catch { XCTAssertEqual(error as? ThorchainError, .transport) }
            let count = await transport.requests.count
            XCTAssertEqual(count, 2)
        }
    }

    func testCancellationDoesNotRetryOrBecomeTransportFailure() async throws {
        for failure in [ThorchainInterruptedRead.Reply.cancel, .url(.cancelled)] {
            let transport = ThorchainInterruptedRead([failure, .response(block, 200)])
            do { _ = try await ThorchainClient(transport: transport).latestHeight(); XCTFail() }
            catch { XCTAssertTrue(error is CancellationError) }
            let count = await transport.requests.count
            XCTAssertEqual(count, 1)
        }
        let transport = ThorchainInterruptedRead([.failure(.transport), .response(block, 200)])
        let task = Task { try await ThorchainClient(transport: transport).latestHeight() }
        for _ in 0..<100 where await transport.requests.isEmpty { try await Task.sleep(for: .milliseconds(2)) }
        task.cancel()
        do { _ = try await task.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        let count = await transport.requests.count
        XCTAssertEqual(count, 1, "Cancellation during backoff cannot launch another read")
    }

    func testMalformedAuthorizationAndExplicitTLSFailuresDoNotRetry() async throws {
        for reply in [ThorchainInterruptedRead.Reply.response("invalid json", 200), .response("{}", 401),
                      .response("{}", 403), .response("{}", 400), .failure(.responseTooLarge), .url(.serverCertificateUntrusted)] {
            let transport = ThorchainInterruptedRead([reply, .response(block, 200)])
            do { _ = try await ThorchainClient(transport: transport).latestHeight(); XCTFail() } catch { }
            let count = await transport.requests.count
            XCTAssertEqual(count, 1)
        }
    }

    func testPublicMarketFailuresKeepSharedCooldownAndFallbackScheduling() async throws {
        for base in ["https://api.coingecko.com", "https://api.rujira.network", "https://coins.llama.fi"] {
            let transport = ThorchainInterruptedRead([.failure(.transport), .response("{}", 200)])
            do { _ = try await ThorchainClient(transport: transport).read(URL(string: base)!, path: "fixture"); XCTFail() } catch { }
            let count = await transport.requests.count
            XCTAssertEqual(count, 1, "Do not replay independently coordinated public price requests")
        }
    }

    func testPublicMarketDeferralsRemainLocalWithoutRetryOrTransportConversion() async throws {
        for deferral in [DiagnosticDeferral.publicMarketCooldown, .publicMarketCapacity] {
            let transport = ThorchainInterruptedRead([.deferred(deferral), .response("{}", 200)])
            do {
                _ = try await ThorchainClient(transport: transport).read(URL(string: "https://coins.llama.fi")!, path: "fixture")
                XCTFail("Deferred work must not invent a result")
            } catch { XCTAssertEqual(error as? DiagnosticDeferral, deferral) }
            let attempts = await transport.requests.count
            XCTAssertEqual(attempts, 1, "The shared scheduler owns retry admission")
        }
    }

    func testRecoveredConnectionIsExcludedButInvalidResponseRemainsCorrelated() async throws {
        let reports = ThorchainRetryReports()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        OathDiagnostics.configure(file: file, transport: reports)
        let operation = UUID()
        let transport = ThorchainInterruptedRead([.url(.networkConnectionLost), .response(second, 200)])
        let inventory = try await OathDiagnostics.$operationID.withValue(operation) {
            try await ThorchainClient(transport: transport).inventory(owner: owner, height: 200)
        }
        XCTAssertEqual(inventory.height, 200)
        for _ in 0..<3_000 {
            OathDiagnostics.record(AnkrError.transport, component: "provider", operation: "excluded_typed_burst")
            OathDiagnostics.record(ThorchainError.http(503), component: "provider", operation: "excluded_typed_burst")
        }
        OathDiagnostics.$operationID.withValue(operation) {
            OathDiagnostics.record(AnkrError.invalidResponse, component: "ThorchainClient", operation: "fixture_invalid_response", context: ["chain": "thorchain"])
        }
        for _ in 0..<100 {
            await OathDiagnostics.flush()
            if await reports.events.contains(where: { $0.operationID == operation }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(100))
        let allEvents = await reports.events
        XCTAssertFalse(allEvents.contains { $0.error.message == "diagnostics_queue_overflow" || $0.error.message == "diagnostics_retention_limit" })
        let events = allEvents.filter { $0.operationID == operation }
        XCTAssertEqual(events.count, 1, "The user excludes connection failures, including recovered retries")
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event.operation, "fixture_invalid_response")
        XCTAssertEqual(event.context["chain"], "thorchain")
        XCTAssertEqual(event.error.message, "invalidResponse")
        XCTAssertTrue(event.privacyFiltered)
        let payload = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        for value in [owner, "fixture-page-2", "x-cosmos-block-height", "https://", "pagination"] {
            XCTAssertFalse(payload.contains(value))
        }
    }
}
