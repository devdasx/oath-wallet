import Foundation
import XCTest
import GRDB
import OathDiagnostics
@testable import OathAnkr
@testable import OathDatabase

private actor TronHistoryGate: AnkrTransport {
    let owner: String
    private(set) var historyRequestCount = 0
    var historyStarted: Bool { historyRequestCount > 0 }
    private var waiting: CheckedContinuation<Void, Never>?
    private var released = false
    init(owner: String) { self.owner = owner }
    func release() { released = true; waiting?.resume(); waiting = nil }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let url = try XCTUnwrap(request.url)
        if url.host == "api.coinbase.com" { return (Data(#"{"data":{"base":"TRX","currency":"USD","amount":"0.2"}}"#.utf8), 200) }
        if url.host == "tokens.coingecko.com" {
            return (try JSONSerialization.data(withJSONObject: ["tokens": [["chainId": NSNull(), "address": TronIdentity.usdt,
                "decimals": 6, "name": "Fixture", "symbol": "FIX"]]]), 200)
        }
        if url.host != "rpc.ankr.com" && url.host != "api.trongrid.io" { throw URLError(.notConnectedToInternet) }
        if url.path.contains("/transactions") || url.path.contains("/internal-transactions") {
            historyRequestCount += 1
            if !released { await withCheckedContinuation { waiting = $0 } }
            return (Data(#"{"success":true,"data":[]}"#.utf8), 200)
        }
        if url.path.contains("/v1/accounts/") { return (Data(#"{"success":true,"data":[]}"#.utf8), 200) }
        if url.path.hasSuffix("/getaccount") {
            return (try JSONSerialization.data(withJSONObject: ["address":owner,"balance":123]), 200)
        }
        if let data = request.httpBody, let calls = try JSONSerialization.jsonObject(with: data) as? [[String:Any]] {
            return (try JSONSerialization.data(withJSONObject: calls.map { ["jsonrpc":"2.0","id":$0["id"]!,"result":"0x2b6653dc"] }), 200)
        }
        throw URLError(.notConnectedToInternet)
    }
}

extension TronLedgerTests {
    func testGateReleasesAllOverlappingHistoryRequests() async throws {
        let feed = TronHistoryGate(owner: "fixture")
        let completed = expectation(description: "both outstanding history requests returned")
        completed.expectedFulfillmentCount = 2
        let url = try XCTUnwrap(URL(string: "https://api.trongrid.io/v1/accounts/fixture/transactions"))
        for _ in 0..<2 {
            Task {
                _ = try await feed.send(URLRequest(url: url))
                completed.fulfill()
            }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while await feed.historyRequestCount < 2 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let gathered = await feed.historyRequestCount
        XCTAssertEqual(gathered, 2)
        await feed.release()
        await fulfillment(of: [completed], timeout: 2)
    }

    func testCurrentRunCursorConflictRemainsAReportedFailure() async throws {
        let (db, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let sink = DatabaseDiagnosticProbe.shared
        await sink.configure()
        let operation = UUID(), feed = TronHistoryGate(owner: owner)
        let sync = TronSynchronizer(database: db, client: try TronClient(apiKey: "fixture", transport: feed),
                                    markets: TronMarkets(transport: feed))
        try await OathDiagnostics.$operationID.withValue(operation) { try await sync.refresh(accountID: "a1") }
        for _ in 0..<300 {
            if await feed.historyStarted { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let started = await feed.historyStarted
        XCTAssertTrue(started)
        // The ticket still belongs to this run, but its fetched cursor changed.
        // This is not proof of teardown and must remain visible as a conflict.
        try await db.pool.write { try $0.execute(sql: "UPDATE tronHistoryCursors SET end=end+1 WHERE accountID='a1'") }
        await feed.release()
        await sync.waitForHistory(accountID: "a1")
        let reported = try await sink.waitForEvent(operation: operation) {
            $0.error.domain == "OathDatabase.StoreError" && $0.error.message == "staleSync"
        }
        XCTAssertTrue(reported, "The current conflict must reach this refresh's diagnostic stream")
        let failure = try await db.pool.read { try String.fetchOne($0, sql: "SELECT historyFailure FROM tronSync WHERE accountID='a1'") }
        XCTAssertEqual(failure, "storage")
        await sync.cancel()
    }

    func testSupersededHistoryStopsWithoutFailureWritesOrDiagnostics() async throws {
        let (db, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let sink = DatabaseDiagnosticProbe.shared
        await sink.configure()
        let operation = UUID()
        let feed = TronHistoryGate(owner: owner)
        let sync = TronSynchronizer(database: db, client: try TronClient(apiKey: "fixture", transport: feed),
                                    markets: TronMarkets(transport: feed))
        try await OathDiagnostics.$operationID.withValue(operation) { try await sync.refresh(accountID: "a1") }
        for _ in 0..<300 {
            if await feed.historyStarted { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let started = await feed.historyStarted
        XCTAssertTrue(started)
        let newer = try await db.beginTronSync(accountID: "a1")
        try await db.commitTronInventory(inventory(time: Date().timeIntervalSince1970 + 1), ticket: newer, catalog: catalog)
        try await db.pool.write { db in
            try db.execute(sql: "CREATE TABLE tronFailureAudit (count INTEGER)")
            try db.execute(sql: "CREATE TRIGGER audit_tron_failure AFTER UPDATE OF failure,historyFailure ON tronSync BEGIN INSERT INTO tronFailureAudit VALUES (1); END")
        }
        await feed.release()
        await sync.waitForHistory(accountID: "a1")
        try await Task.sleep(for: .milliseconds(100))
        await OathDiagnostics.flush()
        let reports = await sink.events().filter { $0.operationID == operation }
        XCTAssertTrue(reports.isEmpty, "Superseded work must stop without being misreported as a storage failure: \(reports.map { $0.operation + ":" + $0.error.message })")
        try await db.pool.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM tronFailureAudit"), 0)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT runID FROM tronSync WHERE accountID='a1'"), newer.runID)
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT historyFailure FROM tronSync WHERE accountID='a1'"))
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM tronHistoryCursors WHERE accountID='a1' AND complete=1"), 0)
        }
        await sync.cancel()
    }
}
