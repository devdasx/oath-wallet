import XCTest
@testable import OathAnkr

final class EVMHistoryBridgeTests: XCTestCase {
    let owner = "0x20a1aafc179199ddbc8eaf73f5aec5a8adce6967"
    func fixture(_ name: String) throws -> EVMHistoryEvidence {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/HistoryBridges"))
        return try JSONDecoder().decode(EVMHistoryEvidence.self, from: Data(contentsOf: url))
    }
    func classify(_ name: String, chain: UInt64) throws -> EVMHistoryBridge? {
        try EVMHistoryBridge.classify(fixture(name), owner: owner, chainID: chain)
    }
    func testAllFourReportedReceipts() throws {
        for (name,chain,direction,provider) in [("bsc",UInt64(56),"outgoing","Relay"),
             ("robinhood_mainnet",4663,"incoming","Relay"),("optimism",10,"incoming","Across"),("arbitrum",42161,"incoming","Across")] {
            let bridge = try XCTUnwrap(classify(name,chain:chain), name)
            XCTAssertEqual(bridge.direction,direction); XCTAssertEqual(bridge.protocolName,provider)
            XCTAssertNotEqual(bridge.amount,"0")
        }
        XCTAssertEqual(try classify("bsc",chain:56)?.amount,"100000000000000000000")
    }
    func testAcrossMatchesProtocolIdentityNotDifferentSourceAssetOrQuote() throws {
        let source = try XCTUnwrap(classify("optimism-source",chain:56))
        let destination = try XCTUnwrap(classify("optimism",chain:10))
        XCTAssertEqual(source.key,destination.key)
        XCTAssertEqual(source.asset,"0x55d398326f99059ff775485246999027b3197955")
        XCTAssertEqual(source.amount,"100000000000000000000")
        XCTAssertEqual(destination.asset,"0x0b2c639c533813f4aa9d7837caf62653d097ff85")
        XCTAssertEqual(destination.amount,"99009481")
    }
    func testRelayOriginalRequestPairsBNBWithRobinhoodActualUSDe() throws {
        let source = try XCTUnwrap(classify("bsc", chain: 56))
        let fill = try XCTUnwrap(classify("robinhood_mainnet", chain: 4663))
        XCTAssertEqual(source.key, fill.key)
        XCTAssertEqual(fill.key, "relay:0xeaa8cc029e8c9ae1db6f4d8d23a8dca655f3e31d4d6748e3bab5fd4a35438fa4")
        XCTAssertEqual(fill.asset, "0x5d3a1ff2b6bab83b63cd9ad0787074081a52ef34")
        XCTAssertEqual(fill.amount, "98864689267516090857")
        let signature = "permit2TransferAndMulticall(address,((address,uint256)[],uint256,uint256),(address,bool,uint256,bytes)[],address,address,bytes,bytes)"
        XCTAssertEqual(TronSendCrypto.hex(TronSendCrypto.keccak(Data(signature.utf8))).prefix(8), "0a2b8f36")
    }
    func testRelayFillRejectsMissingTrailerMalformedABIAndDifferentRecipient() throws {
        let e = try fixture("robinhood_mainnet")
        let original = try XCTUnwrap(e.transaction["input"].string)
        func word(_ index: Int, _ value: String) -> String {
            var bytes = Array(original)
            let replacement = Array(String(repeating: "0", count: 64-value.count) + value)
            bytes.replaceSubrange((10+index*64)..<(10+(index+1)*64), with: replacement)
            return String(bytes)
        }
        for input in [String(original.dropLast(64)), original + String(repeating:"0",count:64),
                      word(1,"ff"), word(2,"ffffffff"), word(3,"1"), word(4,"1"),
                      word(5,"e0"), word(6,"e0"), word(10,"ffffffff"),
                      String(original.dropLast(64)) + String(repeating:"0",count:64)] {
            XCTAssertNil(try EVMHistoryBridge.classify(.init(transaction: replacing(e.transaction,"input",.string(input)),receipt:e.receipt),owner:owner,chainID:4663))
        }
    }
    func replacing(_ json: SolanaJSON,_ key: String,_ value: SolanaJSON) -> SolanaJSON {
        guard case .object(var object) = json else { return json }; object[key]=value;return .object(object)
    }
    func testFailureReorgOwnerAndUnsupportedNetwork() throws {
        let e = try fixture("optimism")
        for (key,value) in [("status",SolanaJSON.string("0x0")),("blockHash",.string("0x"+String(repeating:"f",count:64))),("logs",.array([]))] {
            XCTAssertNil(try EVMHistoryBridge.classify(.init(transaction:e.transaction,receipt:replacing(e.receipt,key,value)),owner:owner,chainID:10))
        }
        XCTAssertNil(try EVMHistoryBridge.classify(e,owner:"0x1111111111111111111111111111111111111111",chainID:10))
        for network in EVMSendNetwork.allCases where !network.isTestnet && network.chainID != 10 {
            XCTAssertNil(try EVMHistoryBridge.classify(e,owner:owner,chainID:network.chainID))
        }
    }
    func testDuplicateLogsAndForgedProtocolEmitter() throws {
        let e = try fixture("optimism"), logs = try XCTUnwrap(e.receipt["logs"].array)
        let duplicate = replacing(e.receipt,"logs",.array(Array(logs.reversed())+logs))
        XCTAssertEqual(try EVMHistoryBridge.classify(e,owner:owner,chainID:10),try EVMHistoryBridge.classify(.init(transaction:e.transaction,receipt:duplicate),owner:owner,chainID:10))
        let forged = logs.map { log in log["address"].string?.lowercased() == EVMHistoryBridge.spokes[10] ? replacing(log,"address",.string("0x1111111111111111111111111111111111111111")) : log }
        XCTAssertNil(try EVMHistoryBridge.classify(.init(transaction:e.transaction,receipt:replacing(e.receipt,"logs",.array(forged))),owner:owner,chainID:10))
    }
    func testRelayedSourceRequiresSuccessfulOwnerOperation() throws {
        let e = try fixture("bsc"), logs = try XCTUnwrap(e.receipt["logs"].array)
        let withoutOperation = logs.filter { $0["topics"].array?.first?.string != "0x49628fd1471006c1482da88028e9ce4dbb080b815c9b0344d39e5a8e6ec1419f" }
        XCTAssertNil(try EVMHistoryBridge.classify(.init(transaction:e.transaction,receipt:replacing(e.receipt,"logs",.array(withoutOperation))),owner:owner,chainID:56))
    }

    func testNativeRelayDepositNetsRefundAndRejectsTokenBridgeFee() throws {
        let e = try fixture("bsc")
        let deposit = "0x4cd00e387622c35bddb9b4c962c136462338bc31"
        let logs = e.receipt["logs"].array!.filter { log in
            guard log["topics"].array?.first?.string == EVMHistorySwap.transferTopic else { return true }
            return !log["topics"].array!.dropFirst().contains { $0.string?.suffix(40) == owner.dropFirst(2) }
        }
        let helper = EVMHistoryTraceTests()
        let root: SolanaJSON = .object([
            "type": .string("CALL"), "from": e.transaction["from"], "to": e.transaction["to"],
            "input": e.transaction["input"], "value": e.transaction["value"],
            "calls": .array([helper.frame(owner, deposit, "0x64"), helper.frame(deposit, owner, "0x14")])])
        let trace = EVMHistoryTrace(chainID: 56, transactionHash: e.transaction["hash"].string!, blockHash: e.receipt["blockHash"].string!, root: root)
        // An owner's native fee is not evidence that the token deposit was native.
        XCTAssertNil(try EVMHistoryBridge.classify(.init(transaction: e.transaction,
            receipt: replacing(e.receipt, "logs", .array(logs)), trace: trace), owner: owner, chainID: 56))
        let nativeLogs = logs.map { log -> SolanaJSON in
            guard log["topics"].array?.first?.string == EVMHistoryBridge.relayDeposit else { return log }
            let words = Array(log["data"].string!.dropFirst(2))
            var data = words
            data.replaceSubrange(64..<128, with: String(repeating: "0", count: 64))
            data.replaceSubrange(128..<192, with: String(repeating: "0", count: 62) + "50")
            return replacing(log, "data", .string("0x" + String(data)))
        }
        let proof = try XCTUnwrap(EVMHistoryBridge.classify(.init(transaction: e.transaction,
            receipt: replacing(e.receipt, "logs", .array(nativeLogs)), trace: trace), owner: owner, chainID: 56))
        XCTAssertEqual(proof.asset, "native"); XCTAssertEqual(proof.amount, "80")
        XCTAssertEqual(proof.direction, "outgoing")
        XCTAssertNil(try EVMHistoryBridge.classify(.init(transaction: e.transaction,
            receipt: replacing(e.receipt, "logs", .array(nativeLogs))), owner: owner, chainID: 56))
    }

    func testNativeAcrossFillRequiresExactExecutedPayout() throws {
        let e = try fixture("optimism"), helper = EVMHistoryTraceTests()
        let amount = "99009481", wrapped = "4200000000000000000000000000000000000006"
        let logs = e.receipt["logs"].array!.filter { log in
            guard log["topics"].array?.first?.string == EVMHistorySwap.transferTopic else { return true }
            return !log["topics"].array!.dropFirst().contains { $0.string?.suffix(40) == owner.dropFirst(2) }
        }.map { log -> SolanaJSON in
            guard log["topics"].array?.first?.string == EVMHistoryBridge.filled else { return log }
            var data = Array(log["data"].string!.dropFirst(2))
            data.replaceSubrange(64..<128, with: String(repeating: "0", count: 24) + wrapped)
            return replacing(log, "data", .string("0x" + String(data)))
        }
        let receipt = replacing(e.receipt, "logs", .array(logs))
        let root: SolanaJSON = .object(["type": .string("CALL"), "from": e.transaction["from"], "to": e.transaction["to"],
            "input": e.transaction["input"], "value": e.transaction["value"],
            "calls": .array([helper.frame(EVMHistoryBridge.spokes[10]!, owner, "0x" + String(UInt64(amount)!, radix: 16))])])
        let trace = EVMHistoryTrace(chainID: 10, transactionHash: e.transaction["hash"].string!, blockHash: e.receipt["blockHash"].string!, root: root)
        let result = try XCTUnwrap(EVMHistoryBridge.classify(.init(transaction: e.transaction, receipt: receipt, trace: trace), owner: owner, chainID: 10))
        XCTAssertEqual(result.asset, "native"); XCTAssertEqual(result.amount, amount)
        XCTAssertEqual(result.direction, "incoming")
        XCTAssertNil(try EVMHistoryBridge.classify(.init(transaction: e.transaction, receipt: receipt), owner: owner, chainID: 10))
        let wrongRoot = replacing(root, "calls", .array([helper.frame(EVMHistoryBridge.spokes[10]!, owner, "0x1")]))
        let wrong = EVMHistoryTrace(chainID: 10, transactionHash: e.transaction["hash"].string!, blockHash: e.receipt["blockHash"].string!, root: wrongRoot)
        XCTAssertNil(try EVMHistoryBridge.classify(.init(transaction: e.transaction, receipt: receipt, trace: wrong), owner: owner, chainID: 10))
    }

}
