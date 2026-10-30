import XCTest
@testable import OathAnkr

final class SeiTests: XCTestCase, @unchecked Sendable {
    private let owner = "0x1111111111111111111111111111111111111111"
    private let token = "0x2222222222222222222222222222222222222222"
    private let transactionHash = "0x" + String(repeating: "a", count: 64)
    private func json(_ object: Any) throws -> SolanaJSON {
        try JSONDecoder().decode(SolanaJSON.self, from: JSONSerialization.data(withJSONObject: object))
    }
    private func page(_ rows: [[String: Any]], more: Bool = false, cursor: String? = nil) throws -> SolanaJSON {
        var pagination: [String: Any] = ["hasMore":more,"offset":0]
        pagination["nextCursor"] = cursor
        return try json(["items":rows,"pagination":pagination])
    }
    private func transfer() -> [String: Any] {
        ["txHash":transactionHash,"height":100,"timestamp":"2026-10-28T12:00:00Z","logIndex":3,
         "from":token,"to":owner,"value":"9007199254740993",
         "token":["hash":token,"tokenType":"erc20","name":"Token","symbol":"TOK","decimals":"6"]]
    }
    func testMainnetIdentityAndExactCoinGeckoPlatform() throws {
        XCTAssertEqual(IndexedEVMChain.sei.chainID, 1329)
        XCTAssertEqual(IndexedEVMChain.sei.rpcPath, "sei_evm")
        XCTAssertEqual(IndexedEVMChain.sei.nativeCoinID, "sei-network")
        XCTAssertEqual(IndexedEVMToken.native(.sei).decimals, 18)
        XCTAssertNil(AnkrChain(networkID: "sei"))
        let data = try JSONSerialization.data(withJSONObject: [["id":"exact", "platforms":["sei-v2":token]], ["id":"wrong","platforms":["sei":token]]])
        XCTAssertEqual(try IndexedEVMMarkets.decodeCatalog(data, chain: .sei).ids, [token:"exact"])
    }
    func testTransferNormalizationPreservesLogIdentityAndExactUnits() throws {
        let normalized = try SeiIndex.normalize(page([transfer()], more: true, cursor: "100:next"), resource: "token-transfers")
        let decoded = try IndexedEVMClient.decodeHistory(JSONEncoder().encode(normalized), chain: .sei, owner: owner, stream: .transfers, through: 2_000_000_000)
        XCTAssertEqual(decoded.events.first?.amount,"9007199254740993")
        XCTAssertEqual(decoded.events.first?.id,transactionHash + ":log:3")
        XCTAssertEqual(decoded.events.first?.token?.decimals,6)
        XCTAssertNotNil(decoded.next)
        XCTAssertThrowsError(try IndexedEVMClient.decodeHistory(JSONEncoder().encode(normalized), chain: .sei, owner: "0x3333333333333333333333333333333333333333", stream: .transfers, through: 2_000_000_000))
    }
    func testNFTsAreNotFungibleTokensAndMissingPaginationIsNotComplete() throws {
        let normalized = try SeiIndex.normalize(page([["token":["tokenType":"erc721"]]]), resource:"tokens")
        XCTAssertEqual(normalized["items"].array?.count,0)
        XCTAssertThrowsError(try SeiIndex.normalize(json(["items":[]]), resource:"tokens"))
        XCTAssertThrowsError(try SeiIndex.normalize(page([],more:true), resource:"tokens"))
        XCTAssertThrowsError(try SeiIndex.parameters(["offset":.number("100001")]))
        XCTAssertThrowsError(try SeiIndex.parameters(["apikey":.string("untrusted")]))
    }
    func testOffsetPaginationAndRelativeLogoResolution() throws {
        let metadata: [String:Any] = ["tokenType":"erc20","hash":token,"decimals":"6","image":"/api/v2/icons/erc20/token.png"]
        let normalized = try SeiIndex.normalize(page([["token":metadata]],more:true),resource:"tokens")
        XCTAssertEqual(normalized["next_page_params"]["offset"].text,"1")
        XCTAssertEqual(normalized["items"].array?.first?["token"]["icon_url"].string,"https://api-v2.seistream.app/api/v2/icons/erc20/token.png")
    }
    func testInternalRootsDelegateCallsAndRevertedParents() throws {
        func row(_ index:Int,_ type:String) -> [String:Any] {
            ["txHash":transactionHash,"height":100,"timestamp":"2026-10-28T12:00:00Z","index":index,"parentIndex":NSNull(),"callType":type,"from":token,"to":owner,"value":"12"]
        }
        let normalized = try SeiIndex.normalize(page([row(0,"CALL"),row(1,"DELEGATECALL"),row(2,"CALL")]), resource:"internal-transactions")
        let event = try XCTUnwrap(normalized["items"].array?.first)
        XCTAssertEqual(normalized["items"].array?.count,1)
        func trace(_ path:[Int],error:String? = nil) -> [String:Any] {
            var t: [String:Any] = ["traceAddress":path,"type":"call","transactionHash":transactionHash,
                "action":["callType":"call","from":token,"to":owner,"value":"0xc"]]
            t["error"] = error;return t
        }
        XCTAssertTrue(try SeiIndex.corroborateInternal(event,traces:json([trace([]),trace([0]),trace([0,0])])))
        XCTAssertFalse(try SeiIndex.corroborateInternal(event,traces:json([trace([]),trace([0],error:"reverted"),trace([0,0])])))
        XCTAssertThrowsError(try SeiIndex.corroborateInternal(event,traces:json([trace([]),trace([0]),trace([1,0])])))
    }
    func testInactiveOrWrongNetworkDEXQuotesAreRejected() throws {
        func pair(_ network:String,_ volume:Int) -> [String:Any] {
            ["chainId":network,"baseToken":["address":token],"priceUsd":"0.2","liquidity":["usd":20000],"volume":["h24":volume]]
        }
        let bad = try JSONSerialization.data(withJSONObject:[pair("sei",10000),pair("seiv2",35)])
        XCTAssertTrue(try IndexedEVMMarkets.decodeDEX(bad, chain:.sei, references:[token]).isEmpty)
        let good = try JSONSerialization.data(withJSONObject:[pair("seiv2",12000)])
        XCTAssertEqual(try IndexedEVMMarkets.decodeDEX(good, chain:.sei, references:[token]).first?.usd,"0.2")
    }
}

private actor SeiCreationTransport: AnkrTransport {
    let badRecipient: Bool
    let primaryMissing: Bool
    let archiveOnly: Bool
    var fallbackCalls = 0
    init(badRecipient: Bool = false, primaryMissing: Bool = true, archiveOnly: Bool = false) { self.badRecipient = badRecipient; self.primaryMissing = primaryMissing; self.archiveOnly = archiveOnly }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let owner = "0x1111111111111111111111111111111111111111", contract = "0x2222222222222222222222222222222222222222"
        let hash = "0x" + String(repeating:"a",count:64), block = "0x" + String(repeating:"b",count:64)
        if request.url?.host == "api-v2.seistream.app" {
            return (try JSONSerialization.data(withJSONObject:["items":[["hash":hash,"height":100,"blockHash":block,
                "from":owner,"to":NSNull(),"contractAddress":contract,"status":true,"timestamp":"2026-10-28T12:00:00Z","value":"123"]],
                "pagination":["hasMore":false]]),200)
        }
        let primary = request.url?.host == "rpc.ankr.com"
        if !primary { XCTAssertTrue(["evm-rpc.sei-apis.com", "sei-mainnet.g.alchemy.com"].contains(request.url?.host)); fallbackCalls += 1 }
        var receipt: [String:Any] = ["transactionHash":hash,"blockHash":block,"blockNumber":"0x64","from":owner,
            "contractAddress":contract,"status":"0x1","gasUsed":"0x5208","effectiveGasPrice":"0x3b9aca00","logs":[]]
        if badRecipient { receipt["to"] = owner }
        let tx: [String:Any] = ["hash":hash,"blockHash":block,"from":owner,"to":NSNull(),"value":"0x7b"]
        let calls = try XCTUnwrap(JSONSerialization.jsonObject(with:XCTUnwrap(request.httpBody)) as? [[String:Any]])
        let replies = calls.map { call -> [String:Any] in
            if archiveOnly, request.url?.host == "evm-rpc.sei-apis.com", call["method"] as? String == "eth_getTransactionReceipt" {
                return ["jsonrpc":"2.0","id":call["id"]!,"error":["code":-32603,"message":"method handler crashed"]]
            }
            let result: Any
            switch call["method"] as? String {
            case "eth_chainId": result = "0x531"
            case "eth_getTransactionReceipt": result = primary && primaryMissing ? NSNull() : receipt
            case "eth_getTransactionByHash": result = primary && primaryMissing ? NSNull() : tx
            default: result = NSNull()
            }
            return ["jsonrpc":"2.0","id":call["id"]!,"result":result]
        }
        return (try JSONSerialization.data(withJSONObject:replies),200)
    }
}
extension SeiTests {
    func testMissingAnkrHistoryFallsBackAndAcceptsSeiCreationReceipt() async throws {
        let transport = SeiCreationTransport()
        let page = try await IndexedEVMClient(chain:.sei,apiKey:"fixture",transport:transport).history(owner:owner,stream:.transactions,through:2_000_000_000)
        XCTAssertEqual(page.events.first?.to,token)
        XCTAssertEqual(page.events.first?.amount,"123")
        XCTAssertEqual(page.events.first?.fee,"21000000000000")
        let count = await transport.fallbackCalls; XCTAssertEqual(count,1)
    }
    func testPrunedPublicNodeUsesConfiguredArchiveAndRetainsVerification() async throws {
        let transport = SeiCreationTransport(archiveOnly:true)
        let page = try await IndexedEVMClient(chain:.sei,apiKey:"fixture",alchemyAPIKey:"archiveFixture",transport:transport)
            .history(owner:owner,stream:.transactions,through:2_000_000_000)
        XCTAssertEqual(page.events.first?.amount,"123")
        let count = await transport.fallbackCalls; XCTAssertEqual(count,2)
        XCTAssertFalse(String(decoding:page.raw,as:UTF8.self).contains("archiveFixture"))
    }
    func testMissingArchiveNeverMarksUnavailableHistoryComplete() async throws {
        let transport = SeiCreationTransport(archiveOnly:true)
        do {
            _ = try await IndexedEVMClient(chain:.sei,apiKey:"fixture",transport:transport)
                .history(owner:owner,stream:.transactions,through:2_000_000_000)
            XCTFail("Unavailable history must retain an incomplete cursor")
        } catch { XCTAssertEqual(error as? AnkrError,.rpc(-32603)) }
    }
    func testContradictoryCreationRecipientIsRejectedWithoutFailover() async throws {
        let transport = SeiCreationTransport(badRecipient:true,primaryMissing:false)
        do {
            _ = try await IndexedEVMClient(chain:.sei,apiKey:"fixture",transport:transport).history(owner:owner,stream:.transactions,through:2_000_000_000)
            XCTFail("A contradictory receipt must not enter history")
        } catch { XCTAssertEqual(error as? AnkrError,.invalidResponse) }
        let count = await transport.fallbackCalls; XCTAssertEqual(count,0)
    }
}
