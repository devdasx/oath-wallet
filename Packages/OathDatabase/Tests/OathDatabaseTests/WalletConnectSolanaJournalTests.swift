import XCTest
import GRDB
@testable import OathAnkr
@testable import OathDatabase

@MainActor final class WalletConnectSolanaJournalTests: XCTestCase {
    func testDurableNonceSurvivesReopenWithoutAgeExpiry() async throws {
        let (db, folder, plan) = try await SolanaSendJournalTests().fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let nonce = try SolanaSendCrypto.address(privateKey: Data(repeating: 2, count: 32))
        let keys = [plan.sender, nonce, SolanaSendCrypto.system, "SysvarRecentB1ockHashes11111111111111111111"]
        var message = Data([1, 0, 2, 4])
        for key in keys { message += try SolanaSendCrypto.decode(key) }
        message += Data(repeating: 4, count: 32)
        message += Data([1, 2, 3, 1, 3, 0, 4, 4, 0, 0, 0])
        let wire = Data([1]) + Data(repeating: 0, count: 64) + message
        let input = try WalletConnectSolanaRequest(method: "solana_signAndSendTransaction", chain: SolanaSendNetwork.devnet.walletConnectChain,
            account: plan.sender, params: JSONEncoder().encode(SolanaJSON.object(["transaction": .string(wire.base64EncodedString())])))
        let signed = try input.sign(privateKey: Data(repeating: 1, count: 32)).transactions[0]
        let stored = try await db.journalWalletConnectSolana(id: "wc:nonce", walletID: "w1", accountID: "a1", request: input, signed: signed)
        try await db.pool.write {
            try $0.execute(sql: "UPDATE walletConnectSolanaSubmissions SET createdAt=? WHERE id=?", arguments: [Date.now.addingTimeInterval(-30 * 86400).timeIntervalSince1970, stored.id])
        }
        let reopened = try await OathDatabase.open(at: folder.appendingPathComponent("db.sqlite"))
        let rows = try await reopened.pendingWalletConnectSolanaSubmissions()
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.signed, signed)
        XCTAssertEqual(row.state, "signed")
        let recovered = try WalletConnectSolanaRequest(method: input.method, chain: row.chain, account: row.owner,
            params: JSONEncoder().encode(SolanaJSON.object(["transaction": .string(row.unsigned.base64EncodedString())])))
        XCTAssertEqual(recovered.fingerprint, row.fingerprint)
        XCTAssertEqual(try recovered.transactions[0].durableNonce()?.address, nonce)
        try recovered.transactions[0].verifySigned(row.signed, requireAll: true)
        let replay = try await reopened.journalWalletConnectSolana(id: row.id, walletID: row.walletID, accountID: row.accountID, request: recovered, signed: row.signed)
        XCTAssertEqual(replay.signature, row.signature)
        try await reopened.settleWalletConnectSolana(row.id, outcome: .failed)
        let remaining = try await reopened.pendingWalletConnectSolanaSubmissions()
        XCTAssertTrue(remaining.isEmpty)
    }
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
        let historical = try WalletConnectSolanaRequest(method: input.method, chain: SolanaSendNetwork.devnet.walletConnectChains[1], account: plan.sender,
            params: JSONEncoder().encode(SolanaJSON.object(["transaction": .string(wire.base64EncodedString())])))
        let aliasReplay = try await reopened.journalWalletConnectSolana(id: record.id, walletID: "w1", accountID: "a1", request: historical, signed: signed.transactions[0])
        XCTAssertEqual(aliasReplay.signature, record.signature)
        XCTAssertEqual(aliasReplay.chain, SolanaSendNetwork.devnet.walletConnectChain)
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
