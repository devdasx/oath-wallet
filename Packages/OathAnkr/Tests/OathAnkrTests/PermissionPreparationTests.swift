import XCTest
import OathDiagnostics
@testable import OathAnkr

private actor PermissionPreparationReports: DiagnosticTransport {
    var events = [DiagnosticEvent]()
    func upload(_ events: [DiagnosticEvent]) async throws { self.events += events }
}

@MainActor final class PermissionPreparationTests: XCTestCase {
    func testGasBoundaryPreservesValidationAndOnlyReportsUnexpectedFailures() async throws {
        let capture = PermissionPreparationReports()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        OathDiagnostics.configure(file: file, transport: capture)
        let owner = "0x" + String(repeating: "1", count: 40)
        let contract = "0x" + String(repeating: "3", count: 40)
        let spender = "0x" + String(repeating: "2", count: 40)
        let removal = EVMPermissionRemoval(kind: .token, contract: contract, spender: spender, expected: "1")
        // The real Base quote computes gas + 20% + 1000, the EIP-1559 cap,
        // and twice (L1 data + operator fee). No token value is transferred.
        let fee: UInt64 = 61_000 * 41_000_000_000 + 4_000
        for balance in [0, fee - 1, fee, fee + 1] {
            let transport = EVMSendFixtureTransport(network: .base, nativeBalance: String(balance), gasEstimate: 50_000)
            let client = try EVMSendClient(network: .base, endpoints: [URL(string: "https://fixture.example")!], transport: transport)
            do {
                let plan = try await PermissionPreparation.run(chain: "base") {
                    try await client.quote(sender: owner, recipient: contract, reference: "native", decimals: 18, amount: "0", removal: removal)
                }
                XCTAssertGreaterThanOrEqual(balance, fee, "Unfunded removal must never become signable")
                XCTAssertEqual(plan.fee, fee); XCTAssertEqual(plan.amount, "0")
                XCTAssertEqual(plan.remaining, StellarIdentity.sum(String(balance), "-" + String(fee)))
                try await client.preflight(plan)
            } catch { XCTAssertLessThan(balance, fee); XCTAssertEqual(error as? EVMSendError, .insufficientFunds) }
            let counts = await transport.counts(); XCTAssertEqual(counts.1, 0)
        }
        // These other clients return the same expected unsigned fee validation.
        for (chain, failure) in [("tron", TronSendError.insufficientFunds as any Error),
                                 ("solana", SolanaSendError.insufficientFunds as any Error)] {
            do {
                let _: Int = try await PermissionPreparation.run(chain: chain) { throw failure }
                XCTFail("Validation must be returned to the review screen")
            } catch { XCTAssertEqual(String(describing: error), "insufficientFunds") }
        }
        do {
            let _: Int = try await PermissionPreparation.run(chain: "base") { throw CancellationError() }
            XCTFail("Cancellation must propagate")
        } catch { XCTAssertTrue(error is CancellationError) }
        let canceled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            let _: Int = try await PermissionPreparation.run(chain: "base") {
                XCTFail("Canceled review must not begin a provider request")
                throw EVMSendError.transport
            }
        }
        do { try await canceled.value; XCTFail("Canceled review must finish as cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        for succeedsAfterCancel in [false, true] {
            let interrupted = Task {
                try await PermissionPreparation.run(chain: "base") {
                    withUnsafeCurrentTask { $0?.cancel() }
                    if !succeedsAfterCancel { throw EVMSendError.transport }
                    return 7
                }
            }
            do { _ = try await interrupted.value; XCTFail("Canceled review must not publish a quote") }
            catch { XCTAssertTrue(error is CancellationError) }
        }
        try await Task.sleep(for: .milliseconds(200))
        let validationEvents = await capture.events
        XCTAssertTrue(validationEvents.isEmpty, "Insufficient gas before approval is expected validation, not an app defect")

        // A failing provider must retain both its original RPC event and the
        // review boundary, correlated without addresses or request payloads.
        let transport = EVMSendFixtureTransport("rpcError", network: .base)
        let client = try EVMSendClient(network: .base, endpoints: [URL(string: "https://fixture.example")!], transport: transport)
        do {
            let _: EVMSendPlan = try await PermissionPreparation.run(chain: "base") {
                try await client.quote(sender: owner, recipient: contract, reference: "native", decimals: 18, amount: "0", removal: removal)
            }
            XCTFail("Provider rejection must not become a quote")
        } catch { XCTAssertEqual(error as? EVMSendError, .rpc(-32000)) }
        let databaseFailure = NSError(domain: "GRDB.DatabaseError", code: 11)
        do {
            let _: Int = try await PermissionPreparation.run(chain: "base") { throw databaseFailure }
            XCTFail("Storage failure must propagate")
        } catch { XCTAssertEqual((error as NSError).domain, databaseFailure.domain) }
        // Balance can change after approval: keep submission reporting intact.
        OathDiagnostics.record(EVMSendError.insufficientFunds, component: "permissions", operation: "submit", context: ["chain": "base"])
        for _ in 0..<100 {
            if await capture.events.contains(where: { $0.operation == "submit" }),
               await capture.events.contains(where: { $0.error.domain == "GRDB.DatabaseError" }),
               await capture.events.contains(where: { $0.operation == "prepare" && $0.error.message == "rpc(-32000)" }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let events = await capture.events
        let provider = try XCTUnwrap(events.first { $0.operation == "prepare" && $0.error.message == "rpc(-32000)" })
        let storage = try XCTUnwrap(events.first { $0.error.domain == "GRDB.DatabaseError" })
        XCTAssertNotNil(provider.operationID); XCTAssertNotNil(storage.operationID)
        XCTAssertNotEqual(provider.operationID, storage.operationID)
        XCTAssertEqual(provider.context["chain"], "base"); XCTAssertEqual(storage.context["chain"], "base")
        XCTAssertTrue(events.contains { $0.operation == "rpc_response" && $0.operationID == provider.operationID })
        XCTAssertTrue(events.contains { $0.operation == "submit" && $0.error.message == "insufficientFunds" })
        let encoded = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        for privateValue in [owner, contract, spender, "https://fixture.example", "\"params\"", "\"body\""] {
            XCTAssertFalse(encoded.contains(privateValue))
        }
    }
}
