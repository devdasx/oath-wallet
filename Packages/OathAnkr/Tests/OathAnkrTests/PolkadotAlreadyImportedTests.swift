import XCTest
@testable import OathAnkr

final class PolkadotAlreadyImportedTests: XCTestCase, @unchecked Sendable {
    func testMatchingAlreadyImportedIsAcceptedButNotConfirmed() async throws {
        let plan = try PolkadotSendTests().plan()
        let signed = try PolkadotSendCrypto.sign(plan, privateKey: Data(repeating: 1, count: 32))
        let transport = ImportedExtrinsicFixture(plan: plan, hash: signed.hash)
        let client = try PolkadotSendClient(transport: transport)
        let receipt = try await client.submit(signed, plan: plan)
        XCTAssertEqual(receipt.outcome, .accepted)
        XCTAssertEqual(receipt.hash, signed.hash)
        XCTAssertNil(receipt.block)
        XCTAssertNil(receipt.fee)
        let pending = try await client.status(signed, plan: plan)
        XCTAssertEqual(pending.outcome, .unknown, "Pool acknowledgement is not finalized execution")
        let submissions = await transport.submissions
        XCTAssertEqual(submissions, [PolkadotIdentity.hex(signed.bytes)])
    }

    func testDifferentHashMissingHashAndOtherRPCFailuresCannotAcknowledgeSubmission() async throws {
        let plan = try PolkadotSendTests().plan()
        let signed = try PolkadotSendCrypto.sign(plan, privateKey: Data(repeating: 1, count: 32))
        for mode in [ImportedExtrinsicFixture.Mode.wrongHash, .missingHash, .wrongID, .wrongMessage, .otherCode, .bothResultAndError, .httpFailure] {
            let transport = ImportedExtrinsicFixture(plan: plan, hash: signed.hash, mode: mode)
            let client = try PolkadotSendClient(transport: transport)
            do {
                _ = try await client.submit(signed, plan: plan, reconcileFirst: false)
                XCTFail("Must not acknowledge \(mode)")
            } catch { XCTAssertTrue(error is PolkadotSendError) }
            let submissions = await transport.submissions
            XCTAssertEqual(submissions, [PolkadotIdentity.hex(signed.bytes)], "Never retry another provider on uncertain submission")
        }
    }

    func testExpiredAndWrongNetworkNeverSubmit() async throws {
        let plan = try PolkadotSendTests().plan()
        let signed = try PolkadotSendCrypto.sign(plan, privateKey: Data(repeating: 1, count: 32))
        for mode in [ImportedExtrinsicFixture.Mode.expired, .wrongNetwork] {
            let transport = ImportedExtrinsicFixture(plan: plan, hash: signed.hash, mode: mode)
            let client = try PolkadotSendClient(transport: transport)
            if mode == .expired {
                let receipt = try await client.submit(signed, plan: plan, reconcileFirst: false)
                XCTAssertEqual(receipt.outcome, .expired)
            } else {
                do { _ = try await client.submit(signed, plan: plan); XCTFail("Reject wrong chain") }
                catch { XCTAssertEqual(error as? PolkadotSendError, .wrongNetwork) }
            }
            let submissions = await transport.submissions
            XCTAssertTrue(submissions.isEmpty)
        }
    }
}

private actor ImportedExtrinsicFixture: AnkrTransport {
    enum Mode { case matching, wrongHash, missingHash, wrongID, wrongMessage, otherCode, bothResultAndError, httpFailure, expired, wrongNetwork }
    let plan: PolkadotSendPlan, hash: String, mode: Mode
    var submissions: [String] = []
    init(plan: PolkadotSendPlan, hash: String, mode: Mode = .matching) {
        self.plan = plan; self.hash = hash; self.mode = mode
    }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let body = try JSONDecoder().decode(SolanaJSON.self, from: XCTUnwrap(request.httpBody))
        let method = try XCTUnwrap(body["method"].string)
        let params = try XCTUnwrap(body["params"].array)
        var reply: [String: SolanaJSON] = ["jsonrpc": .string("2.0"), "id": .number("1")]
        switch method {
        case "chain_getBlockHash":
            let height = try XCTUnwrap(UInt64(params[0].text ?? ""))
            reply["result"] = .string(height == 0 && mode != .wrongNetwork ? plan.network.genesis : "0x" + String(format: "%064llx", height))
        case "chain_getFinalizedHead": reply["result"] = .string(plan.blockHash)
        case "chain_getHeader": reply["result"] = .object(["number": .string("0x" + String(mode == .expired ? plan.expiresAtHeight : plan.blockHeight, radix: 16))])
        case "chain_getBlock":
            let height = try XCTUnwrap(UInt64(try XCTUnwrap(params[0].string).dropFirst(2), radix: 16))
            reply["result"] = .object(["block": .object(["header": .object(["number": .string("0x" + String(height, radix: 16))]), "extrinsics": .array([])])])
        case "author_submitExtrinsic":
            submissions.append(try XCTUnwrap(params.first?.string))
            var error: [String: SolanaJSON] = ["code": .number(mode == .otherCode ? "1014" : "1013"),
                "message": .string(mode == .wrongMessage ? "Unknown rejection" : "Transaction Already Imported")]
            if mode != .missingHash { error["data"] = .string(mode == .wrongHash ? "0x" + String(repeating: "ab", count: 32) : hash) }
            reply["error"] = .object(error)
            if mode == .wrongID { reply["id"] = .number("2") }
            if mode == .bothResultAndError { reply["result"] = .string(hash) }
        default: throw PolkadotSendError.runtimeUnsupported
        }
        return (try JSONEncoder().encode(SolanaJSON.object(reply)), mode == .httpFailure && method == "author_submitExtrinsic" ? 503 : 200)
    }
}
