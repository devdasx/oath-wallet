import Foundation
import XCTest
@testable import OathExchangeRates

private final class RateStream: URLProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "rates.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let mode = url.lastPathComponent
        let status = mode == "unavailable" ? 503 : 200
        let head = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: head, cacheStoragePolicy: .notAllowed)
        if mode == "interrupted" {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }
        if mode == "exact" {
            client?.urlProtocol(self, didLoad: Data(repeating: 65, count: 131_072))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        client?.urlProtocol(self, didLoad: Data(repeating: 65, count: 139_264))
        // Byte streams may batch small chunks. Send a whole extra page and keep
        // the connection open, then simulate the remote peer disconnecting.
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [self] in
            guard !lock.withLock({ stopped }) else { return }
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
        }
    }

    override func stopLoading() { lock.withLock { stopped = true } }
}

final class RateResponseBudgetTests: XCTestCase, @unchecked Sendable {
    private func fetch(_ mode: String) async throws -> Data {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RateStream.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        return try await URLSessionRateTransport(session: session).data(from: URL(string: "https://rates.invalid/" + mode)!)
    }

    func testOversizePrecedesRemoteDisconnect() async throws {
        do { _ = try await fetch("oversized"); XCTFail("Accepted oversized body") }
        catch ExchangeRateError.invalidResponse {}
        catch let e as URLError where e.code == .networkConnectionLost { XCTFail("Downloaded past the rate limit until disconnect") }
    }

    func testOversizedFailureKeepsHTTPStatus() async throws {
        do { _ = try await fetch("unavailable"); XCTFail("Accepted HTTP error") }
        catch let e as URLError where e.code == .networkConnectionLost { XCTFail("Lost the HTTP status while waiting for oversized tail") }
        catch {
            XCTAssertEqual((error as NSError).domain, "Oath.HTTP")
            XCTAssertEqual((error as NSError).code, 503)
        }
    }

    func testBodyExactlyAtLimitIsComplete() async throws {
        let result = try await fetch("exact")
        XCTAssertEqual(result, Data(repeating: 65, count: 131_072))
    }

    func testInterruptedSmallBodyPreservesError() async throws {
        do { _ = try await fetch("interrupted"); XCTFail("Accepted an incomplete response") }
        catch let e as URLError { XCTAssertEqual(e.code, .networkConnectionLost) }
    }
}
