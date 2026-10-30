import XCTest
@testable import OathAnkr

final class EVMHistoryCCTPTests: XCTestCase {
    func fixture() throws -> EVMHistoryEvidence { try EVMHistoryBridgeTests().fixture("sepolia-cctp-source") }
    func testRealSepoliaCCTPBurnUsesDomainNonceAndExecutedAmount() throws {
        let e = try fixture(), owner = e.transaction["from"].string!
        let bridge = try XCTUnwrap(EVMHistoryBridge.classify(e, owner: owner, chainID: 11155111))
        XCTAssertEqual(bridge.key, "cctp1:test:0:7:619672")
        XCTAssertEqual(bridge.asset, "0x1c7d4b196cb0c7b01d743fbc6116a902379c7238")
        XCTAssertEqual(bridge.amount, "100000000")
        XCTAssertEqual(bridge.direction, "outgoing")
    }
    func testLiveSepoliaAmoyPairUsesSameIdentityAndActualMint() throws {
        let helper = EVMHistoryBridgeTests()
        let source = try helper.fixture("sepolia-cctp-paired-source")
        let destination = try helper.fixture("amoy-cctp-destination")
        let owner = source.transaction["from"].string!
        let burn = try XCTUnwrap(EVMHistoryBridge.classify(source, owner: owner, chainID: 11155111))
        let mint = try XCTUnwrap(EVMHistoryBridge.classify(destination, owner: owner, chainID: 80002))
        XCTAssertEqual(burn.key, mint.key)
        XCTAssertEqual(burn.key, "cctp1:test:0:7:619673")
        XCTAssertEqual(mint.direction, "incoming")
        XCTAssertEqual(burn.amount, "357000000")
        XCTAssertEqual(mint.amount, "357000000")
    }
    func testWrongChainForgedEmitterDifferentRecipientAndFailedReceiptRemainTransfers() throws {
        let e = try fixture(), owner = e.transaction["from"].string!, helper = EVMHistoryBridgeTests()
        XCTAssertNil(try EVMHistoryBridge.classify(e, owner: owner, chainID: 1))
        XCTAssertNil(try EVMHistoryBridge.classify(.init(transaction: e.transaction,
            receipt: helper.replacing(e.receipt, "status", .string("0x0"))), owner: owner, chainID: 11155111))
        let logs = e.receipt["logs"].array!
        for change in ["emitter", "recipient", "nonce"] {
            let modified = logs.map { log -> SolanaJSON in
                guard log["topics"].array?.first?.string == EVMHistoryCCTP.deposit else { return log }
                if change == "emitter" { return helper.replacing(log, "address", .string(owner)) }
                if change == "nonce" {
                    var topics = log["topics"].array!; topics[1] = .string("0x" + String(repeating: "f", count: 64))
                    return helper.replacing(log, "topics", .array(topics))
                }
                var data = Array(log["data"].string!); data.replaceSubrange(66..<130, with: String(repeating: "0", count: 64))
                return helper.replacing(log, "data", .string(String(data)))
            }
            XCTAssertNil(try EVMHistoryBridge.classify(.init(transaction: e.transaction,
                receipt: helper.replacing(e.receipt, "logs", .array(modified))), owner: owner, chainID: 11155111), change)
        }
    }
}
