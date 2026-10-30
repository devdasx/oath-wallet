import XCTest
@testable import OathAnkr

final class ZeroGTests: XCTestCase {
    private let owner = "0x1111111111111111111111111111111111111111"
    private let other = "0x2222222222222222222222222222222222222222"
    private let transactionHash = "0x" + String(repeating: "a", count: 64)
    private func json(_ object: Any) throws -> SolanaJSON {
        try JSONDecoder().decode(SolanaJSON.self, from: JSONSerialization.data(withJSONObject: object))
    }
    private func row(_ height: Int = 100, _ index: Int = 1) -> [String: Any] {
        ["hash":transactionHash,"transactionHash":transactionHash,"epochNumber":height,"timestamp":1700000000,"from":owner,"to":other,
         "value":"9007199254740993","status":0,"blockHash":"0","type":"call","txLogIndex":index]
    }
    func testIdentityAndExactContractPlatform() throws {
        XCTAssertEqual(IndexedEVMChain.zerog.chainID,16661)
        XCTAssertEqual(IndexedEVMChain.zerog.rpcPath,"0g_mainnet_evm")
        XCTAssertEqual(IndexedEVMToken.native(.zerog).symbol,"0G")
        XCTAssertEqual(IndexedEVMToken.native(.zerog).decimals,18)
        XCTAssertEqual(IndexedEVMChain.zerog.nativeCoinID,"zero-gravity")
        XCTAssertNil(AnkrChain(networkID:"zerog"))
        let data = try JSONSerialization.data(withJSONObject:[["id":"correct","platforms":["0g":owner]],["id":"testnet","platforms":["a0gi":owner]]])
        XCTAssertEqual(try IndexedEVMMarkets.decodeCatalog(data,chain:.zerog).ids,[owner:"correct"])
    }
    func testInventoryRejectsTruncationAndFiltersNFTs() throws {
        let token: [String:Any] = ["address":owner,"transferType":"ERC20","decimals":18,"name":"One","symbol":"ONE"]
        let nft: [String:Any] = ["address":other,"transferType":"ERC721"]
        let response = try json(["status":"1","result":["list":[token,nft],"total":2]])
        XCTAssertEqual(try ZeroGIndex.inventory(response)["items"].array?.count,1)
        XCTAssertThrowsError(try ZeroGIndex.inventory(json(["status":"1","result":["list":[token],"total":2]])))
        XCTAssertThrowsError(try ZeroGIndex.inventory(json(["status":"0","result":["list":[],"total":0]])))
    }
    func testPaginationKeepsEveryEntryAtTheBlockBoundary() throws {
        var rows = Array(repeating:row(101),count:45) + Array(repeating:row(100),count:5)
        let first = try ZeroGIndex.history(json(["status":"1","result":["list":rows,"total":10000]]),stream:.transactions,cursor:[:])
        guard case .object(let cursor) = first["next_page_params"] else { return XCTFail() }
        XCTAssertEqual(cursor["height"]?.text,"100"); XCTAssertEqual(cursor["skip"]?.text,"5")
        rows = Array(repeating:row(100),count:50)
        let second = try ZeroGIndex.history(json(["status":"1","result":["list":rows,"total":10000]]),stream:.transactions,cursor:cursor)
        XCTAssertEqual(second["next_page_params"]["skip"].text,"55")
        let query = try ZeroGIndex.query(owner:owner,stream:.transfers,cursor:cursor,from:0,through:1700000000)
        XCTAssertEqual(query.first{$0.name == "maxEpochNumber"}?.value,"100")
        XCTAssertEqual(query.first{$0.name == "maxTimestamp"}?.value,"1700000000")
        XCTAssertThrowsError(try ZeroGIndex.query(owner:owner,stream:.transfers,cursor:["skip":.number("2")],from:0,through:1))
        XCTAssertThrowsError(try ZeroGIndex.history(json(["status":"1","result":["list":[row(100),row(101)],"total":2]]),stream:.transactions,cursor:[:]))
    }
    func testNativeRootExcludedAndTransactionSuccessNotInverted() throws {
        let data = try json(["status":"1","result":["list":[row(100,0),row(100,10)],"total":2]])
        let internalPage = try ZeroGIndex.history(data,stream:.internalTransactions,cursor:[:])
        XCTAssertEqual(internalPage["items"].array?.count,1)
        XCTAssertEqual(internalPage["items"].array?.first?["index"].text,"10")
        let external = try ZeroGIndex.history(data,stream:.transactions,cursor:[:])
        XCTAssertEqual(external["items"].array?.first?["status"].string,"ok")
        XCTAssertTrue(external["items"].array?.first?["block_hash"].isNull == true)
    }
    func testTraceChecksNetworkChecksumReceiptAndRevertedAncestors() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource:"trace",withExtension:"json",subdirectory:"Fixtures/ZeroG"))
        var records = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [[String:Any]])
        let trace = try json(records)
        let value: [String:Any] = ["index":10,"transaction_hash":records[0]["transactionHash"]!,"from":["hash":"0x62d4144db0f0a6fbbaeb6296c785c71b3d57c526"],"to":["hash":"0xf574ff1fd8602f0131baab74f9f7cf24993321de"],"value":"157356262205440"]
        let receipt = try json(["blockHash":records[0]["blockHash"]!,"blockNumber":records[0]["epochNumber"]!])
        XCTAssertTrue(try ZeroGTrace.corroborate(json(value),traces:trace,receipt:receipt))
        var action = records[35]["action"] as! [String:Any]; action["outcome"] = "revert"; records[35]["action"] = action
        XCTAssertFalse(try ZeroGTrace.corroborate(json(value),traces:json(records),receipt:receipt))
        XCTAssertThrowsError(try ZeroGTrace.corroborate(json(value),traces:trace,receipt:json(["blockHash":transactionHash,"blockNumber":"1"])))
        let encoded = "net16661:abvrjfcr0d2mr8747rvkrv6f26rx4z8fe26t76aa9b"
        XCTAssertEqual(try ZeroGTrace.address(encoded),"0x62d4144db0f0a6fbbaeb6296c785c71b3d57c526")
        XCTAssertThrowsError(try ZeroGTrace.address(encoded.replacingOccurrences(of:"16661",with:"16602")))
        XCTAssertThrowsError(try ZeroGTrace.address(String(encoded.dropLast())+"a"))
    }
    func testDEXQuotesRejectWrongNetworkAndInactiveLiquidity() throws {
        func quote(_ id: String, _ volume: String) -> [String:Any] { ["id":id,"type":"token","attributes":["address":owner,"price_usd":"0.2","total_reserve_in_usd":"100000","volume_usd":["h24":volume]]] }
        func decode(_ row: [String:Any]) throws -> [IndexedEVMPrice] {
            try IndexedEVMMarkets.decodeTerminalDEX(JSONSerialization.data(withJSONObject:["data":[row]]),chain:.zerog,references:[owner])
        }
        XCTAssertEqual(try decode(quote("0g_"+owner,"10000")).first?.usd,"0.2")
        XCTAssertTrue(try decode(quote("0g_"+owner,"0")).isEmpty)
        XCTAssertThrowsError(try decode(quote("ethereum_"+owner,"10000")))
    }
}

private struct ZeroGStaleNativeQuote: AnkrTransport {
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let value: Any
        if request.url?.host == "coins.llama.fi" {
            value = ["coins":["coingecko:zero-gravity":["price":99,"confidence":0.99,"timestamp":Date().timeIntervalSince1970-3600]]]
        } else {
            XCTAssertEqual(request.url?.host,"api.coingecko.com")
            XCTAssertTrue(request.url?.query?.contains("ids=zero-gravity&") == true)
            value = ["zero-gravity":["usd":"0.2","last_updated_at":Date().timeIntervalSince1970]]
        }
        return (try JSONSerialization.data(withJSONObject:value),200)
    }
}
extension ZeroGTests {
    func testStaleNativeQuoteFallsBackWithoutUsingOutdatedValue() async throws {
        let quote = try await IndexedEVMMarkets(chain:.zerog,transport:ZeroGStaleNativeQuote()).nativePrice()
        XCTAssertEqual(quote.usd,"0.2")
        XCTAssertEqual(quote.source,"CoinGecko")
    }
}
