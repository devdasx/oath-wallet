import XCTest
@testable import OathAnkr

final class EVMHistoryContractCallTests: XCTestCase {
    let owner = "0x1111111111111111111111111111111111111111"
    let token = "0x2222222222222222222222222222222222222222"
    let spender = "0x3333333333333333333333333333333333333333"
    let transactionHash = "0x" + String(repeating: "a", count: 64)
    let block = "0x" + String(repeating: "b", count: 64)
    func word(_ address: String) -> String { String(repeating: "0", count: 24) + address.dropFirst(2) }
    func evidence(_ input: String, chain: UInt64 = 56) -> (SolanaJSON, SolanaJSON) {
        (.object(["hash": .string(transactionHash), "blockHash": .string(block), "from": .string(owner),
                  "to": .string(token), "value": .string("0x0"), "input": .string(input),
                  "chainId": .string("0x" + String(chain, radix: 16))]),
         .object(["transactionHash": .string(transactionHash), "blockHash": .string(block), "from": .string(owner),
                  "to": .string(token), "status": .string("0x1"), "logs": .array([])]))
    }
    func replacing(_ json: SolanaJSON, _ key: String, _ value: SolanaJSON) -> SolanaJSON {
        guard case .object(var object) = json else { return json }
        object[key] = value; return .object(object)
    }
    func classify(_ e: (SolanaJSON, SolanaJSON), chain: UInt64 = 56) throws -> EVMHistoryContractCall? {
        try EVMHistoryContractCall.classify(transaction: e.0, receipt: e.1, owner: owner, chainID: chain)
    }
    func testApprovalAndInteractionAcrossEveryEVMNetwork() throws {
        for network in EVMSendNetwork.allCases {
            let e = evidence("0x095ea7b3" + word(spender) + String(repeating: "f", count: 64), chain: network.chainID)
            XCTAssertEqual(try classify(e, chain: network.chainID), .approval, network.rawValue)
            let call = evidence("0xdeadbeef", chain: network.chainID)
            XCTAssertEqual(try classify(call, chain: network.chainID), .contractInteraction, network.rawValue)
        }
    }
    func testZeroAllowanceRequiresERC20EvidenceAndIgnoresRemovedLogs() throws {
        let e = evidence("0x095ea7b3" + word(spender) + String(repeating: "0", count: 64))
        XCTAssertEqual(try classify(e), .approval) // NFT token ID zero is not proof of revocation.
        let topic = "0x" + TronSendCrypto.hex(TronSendCrypto.keccak(Data("Approval(address,address,uint256)".utf8)))
        let log: SolanaJSON = .object(["address": .string(token), "transactionHash": .string(transactionHash),
            "blockHash": .string(block), "topics": .array([.string(topic), .string("0x" + word(owner)), .string("0x" + word(spender))]),
            "data": .string("0x" + String(repeating: "0", count: 64))])
        XCTAssertEqual(try classify((e.0, replacing(e.1, "logs", .array([log])))), .approvalRemoval)
        XCTAssertEqual(try classify((e.0, replacing(e.1, "logs", .array([replacing(log,"removed",.bool(true))])))), .approval)
    }
    func testOperatorApprovalAndRemoval() throws {
        for (value, expected) in [("0", EVMHistoryContractCall.approvalRemoval), ("1", .approval)] {
            XCTAssertEqual(try classify(evidence("0xa22cb465" + word(spender) + String(repeating: "0", count: 63) + value)), expected)
        }
    }
    func testRejectsTransfersAndMismatchedEvidence() throws {
        let e = evidence("0xdeadbeef")
        for (key, value) in [("value", "0x1"), ("input", "0x"), ("from", spender), ("chainId", "0x1")] {
            XCTAssertNil(try classify((replacing(e.0,key,.string(value)),e.1)))
        }
        for (key, value) in [("transactionHash", block), ("blockHash", transactionHash), ("from", spender), ("to", spender), ("status", "0x2")] {
            XCTAssertNil(try classify((e.0,replacing(e.1,key,.string(value)))))
        }
        XCTAssertEqual(try classify((e.0,replacing(e.1,"status",.string("0x0")))), .contractInteraction)
    }
}
