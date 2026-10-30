import Foundation
import XCTest
@testable import OathAnkr

final class EVMHistoryEnrichmentTests: XCTestCase {
    func testOptionalTraceFailureRetainsReceiptAndNeverInventsNativeAmount() async throws {
        let evidence = try EVMHistoryTraceTests().fixture()
        let transport = ExecutionEvidenceTransport(evidence, mode: .unavailable)
        let client = try EVMSendClient(network: .ethereumSepolia, endpoints: [URL(string: "https://example.invalid")!], transport: transport)
        let result = try await client.historyEvidence(hash: evidence.transaction["hash"].string!)
        XCTAssertEqual(result.receipt, evidence.receipt)
        XCTAssertNil(result.trace)
        XCTAssertNil(try EVMHistorySwap.classify(transaction: result.transaction, receipt: result.receipt,
            owner: result.transaction["from"].string!, chainID: 11155111, trace: result.trace, pools: result.pools ?? []))
    }
    func testReorganizationDiscardsNewTraceAndPoolEvidence() async throws {
        let evidence = try EVMHistoryTraceTests().fixture()
        let client = try EVMSendClient(network: .ethereumSepolia, endpoints: [URL(string: "https://example.invalid")!],
            transport: ExecutionEvidenceTransport(evidence, mode: .reorg))
        let result = try await client.historyEvidence(hash: evidence.transaction["hash"].string!)
        XCTAssertNil(result.trace)
        XCTAssertNil(result.pools)
        XCTAssertEqual(result.receipt, evidence.receipt)
    }
    func testCompleteTraceAllowsKnownNativeSwapAndCancellationPropagates() async throws {
        let evidence = try EVMHistoryTraceTests().fixture()
        let client = try EVMSendClient(network: .ethereumSepolia, endpoints: [URL(string: "https://example.invalid")!],
            transport: ExecutionEvidenceTransport(evidence, mode: .success))
        let result = try await client.historyEvidence(hash: evidence.transaction["hash"].string!)
        let swap = try XCTUnwrap(EVMHistorySwap.classify(transaction: result.transaction, receipt: result.receipt,
            owner: result.transaction["from"].string!, chainID: 11155111, trace: result.trace, pools: result.pools ?? []))
        XCTAssertEqual(swap.spent, "5000000000000000000")
        let canceled = try EVMSendClient(network: .ethereumSepolia, endpoints: [URL(string: "https://example.invalid")!],
            transport: ExecutionEvidenceTransport(evidence, mode: .canceled))
        do {
            _ = try await canceled.historyEvidence(hash: evidence.transaction["hash"].string!)
            XCTFail("Cancellation must not become empty history")
        } catch is CancellationError { }
    }
}

private actor ExecutionEvidenceTransport: AnkrTransport {
    enum Mode { case success, unavailable, reorg, canceled }
    let evidence: EVMHistoryEvidence, mode: Mode
    var receipts = 0
    init(_ evidence: EVMHistoryEvidence, mode: Mode) { self.evidence = evidence; self.mode = mode }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        if case .canceled = mode { throw CancellationError() }
        let calls = try JSONDecoder().decode(SolanaJSON.self, from: XCTUnwrap(request.httpBody)).array!
        let replies = calls.map { call -> SolanaJSON in
            var result = SolanaJSON.null
            switch call["method"].string {
            case "eth_chainId": result = .string("0xaa36a7")
            case "eth_getTransactionByHash": result = evidence.transaction
            case "eth_getTransactionReceipt":
                receipts += 1; result = evidence.receipt
                if case .reorg = mode, receipts > 1, case .object(var object) = result {
                    object["blockHash"] = .string("0x" + String(repeating: "1", count: 64)); result = .object(object)
                }
            case "debug_traceTransaction":
                if case .unavailable = mode {
                    return .object(["jsonrpc": .string("2.0"), "id": call["id"], "error": .object(["code": .number("-32601"), "message": .string("Method unavailable")])])
                }
                result = evidence.trace!.root
            default: break
            }
            return .object(["jsonrpc": .string("2.0"), "id": call["id"], "result": result])
        }
        return (try JSONEncoder().encode(SolanaJSON.array(replies)), 200)
    }
}
