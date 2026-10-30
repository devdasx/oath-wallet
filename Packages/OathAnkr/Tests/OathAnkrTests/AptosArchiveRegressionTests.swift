import Foundation
import XCTest
@testable import OathAnkr

final class AptosArchiveRegressionTests: XCTestCase, @unchecked Sendable {
    func testArchive502ThenPrunedNodesRetriesArchiveAndPreservesRequest() async throws {
        let transport = PrunedArchiveTransport(initial: 502, recovered: 200)
        let result = try await AptosClient(testTransport: transport).node("transactions/by_version/6136308008", version: 6136308008)
        XCTAssertEqual(result["version"].text, "6136308008")
        let calls = await transport.calls
        XCTAssertEqual(calls.map { $0.url!.host! }, ["archive.mainnet.aptoslabs.com", "rpc.ankr.com", "api.mainnet.aptoslabs.com", "archive.mainnet.aptoslabs.com"])
        XCTAssertEqual(calls.first?.url, calls.last?.url)
        XCTAssertNil(calls.last?.value(forHTTPHeaderField: "Authorization"))
    }
    func testPersistentArchiveFailureIsBoundedAndDoesNotBecomePrunedOrEmptyHistory() async throws {
        let transport = PrunedArchiveTransport(initial: 502, recovered: 503)
        do {
            _ = try await AptosClient(testTransport: transport).node("transactions/by_version/6136308008")
            XCTFail("Unavailable receipt must not become an empty history page")
        } catch { XCTAssertEqual(error as? AptosError, .http(503)) }
        let calls = await transport.calls; XCTAssertEqual(calls.count, 4)
    }
    func testRateLimitedArchiveIsNotImmediatelyRetried() async throws {
        let transport = PrunedArchiveTransport(initial: 429, recovered: 200)
        do { _ = try await AptosClient(testTransport: transport).node("transactions/by_version/6136308008"); XCTFail() }
        catch { XCTAssertEqual(error as? AptosError, .http(410)) }
        let calls = await transport.calls; XCTAssertEqual(calls.count, 3)
    }
    func testCancellationDoesNotRunArchiveRetry() async throws {
        let transport = PrunedArchiveTransport(initial: 502, recovered: 200, cancelPruned: true)
        do { _ = try await AptosClient(testTransport: transport).node("transactions/by_version/6136308008"); XCTFail() }
        catch { XCTAssertTrue(error is CancellationError) }
        let calls = await transport.calls; XCTAssertEqual(calls.count, 2)
    }
}
private actor PrunedArchiveTransport: AnkrTransport {
    let initial: Int, recovered: Int, cancelPruned: Bool
    var archiveReads = 0
    private(set) var calls: [URLRequest] = []
    init(initial: Int, recovered: Int, cancelPruned: Bool = false) {
        self.initial = initial; self.recovered = recovered; self.cancelPruned = cancelPruned
    }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        calls.append(request)
        if request.url?.host == "archive.mainnet.aptoslabs.com" {
            archiveReads += 1
            return (Data(#"{"version":"6136308008","type":"user_transaction"}"#.utf8), archiveReads == 1 ? initial : recovered)
        }
        if cancelPruned { throw CancellationError() }
        return (Data(), 410)
    }
}
