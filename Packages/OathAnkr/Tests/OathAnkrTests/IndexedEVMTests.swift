import XCTest
@testable import OathAnkr

private let uniOwner = "0x1111111111111111111111111111111111111111"
private let uniOther = "0x2222222222222222222222222222222222222222"
private let uniToken = "0x3333333333333333333333333333333333333333"
private let uniHash = "0x" + String(repeating: "a", count: 64)

private actor IndexedEVMTransport: AnkrTransport {
    var requests: [URLRequest] = []
    let wrongChain: Bool
    let badDecimals: Bool
    let reorg: Bool
    let badIDs: Bool
    var blocks = 0
    let unavailable: Bool
    let paginated: Bool
    init(wrongChain: Bool = false, badDecimals: Bool = false, reorg: Bool = false, badIDs: Bool = false, paginated: Bool = false, unavailable: Bool = false) {
        self.unavailable = unavailable
        self.wrongChain = wrongChain; self.badDecimals = badDecimals; self.reorg = reorg; self.badIDs = badIDs; self.paginated = paginated
    }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        requests.append(request)
        if request.url?.host == "unichain.blockscout.com" {
            if unavailable { return (Data(), 403) }
            let second = request.url!.query?.contains("items_count") == true
            let token: [String:Any] = ["type":"ERC-20","address_hash":uniToken,"name":"Fixture","symbol":"FIX","decimals":"6"]
            let next: Any = paginated && !second ? ["items_count":50,"token_name":NSNull()] as [String:Any] : NSNull()
            return (try JSONSerialization.data(withJSONObject:["items":second ? [] : [["token":token,"value":"1"]],
                "next_page_params": next]), 200)
        }
        let calls = try JSONSerialization.jsonObject(with: request.httpBody!) as! [[String:Any]]
        let rows: [[String:Any]] = calls.map { call in
            let method = call["method"] as! String, params = call["params"] as! [Any]
            let result: Any
            switch method {
            case "eth_chainId": result = wrongChain ? "0xb626" : "0x82"
            case "eth_getBlockByNumber":
                blocks += 1
                result = ["number":"0x64","hash":reorg && blocks > 1 ? "0x" + String(repeating:"b",count:64) : uniHash]
            case "eth_getBalance": result = "0x20000000000001"
            case "eth_call":
                let data = (params[0] as! [String:Any])["data"] as! String
                result = data == "0x313ce567" ? (badDecimals ? "0x12" : "0x6") : "0x2dc6c0"
            default: result = NSNull()
            }
            return ["jsonrpc":"2.0","id":badIDs ? 99 : call["id"]!,"result":result]
        }
        return (try JSONSerialization.data(withJSONObject:rows.reversed().map{$0}),200)
    }
}

private actor IndexedEVMHistoryTransport: AnkrTransport {
    let indexed: Data
    let wrongChain: Bool
    let wrongAmount: Bool
    let wrongBlock: Bool
    init(indexed: Data, wrongChain: Bool = false, wrongAmount: Bool = false, wrongBlock: Bool = false) {
        self.indexed = indexed; self.wrongChain = wrongChain; self.wrongAmount = wrongAmount; self.wrongBlock = wrongBlock
    }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        if request.url?.host == "unichain.blockscout.com" { return (indexed, 200) }
        let calls = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as! [[String:Any]]
        let pad = String(repeating: "0", count: 24)
        let log: [String:Any] = ["address":uniToken, "logIndex":"0x7", "data":wrongAmount ? "0x1" : "0x20000000000001",
            "topics":["0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef",
                      "0x" + pad + uniOther.dropFirst(2), "0x" + pad + uniOwner.dropFirst(2)]]
        let receipt: [String:Any] = ["transactionHash":uniHash,"blockNumber":wrongBlock ? "0x65":"0x64",
            "blockHash":uniHash,"status":"0x1","gasUsed":"0x5208","effectiveGasPrice":"0x3b9aca00","l1Fee":"0x64","logs":[log]]
        let replies: [[String:Any]] = calls.map { call in
            ["jsonrpc":"2.0","id":call["id"]!,"result":call["method"] as? String == "eth_chainId" ? (wrongChain ? "0x1":"0x82") as Any :
                call["method"] as? String == "eth_getTransactionByHash" ? ["hash":uniHash,"blockHash":uniHash,"from":uniOwner,"to":uniOther,"value":"0x7b"] : receipt]
        }
        return (try JSONSerialization.data(withJSONObject:replies.reversed().map{$0}),200)
    }
}

final class IndexedEVMTests: XCTestCase, @unchecked Sendable {
    func testRPCOnlyReportsPartialInventoryAndPreservesExactUnits() async throws {
        let transport = IndexedEVMTransport(unavailable:true), client = try IndexedEVMClient(chain:.unichain,apiKey:"fixture",transport:transport)
        let inventory = try await client.inventory(owner:uniOwner)
        XCTAssertEqual(inventory.block,100); XCTAssertEqual(inventory.holdings.first?.amount,"9007199254740993")
        XCTAssertFalse(inventory.complete)
        let requests = await transport.requests
        XCTAssertEqual(requests.filter{$0.url?.host == "unichain.blockscout.com"}.count,1)
        XCTAssertFalse(String(data:inventory.raw,encoding:.utf8)!.contains("fixture"))
    }
    func testPaginatedDiscoveryPinnedBatchesAndExactMetadata() async throws {
        let transport = IndexedEVMTransport(paginated:true), client = try IndexedEVMClient(chain:.unichain,apiKey:"fixture",transport:transport)
        let inventory = try await client.inventory(owner:uniOwner)
        XCTAssertTrue(inventory.complete); XCTAssertEqual(inventory.holdings.count,2)
        XCTAssertEqual(inventory.holdings.first{$0.token.reference == uniToken}?.amount,"3000000")
        let requests = await transport.requests
        XCTAssertEqual(requests.filter{$0.url?.host == "unichain.blockscout.com"}.count,2)
        for request in requests where request.httpBody != nil {
            let calls = try JSONSerialization.jsonObject(with:request.httpBody!) as! [[String:Any]]
            for call in calls where call["method"] as? String == "eth_call" || call["method"] as? String == "eth_getBalance" {
                XCTAssertEqual((call["params"] as? [Any])?.last as? String,"0x64")
            }
        }
        XCTAssertFalse(String(data:inventory.raw,encoding:.utf8)!.contains("index-fixture"))
    }
    func testMetadataMismatchNeverBecomesAZeroTokenBalance() async throws {
        let client = try IndexedEVMClient(chain:.unichain,apiKey:"fixture",transport:IndexedEVMTransport(badDecimals:true))
        let inventory = try await client.inventory(owner:uniOwner)
        XCTAssertFalse(inventory.complete)
        XCTAssertNil(inventory.holdings.first{$0.token.reference == uniToken}?.amount)
    }
    func testKnownManualContractsRefreshWithoutIndexer() async throws {
        let client = try IndexedEVMClient(chain:.unichain,apiKey:"fixture",transport:IndexedEVMTransport(unavailable:true))
        let token = try IndexedEVMToken(reference:uniToken,name:"Manual",symbol:"FIX",decimals:6)
        let inventory = try await client.inventory(owner:uniOwner,tracked:[token])
        XCTAssertFalse(inventory.complete); XCTAssertEqual(inventory.holdings.first{$0.token.reference == uniToken}?.amount,"3000000")
    }
    func testRejectsTestnetMismatchedResponseIDsAndReorganization() async throws {
        for (transport,expected) in [(IndexedEVMTransport(wrongChain:true),AnkrError.wrongChain),
                                    (IndexedEVMTransport(badIDs:true),.invalidResponse),(IndexedEVMTransport(reorg:true),.invalidResponse)] {
            do { _ = try await IndexedEVMClient(chain:.unichain,apiKey:"fixture",transport:transport).inventory(owner:uniOwner); XCTFail() }
            catch { XCTAssertEqual(error as? AnkrError,expected) }
        }
    }
    private func transfer(_ override: [String:Any] = [:]) -> [String:Any] {
        var result: [String:Any] = ["transaction_hash":uniHash,"block_number":100,"timestamp":"2026-10-12T00:00:00.000000Z",
            "from":["hash":uniOther],"to":["hash":uniOwner],"log_index":7,
            "token":["type":"ERC-20","address_hash":uniToken,"name":"Fixture","symbol":"FIX","decimals":"6"],
            "total":["decimals":"6","value":"9007199254740993"]]
        for (key,value) in override { result[key] = value }; return result
    }
    private func page(_ rows: [[String:Any]], next: Any = NSNull()) throws -> Data {
        try JSONSerialization.data(withJSONObject:["items":rows,"next_page_params":next])
    }
    func testHistoryKeepsContractIdentityExactAmountsAndPagination() throws {
        let data = try page([transfer()],next:["block_number":100,"index":7,"items_count":50])
        let page = try IndexedEVMClient.decodeHistory(data,chain:.unichain,owner:uniOwner,stream:.transfers,through:2_000_000_000)
        XCTAssertEqual(page.events.first?.amount,"9007199254740993")
        XCTAssertEqual(page.events.first?.token?.reference,uniToken)
        XCTAssertNotNil(page.next); XCTAssertEqual(page.raw,data)
        XCTAssertThrowsError(try IndexedEVMClient.decodeHistory(data,chain:.unichain,owner:uniToken,stream:.transfers,through:2_000_000_000))
        XCTAssertThrowsError(try IndexedEVMClient.decodeHistory(self.page([transfer(),transfer()]),chain:.unichain,owner:uniOwner,stream:.transfers,through:2_000_000_000))
    }
    func testInternalIndexZeroIsNotDiscardedAndFailureHasZeroValue() throws {
        let row: [String:Any] = ["transaction_hash":uniHash,"block_number":100,"timestamp":"2026-10-12T00:00:00Z",
            "from":["hash":uniOther],"to":["hash":uniOwner],"index":0,"value":"123","success":true,"type":"call"]
        var events = try IndexedEVMClient.decodeHistory(page([row]),chain:.unichain,owner:uniOwner,stream:.internalTransactions,through:2_000_000_000).events
        XCTAssertEqual(events.count,1); XCTAssertEqual(events.first?.amount,"123")
        var failed = row; failed["success"] = false
        events = try IndexedEVMClient.decodeHistory(page([failed]),chain:.unichain,owner:uniOwner,stream:.internalTransactions,through:2_000_000_000).events
        XCTAssertEqual(events.first?.amount,"0"); XCTAssertEqual(events.first?.failed,true)
    }
    func testHistoryWindowDoesNotStopAtNewerTransactionsOrAdvanceOnMalformedPage() throws {
        let timestamp = Date.ISO8601FormatStyle().parseStrategy
        let time = try timestamp.parse("2026-10-12T00:00:00Z").timeIntervalSince1970
        let raw = try page([transfer()],next:["block_number":100])
        let newer = try IndexedEVMClient.decodeHistory(raw,chain:.unichain,owner:uniOwner,stream:.transfers,through:time-1)
        XCTAssertTrue(newer.events.isEmpty); XCTAssertNotNil(newer.next)
        let older = try IndexedEVMClient.decodeHistory(raw,chain:.unichain,owner:uniOwner,stream:.transfers,from:time+1,through:time+100)
        XCTAssertTrue(older.events.isEmpty); XCTAssertNil(older.next)
        XCTAssertThrowsError(try IndexedEVMClient.decodeHistory(Data("{\"items\":[]}".utf8),chain:.unichain,owner:uniOwner,stream:.transfers))
    }
    func testIndexedTransfersAreVerifiedAgainstANKRReceiptsAndMissingHeightIsEnriched() async throws {
        var row = transfer(); row.removeValue(forKey:"block_number")
        let raw = try page([row])
        let client = try IndexedEVMClient(chain:.unichain,apiKey:"fixture",transport:IndexedEVMHistoryTransport(indexed:raw))
        let result = try await client.history(owner:uniOwner,stream:.transfers,through:2_000_000_000)
        XCTAssertEqual(result.events.count,1)
        XCTAssertEqual(result.events.first?.block,100)
        XCTAssertEqual(result.events.first?.amount,"9007199254740993")
        let archive = try JSONDecoder().decode([String:[Data]].self,from:result.raw)
        XCTAssertEqual(archive["index"], [raw]); XCTAssertEqual(archive["receipts"]?.count,1)
        XCTAssertFalse(String(data:result.raw,encoding:.utf8)!.contains("fixture"))
    }
    func testHistoryRejectsWrongChainTransferAmountAndReceiptBlock() async throws {
        let raw = try page([transfer()])
        for (transport, expected) in [
            (IndexedEVMHistoryTransport(indexed:raw,wrongChain:true),AnkrError.wrongChain),
            (IndexedEVMHistoryTransport(indexed:raw,wrongAmount:true),.invalidResponse),
            (IndexedEVMHistoryTransport(indexed:raw,wrongBlock:true),.invalidResponse)
        ] {
            do {
                _ = try await IndexedEVMClient(chain:.unichain,apiKey:"fixture",transport:transport)
                    .history(owner:uniOwner,stream:.transfers,through:2_000_000_000)
                XCTFail("Mismatched receipt must not advance history")
            } catch { XCTAssertEqual(error as? AnkrError,expected) }
        }
    }
    func testNativeHistoryFeeUsesExactReceiptUnits() async throws {
        let row: [String:Any] = ["hash":uniHash,"block_number":100,"timestamp":"2026-10-12T00:00:00Z",
            "from":["hash":uniOwner],"to":["hash":uniOther],"status":"ok","value":"123","fee":["value":"999"]]
        let client = try IndexedEVMClient(chain:.unichain,apiKey:"fixture",transport:IndexedEVMHistoryTransport(indexed:page([row])))
        let result = try await client.history(owner:uniOwner,stream:.transactions,through:2_000_000_000)
        XCTAssertEqual(result.events.first?.fee,"21000000000100")
        XCTAssertEqual(result.events.first?.amount,"123")
    }
    func testCatalogAndPricesUseExactChainContractsNeverTickerMatches() throws {
        let raw = try JSONSerialization.data(withJSONObject:[
            ["id":"real","symbol":"FAKE","platforms":["unichain":uniToken]],
            ["id":"wrong-network","symbol":"FAKE","platforms":["ethereum":uniOther]]])
        let catalog = try IndexedEVMMarkets.decodeCatalog(raw,chain:.unichain)
        XCTAssertTrue(catalog.contains(uniToken)); XCTAssertFalse(catalog.contains(uniOther))
        let now = Date(timeIntervalSince1970:2_000_000_000)
        let prices = try JSONSerialization.data(withJSONObject:["real":["usd":1.25,"last_updated_at":1_999_999_990],"wrong-network":["usd":1000,"last_updated_at":1_999_999_990]])
        let result = try IndexedEVMMarkets.decodePrices(prices,references:[uniToken,uniOther],catalog:catalog,now:now)
        XCTAssertEqual(result.count,1); XCTAssertEqual(result.first?.usd,"1.25")
        XCTAssertTrue(try IndexedEVMMarkets.decodePrices(prices,references:[uniToken],catalog:catalog,now:now.addingTimeInterval(3600)).isEmpty)
    }
    func testDEXPricesRejectWrongChainQuoteSideAndShallowLiquidity() throws {
        func pair(_ chain:String,_ base:String,_ liquidity:Int,_ price:String)->[String:Any] {
            ["chainId":chain,"baseToken":["address":base],"quoteToken":["address":uniToken],"priceUsd":price,"liquidity":["usd":liquidity]]
        }
        let raw = try JSONSerialization.data(withJSONObject:[pair("ethereum",uniToken,1_000_000,"10000"),pair("unichain",uniOther,1_000_000,"700"),pair("unichain",uniToken,100,"20"),pair("unichain",uniToken,20_000,"2")])
        let prices = try IndexedEVMMarkets.decodeDEX(raw,chain:.unichain,references:[uniToken])
        XCTAssertEqual(prices.count,1); XCTAssertEqual(prices.first?.usd,"2")
    }
}
