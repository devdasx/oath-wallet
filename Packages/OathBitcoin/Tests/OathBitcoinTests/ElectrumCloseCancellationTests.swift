import Foundation
import XCTest
import OathDiagnostics
@testable import OathBitcoin

/// Like ElectrumWire, close() cancels an outstanding exchange independently of
/// whether its caller's Swift task was cancelled. No socket or wallet is used.
private final class ClosingTransport: ElectrumTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: CheckedContinuation<Data, Error>?
    private var closed = false
    private let closeError: any Error
    init(closeError: any Error = CancellationError()) { self.closeError = closeError }
    var isWaiting: Bool { lock.withLock { pending != nil } }
    func exchange(_ data: Data, timeout: TimeInterval) async throws -> Data {
        let calls = try JSONDecoder().decode(JSONValue.self, from: data).array!
        if calls.first?["method"]?.string == "server.version" {
            return try await StubTransport(.empty).exchange(data, timeout: timeout)
        }
        return try await withCheckedThrowingContinuation { continuation in
            let cancelled = lock.withLock {
                if closed { return true }
                pending = continuation; return false
            }
            if cancelled { continuation.resume(throwing: closeError) }
        }
    }
    func close() {
        let waiting = lock.withLock {
            closed = true
            let waiting = pending; pending = nil; return waiting
        }
        waiting?.resume(throwing: closeError)
    }
}

private final class CloseRecoveryFactory: @unchecked Sendable {
    private let lock = NSLock()
    let closing: ClosingTransport
    init(closeError: any Error = CancellationError()) { closing = ClosingTransport(closeError: closeError) }
    private var created: [String] = []
    var hosts: [String] { lock.withLock { created } }
    func make(_ server: ElectrumServer) -> any ElectrumTransport {
        let first = lock.withLock {
            let first = created.isEmpty
            created.append(server.host)
            return first
        }
        return first ? closing : StubTransport(.empty)
    }
}

private actor CloseReports: DiagnosticTransport {
    var events: [DiagnosticEvent] = []
    func upload(_ events: [DiagnosticEvent]) async throws { self.events += events }
}

final class ElectrumCloseDiagnosticsTests: XCTestCase, @unchecked Sendable {
    // Isolate this test from other diagnostics configurations in the package.
    func testLateTeardownFailureIsQuietButMalformedResponseRemainsReported() async throws {
        let reports = CloseReports()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        OathDiagnostics.configure(file: directory.appendingPathComponent("events.json"), transport: reports)
        let factory = CloseRecoveryFactory(closeError: BitcoinError.disconnected)
        let pool = ElectrumPool(servers: [.init("first"), .init("fallback")], makeTransport: factory.make)
        let work = Task { try await pool.query(scriptHashes: [String(repeating: "1", count: 64)]) }
        for _ in 0..<100 {
            if factory.closing.isWaiting { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(factory.closing.isWaiting)
        work.cancel()
        await pool.close()
        do { _ = try await work.value; XCTFail("Cancelled read succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        try await Task.sleep(for: .milliseconds(100))
        let cancelledEvents = await reports.events
        XCTAssertTrue(cancelledEvents.isEmpty, "A late transport error after task cancellation is teardown, not a new outage")
        XCTAssertEqual(factory.hosts, ["first"])

        // Availability timeouts are excluded by the shared diagnostics policy.
        // A malformed provider reply must still retain original safe context.
        let outage = ElectrumPool(servers: [.init("outage")]) { _ in StubTransport(.malformed) }
        let operation = UUID()
        do {
            _ = try await OathDiagnostics.$operationID.withValue(operation) {
                try await outage.query(scriptHashes: [String(repeating: "2", count: 64)])
            }
            XCTFail("Malformed provider response became success")
        } catch { XCTAssertEqual(error as? BitcoinError, .invalidResponse) }
        for _ in 0..<100 {
            if await reports.events.count > cancelledEvents.count { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let events = await reports.events
        XCTAssertEqual(events.count, 1)
        let event = try XCTUnwrap(events.last)
        XCTAssertEqual(event.operationID, operation)
        XCTAssertEqual(event.operation, "request")
        XCTAssertEqual(event.context["chain"], "bitcoin")
        XCTAssertEqual(event.context["host"], "outage")
        XCTAssertEqual(event.context["stage"], "request")
        XCTAssertTrue(event.privacyFiltered)
        let encoded = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
        XCTAssertFalse(encoded.contains(String(repeating: "2", count: 64)))
        await outage.close()
    }
}

final class ElectrumCloseCancellationTests: XCTestCase, @unchecked Sendable {
    func testExplicitCloseDoesNotTurnCancelledReadIntoFallbackSuccess() async throws {
        let factory = CloseRecoveryFactory()
        let pool = ElectrumPool(servers: [.init("first"), .init("fallback")], maximumConnections: 1, makeTransport: factory.make)
        let work = Task {
            XCTAssertFalse(Task.isCancelled)
            return try await pool.query(scriptHashes: [String(repeating: "1", count: 64)])
        }
        for _ in 0..<100 {
            if factory.closing.isWaiting { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(factory.closing.isWaiting)
        await pool.close()
        do { _ = try await work.value; XCTFail("Closing the request must not start another peer and return its balance") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(work.isCancelled, "Wire cancellation must survive even without a Swift task cancellation")
        XCTAssertEqual(factory.hosts, ["first"])
        let attempts = await pool.diagnostics()
        XCTAssertTrue(attempts.isEmpty, "Teardown must not be recorded as a malformed peer response")
    }

    func testExplicitCloseReleasesLeaseWithoutPoisoningHealthyPeerCooldown() async throws {
        let factory = CloseRecoveryFactory()
        let pool = ElectrumPool(servers: [.init("first")], maximumConnections: 1, makeTransport: factory.make)
        let work = Task { try await pool.query(scriptHashes: [String(repeating: "1", count: 64)]) }
        for _ in 0..<100 {
            if factory.closing.isWaiting { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(factory.closing.isWaiting)
        await pool.close()
        do { _ = try await work.value; XCTFail("Cancelled read succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        let result = try await pool.query(scriptHashes: [String(repeating: "1", count: 64)])
        XCTAssertEqual(result.first?.confirmed, 0)
        XCTAssertEqual(factory.hosts, ["first", "first"])
        let attempts = await pool.diagnostics()
        XCTAssertEqual(attempts.map(\.error), [nil])
        await pool.close()
    }
}
