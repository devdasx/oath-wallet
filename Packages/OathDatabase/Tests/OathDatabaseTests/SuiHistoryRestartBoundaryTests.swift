import Foundation
import XCTest
import GRDB
@testable import OathDatabase
@testable import OathAnkr

extension SuiLedgerTests {
    private func boundaryPage(_ checkpoint: Int64) throws -> SuiHistoryPage {
        let value: SuiJSON = .object([
            "digest": .string(String(repeating: "A", count: 43)),
            "sender": .object(["address": .string(owner)]),
            "gasInput": .object(["gasSponsor": .object(["address": .string(owner)])]),
            "effects": .object([
                "status": .string("SUCCESS"), "timestamp": .string("2026-10-12T01:00:00.000Z"),
                "checkpoint": .object(["sequenceNumber": .number(String(checkpoint))]),
                "gasEffects": .object(["gasSummary": .object([
                    "computationCost": .number("5"), "storageCost": .number("0"), "storageRebate": .number("0")])]),
                "balanceChangesJson": .array([.object([
                    "address": .string(owner), "coinType": .string(SuiIdentity.coin), "amount": .string("-105")])])])])
        let tx = try SuiDecoding.transaction(value, owner: owner, tokens: ["native": .native])
        return .init(transactions: [tx], next: "synthetic-expired-cursor", head: tx.hash, raw: try JSONEncoder().encode(value))
    }
    func testAuditRestartRejectsOverflowFromDecodedProviderCheckpoint() async throws {
        let (db, folder) = try await fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let ticket = try await db.beginSuiSync(accountID: "a1")
        let initialWork = try await db.suiHistoryWork(ticket); let first = try XCTUnwrap(initialWork.first)
        try await db.commitSuiPage(boundaryPage(Int64.max), cursor: first, ticket: ticket)
        let nextWork = try await db.suiHistoryWork(ticket); let cursor = try XCTUnwrap(nextWork.first)
        XCTAssertEqual(cursor.oldestCheckpoint, Int64.max)
        do { try await db.restartSuiHistory(cursor, ticket: ticket); XCTFail("Overflow checkpoint must be rejected") }
        catch { XCTAssertEqual(error as? SuiError, .malformed) }
        let saved = try await db.suiHistoryWork(ticket)
        XCTAssertEqual(saved.first, cursor)
        let reopened = try await OathDatabase.open(at: folder.appendingPathComponent("wallet.sqlite"))
        let persisted = try await reopened.suiHistoryWork(ticket)
        XCTAssertEqual(persisted.first, cursor)
    }
    func testAuditRestartAllowsLargestRepresentableSuccessor() async throws {
        let (db, folder) = try await fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let ticket = try await db.beginSuiSync(accountID: "a1")
        let initialWork = try await db.suiHistoryWork(ticket); let first = try XCTUnwrap(initialWork.first)
        try await db.commitSuiPage(boundaryPage(Int64.max - 1), cursor: first, ticket: ticket)
        let nextWork = try await db.suiHistoryWork(ticket); let cursor = try XCTUnwrap(nextWork.first)
        try await db.restartSuiHistory(cursor, ticket: ticket)
        let saved = try await db.suiHistoryWork(ticket)
        XCTAssertEqual(saved.first?.upperCheckpoint, Int64.max)
        XCTAssertNil(saved.first?.beforeCursor)
    }
    func testAuditRestartRejectsAnotherAccountsCursor() async throws {
        let (db, folder) = try await fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let a = try await db.beginSuiSync(accountID: "a1")
        let b = try await db.beginSuiSync(accountID: "a2")
        let initialWork = try await db.suiHistoryWork(b); let first = try XCTUnwrap(initialWork.first)
        try await db.commitSuiPage(boundaryPage(100), cursor: first, ticket: b)
        let nextWork = try await db.suiHistoryWork(b); let cursor = try XCTUnwrap(nextWork.first)
        do { try await db.restartSuiHistory(cursor, ticket: a); XCTFail("Ticket cannot mutate another account") }
        catch { XCTAssertEqual(error as? StoreError, .staleSync) }
        let saved = try await db.suiHistoryWork(b)
        XCTAssertEqual(saved.first, cursor)
    }
}

extension XrplLedgerTests {
    func testAuditRestartRejectsAnotherAccountsCursor() async throws {
        let (db, folder) = try await fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let a = try await db.beginXrplSync(accountID: "a1")
        let b = try await db.beginXrplSync(accountID: "a2")
        let initial = try await db.xrplHistoryWork(b); let first = try XCTUnwrap(initial.first)
        try await db.commitXrplPage(page(["synthetic-receipt"], next: "expired"), cursor: first, ticket: b)
        let next = try await db.xrplHistoryWork(b); let cursor = try XCTUnwrap(next.first)
        do { try await db.restartXrplHistory(cursor, ticket: a); XCTFail("Ticket cannot mutate another account") }
        catch { XCTAssertEqual(error as? StoreError, .staleSync) }
        let saved = try await db.xrplHistoryWork(b)
        XCTAssertEqual(saved.first, cursor)
    }
}
