import Foundation
import XCTest
@testable import OathAnkr

private actor RecentXrplTransport: AnkrTransport {
    var requests: [URLRequest] = []
    let ranges: String
    let reportedMinimum: Int64
    init(ranges: String = "107562780-107981435", reportedMinimum: Int64 = 107562780) {
        self.ranges = ranges; self.reportedMinimum = reportedMinimum
    }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        requests.append(request)
        let body = try JSONDecoder().decode(XrplJSON.self, from: request.httpBody!)
        let params = body["params"].array![0]
        let result: XrplJSON
        if body["method"].string == "server_info" {
            result = .object(["status":.string("success"), "info":.object([
                "complete_ledgers":.string(ranges), "network_id":.number("0")])])
        } else if body["method"].string == "account_tx", params["ledger_index_min"].integer == 107562780 {
            result = .object(["status":.string("success"), "validated":.bool(true),
                "account":params["account"], "ledger_index_min":.number(String(reportedMinimum)),
                "ledger_index_max":params["ledger_index_max"], "transactions":.array([])])
        } else {
            result = .object(["status":.string("error"), "error":.string("lgrIdxMalformed")])
        }
        return (try JSONEncoder().encode(XrplJSON.object(["result":result])), 200)
    }
}

final class XrplRecentHistoryTests: XCTestCase, @unchecked Sendable {
    private let owner = "r9cZA1mLK5R5Am25ArfXFmqgNwjZgnfk59"
    func testAnkrHistoryRequestsOnlyItsAvailableWindowAndKeepsPinnedCursor() async throws {
        let transport = RecentXrplTransport()
        let client = try XrplClient(apiKey: "fixture", transport: transport)
        let page = try await client.history(owner: owner, before: "{\"ledger\":107800000,\"seq\":4}", upperLedger: 107900000)
        XCTAssertEqual(page.upperLedger, 107900000)
        XCTAssertNil(page.next)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { $0.url?.host == "rpc.ankr.com" })
        let body = try JSONDecoder().decode(XrplJSON.self, from: requests.last!.httpBody!)
        XCTAssertEqual(body["params"].array![0]["ledger_index_min"].integer, 107562780)
        XCTAssertEqual(body["params"].array![0]["marker"]["seq"].integer, 4)
    }
    func testExpiredCursorDoesNotSendAnUnavailableHistoryRequest() async throws {
        let transport = RecentXrplTransport()
        let client = try XrplClient(apiKey: "fixture", transport: transport)
        do {
            _ = try await client.history(owner: owner, before: "\"old\"", upperLedger: 100000000)
            XCTFail("Expired history was accepted")
        } catch { XCTAssertEqual(error as? XrplError, .historyWindowExpired) }
        let count = await transport.requests.count
        XCTAssertEqual(count, 1)
    }
    func testMalformedGappedOrClampedRangeCannotBecomeSuccessfulEmptyHistory() async throws {
        for range in ["empty", "107562780-107700000,107800000-107981435", "107981435-107562780", "-1-107981435", "0-107981435"] {
            let transport = RecentXrplTransport(ranges: range)
            do { _ = try await XrplClient(apiKey:"fixture",transport:transport).history(owner:owner); XCTFail("Accepted invalid range") }
            catch { XCTAssertEqual(error as? XrplError,.incompleteHistory) }
            let count = await transport.requests.count; XCTAssertEqual(count,1)
        }
        let transport = RecentXrplTransport(reportedMinimum: 107562781)
        do { _ = try await XrplClient(apiKey:"fixture",transport:transport).history(owner:owner); XCTFail("Accepted clamped range") }
        catch { XCTAssertEqual(error as? XrplError,.incompleteHistory) }
        let count = await transport.requests.count; XCTAssertEqual(count,2)
    }
    func testLiveAnkrRecentHistoryUsesExistingKeyAndPersistsPinnedUpperBound() async throws {
        guard let key = ProcessInfo.processInfo.environment["OATH_XRPL_RECENT_LIVE_KEY"] else { throw XCTSkip("Opt-in read-only ANKR recent history") }
        let client = try XrplClient(apiKey:key)
        let owner = "rLxePHrWeHbkg8yy83fWxnxXmYbwmuMK9Q"
        let first = try await client.history(owner:owner,limit:10)
        let raw = try JSONDecoder().decode(XrplJSON.self,from:first.raw)
        let lower = try XrplIdentity.number(raw["ledger_index_min"])
        XCTAssertGreaterThan(lower,32570)
        XCTAssertFalse(first.transactions.isEmpty, "The public active-account fixture should exercise decoding")
        XCTAssertTrue(first.transactions.allSatisfy { (lower...first.upperLedger).contains($0.checkpoint) })
        let cursor = try XCTUnwrap(first.next, "The public active-account fixture should exercise pagination")
        do {
            let second = try await client.history(owner:owner,before:cursor,upperLedger:first.upperLedger,limit:10)
            XCTAssertEqual(second.upperLedger,first.upperLedger)
            XCTAssertTrue(Set(first.transactions.map(\.hash)).isDisjoint(with:second.transactions.map(\.hash)))
        }
        print("ANKR recent XRP history verified: bounded range, validated results, unchanged key")
    }
}
