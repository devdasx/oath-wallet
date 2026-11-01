import Foundation
import XCTest
@testable import OathBitcoin

private final class StreamTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private var began = false
    func started() { lock.withLock { began = true } }
    func ended() { lock.withLock { completed = true } }
    func reset() { lock.withLock { began = false; completed = false } }
    var sentTail: Bool { lock.withLock { completed } }
    var hasStarted: Bool { lock.withLock { began } }
}

private final class BudgetProtocol: URLProtocol, @unchecked Sendable {
    static let trace = StreamTrace()
    private let lock = NSLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let mode = url.lastPathComponent
        let status = Int(request.value(forHTTPHeaderField: "X-Fixture-Status") ?? "200")!
        var headers = ["Retry-After": "120"]
        if mode == "short-header" { headers["Content-Length"] = "1" }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if mode == "exact" || mode == "empty" || mode == "rpc" {
            if mode == "exact" { client?.urlProtocol(self, didLoad: Data(repeating: 7, count: 32_768)) }
            if mode == "rpc" { client?.urlProtocol(self, didLoad: Data(#"{"id":1,"error":{"code":-5}}"#.utf8)) }
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        // The protocol remains open after exceeding the caller's limit. Releasing
        // the tail also lets an unfixed implementation finish deterministically.
        client?.urlProtocol(self, didLoad: Data(repeating: 7, count: mode == "cancel" ? 1 : 65_536))
        Self.trace.started()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [self] in
            guard !lock.withLock({ stopped }) else { return }
            Self.trace.ended()
            client?.urlProtocol(self, didLoad: Data([1]))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { lock.withLock { stopped = true } }
}

final class BitcoinResponseBudgetTests: XCTestCase, @unchecked Sendable {
    private func session() -> URLSession {
        BudgetProtocol.trace.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BudgetProtocol.self]
        return URLSession(configuration: config)
    }
    private func request(_ mode: String, status: Int = 200) -> URLRequest {
        var req = URLRequest(url: URL(string: "https://fixture.invalid/" + mode)!)
        req.setValue(String(status), forHTTPHeaderField: "X-Fixture-Status")
        return req
    }
    private func reject(_ mode: String, status: Int = 200) async throws -> UTXOAPIBudget {
        let s = session(), budget = UTXOAPIBudget()
        defer { s.invalidateAndCancel() }
        do {
            _ = try await UTXOAPIProvider.fetch(request(mode,status:status),limit:32_768,session:s,budget:budget)
            XCTFail("Oversized provider response succeeded")
        } catch UTXOAPIProvider.APIError.invalidResponse {}
        XCTAssertFalse(BudgetProtocol.trace.sentTail, "Reader waited for the oversized response tail")
        return budget
    }
    func testUnknownLengthStopsAtTheLimit() async throws { _ = try await reject("chunked") }
    func testActualBytesOverrideShortLengthHeader() async throws { _ = try await reject("short-header") }
    func testOversizedThrottleStillAppliesCooldown() async throws {
        let budget = try await reject("slow", status: 429)
        do {
            try await budget.acquire("fixture.invalid")
            XCTFail("Oversized HTTP 429 lost its cooldown")
        } catch UTXOAPIBudget.Deferred.cooldown {}
    }
    func testMissing404DoesNotConsumeTheBody() async throws {
        let s = session()
        defer { s.invalidateAndCancel() }
        let data = try await UTXOAPIProvider.fetch(request("missing",status:404),limit:0,allowMissing:true,session:s,budget:UTXOAPIBudget())
        XCTAssertTrue(data.isEmpty)
        XCTAssertFalse(BudgetProtocol.trace.sentTail, "Reader waited for an irrelevant 404 body")
    }
    func testExactAndZeroLimitsAcceptCompleteBodies() async throws {
        let s = session(), budget = UTXOAPIBudget()
        defer { s.invalidateAndCancel() }
        let exact = try await UTXOAPIProvider.fetch(request("exact"),limit:32_768,session:s,budget:budget)
        XCTAssertEqual(exact, Data(repeating: 7, count: 32_768))
        let empty = try await UTXOAPIProvider.fetch(request("empty"),limit:0,session:s,budget:budget)
        XCTAssertTrue(empty.isEmpty)
    }
    func testCancelDuringBodyReleasesAdmission() async throws {
        let s = session(), budget = UTXOAPIBudget()
        defer { s.invalidateAndCancel() }
        let task = Task { try await UTXOAPIProvider.fetch(request("cancel"),limit:32,session:s,budget:budget) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !BudgetProtocol.trace.hasStarted && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(3)) }
        XCTAssertTrue(BudgetProtocol.trace.hasStarted)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation returned data") }
        catch { XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled) }
        XCTAssertFalse(BudgetProtocol.trace.sentTail)
        try await budget.acquire("fixture.invalid")
        try await budget.acquire("fixture.invalid")
        await budget.release("fixture.invalid")
        await budget.release("fixture.invalid")
    }
}
