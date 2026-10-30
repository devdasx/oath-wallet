import XCTest
@testable import OathAnkr
@testable import OathDatabase

@MainActor final class PolkadotImportedJournalTests: XCTestCase {
    func testRestartReconcilesAlreadyImportedWithoutReleasingOrResigning() async throws {
        let helper = PolkadotSendJournalTests()
        let (db, folder, plan) = try await helper.fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await helper.draft("one", plan: plan, db: db)
        try await db.queuePolkadotSend(sendID: "one", plan: plan)
        let signed = try PolkadotSendCrypto.sign(plan, privateKey: helper.key)
        try await db.journalPolkadotSignature(sendID: "one", signed: signed)
        let original = try await db.send("one")
        let transport = ImportedJournalTransport(plan: plan, signed: signed)
        let reopened = try await OathDatabase.open(at: folder.appendingPathComponent("wallet.sqlite"))
        for _ in 0..<2 {
            // A fresh client models losing in-memory state after relaunch.
            try await reopened.reconcilePolkadotSend("one", client: PolkadotSendClient(transport: transport))
            let pending = try await reopened.send("one")
            XCTAssertEqual(pending?.state, "broadcast")
            XCTAssertNil(pending?.failureCode)
            XCTAssertEqual(pending?.signedPayload, original?.signedPayload)
        }
        try await helper.draft("two", wallet: 2, plan: plan, db: reopened)
        do { try await reopened.queuePolkadotSend(sendID: "two", plan: plan); XCTFail("Pool acknowledgement must keep funds reserved") }
        catch { XCTAssertEqual(error as? PolkadotSendError, .busy) }
        let submissions = await transport.submissions
        XCTAssertEqual(submissions, Array(repeating: PolkadotIdentity.hex(signed.bytes), count: 2))
    }
}

private actor ImportedJournalTransport: AnkrTransport {
    let plan: PolkadotSendPlan, signed: PolkadotSignedSend
    var submissions: [String] = []
    init(plan: PolkadotSendPlan, signed: PolkadotSignedSend) { self.plan = plan; self.signed = signed }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let body = try JSONDecoder().decode(SolanaJSON.self, from: XCTUnwrap(request.httpBody))
        let method = try XCTUnwrap(body["method"].string)
        let params = try XCTUnwrap(body["params"].array)
        var reply: [String: SolanaJSON] = ["jsonrpc": .string("2.0"), "id": .number("1")]
        switch method {
        case "chain_getBlockHash": reply["result"] = .string(params[0].text == "0" ? plan.network.genesis : plan.blockHash)
        case "chain_getFinalizedHead": reply["result"] = .string(plan.blockHash)
        case "chain_getHeader": reply["result"] = .object(["number": .string("0x" + String(plan.blockHeight, radix: 16))])
        case "chain_getBlock": reply["result"] = .object(["block": .object(["header": .object(["number": .string("0x" + String(plan.blockHeight, radix: 16))]), "extrinsics": .array([])])])
        case "author_submitExtrinsic":
            submissions.append(try XCTUnwrap(params.first?.string))
            reply["error"] = .object(["code": .number("1013"), "message": .string("Transaction Already Imported"), "data": .string(signed.hash)])
        default: throw PolkadotSendError.runtimeUnsupported
        }
        return (try JSONEncoder().encode(SolanaJSON.object(reply)), 200)
    }
}
