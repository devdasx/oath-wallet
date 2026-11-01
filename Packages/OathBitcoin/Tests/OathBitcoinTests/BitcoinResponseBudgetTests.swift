import Foundation
import XCTest
@testable import OathBitcoin

private final class StreamTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private var began = false
    func started() { lock.withLock { began = true } }
    func ended() { lock.withLock { completed = true } }
    private var cancelled = false
    func stopped() { lock.withLock { cancelled = true } }
    var hasStopped: Bool { lock.withLock { cancelled } }
    var sentTail: Bool { lock.withLock { completed } }
    var hasStarted: Bool { lock.withLock { began } }
}

private final class TraceRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var registered: [String: StreamTrace] = [:]
    subscript(_ host: String) -> StreamTrace? {
        get { lock.withLock { registered[host] } }
        set { lock.withLock { registered[host] = newValue } }
    }
}

private final class BudgetProtocol: URLProtocol, @unchecked Sendable {
    static let registry = TraceRegistry()
    private var trace: StreamTrace? { Self.registry[request.url?.host ?? ""] }
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
        if mode == "interrupted" {
            client?.urlProtocol(self, didLoad: Data([1]))
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }
        if ["exact", "empty", "throttle-envelope", "policy"].contains(mode) {
            if mode == "exact" { client?.urlProtocol(self, didLoad: Data(repeating: 7, count: 32_768)) }
            if mode == "throttle-envelope" { client?.urlProtocol(self, didLoad: Data(#"{"id":1,"error":{"code":429}}"#.utf8)) }
            if mode == "policy" { client?.urlProtocol(self, didLoad: Data("min relay fee not met".utf8)) }
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        // The protocol remains open after exceeding the caller's limit. Releasing
        // the tail also lets an unfixed implementation finish deterministically.
        client?.urlProtocol(self, didLoad: Data(repeating: 7, count: mode == "cancel" ? 1 : 65_536))
        trace?.started()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [self] in
            guard !lock.withLock({ stopped }) else { return }
            trace?.ended()
            client?.urlProtocol(self, didLoad: Data([1]))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { lock.withLock { stopped = true }; trace?.stopped() }
}

final class BitcoinResponseBudgetTests: XCTestCase, @unchecked Sendable {
    private let host = UUID().uuidString.lowercased() + ".invalid"
    private let trace = StreamTrace()

    override func setUp() { super.setUp(); BudgetProtocol.registry[host] = trace }
    override func tearDown() { BudgetProtocol.registry[host] = nil; super.tearDown() }

    private func assertStoppedBeforeTail(_ message: String) async throws {
        if trace.sentTail { XCTFail(message); return }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !trace.hasStopped && !trace.sentTail && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(3))
        }
        XCTAssertTrue(trace.hasStopped && !trace.sentTail, "The transfer continued after the reader returned")
    }
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BudgetProtocol.self]
        return URLSession(configuration: config)
    }
    private func request(_ mode: String, status: Int = 200) -> URLRequest {
        var req = URLRequest(url: URL(string: "https://" + host + "/" + mode)!)
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
        try await assertStoppedBeforeTail("Reader waited for the oversized response tail")
        return budget
    }
    func testUnknownLengthStopsAtTheLimit() async throws { _ = try await reject("chunked") }
    func testActualBytesOverrideShortLengthHeader() async throws { _ = try await reject("short-header") }
    func testOversizedThrottleStillAppliesCooldown() async throws {
        let budget = try await reject("slow", status: 429)
        do {
            try await budget.acquire(host)
            XCTFail("Oversized HTTP 429 lost its cooldown")
        } catch UTXOAPIBudget.Deferred.cooldown {}
    }
    func testMissing404DoesNotConsumeTheBody() async throws {
        let s = session()
        defer { s.invalidateAndCancel() }
        let data = try await UTXOAPIProvider.fetch(request("missing",status:404),limit:0,allowMissing:true,session:s,budget:UTXOAPIBudget())
        XCTAssertTrue(data.isEmpty)
        try await assertStoppedBeforeTail("Reader waited for an irrelevant 404 body")
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
        while !trace.hasStarted && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(3)) }
        XCTAssertTrue(trace.hasStarted)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation returned data") }
        catch { XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled) }
        try await assertStoppedBeforeTail("Caller cancellation waited for the response tail")
        try await budget.acquire(host)
        try await budget.acquire(host)
        await budget.release(host)
        await budget.release(host)
    }

    func testSmallThrottleEnvelopeStillAppliesCooldown() async throws {
        let s = session(), budget = UTXOAPIBudget()
        defer { s.invalidateAndCancel() }
        let body = try await UTXOAPIProvider.fetch(request("throttle-envelope"),limit:128,session:s,budget:budget)
        XCTAssertEqual(body, Data(#"{"id":1,"error":{"code":429}}"#.utf8))
        do { try await budget.acquire(host); XCTFail("Envelope cooldown was lost") }
        catch UTXOAPIBudget.Deferred.cooldown {}
    }
    func testSmallHTTPPolicyErrorKeepsItsClassification() async throws {
        let s = session()
        defer { s.invalidateAndCancel() }
        do {
            _ = try await UTXOAPIProvider.fetch(request("policy", status:400),limit:128,session:s,budget:UTXOAPIBudget())
            XCTFail("Expected policy error")
        } catch {
            let e = error as NSError
            XCTAssertEqual(e.domain,"Oath.UTXOAPI"); XCTAssertEqual(e.code,400)
            XCTAssertEqual(e.localizedDescription,"min relay fee not met")
        }
    }
    func testInterruptedBodyPreservesCauseAndReleasesAdmission() async throws {
        let s = session(), budget = UTXOAPIBudget()
        defer { s.invalidateAndCancel() }
        do {
            _ = try await UTXOAPIProvider.fetch(request("interrupted"),limit:128,session:s,budget:budget)
            XCTFail("Incomplete body succeeded")
        } catch { XCTAssertEqual((error as? URLError)?.code,.networkConnectionLost) }
        try await budget.acquire(host); try await budget.acquire(host)
        await budget.release(host); await budget.release(host)
    }
}
