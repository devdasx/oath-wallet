import XCTest
import OathDiagnostics
@testable import OathAnkr

private actor DuplicateDiagnosticSink: DiagnosticTransport {
    var events: [DiagnosticEvent] = []
    func upload(_ events: [DiagnosticEvent]) async throws { self.events += events }
}

private actor DuplicateBroadcastFeed: AnkrTransport {
    enum Mode { case matched, missing, wrongTransaction, wrongChain, differentError, cancelled, included }
    let base: EVMSendFixtureTransport
    let mode: Mode
    var plan: EVMSendPlan?, signed: EVMSignedSend?
    var broadcasts = 0, lookups = 0
    init(network: EVMSendNetwork, mode: Mode) { base = .init(mode == .included ? "unfinalized" : "normal", network: network); self.mode = mode }
    func configure(_ plan: EVMSendPlan, _ signed: EVMSignedSend) async {
        self.plan = plan; self.signed = signed
        await base.configure(plan, signed)
    }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let payload = try JSONDecoder().decode(SolanaJSON.self, from: XCTUnwrap(request.httpBody))
        let calls = payload.array ?? [payload]
        let broadcast = calls.contains { $0["method"].string == "eth_sendRawTransaction" }
        let lookup = calls.contains { $0["method"].string == "eth_getTransactionByHash" }
        if broadcast { broadcasts += 1 }
        if lookup { lookups += 1; if mode == .cancelled { throw CancellationError() } }
        let (data, status) = try await base.send(request)
        guard let rows = try JSONDecoder().decode(SolanaJSON.self, from: data).array else { return (data, status) }
        let mapped = try rows.map { row -> SolanaJSON in
            guard let call = calls.first(where: { $0["id"] == row["id"] }), let p = plan, let s = signed else { return row }
            let method = call["method"].string
            if method == "eth_chainId", broadcast, mode == .wrongChain {
                return .object(["jsonrpc": .string("2.0"), "id": row["id"], "result": .string("0x0")])
            }
            if method == "eth_sendRawTransaction" {
                XCTAssertEqual(call["params"].array, [.string("0x" + TronSendCrypto.hex(s.bytes))])
                return .object(["jsonrpc": .string("2.0"), "id": row["id"], "error": .object([
                    "code": .number("-32000"), "message": .string(mode == .differentError ? "execution reverted" : "already known")])])
            }
            if method == "eth_getTransactionByHash", broadcasts > 0, mode != .missing, mode != .included {
                XCTAssertEqual(call["params"].array, [.string(s.hash)])
                func hex(_ n: UInt64) -> SolanaJSON { .string("0x" + String(n, radix: 16)) }
                return .object(["jsonrpc": .string("2.0"), "id": row["id"], "result": .object([
                    "hash": .string(s.hash), "from": .string(p.sender), "to": .string(mode == .wrongTransaction ? p.sender : p.receiver),
                    "chainId": hex(p.network.chainID), "type": hex(p.legacy ? 0 : 2), "nonce": hex(p.nonce), "gas": hex(p.gasLimit),
                    "gasPrice": hex(p.maxFeePerGas), "maxFeePerGas": hex(p.maxFeePerGas), "maxPriorityFeePerGas": hex(p.maxPriorityFeePerGas),
                    "value": .string(try EVMSendAmount.hex(p.value)), "input": .string("0x" + TronSendCrypto.hex(try EVMSendCrypto.data(p))),
                    "blockNumber": .null, "blockHash": .null])])
            }
            return row
        }
        return (try JSONEncoder().encode(SolanaJSON.array(mapped)), status)
    }
}

final class EVMDuplicateBroadcastTests: XCTestCase, @unchecked Sendable {
    private func fixture(_ mode: DuplicateBroadcastFeed.Mode, network: EVMSendNetwork = .base, token: Bool = false) async throws -> (DuplicateBroadcastFeed, EVMSendClient, EVMSendPlan, EVMSignedSend) {
        let feed = DuplicateBroadcastFeed(network: network, mode: mode)
        let client = try EVMSendClient(network: network, endpoints: [URL(string: "https://rpc.example")!], transport: feed)
        let key = Data(repeating: 1, count: 32)
        let plan = try await client.quote(sender: EVMSendCrypto.address(privateKey: key),
            recipient: EVMSendCrypto.address(privateKey: Data(repeating: 2, count: 32)),
            reference: token ? "0x" + String(repeating: "3", count: 40) : "native", decimals: token ? 6 : 18,
            amount: token ? "123" : "1000000000000000000")
        let signed = try EVMSendCrypto.sign(plan, privateKey: key)
        await feed.configure(plan, signed)
        return (feed, client, plan, signed)
    }
    func testAlreadyKnownReconcilesExactSignedTransactionAcrossNetworks() async throws {
        for network in EVMSendNetwork.allCases {
            for token in [false, true] {
                let (feed, client, plan, signed) = try await fixture(.matched, network: network, token: token)
                let receipt = try await client.submit(signed, plan: plan, reconcileFirst: false)
                XCTAssertEqual(receipt.hash, signed.hash); XCTAssertEqual(receipt.outcome, .accepted)
                let broadcasts = await feed.broadcasts, lookups = await feed.lookups
                XCTAssertEqual(broadcasts, 1); XCTAssertEqual(lookups, 1)
            }
        }
    }
    func testRecoveryReadCanRaceWithBroadcastAndThenReconcile() async throws {
        let (feed, client, plan, signed) = try await fixture(.matched)
        let receipt = try await client.submit(signed, plan: plan)
        XCTAssertEqual(receipt.outcome, .accepted)
        let broadcasts = await feed.broadcasts, lookups = await feed.lookups
        XCTAssertEqual(broadcasts, 1); XCTAssertEqual(lookups, 2)
    }
    func testUnverifiableDuplicateNeverBecomesSuccess() async throws {
        for (mode, expected) in [(DuplicateBroadcastFeed.Mode.missing, EVMSendError.rpc(-32000)), (.wrongTransaction, .changed), (.wrongChain, .wrongNetwork), (.differentError, .rpc(-32000))] {
            let (feed, client, plan, signed) = try await fixture(mode)
            do { _ = try await client.submit(signed, plan: plan, reconcileFirst: false); XCTFail("Unverified transaction accepted") }
            catch { XCTAssertEqual(error as? EVMSendError, expected) }
            let broadcasts = await feed.broadcasts, lookups = await feed.lookups
            XCTAssertEqual(broadcasts, 1)
            XCTAssertEqual(lookups, mode == .missing || mode == .wrongTransaction ? 1 : 0)
        }
    }
    func testDuplicateSafeOuterExecutionStillRequiresInnerSuccess() async throws {
        let owner = Data(repeating: 1, count: 32), executor = Data(repeating: 9, count: 32)
        let policy = try EVMMultisigPolicy(required: 1, owners: [EVMSendCrypto.address(privateKey: owner), EVMSendCrypto.address(privateKey: Data(repeating: 2, count: 32))],
            salt: Data(repeating: 3, count: 32), executor: EVMSendCrypto.address(privateKey: executor))
        let plan = EVMSendPlan(network: .base, sender: try policy.address, recipient: "0x" + String(repeating: "a", count: 40),
            reference: "native", decimals: 18, requestedAmount: "100", amount: "100", assetBalance: "1000", nativeBalance: "1000",
            nonce: 7, gasLimit: 400_000, maxFeePerGas: 41_000_000_000, maxPriorityFeePerGas: 1_000_000_000, blockHeight: 100,
            multisig: .init(policy: policy, safeNonce: 0, executorBalance: "1000000000000000000"))
        let signed = try EVMMultisigCrypto.sign(plan, keys: [owner], executorKey: executor)
        let outer = try EVMMultisigCrypto.outer(plan, signatures: XCTUnwrap(signed.multisigSignatures))
        for innerSuccess in [false, true] {
            let feed = DuplicateBroadcastFeed(network: .base, mode: .included)
            await feed.configure(outer, signed)
            if innerSuccess {
                await feed.base.setReceiptLogs([.object([
                    "address": .string(plan.sender), "topics": .array([
                        .string("0x" + TronSendCrypto.hex(TronSendCrypto.keccak(Data("ExecutionSuccess(bytes32,uint256)".utf8)))),
                        .string("0x" + (try TronSendCrypto.hex(EVMMultisigCrypto.digest(plan))))]),
                    "data": .string("0x" + String(repeating: "0", count: 64))])])
            }
            let client = try EVMSendClient(network: .base, endpoints: [URL(string: "https://rpc.example")!], transport: feed)
            do {
                let receipt = try await client.submit(signed, plan: plan, reconcileFirst: false)
                XCTAssertTrue(innerSuccess); XCTAssertEqual(receipt.inclusion?.succeeded, true)
                XCTAssertEqual(receipt.outcome, .accepted)
            } catch { XCTAssertFalse(innerSuccess); XCTAssertEqual(error as? EVMSendError, .execution) }
            let broadcasts = await feed.broadcasts; XCTAssertEqual(broadcasts, 1)
        }
    }
    func testReconciledDuplicateIsSilentButUnverifiedDuplicateReportsItsCause() async throws {
        guard ProcessInfo.processInfo.environment["OATH_EVM_DUPLICATE_DIAGNOSTICS"] == "1" else {
            throw XCTSkip("Fresh process required for the production diagnostics reporter")
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        let sink = DuplicateDiagnosticSink(), acceptedID = UUID(), unresolvedID = UUID()
        OathDiagnostics.configure(file: file, transport: sink)
        let (_, client, plan, signed) = try await fixture(.matched)
        _ = try await OathDiagnostics.$operationID.withValue(acceptedID) {
            try await client.submit(signed, plan: plan, reconcileFirst: false)
        }
        let (_, missing, missingPlan, missingSigned) = try await fixture(.missing)
        do {
            _ = try await OathDiagnostics.$operationID.withValue(unresolvedID) {
                try await missing.submit(missingSigned, plan: missingPlan, reconcileFirst: false)
            }
            XCTFail("Missing transaction accepted")
        } catch { XCTAssertEqual(error as? EVMSendError, .rpc(-32000)) }
        for _ in 0..<100 {
            await OathDiagnostics.flush()
            if await sink.events.contains(where: { $0.operationID == unresolvedID }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let events = await sink.events
        XCTAssertFalse(events.contains(where: { $0.operationID == acceptedID }))
        let event = try XCTUnwrap(events.first(where: { $0.operationID == unresolvedID && $0.operation == "broadcast_reconciliation" }))
        XCTAssertEqual(event.context["chain"], "base")
        XCTAssertTrue(event.error.underlying.contains(where: { $0.domain == "OathAnkr.EVMSendError" && $0.message == "rpc(-32000)" }))
        let encoded = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        XCTAssertFalse(encoded.contains(TronSendCrypto.hex(signed.bytes)))
        XCTAssertFalse(encoded.contains(plan.sender)); XCTAssertFalse(encoded.contains(plan.recipient))
        XCTAssertNil(DiagnosticHTTP.submittedEVMBroadcast)
    }
    func testCancellationDuringReconciliationDoesNotRebroadcast() async throws {
        let (feed, client, plan, signed) = try await fixture(.cancelled)
        do { _ = try await client.submit(signed, plan: plan, reconcileFirst: false); XCTFail() }
        catch { XCTAssertTrue(error is CancellationError) }
        let broadcasts = await feed.broadcasts; XCTAssertEqual(broadcasts, 1)
    }
}
