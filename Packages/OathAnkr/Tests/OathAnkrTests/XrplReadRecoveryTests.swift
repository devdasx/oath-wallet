import Foundation
import XCTest
import OathDiagnostics
@testable import OathAnkr

private actor XrplRecoveryTransport: AnkrTransport {
    struct Reply: Sendable {
        let body: String
        var status = 200
    }
    private var replies: [Reply]
    private(set) var requests: [URLRequest] = []
    init(_ replies: [Reply]) { self.replies = replies }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        requests.append(request)
        guard !replies.isEmpty else { throw XrplError.transport }
        let reply = replies.removeFirst()
        return (Data(reply.body.utf8), reply.status)
    }
}

private actor XrplLaggedLiveHistoryTransport: AnkrTransport {
    private let live = AnkrHTTPTransport()
    private(set) var historyBodies: [Data] = []
    private(set) var historyHosts: [String] = []

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let body = try JSONDecoder().decode(XrplJSON.self, from: request.httpBody ?? Data())
        if body["method"].string == "account_tx" {
            historyBodies.append(request.httpBody ?? Data())
            historyHosts.append(request.url?.host ?? "")
            if historyBodies.count <= 2 {
                return (Data(#"{"result":{"status":"error","error":"lgrIdxMalformed","error_code":58,"error_message":"Ledger index malformed."}}"#.utf8), 200)
            }
        }
        return try await live.send(request)
    }
}

final class XrplReadRecoveryTests: XCTestCase, @unchecked Sendable {
    private let owner = "r9cZA1mLK5R5Am25ArfXFmqgNwjZgnfk59"
    private let ledgerHash = String(repeating: "A", count: 64)
    private var ledger: XrplLedger { .init(hash: ledgerHash, height: 123, timestamp: 1700000000) }
    private func failure(_ code: String) -> XrplRecoveryTransport.Reply {
        .init(body: "{\"result\":{\"status\":\"error\",\"error\":\"\(code)\"}}")
    }
    private func account(hash: String? = nil, owner: String? = nil) -> XrplRecoveryTransport.Reply {
        .init(body: "{\"result\":{\"status\":\"success\",\"validated\":true,\"ledger_hash\":\"\(hash ?? self.ledgerHash)\",\"account_data\":{\"Account\":\"\(owner ?? self.owner)\",\"Balance\":\"1234567\"}}}")
    }
    private func page() -> XrplRecoveryTransport.Reply {
        .init(body: "{\"result\":{\"status\":\"success\",\"validated\":true,\"ledger_hash\":\"\(ledgerHash)\",\"account\":\"\(owner)\",\"lines\":[],\"account_objects\":[]}}")
    }
    private func client(_ transport: XrplRecoveryTransport, fallback: Bool = true) throws -> XrplClient {
        try .init(endpoint: URL(string: "https://primary.test")!,
                  fallback: fallback ? URL(string: "https://fallback.test")! : nil, transport: transport)
    }
    private func body(_ request: URLRequest) throws -> XrplJSON {
        try JSONDecoder().decode(XrplJSON.self, from: XCTUnwrap(request.httpBody))
    }
    private func canonicalBody(_ request: URLRequest) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(body(request))
    }

    func testMissingLedgerThenForwardingFailureRecoversExactInventory() async throws {
        let transport = XrplRecoveryTransport([failure("ledgerNotFound"), failure("failedToForward"),
            account(), page(), page()])
        let value = try await client(transport).inventory(owner: owner, at: ledger)
        XCTAssertEqual(value.holdings.first?.amount, "1234567")
        XCTAssertEqual(value.ledger, ledger)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 5)
        XCTAssertEqual(requests.prefix(3).map { $0.url?.host }, ["primary.test", "fallback.test", "primary.test"])
        XCTAssertEqual(Set(try requests.prefix(3).map(canonicalBody)).count, 1)
        for request in requests {
            let p = try body(request)["params"].array![0]
            XCTAssertEqual(p["ledger_hash"].string, ledgerHash)
            XCTAssertEqual(p["account"].string, owner)
        }
    }

    func testHistoryRecoveryKeepsRangeAndOpaqueCursor() async throws {
        let ok = XrplRecoveryTransport.Reply(body: "{\"result\":{\"status\":\"success\",\"validated\":true,\"account\":\"\(owner)\",\"ledger_index_min\":32570,\"ledger_index_max\":200000000,\"transactions\":[]}}")
        let transport = XrplRecoveryTransport([failure("lgrIdxMalformed"), failure("failedToForward"), ok])
        let value = try await client(transport).history(owner: owner, before: "{\"ledger\":123,\"seq\":4}", upperLedger: 200000000)
        XCTAssertEqual(value.upperLedger, 200000000)
        XCTAssertNil(value.next)
        let requests = await transport.requests
        XCTAssertEqual(requests.map { $0.url?.host }, ["primary.test", "fallback.test", "primary.test"])
        XCTAssertEqual(Set(try requests.map(canonicalBody)).count, 1)
        let p = try body(XCTUnwrap(requests.last))["params"].array![0]
        XCTAssertEqual(p["ledger_index_min"].text, "32570")
        XCTAssertEqual(p["ledger_index_max"].text, "200000000")
        XCTAssertEqual(p["marker"]["seq"].integer, 4)
    }

    func testBothHistoryProvidersCanCatchUpWithoutChangingRangeOrCursor() async throws {
        let ok = XrplRecoveryTransport.Reply(body: "{\"result\":{\"status\":\"success\",\"validated\":true,\"account\":\"\(owner)\",\"ledger_index_min\":32570,\"ledger_index_max\":200000000,\"transactions\":[]}}")
        let transport = XrplRecoveryTransport([failure("lgrIdxMalformed"), failure("lgrIdxMalformed"), ok])
        let value = try await client(transport).history(owner: owner, before: "{\"ledger\":123,\"seq\":4}", upperLedger: 200000000)
        XCTAssertEqual(value.upperLedger, 200000000)
        let requests = await transport.requests
        XCTAssertEqual(requests.map { $0.url?.host }, ["primary.test", "fallback.test", "primary.test"])
        XCTAssertEqual(Set(try requests.map(canonicalBody)).count, 1)
        let params = try body(XCTUnwrap(requests.last))["params"].array![0]
        XCTAssertEqual(params["ledger_index_min"].text, "32570")
        XCTAssertEqual(params["ledger_index_max"].text, "200000000")
        XCTAssertEqual(params["marker"]["seq"].integer, 4)
    }

    func testUnavailableHistoryRangeExhaustsBoundedRetriesWithoutInventingHistory() async throws {
        for fallback in [false, true] {
            let transport = XrplRecoveryTransport(Array(repeating: failure("lgrIdxMalformed"), count: 8))
            do {
                _ = try await client(transport, fallback: fallback).history(owner: owner, upperLedger: 200000000)
                XCTFail("Unavailable history became a successful page")
            } catch { XCTAssertEqual(error as? XrplError, .rpc("lgrIdxMalformed")) }
            let count = await transport.requests.count
            XCTAssertEqual(count, fallback ? 6 : 3)
        }
    }

    func testLedgerRangeErrorDoesNotRetryUnrelatedMethodsOrInvalidHistoryBounds() async throws {
        let transport = XrplRecoveryTransport(Array(repeating: failure("lgrIdxMalformed"), count: 8))
        do {
            _ = try await client(transport).inventory(owner: owner, at: ledger)
            XCTFail("Accepted failed inventory")
        } catch { XCTAssertEqual(error as? XrplError, .rpc("lgrIdxMalformed")) }
        let count = await transport.requests.count
        XCTAssertEqual(count, 2)
        for upper: Int64 in [-1, 0, 32569] {
            let invalid = XrplRecoveryTransport(Array(repeating: failure("lgrIdxMalformed"), count: 8))
            do {
                _ = try await client(invalid).history(owner: owner, upperLedger: upper)
                XCTFail("Accepted invalid history bounds")
            } catch { XCTAssertEqual(error as? XrplError, .rpc("lgrIdxMalformed")) }
            let count = await invalid.requests.count
            XCTAssertEqual(count, 2)
        }
    }

    func testPersistentTransientFailureIsBoundedAndNeverEmptySuccess() async throws {
        for fallback in [false, true] {
            let transport = XrplRecoveryTransport(Array(repeating: failure("failedToForward"), count: 6))
            do { _ = try await client(transport, fallback: fallback).inventory(owner: owner, at: ledger); XCTFail("Failed read became a balance") }
            catch { XCTAssertEqual(error as? XrplError, .rpc("failedToForward")) }
            let count = await transport.requests.count
            XCTAssertEqual(count, fallback ? 6 : 3)
        }
    }

    func testPermanentErrorsAndRateLimitsDoNotRetrySameProvider() async throws {
        for reply in [failure("invalidParams"), failure("untrusted-private-error"), .init(body: "{}", status: 429)] {
            let transport = XrplRecoveryTransport([reply, reply])
            do { _ = try await client(transport).inventory(owner: owner, at: ledger); XCTFail("Accepted failure") }
            catch { XCTAssertTrue(error is XrplError) }
            let count = await transport.requests.count
            XCTAssertEqual(count, 2)
        }
    }

    func testRecoveryStillRejectsWrongLedgerAndWrongAccount() async throws {
        for (reply, expected) in [(account(hash: String(repeating: "B", count: 64)), XrplError.wrongLedger),
                                  (account(owner: "rMxCKbEDwqr76QuheSUMdEGf4B9xJ8m5De"), .wrongOwner)] {
            let transport = XrplRecoveryTransport([failure("lgrNotFound"), reply])
            do { _ = try await client(transport, fallback: false).inventory(owner: owner, at: ledger); XCTFail("Accepted changed snapshot") }
            catch { XCTAssertEqual(error as? XrplError, expected) }
            let count = await transport.requests.count
            XCTAssertEqual(count, 2)
        }
    }

    func testCancellationDuringBackoffStopsFurtherReads() async throws {
        let transport = XrplRecoveryTransport(Array(repeating: failure("failedToForward"), count: 3))
        let client = try client(transport, fallback: false), owner = owner, ledger = ledger
        let task = Task { try await client.inventory(owner: owner, at: ledger) }
        for _ in 0..<100 {
            if await transport.requests.count > 0 { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled read completed") }
        catch { XCTAssertTrue(error is CancellationError) }
        let count = await transport.requests.count
        XCTAssertEqual(count, 1)
    }

    func testCancellationDuringHistoryRangeBackoffStopsFurtherReads() async throws {
        let transport = XrplRecoveryTransport(Array(repeating: failure("lgrIdxMalformed"), count: 8))
        let client = try client(transport), owner = owner
        let task = Task { try await client.history(owner: owner, upperLedger: 200000000) }
        for _ in 0..<100 {
            if await transport.requests.count >= 2 { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled history read completed") }
        catch { XCTAssertTrue(error is CancellationError) }
        let count = await transport.requests.count
        XCTAssertEqual(count, 2)
    }

    func testProviderEchoIsRemovedAndSafeFailureCodeSurvivesDiagnosticFiltering() async throws {
        let transport = XrplRecoveryTransport([failure("private-provider-echo")])
        do { _ = try await client(transport, fallback: false).inventory(owner: owner, at: ledger); XCTFail() }
        catch {
            XCTAssertEqual(error as? XrplError, .rpc("serverError"))
            let event = DiagnosticEvent(error: error, component: "provider", operation: "xrpl_read",
                context: ["chain":"xrpl", "method":"account_info", "host":"xrplcluster.com",
                          "rpc_code":"failedToForward", "attempt":"3", "account":owner, "ledger_hash":ledgerHash], sessionID: UUID())
            XCTAssertEqual(event.context["rpc_code"], "failedToForward")
            XCTAssertEqual(event.context["attempt"], "3")
            let data = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
            for secret in ["private-provider-echo", owner, ledgerHash] { XCTAssertFalse(data.contains(secret)) }
        }
    }

    func testLiveHistoryPagesRecoverAfterBothProvidersReportUnavailableRange() async throws {
        guard let key = ProcessInfo.processInfo.environment["OATH_XRPL_LIVE_KEY"] else {
            throw XCTSkip("Opt-in public XRP history comparison with injected provider lag")
        }
        let peer = try XrplClient(endpoint: URL(string: "https://xrplcluster.com")!)
        let ledger = try await peer.validatedLedger()
        var cursor: String?
        var previousHashes: Set<String> = []
        for pageNumber in 1...2 {
            let expected = try await peer.history(owner: owner, before: cursor, upperLedger: ledger.height, limit: 20)
            let transport = XrplLaggedLiveHistoryTransport()
            // Explicit archive-mode client: this test exercises pinned full-range
            // recovery. Production ANKR recent-window behavior has separate tests.
            let recovered = try await XrplClient(endpoint: URL(string:"https://rpc.ankr.com/xrp_mainnet")!.appendingPathComponent(key), fallback:URL(string:"https://xrplcluster.com")!, transport: transport)
                .history(owner: owner, before: cursor, upperLedger: ledger.height, limit: 20)
            XCTAssertEqual(recovered.upperLedger, expected.upperLedger)
            XCTAssertEqual(recovered.transactions.map(\.hash), expected.transactions.map(\.hash))
            XCTAssertFalse(recovered.transactions.isEmpty)
            XCTAssertEqual(recovered.next, expected.next)
            XCTAssertTrue(previousHashes.isDisjoint(with: recovered.transactions.map(\.hash)))
            let hosts = await transport.historyHosts
            XCTAssertEqual(Array(hosts.prefix(2)), ["rpc.ankr.com", "xrplcluster.com"])
            XCTAssertTrue((3...6).contains(hosts.count))
            let bodies = await transport.historyBodies
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let canonical = try bodies.map { try encoder.encode(JSONDecoder().decode(XrplJSON.self, from: $0)) }
            XCTAssertEqual(Set(canonical).count, 1, "Recovery changed the pinned history request")
            print("XRPL live recovered page \(pageNumber): \(recovered.transactions.count) transactions match the independent provider")
            previousHashes.formUnion(recovered.transactions.map(\.hash))
            cursor = try XCTUnwrap(expected.next)
        }
    }
}
