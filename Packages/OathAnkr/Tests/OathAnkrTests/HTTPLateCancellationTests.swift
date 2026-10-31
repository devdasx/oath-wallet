import Foundation
import XCTest
import OathDiagnostics
@testable import OathAnkr

/// Holds the requesting task's continuation after URLSession has produced a
/// failure. This models navigation cancelling between completion and delivery,
/// without replacing the production transport or relying on a timing race.
@available(macOS 15.0, iOS 18.0, *)
private final class HeldHTTPExecutor: TaskExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "oath.fixture.http-delivery")
    private var paused = false
    private var pending: [UnownedJob] = []
    var waiting: Bool { lock.withLock { !pending.isEmpty } }
    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        let held = lock.withLock {
            if paused { pending.append(job); return true }
            return false
        }
        if !held { dispatch(job) }
    }
    func pause() { lock.withLock { paused = true } }
    func resume() {
        let jobs = lock.withLock { paused = false; let jobs = pending; pending.removeAll(); return jobs }
        for job in jobs { dispatch(job) }
    }
    private func dispatch(_ job: UnownedJob) {
        queue.async { job.runSynchronously(on: self.asUnownedTaskExecutor()) }
    }
}

private final class HeldHTTPReplies: @unchecked Sendable {
    private let lock = NSLock()
    private var loading: HeldHTTPProtocol?
    var started: Bool { lock.withLock { loading != nil } }
    func start(_ value: HeldHTTPProtocol) { lock.withLock { loading = value } }
    func fail(_ code: URLError.Code = .networkConnectionLost) {
        let loading = lock.withLock { let value = loading; loading = nil; return value }
        if let loading { loading.client?.urlProtocol(loading, didFailWithError: URLError(code)) }
    }
}
private final class HeldHTTPProtocol: URLProtocol, @unchecked Sendable {
    static let replies = HeldHTTPReplies()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.replies.start(self) }
    override func stopLoading() { }
}
private actor LateHTTPReports: DiagnosticTransport {
    private(set) var events: [DiagnosticEvent] = []
    func upload(_ events: [DiagnosticEvent]) async throws { self.events += events }
}

final class HTTPLateCancellationTests: XCTestCase, @unchecked Sendable {
    private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<500 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw DiagnosticFailure("fixture_http_delivery_timeout")
    }

    // Run in isolation: the shared diagnostics destination configures once.
    func testCancelledDeliveryAndOutageAreQuietButInvalidResponseReports() async throws {
        guard #available(macOS 15.0, iOS 18.0, *) else { throw XCTSkip("Controlled executor requires macOS 15 or iOS 18") }
        let reports = LateHTTPReports()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        OathDiagnostics.configure(file: file, transport: reports)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HeldHTTPProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let transport = AnkrHTTPTransport(session: session)
        let executor = HeldHTTPExecutor()
        defer { executor.resume() }
        let request = URLRequest(url: URL(string: "https://rpc.fixture/fixture_secret_key")!)
        let cancelled = Task(executorPreference: executor) {
            try await OathDiagnostics.withChain("ethereum") { try await transport.send(request) }
        }
        try await wait { HeldHTTPProtocol.replies.started }
        executor.pause()
        HeldHTTPProtocol.replies.fail()
        try await wait { executor.waiting }
        cancelled.cancel()
        executor.resume()
        do { _ = try await cancelled.value; XCTFail("Cancelled request succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }

        let active = Task {
            try await OathDiagnostics.withChain("ethereum") { try await transport.send(request) }
        }
        try await wait { HeldHTTPProtocol.replies.started }
        HeldHTTPProtocol.replies.fail()
        do { _ = try await active.value; XCTFail("Disconnected request succeeded") }
        catch { XCTAssertEqual(error as? AnkrError, .transport) }
        let invalid = Task {
            try await OathDiagnostics.withChain("ethereum") { try await transport.send(request) }
        }
        try await wait { HeldHTTPProtocol.replies.started }
        HeldHTTPProtocol.replies.fail(.badServerResponse)
        do { _ = try await invalid.value; XCTFail("Invalid response succeeded") }
        catch { XCTAssertEqual(error as? AnkrError, .transport) }
        for _ in 0..<200 {
            await OathDiagnostics.flush()
            if await reports.events.count >= 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(100))
        await OathDiagnostics.flush()
        let events = await reports.events
        XCTAssertEqual(events.count, 1, "Only the non-availability response failure belongs in local diagnostics")
        let event = try XCTUnwrap(events.last)
        XCTAssertEqual(event.error.code, URLError.badServerResponse.rawValue)
        XCTAssertEqual(event.context["chain"], "ethereum")
        XCTAssertEqual(event.context["host"], "rpc.fixture")
        XCTAssertNotNil(event.operationID)
        XCTAssertTrue(event.privacyFiltered)
        let payload = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        XCTAssertFalse(payload.contains("fixture_secret_key"))
        XCTAssertFalse(payload.contains("https://"))
    }
}
