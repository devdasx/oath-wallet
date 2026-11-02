import Foundation
import XCTest
import OathDiagnostics
@testable import OathAnkr

private actor RecentXrplTransport: AnkrTransport {
    var requests: [URLRequest] = []
    var pageSteps: [String?] = []
    var ranges: String
    var subsequentRanges: [String]
    let reportedMinimum: Int64
    let servingUpper: Int64
    init(ranges: String = "107562780-107981435", reportedMinimum: Int64 = 107562780, servingUpper: Int64 = 107981435, subsequentRanges: [String] = []) {
        self.subsequentRanges = subsequentRanges
        self.servingUpper = servingUpper
        self.ranges = ranges; self.reportedMinimum = reportedMinimum
    }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        requests.append(request)
        let body = try JSONDecoder().decode(XrplJSON.self, from: request.httpBody!)
        if body["method"].string == "account_tx" { pageSteps.append(OathDiagnostics.trace?.step) }
        let params = body["params"].array![0]
        let result: XrplJSON
        if body["method"].string == "server_info" {
            defer { if !subsequentRanges.isEmpty { ranges = subsequentRanges.removeFirst() } }
            result = .object(["status":.string("success"), "info":.object([
                "complete_ledgers":.string(ranges), "network_id":.number("0")])])
        } else if body["method"].string == "account_tx", params["ledger_index_min"].integer == 107562780,
                  params["ledger_index_max"].text == "-1" || (params["ledger_index_max"].integer ?? UInt64.max) <= UInt64(servingUpper) {
            result = .object(["status":.string("success"), "validated":.bool(true),
                "account":params["account"], "ledger_index_min":.number(String(reportedMinimum)),
                "ledger_index_max":params["ledger_index_max"].text == "-1" ? .number(String(servingUpper)) : params["ledger_index_max"], "transactions":.array([])])
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
    func testRecentFirstPagePinsTheServingReplicasValidatedHead() async throws {
        let serving: Int64 = 107981433
        let transport = RecentXrplTransport(servingUpper: serving)
        let client = try XrplClient(apiKey: "fixture", transport: transport)
        let first = try await client.history(owner: owner)
        XCTAssertEqual(first.upperLedger, serving)
        let next = try await client.history(owner: owner, before: "{\"ledger\":107900000,\"seq\":2}", upperLedger: first.upperLedger)
        XCTAssertEqual(next.upperLedger, serving)
        let requests = try await transport.requests.map { try JSONDecoder().decode(XrplJSON.self, from: XCTUnwrap($0.httpBody)) }
        let pages = requests.filter { $0["method"].string == "account_tx" }.compactMap { $0["params"].array?.first }
        XCTAssertEqual(pages.map { $0["ledger_index_max"].text }, ["-1", String(serving)])
        XCTAssertEqual(pages.map { $0["ledger_index_min"].integer }, [107562780, 107562780])
        XCTAssertEqual(pages.last?["marker"]["seq"].integer, 2)
        let steps = await transport.pageSteps
        XCTAssertEqual(steps, ["history_latest_page", "history_next_page"])
    }

    func testUnpinnedHeadBeyondOriginalAnnouncementNeedsANewerConfirmedRange() async throws {
        let upper: Int64 = 107981437
        let confirmed = RecentXrplTransport(servingUpper: upper, subsequentRanges: ["107562780-107981437"])
        let page = try await XrplClient(apiKey: "fixture", transport: confirmed).history(owner: owner)
        XCTAssertEqual(page.upperLedger, upper)
        let unconfirmed = RecentXrplTransport(servingUpper: upper)
        do {
            _ = try await XrplClient(apiKey: "fixture", transport: unconfirmed).history(owner: owner)
            XCTFail("Unconfirmed future head was accepted")
        } catch { XCTAssertEqual(error as? XrplError, .wrongLedger) }
    }

    func testPinnedPageWaitsForAdvertisedHeadWithoutMovingItsCursorOrUpperLedger() async throws {
        let upper: Int64 = 107981437
        let feed = RecentXrplTransport(servingUpper: upper, subsequentRanges: ["107562780-107981437"])
        let marker = "{\"ledger\":107900000,\"seq\":2}"
        let page = try await XrplClient(apiKey: "fixture", transport: feed).history(owner: owner, before: marker, upperLedger: upper)
        XCTAssertEqual(page.upperLedger, upper)
        let sent = try await feed.requests.map { try JSONDecoder().decode(XrplJSON.self, from: XCTUnwrap($0.httpBody)) }
        XCTAssertEqual(sent.map { $0["method"].string }, ["server_info", "server_info", "account_tx"])
        let params = try XCTUnwrap(sent.last?["params"].array?.first)
        XCTAssertEqual(params["ledger_index_max"].integer, UInt64(upper))
        XCTAssertEqual(params["marker"], try JSONDecoder().decode(XrplJSON.self, from: Data(marker.utf8)))
    }

    func testCancellingWhileTheReplicaIsBehindDoesNotIssueAnotherRead() async throws {
        let feed = RecentXrplTransport(), client = try XrplClient(apiKey: "fixture", transport: feed)
        let task = Task { try await client.history(owner: owner, before: "\"opaque\"", upperLedger: 107981440) }
        for _ in 0..<100 {
            if await !feed.requests.isEmpty { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled page completed") }
        catch { XCTAssertTrue(error is CancellationError) }
        let requests = await feed.requests
        XCTAssertEqual(requests.count, 1)
        let body = try JSONDecoder().decode(XrplJSON.self, from: XCTUnwrap(requests.first?.httpBody))
        XCTAssertEqual(body["method"].string, "server_info")
    }

    func testBackfillBelowTheMovingFloorExpiresEvenWhenItsUpperPinIsStillAvailable() async throws {
        let feed = RecentXrplTransport(), client = try XrplClient(apiKey: "fixture", transport: feed)
        let marker = "\"opaque-marker\"", upper: Int64 = 107981430, lower: Int64 = 107562780
        do {
            _ = try await client.history(owner: owner, before: marker, upperLedger: upper, oldestFetchedLedger: lower - 1)
            XCTFail("A continuation already below the advertised floor should not be sent")
        } catch { XCTAssertEqual(error as? XrplError, .historyWindowExpired) }
        let expiredRequests = await feed.requests.count
        XCTAssertEqual(expiredRequests, 1)
        // Transactions may share the floor ledger. Equality cannot end pagination.
        let boundary = try await client.history(owner: owner, before: marker, upperLedger: upper, oldestFetchedLedger: lower)
        XCTAssertEqual(boundary.upperLedger, upper)
        let total = await feed.requests.count
        XCTAssertEqual(total - expiredRequests, 2)
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
    func testFailureOfAnkrHistoryCannotForwardAnAnkrMarkerToAnotherProvider() async throws {
        let feed = ProviderBoundMarkerTransport()
        let marker = "{\"ledger\":107900000,\"seq\":2}"
        // Reproduce the old full-archive route with the recorded pair of RPC rejections.
        let archive = try XrplClient(endpoint: URL(string: "https://rpc.ankr.com/xrp_mainnet/fixture")!,
                                     fallback: URL(string: "https://xrplcluster.com")!, transport: feed)
        _ = try? await archive.history(owner: owner, before: marker, upperLedger: 107981435)
        let old = await feed.pages
        XCTAssertTrue(old.contains { $0.host == "xrplcluster.com" && $0.params["marker"]["seq"].integer == 2 })
        let production = ProviderBoundMarkerTransport()
        do {
            _ = try await XrplClient(apiKey: "fixture", transport: production).history(owner: owner, before: marker, upperLedger: 107981435)
            XCTFail("Persistent failure must not complete history")
        } catch { XCTAssertEqual(error as? XrplError, .rpc("lgrIdxMalformed")) }
        let pages = await production.pages
        XCTAssertEqual(pages.count, 3)
        XCTAssertTrue(pages.allSatisfy { $0.host == "rpc.ankr.com" && $0.params["ledger_index_min"].integer == 107562780 &&
            $0.params["ledger_index_max"].integer == 107981435 && $0.params["marker"]["seq"].integer == 2 })
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

private actor ProviderBoundMarkerTransport: AnkrTransport {
    var pages: [(host: String, params: XrplJSON)] = []
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let body = try JSONDecoder().decode(XrplJSON.self, from: XCTUnwrap(request.httpBody))
        let result: XrplJSON
        if body["method"].string == "server_info" {
            result = .object(["status": .string("success"), "info": .object(["network_id": .number("0"),
                "complete_ledgers": .string("107562780-107981435")])])
        } else {
            XCTAssertEqual(body["method"].string, "account_tx")
            let host = try XCTUnwrap(request.url?.host), params = try XCTUnwrap(body["params"].array?.first)
            pages.append((host, params))
            result = .object(["status": .string("error"), "error": .string(host == "rpc.ankr.com" ? "lgrIdxMalformed" : "invalidParams"),
                              "error_code": .number(host == "rpc.ankr.com" ? "58" : "31")])
        }
        return (try JSONEncoder().encode(XrplJSON.object(["result": result])), 200)
    }
}
