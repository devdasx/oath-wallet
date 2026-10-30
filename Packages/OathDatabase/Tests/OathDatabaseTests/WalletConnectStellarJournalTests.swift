import XCTest
@testable import OathAnkr
@testable import OathDatabase

@MainActor final class WalletConnectStellarJournalTests: XCTestCase {
    let key = Data(repeating: 7, count: 32)
    func fixture() async throws -> (OathDatabase, URL, WalletConnectStellarReview, WalletConnectStellarSigned) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("WCStellar-" + UUID().uuidString)
        let db = try await OathDatabase.open(at: folder.appendingPathComponent("wallet.sqlite"))
        let owner = try StellarSendCrypto.address(privateKey: key)
        try await db.seed(networks: [.init(id: "stellar", name: "Stellar", family: "account", symbol: "XLM", decimals: 7, derivationPath: "m/44'/148'/0'", logo: "stellar", sortOrder: 0)], assets: [.init(id: "stellar:native", networkID: "stellar", reference: "native", name: "Stellar", symbol: "XLM", decimals: 7)])
        for i in 1...2 { try await db.importWalletIfNeeded(.init(id: "w\(i)", name: "Test", kind: "hd", vaultReference: "test\(i)", createdAt: 1), accounts: [.init(id: "a\(i)", walletID: "w\(i)", networkID: "stellar", address: owner, derivationPath: "m/44'/148'/0'")]) }
        var raw = try StellarSendXDR.account(owner)
        raw += StellarSendXDR.u32(100) + StellarSendXDR.u64(42)
        raw += StellarSendXDR.u32(1) + StellarSendXDR.u64(0) + StellarSendXDR.u64(UInt64(Date.now.timeIntervalSince1970) + 100)
        raw += StellarSendXDR.u32(0) + StellarSendXDR.u32(1) + StellarSendXDR.u32(0) + StellarSendXDR.u32(1)
        raw += try StellarSendXDR.account(owner)
        raw += StellarSendXDR.u32(0) + StellarSendXDR.u64(100) + StellarSendXDR.u32(0)
        let request = try WalletConnectStellarRequest(method: "stellar_signAndSubmitXDR", chain: "stellar:pubnet", account: owner, params: JSONEncoder().encode(["xdr": StellarSendXDR.envelope(raw).base64EncodedString()]))
        let review = WalletConnectStellarReview(request: request, details: try request.details(), firstLedger: 1, createdAt: .now)
        return (db, folder, review, try request.sign(privateKey: key, review: review))
    }
    func testRestartExactReplayReservationAndMonotonicState() async throws {
        let (db, folder, review, signed) = try await fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let row = try await db.journalWalletConnectStellar(id: "r1", walletID: "w1", accountID: "a1", plan: review, signed: signed)
        let duplicate = try await db.journalWalletConnectStellar(id: "r1", walletID: "w1", accountID: "a1", plan: review, signed: signed)
        XCTAssertEqual(row.signedData, duplicate.signedData)
        let reopened = try await OathDatabase.open(at: folder.appendingPathComponent("wallet.sqlite"))
        let recovered = try await reopened.pendingWalletConnectStellarSubmissions()
        XCTAssertEqual(recovered.count, 1); XCTAssertEqual(try recovered[0].decoded().1, signed)
        do { _ = try await reopened.journalWalletConnectStellar(id: "r2", walletID: "w2", accountID: "a2", plan: review, signed: signed); XCTFail("Concurrent owner") } catch { XCTAssertEqual(error as? StellarSendError, .busy) }
        try await reopened.settleWalletConnectStellar("r1", outcome: .accepted)
        try await reopened.settleWalletConnectStellar("r1", outcome: .unknown)
        let accepted = try await reopened.walletConnectStellarSubmission("r1"); XCTAssertEqual(accepted?.state, "accepted")
        try await reopened.settleWalletConnectStellar("r1", outcome: .confirmed)
        try await reopened.settleWalletConnectStellar("r1", outcome: .failed)
        let final = try await reopened.walletConnectStellarSubmission("r1"); XCTAssertEqual(final?.state, "confirmed")
        let pending = try await reopened.pendingWalletConnectStellarSubmissions(); XCTAssertTrue(pending.isEmpty)
    }
    func testTamperingAndCrossWalletReplayRejected() async throws {
        let (db, folder, review, signed) = try await fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        var signature = signed.signature; signature[0] ^= 1
        do { _ = try await db.journalWalletConnectStellar(id: "r1", walletID: "w1", accountID: "a1", plan: review, signed: .init(bytes: signed.bytes, hash: signed.hash, publicKey: signed.publicKey, signature: signature)); XCTFail("Forged signature") } catch { XCTAssertEqual(error as? StellarSendError, .signing) }
        _ = try await db.journalWalletConnectStellar(id: "r1", walletID: "w1", accountID: "a1", plan: review, signed: signed)
        do { _ = try await db.journalWalletConnectStellar(id: "r1", walletID: "w2", accountID: "a2", plan: review, signed: signed); XCTFail("Cross-wallet replay") } catch { XCTAssertEqual(error as? StellarSendError, .changed) }
    }
}
