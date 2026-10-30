import XCTest
import OathDiagnostics
@testable import OathAnkr

@MainActor final class XrplFailureCauseTests: XCTestCase {
    func testSendAndValidatedFailureCodesSurviveSharedPrivacyFiltering() async throws {
        guard ProcessInfo.processInfo.environment["OATH_XRPL_FAILURE_CAUSE_TEST"] == "1" else {
            throw XCTSkip("Run alone to isolate the process-wide diagnostics outbox")
        }
        let reports = XrplFailureReports()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        OathDiagnostics.configure(file: file, transport: reports)
        let key = Data(repeating: 7, count: 32)
        let sender = try XrplSendCrypto.address(privateKey: key)
        let recipient = "rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh"
        let fixture = XrplRPCFixture(sender: sender, recipient: recipient)
        let client = try XrplSendClient(network: .testnet, transport: fixture)
        let plan = try await client.quote(sender: sender, recipient: recipient, reference: "native", amount: "100")
        let signed = try XrplSendCrypto.sign(plan, privateKey: key)
        for code in ["tecUNFUNDED_PAYMENT", "tefPAST_SEQ", "PRIVATE_RESPONSE_MARKER"] {
            await fixture.ack(.object(["accepted": .bool(false), "engine_result": .string(code),
                                      "engine_result_message": .string("PRIVATE_RESPONSE_MARKER")]))
            let receipt = try await client.submit(signed, plan: plan, reconcileFirst: false)
            XCTAssertEqual(receipt.outcome, .unknown, "An unaccepted response cannot acknowledge the send")
        }
        for code in ["tecPATH_DRY", "tecPRIVATE_RESPONSE_MARKER"] {
            await fixture.response(.object(["status": .string("success"), "hash": .string(signed.hash),
                "validated": .bool(true), "ledger_index": .number("101"),
                "tx_json": try plan.transactionJSON(), "meta": .object(["TransactionResult": .string(code)])]))
            let receipt = try await client.status(signed, plan: plan)
            XCTAssertEqual(receipt.outcome, .failed)
            XCTAssertEqual(receipt.code, code == "tecPATH_DRY" ? code : "tecUNKNOWN")
        }
        for (engine, meta, expected) in [("tecPATH_DRY", "tecPATH_DRY", "tecPATH_DRY"),
                                         ("tesSUCCESS", "tecNO_AUTH", "tecNO_AUTH"),
                                         ("tesSUCCESS", "PRIVATE_RESPONSE_MARKER", "UNKNOWN")] {
            let transport = SimulationCauseTransport(base: fixture, engine: engine, meta: meta)
            let simulator = try XrplSendClient(network: .testnet, transport: transport)
            do {
                _ = try await simulator.quote(sender: sender, recipient: recipient, reference: "native", amount: "100")
                XCTFail("Failed simulation became a usable quote")
            } catch { XCTAssertEqual(error as? XrplSendError, .simulation(expected)) }
        }
        for _ in 0..<200 {
            let captured = await reports.events
            if captured.filter({ ["submit_result", "validated_failure", "simulate_result"].contains($0.operation) }).count >= 8 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(100))
        let events = await reports.events
        let submissions = events.filter { $0.operation == "submit_result" }
        let settlements = events.filter { $0.operation == "validated_failure" }
        let simulations = events.filter { $0.operation == "simulate_result" }
        XCTAssertEqual(submissions.count, 3)
        XCTAssertEqual(settlements.count, 2)
        XCTAssertEqual(simulations.count, 3)
        XCTAssertEqual(Set(submissions.compactMap { $0.context["rpc_code"] }), ["tecUNFUNDED_PAYMENT", "tefPAST_SEQ", "UNKNOWN"])
        XCTAssertEqual(Set(settlements.compactMap { $0.context["rpc_code"] }), ["tecPATH_DRY", "UNKNOWN"])
        XCTAssertTrue(submissions.allSatisfy { $0.context["stage"] == "broadcast" })
        XCTAssertTrue(settlements.allSatisfy { $0.context["stage"] == "reconcile" })
        XCTAssertEqual(Set(simulations.compactMap { $0.context["rpc_code"] }), ["tecPATH_DRY", "tecNO_AUTH", "UNKNOWN"])
        XCTAssertTrue(simulations.allSatisfy { $0.context["stage"] == "simulate" })
        let wire = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        for privateValue in ["PRIVATE_RESPONSE_MARKER", sender, recipient, signed.hash, XrplSendCrypto.hex(signed.bytes)] {
            XCTAssertFalse(wire.contains(privateValue), "Untrusted response or transaction data escaped filtering")
        }
    }
}

private struct SimulationCauseTransport: AnkrTransport {
    let base: XrplRPCFixture
    let engine: String, meta: String
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, status) = try await base.send(request)
        let body = try JSONDecoder().decode(XrplJSON.self, from: request.httpBody!)
        guard body["method"].string == "simulate" else { return (data, status) }
        let response = try JSONDecoder().decode(XrplJSON.self, from: data)
        guard case .object(var root) = response, case .object(var result) = root["result"] else {
            throw XrplSendError.malformed
        }
        result["engine_result"] = .string(engine)
        result["meta"] = .object(["TransactionResult": .string(meta)])
        root["result"] = .object(result)
        return (try JSONEncoder().encode(XrplJSON.object(root)), status)
    }
}

private actor XrplFailureReports: DiagnosticTransport {
    var events: [DiagnosticEvent] = []
    func upload(_ events: [DiagnosticEvent]) async throws { self.events += events }
}
