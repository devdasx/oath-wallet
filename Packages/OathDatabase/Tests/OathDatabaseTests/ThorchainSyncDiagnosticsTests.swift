import Foundation
import XCTest
import GRDB
@testable import OathAnkr
import OathDiagnostics
@testable import OathDatabase

extension ThorchainTests {
    func testHeightRecoveryReportsOnlyStaticStageAndBoundedAttempt() async throws {
        struct LaggedHeight: AnkrTransport {
            func send(_ request: URLRequest) async throws -> (Data, Int) {
                if request.url?.lastPathComponent != "latest" { return (Data("{}".utf8), 404) }
                return (Data(#"{"block":{"header":{"chain_id":"thorchain-1","height":"1"}}}"#.utf8), 200)
            }
        }
        let sink = DatabaseDiagnosticProbe.shared
        await sink.configure()
        let operationID = UUID()
        do {
            _ = try await OathDiagnostics.$operationID.withValue(operationID) {
                try await ThorchainClient(transport: LaggedHeight()).latestHeight(atLeast: 200)
            }
            XCTFail("Persistent lag accepted")
        } catch { XCTAssertEqual(error as? ThorchainError, .staleHeight) }
        var reports: [DiagnosticEvent] = []
        for _ in 0..<100 {
            reports = await sink.events().filter { $0.operationID == operationID && $0.operation == "height_retry" }
            if reports.count == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(Set(reports.compactMap { $0.context["attempt"] }), ["3"])
        for report in reports {
            XCTAssertEqual(report.component, "ThorchainClient")
            XCTAssertEqual(report.operation, "height_retry")
            XCTAssertEqual(report.error.message, "staleHeight")
            XCTAssertEqual(report.context, ["chain": "thorchain", "stage": "lower_height", "attempt": "3", "step": "lower_height", "action": "height_retry", "screen": "unknown", "screen_source": "unknown", "origin_screen": "unknown", "app_state": "unknown", "time_source": "capture_time", "step_source": "explicit_stage", "cause_status": "original_error_only"])
            XCTAssertEqual(report.context["chain"], "thorchain")
            XCTAssertEqual(report.context["stage"], "lower_height")
        }
    }

    func testSuccessfulWritesAndAlreadyCancelledTeardownProduceNoGuardReports() async throws {
        let (database, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let transport = DatabaseDiagnosticProbe.shared
        await transport.configure()
        let ticket = try await database.beginThorchainSync(accountID: "a1")
        let operationID = UUID(), cancelledID = UUID()
        try await OathDiagnostics.$operationID.withValue(operationID) {
            try await database.commitThorchainInventory(.init(owner: owner, holdings: [.init(reference: "native", amount: "123")]),
                ticket: ticket, catalog: .init())
            try await database.commitThorchainCatalog(.init(), ticket: ticket)
            let cursor = try await database.thorchainCursor(ticket: ticket, stream: "transfer.recipient", lane: "recent", height: 200)
            try await database.commitThorchainHistory(.init(owner: owner, events: [], next: nil, rawCount: 0),
                cursor: cursor, ticket: ticket, catalog: .init())
        }
        _ = try await database.beginThorchainSync(accountID: "a1")
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                try await OathDiagnostics.$operationID.withValue(cancelledID) {
                    try await database.commitThorchainCatalog(.init(), ticket: ticket)
                }
                XCTFail("Cancelled superseded write accepted")
            } catch {
                XCTAssertTrue(error is CancellationError || (error as? StoreError) == .staleSync)
            }
        }
        await cancelled.value
        try await Task.sleep(for: .milliseconds(100))
        let reports = await transport.events().filter { $0.operationID == operationID || $0.operationID == cancelledID }
        XCTAssertTrue(reports.isEmpty)
    }

    func testEverySyncGuardReportsItsSafeStageWithoutChangingTheRejectedWrite() async throws {
        let transport = DatabaseDiagnosticProbe.shared
        await transport.configure()
        for stage in ["account_changed", "wallet_unavailable", "generation_changed", "older_observation",
                      "lower_height", "history_cursor_changed", "history_complete"] {
            let (database, folder) = try await fixture()
            defer { try? FileManager.default.removeItem(at: folder) }
            let ticket = try await database.beginThorchainSync(accountID: "a1")
            let saved = ThorchainInventory(owner: owner, holdings: [.init(reference: "native", amount: "123")],
                observedAt: Date(timeIntervalSince1970: 200), height: 200)
            try await database.commitThorchainInventory(saved, ticket: ticket, catalog: .init())
            let original = try await database.pool.read { try Data.fetchOne($0, sql: "SELECT inventory FROM thorchainSync WHERE accountID='a1'") }
            let incoming = ThorchainInventory(owner: owner, holdings: [.init(reference: "native", amount: "999")],
                observedAt: Date(timeIntervalSince1970: stage == "older_observation" ? 100 : 300),
                height: stage == "lower_height" ? 100 : 300)
            var cursor: ThorchainCursor?
            switch stage {
            case "account_changed":
                try await database.pool.write { try $0.execute(sql: "UPDATE accounts SET syncGeneration=syncGeneration+1 WHERE id='a1'") }
            case "wallet_unavailable":
                try await database.pool.write { try $0.execute(sql: "UPDATE wallets SET deletedAt=1 WHERE id='w1'") }
            case "generation_changed":
                _ = try await database.beginThorchainSync(accountID: "a1")
            case "history_cursor_changed", "history_complete":
                let first = try await database.thorchainCursor(ticket: ticket, stream: "transfer.recipient", lane: "recent", height: 200)
                try await database.commitThorchainHistory(.init(owner: owner, events: [], next: nil, rawCount: 0),
                    cursor: first, ticket: ticket, catalog: .init())
                cursor = stage == "history_complete"
                    ? try await database.thorchainCursor(ticket: ticket, stream: "transfer.recipient", lane: "recent", height: 200)
                    : first
            default: break
            }
            // Each rejection gets one correlation ID, carried over the SQLite
            // queue without putting an account/wallet identifier in telemetry.
            let operationID = UUID()
            do {
                try await OathDiagnostics.$operationID.withValue(operationID) {
                    if let cursor {
                        try await database.commitThorchainHistory(.init(owner: owner, events: [], next: nil, rawCount: 0),
                            cursor: cursor, ticket: ticket, catalog: .init())
                    } else if stage == "generation_changed" {
                        try await database.commitThorchainCatalog(.init(), ticket: ticket)
                    } else if stage == "wallet_unavailable" {
                        _ = try await database.thorchainCursor(ticket: ticket, stream: "transfer.sender", lane: "recent", height: 300)
                    } else {
                        try await database.commitThorchainInventory(incoming, ticket: ticket, catalog: .init())
                    }
                }
                XCTFail("Stale write accepted at \(stage)")
            } catch { XCTAssertEqual(error as? StoreError, .staleSync, stage) }
            var reports: [DiagnosticEvent] = []
            for _ in 0..<100 {
                reports = await transport.events().filter { $0.operationID == operationID }
                if !reports.isEmpty { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(reports.count, 1, stage)
            if let report = reports.first {
                XCTAssertEqual(report.component, "database")
                XCTAssertEqual(report.operation, "thorchain_sync_guard")
                XCTAssertEqual(report.error.message, "staleSync")
                XCTAssertEqual(report.context, ["chain": "thorchain", "stage": stage, "step": stage, "action": "thorchain_sync_guard", "screen": "unknown", "screen_source": "unknown", "origin_screen": "unknown", "app_state": "unknown", "time_source": "capture_time", "step_source": "explicit_stage", "cause_status": "original_error_only"])
                let encoded = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
                for sensitive in [owner, other, ticket.runID, ticket.account.derivationPath, "SELECT", "UPDATE", "WHERE"] {
                    XCTAssertFalse(encoded.contains(sensitive), stage)
                }
            }
            let after = try await database.pool.read { try Data.fetchOne($0, sql: "SELECT inventory FROM thorchainSync WHERE accountID='a1'") }
            XCTAssertEqual(after, original, stage)
            let balance = try await database.pool.read { try String.fetchOne($0, sql: "SELECT amountAtomic FROM balances WHERE accountID='a1' AND assetID='thorchain:native'") }
            XCTAssertEqual(balance, "123", stage)
        }
    }

    func testDatabaseWriteFailureIsNotRelabeledAsAStaleSnapshot() async throws {
        let (database, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let transport = DatabaseDiagnosticProbe.shared
        await transport.configure()
        let ticket = try await database.beginThorchainSync(accountID: "a1")
        try await database.pool.write { db in
            try db.execute(sql: "CREATE TRIGGER reject_inventory BEFORE INSERT ON balances BEGIN SELECT RAISE(ABORT,'fixture failure'); END")
        }
        let operationID = UUID()
        do {
            try await OathDiagnostics.$operationID.withValue(operationID) {
                try await database.commitThorchainInventory(.init(owner: owner, holdings: [.init(reference: "native", amount: "1")]),
                    ticket: ticket, catalog: .init())
            }
            XCTFail("Injected database failure swallowed")
        } catch { XCTAssertTrue(error is DatabaseError); XCTAssertNil(error as? StoreError) }
        let inventory = try await database.pool.read { try Data.fetchOne($0, sql: "SELECT inventory FROM thorchainSync WHERE accountID='a1'") }
        XCTAssertNil(inventory)
        try await Task.sleep(for: .milliseconds(100))
        let reports = await transport.events().filter { $0.operationID == operationID }
        XCTAssertTrue(reports.isEmpty, "Unexpected SQLite failures propagate to the existing caller boundary unchanged")
    }
}
