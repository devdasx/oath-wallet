import XCTest
@testable import OathAnkr

final class EVMHistoryTraceTests: XCTestCase {
    func fixture() throws -> EVMHistoryEvidence {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "sepolia-native-usdc", withExtension: "json", subdirectory: "Fixtures/HistorySwaps"))
        return try JSONDecoder().decode(EVMHistoryEvidence.self, from: Data(contentsOf: url))
    }
    func testLiveSepoliaNativeInputUsesTraceAndDoesNotDoubleCountSystemLogs() throws {
        let e = try fixture()
        let owner = try XCTUnwrap(e.transaction["from"].string)
        XCTAssertNil(try EVMHistorySwap.classify(transaction: e.transaction, receipt: e.receipt, owner: owner, chainID: 11155111))
        let swap = try XCTUnwrap(EVMHistorySwap.classify(transaction: e.transaction, receipt: e.receipt,
            owner: owner, chainID: 11155111, trace: e.trace))
        XCTAssertEqual(swap.input, "native")
        XCTAssertEqual(swap.spent, "5000000000000000000")
        XCTAssertEqual(swap.output, "0x1c7d4b196cb0c7b01d743fbc6116a902379c7238")
        XCTAssertEqual(swap.received, "207044607346")
    }
    func replacing(_ json: SolanaJSON, _ key: String, _ value: SolanaJSON) -> SolanaJSON {
        guard case .object(var fields) = json else { return json }
        fields[key] = value; return .object(fields)
    }
    func frame(_ from: String, _ to: String, _ value: String, kind: String = "CALL") -> SolanaJSON {
        .object(["from": .string(from), "to": .string(to), "value": .string(value), "type": .string(kind)])
    }
    func trace(_ e: EVMHistoryEvidence, root: SolanaJSON, chain: UInt64 = 11155111, block: String? = nil) -> EVMHistoryTrace {
        .init(chainID: chain, transactionHash: e.transaction["hash"].string!, blockHash: block ?? e.receipt["blockHash"].string!, root: root)
    }
    func testRefundsRevertedSubtreesAndDelegateValuesAreNotDoubleCounted() throws {
        let e = try fixture(), root = try XCTUnwrap(e.trace?.root)
        let owner = e.transaction["from"].string!, router = e.transaction["to"].string!
        let refund = frame(router, owner, "0xde0b6b3a7640000")
        let reverted = replacing(replacing(frame(router, owner, "0xde0b6b3a7640000"), "error", .string("execution reverted")), "calls", .array([refund]))
        let delegate = frame(router, owner, "0xde0b6b3a7640000", kind: "DELEGATECALL")
        let changed = replacing(root, "calls", .array((root["calls"].array ?? []) + [refund, reverted, delegate]))
        let swap = try XCTUnwrap(EVMHistorySwap.classify(transaction: e.transaction, receipt: e.receipt,
            owner: owner, chainID: 11155111, trace: trace(e, root: changed)))
        XCTAssertEqual(swap.spent, "4000000000000000000")
        XCTAssertEqual(swap.received, "207044607346")
    }
    func testUnboundFailedMalformedOrExcessivelyDeepTraceCannotClassifyNative() throws {
        let e = try fixture(), root = try XCTUnwrap(e.trace?.root), owner = e.transaction["from"].string!
        var deep = frame(owner, owner, "0x0")
        for _ in 0..<66 { deep = replacing(frame(owner, owner, "0x0"), "calls", .array([deep])) }
        for invalid in [replacing(root, "from", .string("0x" + String(repeating: "1", count: 40))),
                        replacing(root, "value", .string("0x0")), replacing(root, "input", .string("0x")),
                        replacing(root, "error", .string("execution reverted")), replacing(root, "calls", .string("truncated")),
                        replacing(root, "calls", .array([deep])), replacing(root, "calls", .array([.object(["type": .string("CALL")])]))] {
            XCTAssertNil(try EVMHistorySwap.classify(transaction: e.transaction, receipt: e.receipt,
                owner: owner, chainID: 11155111, trace: trace(e, root: invalid)))
        }
        for bad in [trace(e, root: root, chain: 1), trace(e, root: root, block: "0x" + String(repeating: "0", count: 64))] {
            XCTAssertNil(try EVMHistorySwap.classify(transaction: e.transaction, receipt: e.receipt,
                owner: owner, chainID: 11155111, trace: bad))
        }
    }

}
