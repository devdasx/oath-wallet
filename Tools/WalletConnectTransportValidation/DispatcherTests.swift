import XCTest
import RelayDispatcher
import OathDiagnostics
@testable import SocketTransport

/// Deterministic disconnect in the real interval between the SDK's connected
/// check and the native write. Frames are never fabricated or acknowledged.
private final class DisconnectBeforeWrite: WebSocketErrorReporting {
    let base: any WebSocketConnecting
    init(_ base: any WebSocketConnecting) { self.base = base }
    var isConnected: Bool { base.isConnected }
    var onConnect: (() -> Void)? { get { base.onConnect } set { base.onConnect = newValue } }
    var onDisconnect: ((Error?) -> Void)? { get { base.onDisconnect } set { base.onDisconnect = newValue } }
    var onText: ((String) -> Void)? { get { base.onText } set { base.onText = newValue } }
    var request: URLRequest { get { base.request } set { base.request = newValue } }
    func connect() { base.connect() }
    func disconnect() { base.disconnect() }
    func write(string: String, completion: (() -> Void)?) {
        base.disconnect()
        base.write(string: string, completion: completion)
    }
    func write(string: String, resultCompletion: @escaping (Error?) -> Void) {
        base.disconnect()
        (base as! any WebSocketErrorReporting).write(string: string, resultCompletion: resultCompletion)
    }
}
private final class SendOutcome: @unchecked Sendable {
    let lock = NSLock()
    private var results: [Error?] = []
    func received(_ error: Error?) { lock.withLock { results.append(error) } }
    var count: Int { lock.withLock { results.count } }
    var failureCount: Int { lock.withLock { results.compactMap { $0 }.count } }
    var codes: [Int] { lock.withLock { results.compactMap { $0.map { ($0 as NSError).code } } } }
}
actor TransportCapture: DiagnosticTransport {
    static let shared = TransportCapture()
    var events: [DiagnosticEvent] = []
    func upload(_ events: [DiagnosticEvent]) async throws { self.events += events }
    static func configured() throws -> TransportCapture {
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["OATH_SOCKET_DIAGNOSTICS_FILE"])
        // Production diagnostics configures once per process. All host cases
        // share this capture instead of silently replacing its uploader.
        OathDiagnostics.configure(file: URL(fileURLWithPath: path), transport: shared)
        return shared
    }
}
@MainActor final class DispatcherTests: XCTestCase {
    private func endpoint(_ path: String = "/echo") throws -> URL {
        let port = try XCTUnwrap(ProcessInfo.processInfo.environment["OATH_SOCKET_TEST_PORT"])
        return URL(string: "ws://127.0.0.1:" + port + path)!
    }
    func testDisconnectBetweenConnectedCheckAndWriteFailsExactlyOnce() async throws {
        let port = try XCTUnwrap(ProcessInfo.processInfo.environment["OATH_SOCKET_TEST_PORT"])
        let factory = OathWCSocketFactory()
        let base = factory.create(with: URL(string: "ws://127.0.0.1:" + port + "/echo")!)
        let socket = DisconnectBeforeWrite(base)
        let fixture = DispatcherFixture(socket: socket, factory: factory)
        socket.connect()
        defer { socket.disconnect() }
        for _ in 0..<400 {
            if socket.isConnected { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(socket.isConnected)
        let outcome = SendOutcome()
        fixture.send("public-unsent-race-fixture", completion: outcome.received)
        for _ in 0..<100 {
            if outcome.count > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(outcome.count, 1, "Native disconnect must terminate the SDK send")
        XCTAssertEqual(outcome.failureCount, 1, "An unsent frame must never be reported as success")
    }

    func testAsyncSDKSendThrowsAfterNativeDisconnect() async throws {
        let factory = OathWCSocketFactory()
        let socket = DisconnectBeforeWrite(factory.create(with: try endpoint()))
        let fixture = DispatcherFixture(socket: socket, factory: factory)
        socket.connect()
        defer { socket.disconnect() }
        for _ in 0..<400 {
            if socket.isConnected { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(socket.isConnected)
        let outcome = SendOutcome()
        let send = Task.detached {
            do { try await fixture.send("public-async-unsent-fixture"); outcome.received(nil) }
            catch { outcome.received(error) }
        }
        for _ in 0..<100 {
            if outcome.count > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        send.cancel()
        XCTAssertEqual(outcome.count, 1)
        XCTAssertEqual(outcome.codes, [NSURLErrorNetworkConnectionLost])
    }

    func testHandshakeCloseFailsPendingWriteOnceAndNextConnectionWorks() async throws {
        let factory = OathWCSocketFactory()
        let socket = factory.create(with: try endpoint("/delayed")) as! any WebSocketErrorReporting
        let outcome = SendOutcome()
        socket.connect()
        socket.write(string: "must-not-send-after-close", resultCompletion: outcome.received)
        socket.disconnect()
        XCTAssertEqual(outcome.count, 1)
        XCTAssertEqual(outcome.failureCount, 1)
        socket.request = URLRequest(url: try endpoint())
        socket.connect()
        defer { socket.disconnect() }
        for _ in 0..<400 {
            if socket.isConnected { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let next = SendOutcome()
        socket.write(string: "new-connection-public-fixture", resultCompletion: next.received)
        for _ in 0..<100 {
            if next.count > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(outcome.count, 1, "Old task completions must not fire twice")
        XCTAssertEqual(next.count, 1)
        XCTAssertEqual(next.failureCount, 0)
        XCTAssertTrue(socket.isConnected, "Old socket callbacks must not close a replacement")
    }

    func testWriteDeadlineAndQueueLimitReportWithoutPayloadOrDuplicateCompletion() async throws {
        let capture = try TransportCapture.configured()
        let socket = OathWCSocketFactory(writeTimeout: 0.05, maximumPendingWrites: 1)
            .create(with: try endpoint("/delayed")) as! any WebSocketErrorReporting
        socket.connect()
        defer { socket.disconnect() }
        let first = SendOutcome(), second = SendOutcome()
        socket.write(string: "never-log-this-test-payload", resultCompletion: first.received)
        socket.write(string: "never-log-this-test-payload", resultCompletion: second.received)
        XCTAssertEqual(second.codes, [NSURLErrorResourceUnavailable])
        for _ in 0..<200 {
            if first.count > 0, await capture.events.filter({ [NSURLErrorTimedOut, NSURLErrorResourceUnavailable].contains($0.error.code) }).count >= 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(first.codes, [NSURLErrorTimedOut])
        XCTAssertFalse(socket.isConnected)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(second.count, 1)
        let events = await capture.events.filter { [NSURLErrorTimedOut, NSURLErrorResourceUnavailable].contains($0.error.code) }
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(Set(events.map(\.operation)), ["relay_transport", "relay_write_capacity"])
        XCTAssertEqual(Set(events.compactMap(\.operationID)).count, 1)
        XCTAssertEqual(Set(events.compactMap { $0.context["stage"] }), ["send", "write_timeout"])
        let text = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        XCTAssertFalse(text.contains("never-log-this-test-payload"))
        XCTAssertFalse(text.contains("127.0.0.1"))
        XCTAssertFalse(text.contains("/delayed"))
    }
}
