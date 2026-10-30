import XCTest
@testable import OathAnkr

private final class TransportRequestCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func record() { lock.withLock { count += 1 } }
    func read() -> Int { lock.withLock { count } }
    func reset() { lock.withLock { count = 0 } }
}

private final class InterruptedHTTPProtocol: URLProtocol, @unchecked Sendable {
    static let calls = TransportRequestCounts()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.calls.record()
        let code: URLError.Code = request.url?.path == "/timeout" ? .timedOut : .cancelled
        client?.urlProtocol(self, didFailWithError: URLError(code))
    }
    override func stopLoading() { }
}

@MainActor final class HTTPTransportCancellationTests: XCTestCase {
    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InterruptedHTTPProtocol.self]
        return URLSession(configuration: configuration)
    }

    func testURLSessionCancellationRemainsCancellationWithoutTaskCancellation() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        XCTAssertFalse(Task.isCancelled)
        do {
            _ = try await AnkrHTTPTransport(session: session).send(URLRequest(url: URL(string: "https://rpc.example/cancelled")!))
            XCTFail("Cancelled request succeeded")
        } catch { XCTAssertTrue(error is CancellationError, "URLSession cancellation must not become a provider outage") }
        XCTAssertFalse(Task.isCancelled)
    }

    func testCancelledMonadReadDoesNotRetryOrFailOver() async throws {
        InterruptedHTTPProtocol.calls.reset()
        let session = session()
        defer { session.invalidateAndCancel() }
        let client = try IndexedEVMClient(chain: .monad, apiKey: "fixture", alchemyAPIKey: "fixture",
                                          transport: AnkrHTTPTransport(session: session))
        do {
            _ = try await client.history(owner: "0x1111111111111111111111111111111111111111", stream: .transactions)
            XCTFail("Cancelled history succeeded")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(InterruptedHTTPProtocol.calls.read(), 1, "Cancellation must not consume three provider attempts")
    }

    func testRealTimeoutRemainsAReportableTransportFailure() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        do {
            _ = try await AnkrHTTPTransport(session: session).send(URLRequest(url: URL(string: "https://rpc.example/timeout")!))
            XCTFail("Timed-out request succeeded")
        } catch { XCTAssertEqual(error as? AnkrError, .transport) }
    }
}
