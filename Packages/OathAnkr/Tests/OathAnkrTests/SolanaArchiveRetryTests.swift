import Foundation
import XCTest
@testable import OathAnkr

private let retryOwner = String(repeating: "1", count: 32)
private let retryBefore = String(repeating: "1", count: 64)
private let retryUntil = String(repeating: "1", count: 63) + "2"
private let retryResult = String(repeating: "1", count: 63) + "3"

private actor ArchiveRetryFeed: AnkrTransport {
    enum Mode { case once, persistent, invalidAnchor, cancelled }
    let mode: Mode
    var archiveCalls: [SolanaJSON] = []
    var primaryHistoryCalls = 0
    init(_ mode: Mode) { self.mode = mode }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let call = try JSONDecoder().decode(SolanaJSON.self, from: XCTUnwrap(request.httpBody))
        let primary = request.url?.host == "rpc.ankr.com"
        var reply: [String: SolanaJSON] = ["jsonrpc": .string("2.0"), "id": call["id"]]
        if call["method"].string == "getGenesisHash" { reply["result"] = .string(SolanaIdentity.genesis) }
        else {
            XCTAssertEqual(call["method"].string, "getSignaturesForAddress")
            if primary { primaryHistoryCalls += 1 } else { archiveCalls.append(call) }
            if !primary && mode == .cancelled { throw CancellationError() }
            if primary || mode == .invalidAnchor {
                reply["error"] = .object(["code": .number("-32020"), "message": .string("Transaction not found")])
            } else if mode == .persistent || archiveCalls.count == 1 {
                reply["error"] = .object(["code": .number("-32019"), "message": .string("Failed to query long-term storage; please try again")])
            } else {
                reply["result"] = .array([.object(["signature": .string(retryResult), "slot": .number("100"), "err": .null])])
            }
        }
        return (try JSONEncoder().encode(SolanaJSON.object(reply)), 200)
    }
}

final class SolanaArchiveRetryTests: XCTestCase, @unchecked Sendable {
    private func page(_ feed: ArchiveRetryFeed) async throws -> SolanaSignaturePage {
        try await SolanaClient(apiKey: "fixture", transport: feed).signatures(address: retryOwner, before: retryBefore, until: retryUntil, limit: 5)
    }
    func testTemporaryArchiveStorageFailureRetriesTheExactPage() async throws {
        let feed = ArchiveRetryFeed(.once)
        let result = try await page(feed)
        XCTAssertTrue(result.archival)
        XCTAssertEqual(result.signatures.map(\.signature), [retryResult])
        let calls = await feed.archiveCalls, primary = await feed.primaryHistoryCalls
        XCTAssertEqual(calls.count, 2); XCTAssertEqual(primary, 0)
        XCTAssertEqual(calls.first, calls.last)
        XCTAssertEqual(calls.first?["params"].array?.last?["before"].string, retryBefore)
        XCTAssertEqual(calls.first?["params"].array?.last?["until"].string, retryUntil)
    }
    func testPersistentFailureIsBoundedAndNeverTurnsIntoEmptyHistory() async throws {
        let feed = ArchiveRetryFeed(.persistent)
        do { _ = try await page(feed); XCTFail("Unavailable history must not become complete") }
        catch { XCTAssertEqual(error as? SolanaError, .rpc(-32020)) }
        let calls = await feed.archiveCalls, primary = await feed.primaryHistoryCalls
        XCTAssertEqual(calls.count, 3); XCTAssertEqual(primary, 1)
        XCTAssertTrue(calls.allSatisfy { $0 == calls.first })
    }
    func testInvalidAnchorIsNotRetriedOrRemoved() async throws {
        let feed = ArchiveRetryFeed(.invalidAnchor)
        do { _ = try await page(feed); XCTFail() }
        catch { XCTAssertEqual(error as? SolanaError, .rpc(-32020)) }
        let calls = await feed.archiveCalls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?["params"].array?.last?["before"].string, retryBefore)
    }
    func testCancellationDoesNotRetryOrStartPrimaryHistory() async throws {
        let feed = ArchiveRetryFeed(.cancelled)
        do { _ = try await page(feed); XCTFail() }
        catch { XCTAssertTrue(error is CancellationError) }
        let calls = await feed.archiveCalls, primary = await feed.primaryHistoryCalls
        XCTAssertEqual(calls.count, 1); XCTAssertEqual(primary, 0)
    }
}

private actor LiveArchiveRetryFeed: AnkrTransport {
    let live = AnkrHTTPTransport()
    var injected = false
    var primaryHistoryCalls = 0
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let call = try JSONDecoder().decode(SolanaJSON.self, from: XCTUnwrap(request.httpBody))
        if call["method"].string == "getSignaturesForAddress" {
            if request.url?.host == "rpc.ankr.com" { primaryHistoryCalls += 1 }
            else if !injected {
                injected = true
                return (try JSONEncoder().encode(SolanaJSON.object(["jsonrpc": .string("2.0"), "id": call["id"],
                    "error": .object(["code": .number("-32019"), "message": .string("Failed to query long-term storage; please try again")])])), 200)
            }
        }
        return try await live.send(request)
    }
}

final class SolanaArchiveRetryLiveTests: XCTestCase, @unchecked Sendable {
    func testRealOldHistorySurvivesOneArchiveStorageFailure() async throws {
        guard ProcessInfo.processInfo.environment["OATH_SOLANA_ARCHIVE_RETRY_LIVE"] == "1" else {
            throw XCTSkip("Opt-in public history reads with one injected provider error")
        }
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["OATH_ANKR_CONFIG"])
        let keys = try PropertyListDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let key = try XCTUnwrap(keys["AnkrAPIKey"])
        let owner = "CutAG7TzyTq6BNECcvLjm2FCxL19pPPQDqV2em91Qeom"
        let independent = try SolanaClient(apiKey: key)
        let head = try await independent.signatures(address: owner, limit: 5)
        XCTAssertTrue(head.archival)
        let before = try XCTUnwrap(head.signatures.last?.signature)
        let expected = try await independent.signatures(address: owner, before: before, limit: 5)
        XCTAssertTrue(expected.archival); XCTAssertEqual(expected.signatures.count, 5)
        let feed = LiveArchiveRetryFeed()
        let actual = try await SolanaClient(apiKey: key, transport: feed).signatures(address: owner, before: before, limit: 5)
        XCTAssertTrue(actual.archival)
        XCTAssertEqual(actual.signatures.map(\.signature), expected.signatures.map(\.signature))
        XCTAssertEqual(actual.signatures.map(\.slot), expected.signatures.map(\.slot))
        let injected = await feed.injected, primary = await feed.primaryHistoryCalls
        XCTAssertTrue(injected); XCTAssertEqual(primary, 0)
        print("Solana public old-history recovery: five exact entries matched after one injected archive outage; cursor preserved")
    }
}
