import XCTest
import GRDB
import OathAnkr
@testable import OathDatabase

@MainActor final class WalletConnectTonJournalTests: XCTestCase {
    func fixture() async throws -> (OathDatabase, URL, WalletConnectTonPlan, TonSignedSend, TonSendPlan) {
        let (db, folder, ordinary) = try await TonSendJournalTests().fixture()
        let input: TonJSON = .object(["valid_until": .number(String(ordinary.expiration)), "messages": .array([
            .object(["address": .string(ordinary.recipient), "amount": .string("123456")])])])
        let request = try WalletConnectTonRequest(method: "ton_sendMessage", chain: "ton:-239", account: ordinary.sender,
            domain: "test.oathwallet.org", params: JSONEncoder().encode(input))
        let plan = WalletConnectTonPlan(request: request, publicKey: ordinary.publicKey, sequence: 7,
            expiration: ordinary.expiration, deploy: false, fee: 1_000_000, feeReserve: 2_000_000)
        return (db, folder, plan, try WalletConnectTonCrypto.sign(plan, privateKey: Data(repeating: 1, count: 32)), ordinary)
    }
    func testRestartIdempotencyOwnerReservationAndMonotonicStatus() async throws {
        let (db, folder, plan, signed, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = try await db.journalWalletConnectTon(id: "one", walletID: "w1", accountID: "a1", plan: plan, signed: signed)
        _ = try await db.journalWalletConnectTon(id: "one", walletID: "w1", accountID: "a1", plan: plan, signed: signed)
        do {
            _ = try await db.journalWalletConnectTon(id: "two", walletID: "w2", accountID: "a2", plan: plan, signed: signed)
            XCTFail("The same address cannot reserve the same sequence through another wallet")
        } catch { XCTAssertEqual(error as? TonSendError, .busy) }
        let reopened = try await OathDatabase.open(at: folder.appendingPathComponent("db.sqlite"))
        let stored = try await reopened.walletConnectTonSubmission("one")
        XCTAssertEqual(try stored?.decoded().1, signed)
        let rows = try await reopened.pendingWalletConnectTonSubmissions(); XCTAssertEqual(rows.count, 1)
        try await reopened.settleWalletConnectTon("one", outcome: .accepted)
        try await reopened.settleWalletConnectTon("one", outcome: .unknown)
        let accepted = try await reopened.walletConnectTonSubmission("one"); XCTAssertEqual(accepted?.state, "accepted")
        try await reopened.settleWalletConnectTon("one", outcome: .confirmed)
        try await reopened.settleWalletConnectTon("one", outcome: .failed)
        let confirmed = try await reopened.walletConnectTonSubmission("one"); XCTAssertEqual(confirmed?.state, "confirmed")
        let pending = try await reopened.pendingWalletConnectTonSubmissions(); XCTAssertTrue(pending.isEmpty)
        _ = try await reopened.journalWalletConnectTon(id: "two", walletID: "w2", accountID: "a2", plan: plan, signed: signed)
    }
    func testOrdinarySendAndWalletConnectCannotDoubleReserve() async throws {
        for ordinaryFirst in [true, false] {
            let (db, folder, plan, signed, ordinary) = try await fixture()
            defer { try? FileManager.default.removeItem(at: folder) }
            try await TonSendJournalTests().draft("normal", plan: ordinary, db: db)
            if ordinaryFirst {
                try await db.queueTonSend(sendID: "normal", plan: ordinary)
                do {
                    _ = try await db.journalWalletConnectTon(id: "wc", walletID: "w1", accountID: "a1", plan: plan, signed: signed)
                    XCTFail("Conflicting ordinary send")
                } catch { XCTAssertEqual(error as? TonSendError, .busy) }
            } else {
                _ = try await db.journalWalletConnectTon(id: "wc", walletID: "w1", accountID: "a1", plan: plan, signed: signed)
                do { try await db.queueTonSend(sendID: "normal", plan: ordinary); XCTFail("Conflicting WalletConnect send") }
                catch { XCTAssertEqual(error as? TonSendError, .busy) }
            }
        }
    }
    func testForgedSignaturesAndCrossWalletReplayRejected() async throws {
        let (db, folder, plan, signed, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            _ = try await db.journalWalletConnectTon(id: "forged", walletID: "w1", accountID: "a1", plan: plan,
                signed: .init(bytes: signed.bytes, signature: Data(repeating: 0, count: 64), hash: signed.hash, bodyHash: signed.bodyHash))
            XCTFail("Invalid signature")
        } catch { }
        _ = try await db.journalWalletConnectTon(id: "one", walletID: "w1", accountID: "a1", plan: plan, signed: signed)
        do {
            _ = try await db.journalWalletConnectTon(id: "one", walletID: "w2", accountID: "a2", plan: plan, signed: signed)
            XCTFail("Cross-wallet replay")
        } catch { XCTAssertEqual(error as? TonSendError, .changed) }
    }
}
