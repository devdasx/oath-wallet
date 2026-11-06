import Foundation
import XCTest
import OathDiagnostics
@testable import OathAnkr

private actor NearRateLimitFeed: AnkrTransport {
    let header: String?
    let persistent: Bool
    let page: Data
    private(set) var requests: [URLRequest] = []
    private(set) var times: [ContinuousClock.Instant] = []
    init(header: String? = "2", persistent: Bool = false, page: Data) {
        self.header = header; self.persistent = persistent; self.page = page
    }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let response = try await sendResponse(request)
        return (response.data, response.status)
    }
    func sendResponse(_ request: URLRequest) async throws -> AnkrHTTPResponse {
        if request.url?.host == "rpc.ankr.com" {
            let method = try JSONDecoder().decode(NearJSON.self, from: XCTUnwrap(request.httpBody))["method"].string
            let result: NearJSON = method == "EXPERIMENTAL_genesis_config"
                ? .object(["chain_id": .string("mainnet")])
                : .object(["header": .object(["hash": .string(NearTests.blockHash), "height": .number("123"), "timestamp_nanosec": .string("1700000000000000000")])])
            return .init(data: try JSONEncoder().encode(NearTests.result(result)), status: 200)
        }
        requests.append(request); times.append(.now)
        if requests.count == 1 || persistent {
            return .init(data: Data(), status: 429, retryAfter: header)
        }
        return .init(data: page, status: 200)
    }
}

private final class RateLimitedHTTPProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: "HTTP/1.1", headerFields: ["retry-after": "7"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

final class NearRateLimitTests: XCTestCase, @unchecked Sendable {
    private func page() throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "transfers", withExtension: "json", subdirectory: "Fixtures/Near")))
    }
    func testProviderWaitPreservesCursorAndExactPage() async throws {
        let data = try page(), transport = NearRateLimitFeed(page: data)
        let result = try await NearClient(apiKey: "fixture", transport: transport)
            .history(owner: "root.near", stream: "transfers", before: "fixture-cursor", limit: 5)
        let expected = try NearDecoding.history(JSONDecoder().decode(NearJSON.self, from: data), owner: "root.near", stream: "transfers", raw: data)
        XCTAssertEqual(result.ids, expected.ids)
        XCTAssertEqual(result.events.map(\.amount), expected.events.map(\.amount))
        XCTAssertEqual(result.next, expected.next)
        let calls = await transport.requests, times = await transport.times
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls.first?.url, calls.last?.url)
        XCTAssertEqual(calls.first?.httpBody, calls.last?.httpBody)
        XCTAssertGreaterThanOrEqual(times[0].duration(to: times[1]), .seconds(2))
    }
    func testPersistentRateLimitStopsAfterOneDelayedRetry() async throws {
        let transport = NearRateLimitFeed(header: "0", persistent: true, page: try page())
        do {
            _ = try await NearClient(apiKey: "fixture", transport: transport).history(owner: "root.near", stream: "transfers")
            XCTFail("A persistent rate limit must not produce an empty successful history")
        } catch { XCTAssertEqual(error as? NearError, .http(429)) }
        let calls = await transport.requests, times = await transport.times
        XCTAssertEqual(calls.count, 2)
        XCTAssertGreaterThanOrEqual(times[0].duration(to: times[1]), .seconds(1))
    }
    func testLongProviderWaitIsNeverShortenedToRetryEarly() async throws {
        let transport = NearRateLimitFeed(header: "3600", page: try page())
        do {
            _ = try await NearClient(apiKey: "fixture", transport: transport).history(owner: "root.near", stream: "transfers")
            XCTFail()
        } catch { XCTAssertEqual(error as? NearError, .http(429)) }
        let calls = await transport.requests
        XCTAssertEqual(calls.count, 1)
    }
    func testCancellationDuringRateLimitWaitDoesNotRetry() async throws {
        let transport = NearRateLimitFeed(header: "10", page: try page())
        let client = try NearClient(apiKey: "fixture", transport: transport)
        let task = Task { try await client.history(owner: "root.near", stream: "transfers") }
        for _ in 0..<200 {
            if await transport.requests.count > 0 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let started = await transport.requests.count
        XCTAssertEqual(started, 1)
        task.cancel()
        do { _ = try await task.value; XCTFail() }
        catch { XCTAssertTrue(error is CancellationError) }
        let calls = await transport.requests
        XCTAssertEqual(calls.count, 1)
        // The canceled delay must not hold a transport permit or poison the client.
        _ = try await client.history(owner: "root.near", stream: "transfers")
    }
    func testDelayParsesDateAndRejectsWaitsOutsideBudget() throws {
        let now = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(NearClient.indexRateLimitDelay("Thu, 01 Jan 1970 00:00:07 GMT", now: now), 7)
        XCTAssertNil(NearClient.indexRateLimitDelay("Thu, 01 Jan 1970 00:01:00 GMT", now: now))
        XCTAssertNil(NearClient.indexRateLimitDelay("11", now: now))
        for header in [nil, "", "invalid", "-1", "NaN", "0", "Thu, 01 Jan 1970 00:00:00 GMT"] {
            let delay = try XCTUnwrap(NearClient.indexRateLimitDelay(header, now: now))
            XCTAssertTrue((1...2).contains(delay))
        }
    }
    func testRealHTTPTransportRetainsRetryAfterForProtocolConsumers() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RateLimitedHTTPProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let transport: any AnkrTransport = AnkrHTTPTransport(session: session)
        let response = try await transport.sendResponse(URLRequest(url: URL(string: "https://tx.main.fastnear.com/v0/account")!))
        XCTAssertEqual(response.status, 429)
        XCTAssertEqual(response.retryAfter, "7")
    }
}
