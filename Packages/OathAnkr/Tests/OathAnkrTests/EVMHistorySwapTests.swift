import XCTest
@testable import OathAnkr

final class EVMHistorySwapTests: XCTestCase {
    let owner = "0x20a1aafc179199ddbc8eaf73f5aec5a8adce6967"
    func fixture(_ name: String = "bnb-usdt-usdc") throws -> EVMHistoryEvidence {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/HistorySwaps"))
        return try JSONDecoder().decode(EVMHistoryEvidence.self, from: Data(contentsOf: url))
    }
    func replacing(_ json: SolanaJSON, _ key: String, _ value: SolanaJSON) -> SolanaJSON {
        guard case .object(var object) = json else { return json }
        object[key] = value; return .object(object)
    }
    func classify(_ e: EVMHistoryEvidence, chain: UInt64 = 56) throws -> EVMHistorySwap? {
        try EVMHistorySwap.classify(transaction: e.transaction, receipt: e.receipt, owner: owner, chainID: chain)
    }
    func testRealBNBReceiptsUseExecutedAmountsNotQuotes() throws {
        for (name,spent,token) in [("bnb-usdt-usdc","100121422443709744075","0x8ac76a51cc950d9822d68b83fe1ad97b32cd580d"),
                                   ("bnb-usdt-dai","100141440409982769392","0x1af3f329e8be154074d8769d1ffa4ee058b1dbc3")] {
            let swap = try XCTUnwrap(classify(fixture(name)))
            XCTAssertEqual(swap.input,"0x55d398326f99059ff775485246999027b3197955")
            XCTAssertEqual(swap.output,token); XCTAssertEqual(swap.spent,spent)
            XCTAssertEqual(swap.received,"100000000000000000000")
        }
    }
    func testReportedBNBExactInputV3SwapWithFrontendAttribution() throws {
        let evidence = try fixture("bnb-usdt-dai-v3-exact-in")
        let params = try JSONSerialization.data(withJSONObject: [["from": owner, "to": evidence.transaction["to"].string!, "data": evidence.transaction["input"].string!, "value": "0x0"]])
        let request = try WalletConnectEVMRequest(params: params, account: owner, chainID: 56)
        let details = WalletConnectCallDetails(history: request)
        XCTAssertTrue(details.isRouter)
        XCTAssertTrue(details.fullyDecoded, "\(details.steps)")
        let swap = try XCTUnwrap(classify(evidence))
        XCTAssertEqual(swap.hash, "0xc839af84c64f4d6481c1b4f97b9d7f587f0269112393e85e8d2fadf0866c73d3")
        XCTAssertEqual(swap.input, "0x55d398326f99059ff775485246999027b3197955")
        XCTAssertEqual(swap.output, "0x1af3f329e8be154074d8769d1ffa4ee058b1dbc3")
        XCTAssertEqual(swap.spent, "50000000000000000000")
        XCTAssertEqual(swap.received, "49951794824533164250")
    }

    func testV3HistoryAcrossRegisteredNetworksKeepsSigningDecoderStrict() throws {
        let evidence = try fixture("bnb-usdt-dai-v3-exact-in")
        let input = try XCTUnwrap(evidence.transaction["input"].string)
        let originalRouter = try XCTUnwrap(evidence.transaction["to"].string)
        let registries = WalletConnectCallDetails.routers.merging(EVMHistorySwap.latestRouters) { $0.union($1) }
        for (chain, routers) in registries {
            for router in routers {
                let tx = replacing(replacing(evidence.transaction, "chainId", .string("0x" + String(chain, radix: 16))), "to", .string(router))
                let logs = try XCTUnwrap(evidence.receipt["logs"].array).map { log in
                    guard log["topics"].array?.first?.string == EVMHistorySwap.v3Topic else { return log }
                    var topics = log["topics"].array!
                    topics[1] = .string("0x" + String(repeating: "0", count: 24) + router.dropFirst(2))
                    return replacing(log, "topics", .array(topics))
                }
                let receipt = replacing(replacing(evidence.receipt, "to", .string(router)), "logs", .array(logs))
                let swap = try XCTUnwrap(classify(.init(transaction: tx, receipt: receipt), chain: chain), "chain \(chain)")
                XCTAssertEqual(swap.spent, "50000000000000000000")
                XCTAssertEqual(swap.received, "49951794824533164250")
                let params = try JSONSerialization.data(withJSONObject: [["from": owner, "to": router, "data": input, "value": "0x0"]])
                let request = try WalletConnectEVMRequest(params: params, account: owner, chainID: chain)
                XCTAssertFalse(WalletConnectCallDetails(request).fullyDecoded, "Signing preview must still reject trailing attribution")
                XCTAssertTrue(WalletConnectCallDetails(history: request).fullyDecoded)
            }
        }
        // A deployment on another network is not an authorization to trust it here.
        let tx = replacing(evidence.transaction, "chainId", .string("0x1"))
        XCTAssertFalse(registries[1]?.contains(originalRouter) == true)
        XCTAssertNil(try classify(.init(transaction: tx, receipt: evidence.receipt), chain: 1))
    }

    func testV3AttributionNeverBypassesRouteOrReceiptChecks() throws {
        let e = try fixture("bnb-usdt-dai-v3-exact-in")
        let input = try XCTUnwrap(e.transaction["input"].string)
        for changed in [input + String(repeating: "00", count: 65),
                        input.replacingOccurrences(of: "1af3f329e8be154074d8769d1ffa4ee058b1dbc3", with: "8ac76a51cc950d9822d68b83fe1ad97b32cd580d")] {
            XCTAssertNil(try classify(.init(transaction: replacing(e.transaction, "input", .string(changed)), receipt: e.receipt)))
        }
        for command: UInt8 in [0x80, 0x40, 0xff] {
            var bytes = try TronIdentity.hex(input)
            bytes[132] = command
            let changed = "0x" + TronSendCrypto.hex(bytes)
            XCTAssertNil(try classify(.init(transaction: replacing(e.transaction, "input", .string(changed)), receipt: e.receipt)))
        }
        for failed in [replacing(e.receipt, "status", .string("0x0")),
                       replacing(e.receipt, "logs", .array(e.receipt["logs"].array!.filter { $0["topics"].array?.first?.string != EVMHistorySwap.v3Topic }))] {
            XCTAssertNil(try classify(.init(transaction: e.transaction, receipt: failed)))
        }
        let stranger = "0x1111111111111111111111111111111111111111"
        XCTAssertNil(try classify(.init(transaction: replacing(e.transaction, "to", .string(stranger)), receipt: replacing(e.receipt, "to", .string(stranger)))))
    }

    func testAdditionalLiveNetworkReceipts() throws {
        let base = try fixture("base-token-usdc")
        let swap = try XCTUnwrap(EVMHistorySwap.classify(transaction:base.transaction,receipt:base.receipt,
            owner:base.transaction["from"].string!,chainID:8453))
        XCTAssertEqual(swap.spent,"480675746097426333696")
        XCTAssertEqual(swap.output,"0x833589fcd6edb6e08f4c7c32d4f71b54bda02913")
        XCTAssertEqual(swap.received,"123550251")
        let eth = try fixture("ethereum-native-output")
        // Native output requires traces: a swap event alone must not invent a received amount.
        XCTAssertNil(try EVMHistorySwap.classify(transaction:eth.transaction,receipt:eth.receipt,
            owner:eth.transaction["from"].string!,chainID:1))
    }
    func testDuplicateLogsAndReversedArrivalAreIdempotent() throws {
        let e = try fixture(), logs = try XCTUnwrap(e.receipt["logs"].array)
        let changed = replacing(e.receipt,"logs",.array(Array(logs.reversed()) + logs))
        XCTAssertEqual(try classify(e), try classify(.init(transaction:e.transaction, receipt:changed)))
        let conflict = replacing(logs[0],"data",.string("0x"+String(repeating:"0",count:64)))
        XCTAssertNil(try classify(.init(transaction:e.transaction, receipt:replacing(e.receipt,"logs",.array(logs+[conflict])))))
    }
    func testRefundNetsExactIntegersAndIntermediateRouteDoesNotBecomeLeg() throws {
        let e = try fixture(); var logs = try XCTUnwrap(e.receipt["logs"].array)
        let debit = try XCTUnwrap(logs.first { $0["address"].string?.lowercased() == "0x55d398326f99059ff775485246999027b3197955" })
        let topics = try XCTUnwrap(debit["topics"].array)
        var refund = replacing(debit,"topics",.array([topics[0],topics[2],topics[1]]))
        refund = replacing(refund,"logIndex",.string("0xffff"))
        refund = replacing(refund,"data",.string("0x"+String(repeating:"0",count:63)+"1"))
        logs.append(refund)
        let swap = try XCTUnwrap(classify(.init(transaction:e.transaction,receipt:replacing(e.receipt,"logs",.array(logs)))))
        XCTAssertEqual(swap.spent,"100121422443709744074")
        // The live fixture itself has pool/router intermediate legs; only owner movements count.
        XCTAssertEqual(swap.received,"100000000000000000000")
    }
    func testFailedUnknownApprovalIncompleteAndReorgStayTransfers() throws {
        let e = try fixture()
        for (key,value) in [("status",SolanaJSON.string("0x0")),("logs",.array([])),("blockHash",.string("0x"+String(repeating:"f",count:64)))] {
            XCTAssertNil(try classify(.init(transaction:e.transaction,receipt:replacing(e.receipt,key,value))))
        }
        for data in ["0x", "0x095ea7b3"+String(repeating:"0",count:128), "0xdeadbeef"] {
            XCTAssertNil(try classify(.init(transaction:replacing(e.transaction,"input",.string(data)),receipt:e.receipt)))
        }
        let logs = try XCTUnwrap(e.receipt["logs"].array)
        let missingOutput = logs.filter { $0["address"].string?.lowercased() != "0x8ac76a51cc950d9822d68b83fe1ad97b32cd580d" }
        XCTAssertNil(try classify(.init(transaction:e.transaction,receipt:replacing(e.receipt,"logs",.array(missingOutput)))))
        XCTAssertNil(try EVMHistorySwap.classify(transaction:e.transaction,receipt:e.receipt,owner:"0x1111111111111111111111111111111111111111",chainID:56))
    }
    func testEveryEVMNetworkKeepsChainIdentityAndCeloAlias() throws {
        let e = try fixture()
        for network in EVMSendNetwork.allCases where !network.isTestnet {
            XCTAssertEqual(try EVMHistorySwap.reference("0x55D398326f99059fF775485246999027B3197955",chainID:network.chainID),"0x55d398326f99059ff775485246999027b3197955")
            if network != .bnb { XCTAssertNil(try classify(e,chain:network.chainID),network.rawValue) }
        }
        let alias = "0x471EcE3750Da237f93B8E339c536989b8978a438"
        XCTAssertEqual(try EVMHistorySwap.reference(alias,chainID:42220),"native")
        XCTAssertEqual(try EVMHistorySwap.reference(alias,chainID:1),alias.lowercased())
    }

    func testEvidenceClientRoutesEverySupportedEVMNetwork() async throws {
        let e = try fixture()
        for network in EVMSendNetwork.allCases {
            let transport = HistoryEvidenceTransport(chainID: network.chainID, evidence: e)
            let client = try EVMSendClient(network: network, endpoints: [URL(string:"https://example.invalid")!], transport: transport)
            let result = try await client.historyEvidence(hash: e.transaction["hash"].string!, includeExecution: false)
            XCTAssertEqual(result.transaction, e.transaction)
            XCTAssertEqual(result.receipt, e.receipt)
            let methods = await transport.methods
            XCTAssertEqual(methods, ["eth_chainId", "eth_getTransactionByHash", "eth_getTransactionReceipt"], network.rawValue)
        }
    }

    func testRegisteredV4NetworksAndCeloGasAlias() throws {
        let e = try fixture()
        for (chain, manager) in EVMHistorySwap.managers {
            let router = try XCTUnwrap(EVMHistorySwap.latestRouters[chain]?.sorted().first)
            var tx = replacing(e.transaction,"chainId",.string("0x"+String(chain,radix:16)))
            tx = replacing(tx,"to",.string(router))
            var receipt = replacing(e.receipt,"to",.string(router))
            var logs = try XCTUnwrap(e.receipt["logs"].array).map { log in
                guard log["topics"].array?.first?.string == EVMHistorySwap.v4Topic else { return log }
                var topics = log["topics"].array!
                topics[2] = .string("0x"+String(repeating:"0",count:24)+router.dropFirst(2))
                return replacing(replacing(log,"address",.string(manager)),"topics",.array(topics))
            }
            if chain == 42220 {
                let debit = try XCTUnwrap(logs.first { $0["topics"].array?.first?.string == EVMHistorySwap.transferTopic })
                let fee = try EVMSendAmount.multiply(AnkrQuantity.decimal(receipt["gasUsed"].string!),AnkrQuantity.decimal(receipt["effectiveGasPrice"].string!))
                var gas = replacing(debit,"address",.string("0x471ece3750da237f93b8e339c536989b8978a438"))
                gas = replacing(gas,"logIndex",.string("0xffff"))
                let feeHex = String(try XCTUnwrap(UInt64(fee)),radix:16)
                gas = replacing(gas,"data",.string("0x"+String(repeating:"0",count:64-feeHex.count)+feeHex))
                logs.append(gas)
            }
            receipt = replacing(receipt,"logs",.array(logs))
            let swap = try XCTUnwrap(classify(.init(transaction:tx,receipt:receipt),chain:chain),"chain \(chain)")
            XCTAssertEqual(swap.received,"100000000000000000000")
            XCTAssertEqual(swap.chainID,chain)
        }
    }

    func testAdditionalUnrelatedAssetAndRemovedLogsRemainTransfers() throws {
        let e = try fixture(); var logs = try XCTUnwrap(e.receipt["logs"].array)
        let output = try XCTUnwrap(logs.first { $0["address"].string?.lowercased() == "0x8ac76a51cc950d9822d68b83fe1ad97b32cd580d" && $0["topics"].array?.last?.string?.suffix(40) == owner.dropFirst(2) })
        let unrelated = replacing(replacing(output,"address",.string("0x1111111111111111111111111111111111111111")),"logIndex",.string("0xffff"))
        XCTAssertNil(try classify(.init(transaction:e.transaction,receipt:replacing(e.receipt,"logs",.array(logs+[unrelated])))))
        logs[0] = replacing(logs[0],"removed",.bool(true))
        XCTAssertNil(try classify(.init(transaction:e.transaction,receipt:replacing(e.receipt,"logs",.array(logs)))))
    }

    func testDecodedV2V3RoutesRequireMatchingAssetsAndRejectOptionalCalls() throws {
        let vectors = WalletConnectCallDetailsTests()
        let e = try fixture(), router = "0x66a9893cc07d91d95644aedd05d03f95e1dba8af"
        var tx = replacing(replacing(e.transaction,"chainId",.string("0x1")),"to",.string(router))
        let logs = try XCTUnwrap(e.receipt["logs"].array).map { log in
            guard log["topics"].array?.first?.string == EVMHistorySwap.v4Topic else { return log }
            return replacing(log,"topics",.array([.string(EVMHistorySwap.v3Topic),
                .string("0x"+String(repeating:"0",count:24)+router.dropFirst(2)),
                .string("0x"+String(repeating:"0",count:24)+owner.dropFirst(2))]))
        }
        let receipt = replacing(replacing(e.receipt,"to",.string(router)),"logs",.array(logs))
        for name in ["v2-exact-in", "v2-exact-out", "v3-exact-in", "v3-exact-out", "optional-nested", "unknown-and-sweep"] {
            let input = try vectors.bytes(name).replacingOccurrences(of: vectors.sender.dropFirst(2),with: owner.dropFirst(2))
                .replacingOccurrences(of:vectors.tokenA.dropFirst(2),with:"55d398326f99059ff775485246999027b3197955")
                .replacingOccurrences(of:vectors.tokenC.dropFirst(2),with:"8ac76a51cc950d9822d68b83fe1ad97b32cd580d")
            tx = replacing(tx,"input",.string(input))
            let swap = try classify(.init(transaction:tx,receipt:receipt),chain:1)
            if name.hasPrefix("v2-") || name.hasPrefix("v3-") {
                XCTAssertNotNil(swap,name)
                XCTAssertEqual(swap?.received,"100000000000000000000")
                let unrelated = input.replacingOccurrences(of:"8ac76a51cc950d9822d68b83fe1ad97b32cd580d",with:"1111111111111111111111111111111111111111")
                XCTAssertNil(try classify(.init(transaction:replacing(tx,"input",.string(unrelated)),receipt:receipt),chain:1))
            } else { XCTAssertNil(swap,name) }
        }
    }
}

private actor HistoryEvidenceTransport: AnkrTransport {
    let chainID: UInt64
    let evidence: EVMHistoryEvidence
    var methods = Set<String>()
    init(chainID: UInt64, evidence: EVMHistoryEvidence) { self.chainID=chainID; self.evidence=evidence }
    func send(_ request: URLRequest) async throws -> (Data,Int) {
        let calls = try JSONDecoder().decode(SolanaJSON.self,from: XCTUnwrap(request.httpBody)).array!
        let replies = calls.map { call -> SolanaJSON in
            let method = call["method"].string!
            methods.insert(method)
            let result: SolanaJSON = method == "eth_chainId" ? .string("0x"+String(chainID,radix:16)) : method == "eth_getTransactionByHash" ? evidence.transaction : evidence.receipt
            return .object(["jsonrpc":.string("2.0"),"id":call["id"],"result":result])
        }
        return (try JSONEncoder().encode(SolanaJSON.array(replies)),200)
    }
}
