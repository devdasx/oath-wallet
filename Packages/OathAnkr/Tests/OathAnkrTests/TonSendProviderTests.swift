import XCTest
import OathDiagnostics
@testable import OathAnkr

private actor TonRecoveryReports: DiagnosticTransport {
    var events = [DiagnosticEvent]()
    func upload(_ events: [DiagnosticEvent]) async throws { self.events += events }
}

private actor TonRecoveryTransport: AnkrTransport {
    enum Mode { case unavailable, lostResponse, allUnavailable, invalidAcceptance, wrongNetwork }
    let mode: Mode
    private(set) var primaryWrites = 0, fallbackWrites = 0
    private(set) var sameBytes = true
    private var bytes: String?
    private var started: CheckedContinuation<Void, Never>?
    init(_ mode: Mode) { self.mode = mode }
    func waitForWrite() async {
        guard primaryWrites == 0 else { return }
        await withCheckedContinuation { started = $0 }
    }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        // Entirely offline fixture: requests are inspected, never forwarded.
        if request.url?.host == "tonapi.io" {
            return (Data(#"{"error":"entity not found"}"#.utf8), 404)
        }
        let value = try JSONDecoder().decode(TonJSON.self, from: XCTUnwrap(request.httpBody))
        let primary = request.url?.host == "rpc.ankr.com"
        let result: TonJSON
        switch value["method"].string {
        case "getMasterchainInfo":
            result = .object(["init": .object(["root_hash": .string(
                mode == .wrongNetwork ? "gj+B8wb/AmlPk1z1AhVI484rhrUpgSr2oSFIh56VoSg=" : TonIdentity.genesis)])])
        case "sendBoc":
            if primary { primaryWrites += 1 } else { fallbackWrites += 1 }
            let sent = try XCTUnwrap(value["params"]["boc"].string)
            if let bytes { sameBytes = sameBytes && bytes == sent } else { bytes = sent }
            started?.resume(); started = nil
            if primary && mode == .lostResponse { throw URLError(.networkConnectionLost) }
            if mode == .allUnavailable || (primary && mode == .unavailable) {
                return (Data(#"{"error":"fixture provider unavailable"}"#.utf8), 500)
            }
            result = .object(["@type": .string(mode == .invalidAcceptance ? "error" : "ok")])
        default: throw TonSendError.malformed
        }
        return (try JSONEncoder().encode(TonJSON.object([
            "jsonrpc": .string("2.0"), "id": .number("1"), "result": result])), 200)
    }
}

@MainActor final class TonSendProviderTests: XCTestCase {
    func testProviderFailureRecoveryRequiresAcceptanceAndPreservesBytesAndCancellation() async throws {
        let reports = TonRecoveryReports()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        OathDiagnostics.configure(file: file, transport: reports)
        let plan = try TonSendTests.plan(network: .mainnet)
        let signed = try TonSendCrypto.sign(plan, privateKey: TonSendTests.key)
        for mode in [TonRecoveryTransport.Mode.unavailable, .lostResponse, .allUnavailable, .invalidAcceptance, .wrongNetwork] {
            let transport = TonRecoveryTransport(mode)
            let client = try TonSendClient(apiKey: "isolatedfixture", transport: transport, indexInterval: 0)
            let result = try await OathDiagnostics.$operationID.withValue(UUID()) {
                try await client.submit(signed, plan: plan)
            }
            let primary = await transport.primaryWrites, fallback = await transport.fallbackWrites
            let unchanged = await transport.sameBytes
            XCTAssertTrue(unchanged, "Retries must not create a different transaction")
            switch mode {
            case .unavailable:
                XCTAssertEqual(primary, 3); XCTAssertEqual(fallback, 1)
                XCTAssertEqual(result.outcome, .accepted)
            case .lostResponse:
                XCTAssertEqual(primary, 1); XCTAssertEqual(fallback, 1)
                XCTAssertEqual(result.outcome, .accepted)
            case .allUnavailable:
                XCTAssertEqual(primary, 3); XCTAssertEqual(fallback, 3)
                XCTAssertEqual(result.outcome, .unknown, "Provider failures and absent traces cannot prove success or failure")
            case .invalidAcceptance:
                XCTAssertEqual(primary, 1); XCTAssertEqual(fallback, 0)
                XCTAssertEqual(result.outcome, .unknown, "HTTP 200 alone is not acceptance")
            case .wrongNetwork:
                XCTAssertEqual(primary, 0); XCTAssertEqual(fallback, 0)
                XCTAssertEqual(result.outcome, .unknown)
            }
        }
        let transport = TonRecoveryTransport(.unavailable)
        let client = try TonSendClient(apiKey: "isolatedfixture", transport: transport, indexInterval: 0)
        let task = Task { try await client.submit(signed, plan: plan) }
        await transport.waitForWrite()
        task.cancel()
        do { _ = try await task.value; XCTFail("Retry cancellation must propagate") }
        catch { XCTAssertTrue(error is CancellationError) }
        let primary = await transport.primaryWrites, fallback = await transport.fallbackWrites
        XCTAssertEqual(primary, 1); XCTAssertEqual(fallback, 0)
        for _ in 0..<100 {
            await OathDiagnostics.flush()
            if await reports.events.count >= 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let events = await reports.events
        // Availability and cancellation are excluded; the rejected acceptance
        // envelope and mismatched genesis remain genuine validation failures.
        XCTAssertEqual(events.count, 2)
        XCTAssertTrue(events.contains { $0.operation == "broadcast" && $0.error.message == "malformed" })
        XCTAssertTrue(events.contains { $0.operation == "broadcast" && $0.error.message == "wrongNetwork" })
        XCTAssertFalse(events.contains { $0.operation == "request_retry" || $0.operation == "provider_fallback" })
        XCTAssertTrue(events.allSatisfy { $0.context["chain"] == "ton" && $0.privacyFiltered })
        let encoded = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        for privateValue in [plan.sender, plan.recipient, signed.bytes.base64EncodedString(), "isolatedfixture"] {
            XCTAssertFalse(encoded.contains(privateValue), "Diagnostics must not expose transfer data or credentials")
        }
    }
}
