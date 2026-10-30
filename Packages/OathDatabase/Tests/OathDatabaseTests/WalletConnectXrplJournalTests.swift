import XCTest
@testable import OathAnkr
@testable import OathDatabase

@MainActor final class WalletConnectXrplJournalTests: XCTestCase {
    let key = Data(repeating: 7, count: 32)
    func fixture() async throws -> (OathDatabase, URL, WalletConnectXrplReview, WalletConnectXrplSigned) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("WCXrpl-" + UUID().uuidString)
        let db = try await OathDatabase.open(at: folder.appendingPathComponent("wallet.sqlite"))
        let owner = try XrplSendCrypto.address(privateKey: key)
        try await db.seed(networks: [.init(id: "xrpl", name: "Xrpl", family: "account", symbol: "XRP", decimals: 6, derivationPath: "m/44'/144'/0'", logo: "xrpl", sortOrder: 0)], assets: [.init(id: "xrpl:native", networkID: "xrpl", reference: "native", name: "Xrpl", symbol: "XRP", decimals: 6)])
        for i in 1...2 { try await db.importWalletIfNeeded(.init(id: "w\(i)", name: "Test", kind: "hd", vaultReference: "test\(i)", createdAt: 1), accounts: [.init(id: "a\(i)", walletID: "w\(i)", networkID: "xrpl", address: owner, derivationPath: "m/44'/144'/0'")]) }
        let tx: XrplJSON = .object(["TransactionType":.string("Payment"),"Account":.string(owner),"Destination":.string(owner),"Amount":.string("100"),"Fee":.string("12"),"Sequence":.number("42"),"LastLedgerSequence":.number("120")])
        let request = try WalletConnectXrplRequest(method:"xrpl_signTransaction",chain:"xrpl:0",account:owner,params:JSONEncoder().encode(XrplJSON.object(["tx_json":tx])))
        let review = WalletConnectXrplReview(request:request,transaction:tx,firstLedger:100,createdAt:.now)
        return (db, folder, review, try request.sign(privateKey: key, review: review))
    }
    func testRestartExactReplayReservationAndMonotonicState() async throws {
        let (db, folder, review, signed) = try await fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let row = try await db.journalWalletConnectXrpl(id: "r1", walletID: "w1", accountID: "a1", plan: review, signed: signed)
        let duplicate = try await db.journalWalletConnectXrpl(id: "r1", walletID: "w1", accountID: "a1", plan: review, signed: signed)
        XCTAssertEqual(row.signedData, duplicate.signedData)
        let reopened = try await OathDatabase.open(at: folder.appendingPathComponent("wallet.sqlite"))
        let recovered = try await reopened.pendingWalletConnectXrplSubmissions()
        XCTAssertEqual(recovered.count, 1); XCTAssertEqual(try recovered[0].decoded().1, signed)
        do { _ = try await reopened.journalWalletConnectXrpl(id: "r2", walletID: "w2", accountID: "a2", plan: review, signed: signed); XCTFail("Concurrent owner") } catch { XCTAssertEqual(error as? XrplSendError, .busy) }
        try await reopened.settleWalletConnectXrpl("r1", outcome: .accepted)
        try await reopened.settleWalletConnectXrpl("r1", outcome: .unknown)
        let accepted = try await reopened.walletConnectXrplSubmission("r1"); XCTAssertEqual(accepted?.state, "accepted")
        try await reopened.settleWalletConnectXrpl("r1", outcome: .confirmed)
        try await reopened.settleWalletConnectXrpl("r1", outcome: .failed)
        let final = try await reopened.walletConnectXrplSubmission("r1"); XCTAssertEqual(final?.state, "confirmed")
        let pending = try await reopened.pendingWalletConnectXrplSubmissions(); XCTAssertTrue(pending.isEmpty)
    }
    func testTamperingAndCrossWalletReplayRejected() async throws {
        let (db, folder, review, signed) = try await fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        var signature = signed.signature; signature[0] ^= 1
        do { _ = try await db.journalWalletConnectXrpl(id: "r1", walletID: "w1", accountID: "a1", plan: review, signed: .init(bytes: signed.bytes, hash: signed.hash, transaction: signed.transaction, publicKey: signed.publicKey, signature: signature)); XCTFail("Forged signature") } catch { XCTAssertEqual(error as? XrplSendError, .signing) }
        _ = try await db.journalWalletConnectXrpl(id: "r1", walletID: "w1", accountID: "a1", plan: review, signed: signed)
        do { _ = try await db.journalWalletConnectXrpl(id: "r1", walletID: "w2", accountID: "a2", plan: review, signed: signed); XCTFail("Cross-wallet replay") } catch { XCTAssertEqual(error as? XrplSendError, .changed) }
    }
}
