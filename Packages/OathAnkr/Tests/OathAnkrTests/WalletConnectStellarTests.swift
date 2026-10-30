import XCTest
import CryptoKit
import stellarsdk
@testable import OathAnkr

final class WalletConnectStellarTests: XCTestCase {
    let seed = Data(repeating: 7, count: 32)
    func transaction(v0: Bool = false, operations: Int = 1, now: Date = .now) throws -> Data {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed).publicKey.rawRepresentation
        let pk = try PublicKey(Array(key))
        let payment = OperationXDR(sourceAccount: Optional<MuxedAccountXDR>.none, body: .paymentOp(.init(destination: .ed25519(Array(key)), asset: .native, amount: 10_000_000)))
        let ops = Array(repeating: payment, count: operations)
        let bounds = TimeBoundsXDR(minTime: 0, maxTime: UInt64(now.timeIntervalSince1970) + 100)
        if v0 {
            return try Data(XDREncoder.encode(TransactionEnvelopeXDR.v0(.init(tx: .init(sourceAccount: pk, seqNum: 42, timeBounds: bounds, memo: .none, operations: ops), signatures: []))))
        }
        let tx = TransactionXDR(sourceAccount: .ed25519(Array(key)), seqNum: 42, cond: .time(bounds), memo: .none, operations: ops)
        return try Data(XDREncoder.encode(TransactionEnvelopeXDR.v1(.init(tx: tx, signatures: []))))
    }
    func request(_ bytes: Data, chain: String = "stellar:testnet", method: String = "stellar_signXDR") throws -> WalletConnectStellarRequest {
        try .init(method: method, chain: chain, account: StellarSendCrypto.address(privateKey: seed), params: JSONEncoder().encode(["xdr": bytes.base64EncodedString()]))
    }
    func testSignatureBindsReviewedNetworkAndBytes() throws {
        let request = try request(transaction()), details = try request.details()
        let review = WalletConnectStellarReview(request: request, details: details, firstLedger: 1, createdAt: .now)
        let signed = try request.sign(privateKey: seed, review: review)
        try request.verify(signed)
        XCTAssertEqual(signed.hash, details.hash)
        XCTAssertEqual(signed.response["signedXDR"].string, signed.bytes.base64EncodedString())
        XCTAssertThrowsError(try self.request(request.bytes, chain: "stellar:pubnet").verify(signed))
        XCTAssertThrowsError(try request.sign(privateKey: Data(repeating: 8, count: 32), review: review))
    }
    func testV0MultipleOperationsUsesTotalFeeInSignaturePayload() throws {
        let now = Date()
        let old = try request(transaction(v0: true, operations: 2, now: now)), current = try request(transaction(operations: 2, now: now))
        XCTAssertEqual(try old.details().fee, 200)
        XCTAssertEqual(try old.details().hash, try current.details().hash)
        let review = WalletConnectStellarReview(request: old, details: try old.details(), firstLedger: 1, createdAt: .now)
        try old.verify(old.sign(privateKey: seed, review: review))
    }
    func testRejectsMalformedAndNonCanonicalEnvelopes() throws {
        let bytes = try transaction()
        XCTAssertThrowsError(try request(bytes + Data(repeating: 0, count: 4)))
        XCTAssertThrowsError(try request(bytes.dropLast(4)))
        XCTAssertThrowsError(try request(Data(repeating: 255, count: 200)))
        XCTAssertThrowsError(try request(bytes, chain: "stellar:mainnet"))
        XCTAssertThrowsError(try request(bytes, method: "stellar_signMessage"))
        let address = try StellarSendCrypto.address(privateKey: seed)
        XCTAssertThrowsError(try WalletConnectStellarRequest(method: "stellar_signXDR", chain: "stellar:testnet", account: address, params: Data("{\"xdr\":\"\",\"xdr\":\"\"}".utf8)))
    }
    func testExistingSignaturesArePreservedAndWrongOwnerRejected() throws {
        let req = try request(transaction()), review = WalletConnectStellarReview(request: req, details: try req.details(), firstLedger: 1, createdAt: .now)
        let signed = try req.sign(privateKey: seed, review: review)
        let second = try request(signed.bytes), secondReview = WalletConnectStellarReview(request: second, details: try second.details(), firstLedger: 1, createdAt: .now)
        let again = try second.sign(privateKey: seed, review: secondReview)
        let envelope = try XDRDecoder.decode(TransactionEnvelopeXDR.self, data: again.bytes)
        guard case .v1(let value) = envelope else { return XCTFail() }
        XCTAssertEqual(value.signatures.count, 1)
        XCTAssertTrue(value.signatures.contains { $0.signature == signed.signature })
        XCTAssertEqual(try second.details().hash, signed.hash)
        XCTAssertThrowsError(try WalletConnectStellarRequest(method: req.method, chain: "stellar:testnet", account: StellarSendCrypto.address(privateKey: Data(repeating: 8, count: 32)), params: JSONEncoder().encode(["xdr": req.bytes.base64EncodedString()])))
    }
    func testExpiredReviewAndTransactionFailBeforeSigning() throws {
        let req = try request(transaction()), review = WalletConnectStellarReview(request: req, details: try req.details(), firstLedger: 1, createdAt: .now.addingTimeInterval(-121))
        XCTAssertThrowsError(try req.sign(privateKey: seed, review: review))
        let old = try request(transaction(now: .now.addingTimeInterval(-300)))
        XCTAssertThrowsError(try old.sign(privateKey: seed, review: .init(request: old, details: old.details(), firstLedger: 1, createdAt: .now)))
    }
    func testSubmissionRequiresReceiptAndRetriesExactSignedBytes() async throws {
        let req = try request(transaction(), method: "stellar_signAndSubmitXDR")
        let transport = StellarTransportFixture(sender: req.account, recipient: req.account, issuer: req.account)
        let client = try StellarSendClient(network: .testnet, transport: transport)
        let review = try await client.walletConnectReview(req), signed = try req.sign(privateKey: seed, review: review)
        await transport.configure(unavailable: true)
        for _ in 0..<2 {
            let outcome = try await client.walletConnectSubmit(signed, review: review)
            XCTAssertEqual(outcome, .unknown)
        }
        let writes = await transport.writes; XCTAssertEqual(writes.count, 2); XCTAssertEqual(writes.first, writes.last)
        await transport.configure(unavailable: false)
        await transport.ack(.object(["hash": .string(signed.hash), "tx_status": .string("PENDING")]))
        let accepted = try await client.walletConnectSubmit(signed, review: review); XCTAssertEqual(accepted, .accepted)
        await transport.receipt(.object(["hash": .string(signed.hash), "successful": .bool(true), "envelope_xdr": .string(signed.bytes.base64EncodedString())]))
        let confirmed = try await client.walletConnectSubmit(signed, review: review); XCTAssertEqual(confirmed, .confirmed)
        await transport.receipt(.object(["hash": .string(signed.hash), "successful": .bool(false), "envelope_xdr": .string(signed.bytes.base64EncodedString())]))
        let failed = try await client.walletConnectSubmit(signed, review: review); XCTAssertEqual(failed, .failed)
    }
    func testWrongHashProxyAbsenceAndWrongNetworkCannotConfirm() async throws {
        let req = try request(transaction(), method: "stellar_signAndSubmitXDR")
        let transport = StellarTransportFixture(sender: req.account, recipient: req.account, issuer: req.account)
        let client = try StellarSendClient(network: .testnet, transport: transport)
        let review = try await client.walletConnectReview(req), signed = try req.sign(privateKey: seed, review: review)
        await transport.ack(.object(["hash": .string("wrong"), "tx_status": .string("PENDING")]))
        let wrong = try await client.walletConnectSubmit(signed, review: review); XCTAssertEqual(wrong, .unknown)
        await transport.configure(proxy404: true)
        let proxy = try await client.walletConnectSubmit(signed, review: review); XCTAssertEqual(proxy, .unknown)
        await transport.configure(wrongNetwork: true)
        do { _ = try await client.walletConnectSubmit(signed, review: review); XCTFail("Wrong chain") } catch { XCTAssertEqual(error as? StellarSendError, .wrongNetwork) }
    }

    func testSequenceRejectionDoesNotDiscardPreviouslyBroadcastTransaction() throws {
        func result(_ body: TransactionResultBodyXDR) throws -> String {
            try Data(XDREncoder.encode(TransactionResultXDR(feeCharged: 100, result: body, ext: .void))).base64EncodedString()
        }
        XCTAssertEqual(try WalletConnectStellarRequest.rejectionOutcome(result(.badSeq)), .unknown)
        XCTAssertEqual(try WalletConnectStellarRequest.rejectionOutcome(result(.tooLate)), .unknown)
        XCTAssertEqual(try WalletConnectStellarRequest.rejectionOutcome(result(.badAuth)), .failed)
        XCTAssertThrowsError(try WalletConnectStellarRequest.rejectionOutcome(nil))
        XCTAssertThrowsError(try WalletConnectStellarRequest.rejectionOutcome(result(.success([]))))
    }

}
