import Foundation
import XCTest
import GRDB
import OathDiagnostics
@testable import OathAnkr
@testable import OathDatabase

private actor ArcHistoryGate: AnkrTransport {
    private(set) var started = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var released = false
    func release() {
        released = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        if request.url?.host == "api.coinbase.com" {
            return (Data(#"{"data":{"base":"USDC","currency":"USD","amount":"1"}}"#.utf8), 200)
        }
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody))
        if let query = body as? [String: Any] {
            started += 1
            if !released { await withCheckedContinuation { waiters.append($0) } }
            return (try JSONSerialization.data(withJSONObject: ["next_block": query["to_block"]!,
                "data": [["blocks": [], "transactions": [], "logs": []]]]), 200)
        }
        let calls = try XCTUnwrap(body as? [[String: Any]])
        let rows: [[String: Any]] = try calls.map { call in
            let value: Any
            switch call["method"] as? String {
            case "eth_chainId": value = "0x13b2"
            case "eth_getBlockByNumber": value = ["number": "0x493e1", "hash": "0x" + String(repeating: "a", count: 64)]
            case "eth_getBalance": value = "0xde0b6b3a7640000"
            case "eth_call": value = "0x" + String(repeating: "0", count: 58) + "0f4240"
            default: throw AnkrError.invalidResponse
            }
            return ["jsonrpc": "2.0", "id": call["id"]!, "result": value]
        }
        return (try JSONSerialization.data(withJSONObject: rows), 200)
    }
}

@MainActor final class ArcHistoryTeardownTests: XCTestCase {
    private func fixture() async throws -> (OathDatabase, ArcHistoryGate, ArcSynchronizer) {
        let db = try await OathDatabase.open(at: FileManager.default.temporaryDirectory
            .appendingPathComponent("ArcHistoryTeardown-" + UUID().uuidString).appendingPathComponent("db.sqlite"))
        try await db.seed(networks: [.init(id: "arc", name: "Arc", family: "evm", symbol: "USDC", decimals: 18, derivationPath: "fixture", logo: "", sortOrder: 0)],
            assets: [.init(id: "arc:native", networkID: "arc", reference: "native", name: "USDC", symbol: "USDC", decimals: 18)])
        try await db.importWalletIfNeeded(.init(id: "w", name: "Fixture", kind: "watchOnly", vaultReference: "fixture", createdAt: 1),
            accounts: [.init(id: "a", walletID: "w", networkID: "arc", address: "0x" + String(repeating: "1", count: 40), derivationPath: "")])
        try await db.saveMarketCache(.init(key: "arc.catalog", source: "fixture", payload: JSONEncoder().encode(ArcCatalog.empty), fetchedAt: Date().timeIntervalSince1970))
        let feed = ArcHistoryGate()
        return (db, feed, ArcSynchronizer(database: db, client: try ArcClient(indexKey: "fixture", transport: feed), markets: ArcMarkets(transport: feed)))
    }
    private func waitForHistory(_ feed: ArcHistoryGate) async throws {
        for _ in 0..<300 {
            if await feed.started == 2 { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Both bounded history lanes must reach the gate")
    }
    func testSupersededRunDoesNotReportOrWriteFailuresOrAdvanceCursors() async throws {
        let (db, feed, sync) = try await fixture()
        let sink = DatabaseDiagnosticProbe.shared; await sink.configure()
        let operation = UUID()
        try await OathDiagnostics.$operationID.withValue(operation) { try await sync.refresh(accountID: "a") }
        try await waitForHistory(feed)
        let newer = try await db.beginArcSync(accountID: "a")
        await feed.release(); await sync.waitForHistory(accountID: "a")
        try await Task.sleep(for: .milliseconds(100)); await OathDiagnostics.flush()
        let reports = await sink.events().filter { $0.operationID == operation }
        XCTAssertTrue(reports.isEmpty, "Superseded work is teardown, not a storage failure")
        try await db.pool.read { sql in
            XCTAssertEqual(try String.fetchOne(sql, sql: "SELECT runID FROM arcSync WHERE accountID='a'"), newer.runID)
            XCTAssertEqual(try Int.fetchOne(sql, sql: "SELECT count(*) FROM arcHistoryCursors WHERE failure IS NOT NULL OR complete=1"), 0)
        }
        await sync.cancel()
    }
    func testCurrentRunCursorConflictRemainsAReportedFailure() async throws {
        let (db, feed, sync) = try await fixture()
        let sink = DatabaseDiagnosticProbe.shared; await sink.configure()
        let operation = UUID()
        try await OathDiagnostics.$operationID.withValue(operation) { try await sync.refresh(accountID: "a") }
        try await waitForHistory(feed)
        try await db.pool.write { try $0.execute(sql: "UPDATE arcHistoryCursors SET nextBlock=nextBlock+1") }
        await feed.release(); await sync.waitForHistory(accountID: "a")
        try await Task.sleep(for: .milliseconds(100)); await OathDiagnostics.flush()
        let reports = await sink.events().filter { $0.operationID == operation }
        XCTAssertTrue(reports.contains { $0.error.domain == "OathDatabase.StoreError" && $0.error.message == "staleSync" })
        let failures = try await db.pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM arcHistoryCursors WHERE failure='storage' AND complete=0") }
        XCTAssertEqual(failures, 2)
        await sync.cancel()
    }
    func testRefreshDrainsOldHistoryBeforeIssuingNewTicket() async throws {
        let (db, feed, sync) = try await fixture()
        try await sync.refresh(accountID: "a"); try await waitForHistory(feed)
        let old = try await db.pool.read { try String.fetchOne($0, sql: "SELECT runID FROM arcSync WHERE accountID='a'") }
        let refresh = Task { try await sync.refresh(accountID: "a") }
        try await Task.sleep(for: .milliseconds(100))
        let during = try await db.pool.read { try String.fetchOne($0, sql: "SELECT runID FROM arcSync WHERE accountID='a'") }
        await feed.release(); try await refresh.value; await sync.waitForHistory(accountID: "a")
        XCTAssertEqual(during, old, "Do not revoke a ticket while its old history tasks are still draining")
        let current = try await db.pool.read { try String.fetchOne($0, sql: "SELECT runID FROM arcSync WHERE accountID='a'") }
        XCTAssertNotEqual(current, old)
        let complete = try await db.pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM arcHistoryCursors WHERE failure IS NULL AND complete=1") }
        XCTAssertEqual(complete, 2, "New history must still finish both retained intervals")
        await sync.cancel()
    }
}
