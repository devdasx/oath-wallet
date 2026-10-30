import XCTest
import OathDiagnostics
@testable import OathAnkr

private actor RecoveryDiagnosticSink: DiagnosticTransport {
    var events: [DiagnosticEvent] = []
    func upload(_ events: [DiagnosticEvent]) async throws { self.events += events }
}

private actor BroadcastRecoveryTransport: AnkrTransport {
    enum Mode { case lostReply, pendingWithoutReceipt, pendingWithoutFinality, replacedWhilePending, laggingPrimary, missing, missingWithoutReceipt, wrongTransaction, cancelled }
    var mode: Mode
    let base: EVMSendFixtureTransport
    var plan: EVMSendPlan?, signed: EVMSignedSend?
    var broadcasts = 0, fallbackLookups = 0
    init(_ mode: Mode, network: EVMSendNetwork) {
        self.mode = mode
        base = .init("confirmed", network: network)
    }
    func configure(_ plan: EVMSendPlan, _ signed: EVMSignedSend) async {
        self.plan = plan; self.signed = signed
        await base.configure(plan, signed)
    }
    func setMode(_ mode: Mode) { self.mode = mode }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let payload = try JSONDecoder().decode(SolanaJSON.self, from: XCTUnwrap(request.httpBody))
        let calls = payload.array ?? [payload]
        let broadcast = calls.contains { $0["method"].string == "eth_sendRawTransaction" }
        if broadcast {
            broadcasts += 1
            if mode == .cancelled { throw CancellationError() }
            throw URLError(.timedOut)
        }
        let lookup = calls.contains { ["eth_getTransactionByHash", "eth_getTransactionReceipt"].contains($0["method"].string ?? "") }
        if lookup, request.url?.host == "fallback.example" { fallbackLookups += 1 }
        let (data, status) = try await base.send(request)
        guard let rows = try JSONDecoder().decode(SolanaJSON.self, from: data).array else { return (data, status) }
        let result = rows.map { row -> SolanaJSON in
            guard let call = calls.first(where: { $0["id"] == row["id"] }) else { return row }
            let method = call["method"].string ?? ""
            var value = row["result"]
            if ["eth_getTransactionByHash", "eth_getTransactionReceipt"].contains(method) {
                if mode == .missing || (mode == .missingWithoutReceipt && method == "eth_getTransactionByHash") || (mode == .laggingPrimary && request.url?.host != "fallback.example") { value = .null }
                else if method == "eth_getTransactionReceipt", [.pendingWithoutReceipt, .pendingWithoutFinality, .missingWithoutReceipt, .replacedWhilePending].contains(mode) {
                    if [.pendingWithoutReceipt, .missingWithoutReceipt].contains(mode) { return .object(["jsonrpc": .string("2.0"), "id": row["id"], "error": .object(["code": .number("-32000"), "message": .string("receipt service unavailable")])]) }
                    value = .null
                } else if method == "eth_getTransactionByHash", case .object(var tx) = value {
                    if [.pendingWithoutReceipt, .pendingWithoutFinality, .replacedWhilePending].contains(mode) { tx["blockNumber"] = .null; tx["blockHash"] = .null }
                    if mode == .wrongTransaction { tx["to"] = tx["from"] }
                    value = .object(tx)
                }
            }
            if mode == .replacedWhilePending, method == "eth_getTransactionCount", let plan {
                value = .string("0x" + String(plan.nonce + 1, radix: 16))
            }
            if mode == .pendingWithoutFinality, method == "eth_getBlockByNumber", call["params"].array?.first == .string("finalized") {
                return .object(["jsonrpc": .string("2.0"), "id": row["id"], "error": .object(["code": .number("-32601"), "message": .string("finalized unavailable")])])
            }
            return .object(["jsonrpc": .string("2.0"), "id": row["id"], "result": value])
        }
        return (try JSONEncoder().encode(SolanaJSON.array(result)), status)
    }
}

final class EVMBroadcastRecoveryTests: XCTestCase, @unchecked Sendable {
    private func fixture(_ mode: BroadcastRecoveryTransport.Mode, network: EVMSendNetwork = .bnb) async throws -> (BroadcastRecoveryTransport, EVMSendClient, EVMSendPlan, EVMSignedSend) {
        let key = Data(repeating: 1, count: 32)
        let feed = BroadcastRecoveryTransport(mode, network: network)
        let endpoints = [URL(string: "https://primary.example")!] + (mode == .laggingPrimary ? [URL(string: "https://fallback.example")!] : [])
        let client = try EVMSendClient(network: network, endpoints: endpoints, transport: feed)
        let plan = try await client.quote(sender: EVMSendCrypto.address(privateKey: key), recipient: EVMSendCrypto.address(privateKey: Data(repeating: 2, count: 32)), reference: "native", decimals: 18, amount: "1000000000000000")
        let signed = try EVMSendCrypto.sign(plan, privateKey: key)
        await feed.configure(plan, signed)
        return (feed, client, plan, signed)
    }

    func testLostBroadcastReplyRecoversConfirmedExactTransaction() async throws {
        for network in EVMSendNetwork.allCases {
            let (feed, client, plan, signed) = try await fixture(.lostReply, network: network)
            let receipt = try await client.submit(signed, plan: plan, reconcileFirst: false)
            XCTAssertEqual(receipt.outcome, .confirmed, network.rawValue)
            XCTAssertEqual(receipt.hash, signed.hash)
            let broadcasts = await feed.broadcasts
            XCTAssertEqual(broadcasts, 1, "Recovery reads must not send new bytes")
        }
    }

    func testVerifiedPendingTransactionDoesNotDependOnReceiptOrFinalityServices() async throws {
        for mode in [BroadcastRecoveryTransport.Mode.pendingWithoutReceipt, .pendingWithoutFinality] {
            let (_, client, plan, signed) = try await fixture(mode)
            let receipt = try await client.status(signed, plan: plan)
            XCTAssertEqual(receipt.outcome, .accepted)
            XCTAssertNil(receipt.inclusion)
            XCTAssertNil(receipt.fee)
        }
    }

    func testNullPrimaryLookupConsultsIndependentProviderOnExistingEVMChains() async throws {
        for network in EVMSendNetwork.allCases {
            let (feed, client, plan, signed) = try await fixture(.laggingPrimary, network: network)
            let receipt = try await client.status(signed, plan: plan)
            XCTAssertEqual(receipt.outcome, .confirmed, network.rawValue)
            let fallbackLookups = await feed.fallbackLookups
            XCTAssertEqual(fallbackLookups, 2)
        }
    }

    func testLostBroadcastReplyShowsSubmittedThenConfirmedWithoutResending() async throws {
        let (feed, client, plan, signed) = try await fixture(.pendingWithoutReceipt)
        let submitted = try await client.submit(signed, plan: plan, reconcileFirst: false)
        XCTAssertEqual(submitted.outcome, .accepted)
        XCTAssertNil(submitted.inclusion)
        await feed.setMode(.lostReply)
        let confirmed = try await client.status(signed, plan: plan)
        XCTAssertEqual(confirmed.outcome, .confirmed)
        let broadcasts = await feed.broadcasts
        XCTAssertEqual(broadcasts, 1)
    }

    func testReceiptFailureWithoutExactTransactionRemainsUnknown() async throws {
        let (_, client, plan, signed) = try await fixture(.missingWithoutReceipt)
        do { _ = try await client.status(signed, plan: plan); XCTFail("Receipt failure fabricated acceptance") }
        catch { XCTAssertEqual(error as? EVMSendError, .rpc(-32000)) }
    }

    func testStalePendingEntryDoesNotHideFinalizedReplacement() async throws {
        let (_, client, plan, signed) = try await fixture(.replacedWhilePending)
        let receipt = try await client.status(signed, plan: plan)
        XCTAssertEqual(receipt.outcome, .replaced)
        XCTAssertEqual(receipt.replacementHash, "0x" + String(repeating: "b", count: 64))
    }

    func testReadOnlyPreviouslyBroadcastBSCTransaction() async throws {
        guard let path = ProcessInfo.processInfo.environment["OATH_BSC_STATUS_READONLY_FIXTURE"] else {
            throw XCTSkip("Opt-in public signed-transaction fixture; status reads only")
        }
        struct Fixture: Decodable { let plan: EVMSendPlan; let signed: EVMSignedSend }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        guard fixture.plan.network == .bnb else { throw EVMSendError.wrongNetwork }
        let client = try EVMSendClient(network: .bnb, endpoints: [URL(string: "https://bsc-dataseed.bnbchain.org")!])
        let receipt = try await client.status(fixture.signed, plan: fixture.plan)
        XCTAssertEqual(receipt.hash, fixture.signed.hash)
        XCTAssertEqual(receipt.outcome, .confirmed)
        XCTAssertNotNil(receipt.height)
        XCTAssertNotNil(receipt.fee)
    }

    func testReceiptLookupFailureRetainsPrivacyFilteredDiagnostics() async throws {
        guard ProcessInfo.processInfo.environment["OATH_EVM_RECOVERY_DIAGNOSTICS"] == "1" else {
            throw XCTSkip("Fresh process required for the production diagnostics reporter")
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        let sink = RecoveryDiagnosticSink(), operation = UUID()
        OathDiagnostics.configure(file: file, transport: sink)
        let (_, client, plan, signed) = try await fixture(.pendingWithoutReceipt)
        let receipt = try await OathDiagnostics.$operationID.withValue(operation) {
            try await client.submit(signed, plan: plan, reconcileFirst: false)
        }
        XCTAssertEqual(receipt.outcome, .accepted)
        for _ in 0..<100 {
            await OathDiagnostics.flush()
            let events = await sink.events.filter { $0.operationID == operation }
            if events.contains(where: { $0.operation == "receipt_lookup" }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let events = await sink.events.filter { $0.operationID == operation }
        // The shared availability policy excludes transport timeouts. Keep that
        // exclusion while retaining the receipt provider's eligible RPC failure.
        XCTAssertFalse(events.contains(where: { $0.operation == "eth_sendRawTransaction" }))
        XCTAssertTrue(events.contains(where: { $0.operation == "receipt_lookup" && $0.context["chain"] == "bnb" }))
        let encoded = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        XCTAssertFalse(encoded.contains(TronSendCrypto.hex(signed.bytes)))
        XCTAssertFalse(encoded.contains(plan.sender))
        XCTAssertFalse(encoded.contains(plan.recipient))
        XCTAssertFalse(encoded.contains(signed.hash))
    }

    func testUnknownMismatchedAndCancelledBroadcastNeverClaimAcceptance() async throws {
        for mode in [BroadcastRecoveryTransport.Mode.missing, .wrongTransaction, .cancelled] {
            let (feed, client, plan, signed) = try await fixture(mode)
            do { _ = try await client.submit(signed, plan: plan, reconcileFirst: false); XCTFail("Unverified submission accepted") }
            catch { if mode == .cancelled { XCTAssertTrue(error is CancellationError) } }
            let broadcasts = await feed.broadcasts
            XCTAssertEqual(broadcasts, 1)
        }
    }
}
