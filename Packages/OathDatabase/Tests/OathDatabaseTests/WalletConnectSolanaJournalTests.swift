import XCTest
import GRDB
@testable import OathAnkr
@testable import OathDatabase

@MainActor final class WalletConnectSolanaJournalTests: XCTestCase {
    func testClusterScopedJournalRecoveryIdempotencyAndReset() async throws {
        let (db, folder, plan) = try await SolanaSendJournalTests().fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let wire = Data([1]) + Data(repeating: 0, count: 64) + (try SolanaSendCrypto.message(plan))
        func request(_ network: SolanaSendNetwork) throws -> WalletConnectSolanaRequest {
            try .init(method: "solana_signAndSendTransaction", chain: network.walletConnectChain, account: plan.sender,
                      params: JSONEncoder().encode(SolanaJSON.object(["transaction": .string(wire.base64EncodedString())])))
        }
        let input = try request(.devnet), signed = try input.sign(privateKey: Data(repeating: 1, count: 32))
        let record = try await db.journalWalletConnectSolana(id: "wc:test", walletID: "w1", accountID: "a1", request: input, signed: signed.transactions[0])
        let reopened = try await OathDatabase.open(at: folder.appendingPathComponent("db.sqlite"))
        let stored = try await reopened.walletConnectSolanaSubmission(record.id)
        XCTAssertEqual(stored?.signed, record.signed); XCTAssertEqual(stored?.chain, SolanaSendNetwork.devnet.walletConnectChain)
        let replay = try await reopened.journalWalletConnectSolana(id: record.id, walletID: "w1", accountID: "a1", request: input, signed: signed.transactions[0])
        XCTAssertEqual(replay.signature, record.signature)
        do { _ = try await db.journalWalletConnectSolana(id: record.id, walletID: "w1", accountID: "a1", request: request(.mainnet), signed: signed.transactions[0]); XCTFail() } catch { XCTAssertEqual(error as? SolanaSendError, .changed) }
        do { _ = try await db.journalWalletConnectSolana(id: "wrong", walletID: "w2", accountID: "a1", request: input, signed: signed.transactions[0]); XCTFail() } catch { XCTAssertEqual(error as? SolanaSendError, .wrongOwner) }
        let nativeHistory = try await db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM transactions") }
        XCTAssertEqual(nativeHistory, 0, "Testnet submissions must not contaminate mainnet history")
        try await db.settleWalletConnectSolana(record.id, outcome: .confirmed)
        try await db.settleWalletConnectSolana(record.id, outcome: .unknown)
        let settled = try await db.walletConnectSolanaSubmission(record.id)
        XCTAssertEqual(settled?.state, "confirmed")
        let pending = try await db.pendingWalletConnectSolanaSubmissions(); XCTAssertTrue(pending.isEmpty)
        let reset = try await db.beginWalletReset()
        do { _ = try await db.journalWalletConnectSolana(id: "reset", walletID: "w1", accountID: "a1", request: input, signed: signed.transactions[0]); XCTFail() } catch { }
        try await db.eraseWalletData(resetID: reset); try await db.finishWalletReset(resetID: reset)
        let erased = try await db.walletConnectSolanaSubmission(record.id); XCTAssertNil(erased)
    }
}
