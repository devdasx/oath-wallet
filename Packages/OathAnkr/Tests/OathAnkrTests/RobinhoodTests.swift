import XCTest
@testable import OathAnkr

private let robinOwner = "0x1111111111111111111111111111111111111111"
private let robinOther = "0x2222222222222222222222222222222222222222"
private let robinToken = "0x3333333333333333333333333333333333333333"
private let robinHash = "0x" + String(repeating: "a", count: 64)

private actor RobinhoodTransport: AnkrTransport {
    var requests: [URLRequest] = []
    let wrongChain: Bool
    let badDecimals: Bool
    let reorg: Bool
    let badIDs: Bool
    var blocks = 0
    let paginated: Bool
    init(wrongChain: Bool = false, badDecimals: Bool = false, reorg: Bool = false, badIDs: Bool = false, paginated: Bool = false) {
        self.wrongChain = wrongChain; self.badDecimals = badDecimals; self.reorg = reorg; self.badIDs = badIDs; self.paginated = paginated
    }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        requests.append(request)
        if request.url?.host == "api.blockscout.com" {
            let second = request.url!.query?.contains("items_count") == true
            let token: [String:Any] = ["type":"ERC-20","address_hash":robinToken,"name":"Fixture","symbol":"FIX","decimals":"6"]
            let next: Any = paginated && !second ? ["items_count":50,"token_name":NSNull()] as [String:Any] : NSNull()
            return (try JSONSerialization.data(withJSONObject:["items":second ? [] : [["token":token,"value":"1"]],
                "next_page_params": next]), 200)
        }
        let calls = try JSONSerialization.jsonObject(with: request.httpBody!) as! [[String:Any]]
        let rows: [[String:Any]] = calls.map { call in
            let method = call["method"] as! String, params = call["params"] as! [Any]
            let result: Any
            switch method {
            case "eth_chainId": result = wrongChain ? "0xb626" : "0x1237"
            case "eth_getBlockByNumber":
                blocks += 1
                result = ["number":"0x64","hash":reorg && blocks > 1 ? "0x" + String(repeating:"b",count:64) : robinHash]
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

private actor RobinhoodHistoryTransport: AnkrTransport {
    let indexed: Data
    let wrongChain: Bool
    let wrongAmount: Bool
    let wrongBlock: Bool
    init(indexed: Data, wrongChain: Bool = false, wrongAmount: Bool = false, wrongBlock: Bool = false) {
        self.indexed = indexed; self.wrongChain = wrongChain; self.wrongAmount = wrongAmount; self.wrongBlock = wrongBlock
    }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        if request.url?.host == "api.blockscout.com" { return (indexed, 200) }
        let calls = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as! [[String:Any]]
        let pad = String(repeating: "0", count: 24)
        let log: [String:Any] = ["address":robinToken, "logIndex":"0x7", "data":wrongAmount ? "0x1" : "0x20000000000001",
            "topics":["0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef",
                      "0x" + pad + robinOther.dropFirst(2), "0x" + pad + robinOwner.dropFirst(2)]]
        let receipt: [String:Any] = ["transactionHash":robinHash,"blockNumber":wrongBlock ? "0x65":"0x64",
            "blockHash":robinHash,"status":"0x1","gasUsed":"0x5208","effectiveGasPrice":"0x3b9aca00","logs":[log]]
        let replies: [[String:Any]] = calls.map { call in
            ["jsonrpc":"2.0","id":call["id"]!,"result":call["method"] as? String == "eth_chainId" ? (wrongChain ? "0x1":"0x1237") : receipt]
        }
        return (try JSONSerialization.data(withJSONObject:replies.reversed().map{$0}),200)
    }
}

final class RobinhoodTests: XCTestCase, @unchecked Sendable {
    func testRPCOnlyReportsPartialInventoryAndPreservesExactUnits() async throws {
        let transport = RobinhoodTransport(), client = try RobinhoodClient(apiKey:"fixture",transport:transport)
        let inventory = try await client.inventory(owner:robinOwner)
        XCTAssertEqual(inventory.block,100); XCTAssertEqual(inventory.holdings.first?.amount,"9007199254740993")
        XCTAssertFalse(inventory.complete)
        let requests = await transport.requests
        XCTAssertTrue(requests.allSatisfy{$0.url?.host == "rpc.ankr.com"})
        XCTAssertFalse(String(data:inventory.raw,encoding:.utf8)!.contains("fixture"))
    }
    func testPaginatedDiscoveryPinnedBatchesAndExactMetadata() async throws {
        let transport = RobinhoodTransport(paginated:true), client = try RobinhoodClient(apiKey:"fixture",blockscoutKey:"index-fixture",transport:transport)
        let inventory = try await client.inventory(owner:robinOwner)
        XCTAssertTrue(inventory.complete); XCTAssertEqual(inventory.holdings.count,2)
        XCTAssertEqual(inventory.holdings.first{$0.token.reference == robinToken}?.amount,"3000000")
        let requests = await transport.requests
        XCTAssertEqual(requests.filter{$0.url?.host == "api.blockscout.com"}.count,2)
        for request in requests where request.httpBody != nil {
            let calls = try JSONSerialization.jsonObject(with:request.httpBody!) as! [[String:Any]]
            for call in calls where call["method"] as? String == "eth_call" || call["method"] as? String == "eth_getBalance" {
                XCTAssertEqual((call["params"] as? [Any])?.last as? String,"0x64")
            }
        }
        XCTAssertFalse(String(data:inventory.raw,encoding:.utf8)!.contains("index-fixture"))
    }
    func testMetadataMismatchNeverBecomesAZeroTokenBalance() async throws {
        let client = try RobinhoodClient(apiKey:"fixture",blockscoutKey:"index-fixture",transport:RobinhoodTransport(badDecimals:true))
        let inventory = try await client.inventory(owner:robinOwner)
        XCTAssertFalse(inventory.complete)
        XCTAssertNil(inventory.holdings.first{$0.token.reference == robinToken}?.amount)
    }
    func testKnownManualContractsRefreshWithoutIndexer() async throws {
        let client = try RobinhoodClient(apiKey:"fixture",transport:RobinhoodTransport())
        let token = try RobinhoodToken(reference:robinToken,name:"Manual",symbol:"FIX",decimals:6)
        let inventory = try await client.inventory(owner:robinOwner,tracked:[token])
        XCTAssertFalse(inventory.complete); XCTAssertEqual(inventory.holdings.first{$0.token.reference == robinToken}?.amount,"3000000")
    }
    func testRejectsTestnetMismatchedResponseIDsAndReorganization() async throws {
        for (transport,expected) in [(RobinhoodTransport(wrongChain:true),AnkrError.wrongChain),
                                    (RobinhoodTransport(badIDs:true),.invalidResponse),(RobinhoodTransport(reorg:true),.invalidResponse)] {
            do { _ = try await RobinhoodClient(apiKey:"fixture",transport:transport).inventory(owner:robinOwner); XCTFail() }
            catch { XCTAssertEqual(error as? AnkrError,expected) }
        }
    }
    private func transfer(_ override: [String:Any] = [:]) -> [String:Any] {
        var result: [String:Any] = ["transaction_hash":robinHash,"block_number":100,"timestamp":"2026-10-12T00:00:00.000000Z",
            "from":["hash":robinOther],"to":["hash":robinOwner],"log_index":7,
            "token":["type":"ERC-20","address_hash":robinToken,"name":"Fixture","symbol":"FIX","decimals":"6"],
            "total":["decimals":"6","value":"9007199254740993"]]
        for (key,value) in override { result[key] = value }; return result
    }
    private func page(_ rows: [[String:Any]], next: Any = NSNull()) throws -> Data {
        try JSONSerialization.data(withJSONObject:["items":rows,"next_page_params":next])
    }
    func testHistoryKeepsContractIdentityExactAmountsAndPagination() throws {
        let data = try page([transfer()],next:["block_number":100,"index":7,"items_count":50])
        let page = try RobinhoodClient.decodeHistory(data,owner:robinOwner,stream:.transfers,through:2_000_000_000)
        XCTAssertEqual(page.events.first?.amount,"9007199254740993")
        XCTAssertEqual(page.events.first?.token.reference,robinToken)
        XCTAssertNotNil(page.next); XCTAssertEqual(page.raw,data)
        XCTAssertThrowsError(try RobinhoodClient.decodeHistory(data,owner:robinToken,stream:.transfers,through:2_000_000_000))
        XCTAssertThrowsError(try RobinhoodClient.decodeHistory(self.page([transfer(),transfer()]),owner:robinOwner,stream:.transfers,through:2_000_000_000))
    }
    func testInternalIndexZeroIsNotDiscardedAndFailureHasZeroValue() throws {
        let row: [String:Any] = ["transaction_hash":robinHash,"block_number":100,"timestamp":"2026-10-12T00:00:00Z",
            "from":["hash":robinOther],"to":["hash":robinOwner],"index":0,"value":"123","success":true,"type":"call"]
        var events = try RobinhoodClient.decodeHistory(page([row]),owner:robinOwner,stream:.internalTransactions,through:2_000_000_000).events
        XCTAssertEqual(events.count,1); XCTAssertEqual(events.first?.amount,"123")
        var failed = row; failed["success"] = false
        events = try RobinhoodClient.decodeHistory(page([failed]),owner:robinOwner,stream:.internalTransactions,through:2_000_000_000).events
        XCTAssertEqual(events.first?.amount,"0"); XCTAssertEqual(events.first?.failed,true)
    }
    func testHistoryWindowDoesNotStopAtNewerTransactionsOrAdvanceOnMalformedPage() throws {
        let timestamp = Date.ISO8601FormatStyle().parseStrategy
        let time = try timestamp.parse("2026-10-12T00:00:00Z").timeIntervalSince1970
        let raw = try page([transfer()],next:["block_number":100])
        let newer = try RobinhoodClient.decodeHistory(raw,owner:robinOwner,stream:.transfers,through:time-1)
        XCTAssertTrue(newer.events.isEmpty); XCTAssertNotNil(newer.next)
        let older = try RobinhoodClient.decodeHistory(raw,owner:robinOwner,stream:.transfers,from:time+1,through:time+100)
        XCTAssertTrue(older.events.isEmpty); XCTAssertNil(older.next)
        XCTAssertThrowsError(try RobinhoodClient.decodeHistory(Data("{\"items\":[]}".utf8),owner:robinOwner,stream:.transfers))
    }
    func testIndexedTransfersAreVerifiedAgainstANKRReceiptsAndMissingHeightIsEnriched() async throws {
        var row = transfer(); row.removeValue(forKey:"block_number")
        let raw = try page([row])
        let client = try RobinhoodClient(apiKey:"fixture",blockscoutKey:"index",transport:RobinhoodHistoryTransport(indexed:raw))
        let result = try await client.history(owner:robinOwner,stream:.transfers,through:2_000_000_000)
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
            (RobinhoodHistoryTransport(indexed:raw,wrongChain:true),AnkrError.wrongChain),
            (RobinhoodHistoryTransport(indexed:raw,wrongAmount:true),.invalidResponse),
            (RobinhoodHistoryTransport(indexed:raw,wrongBlock:true),.invalidResponse)
        ] {
            do {
                _ = try await RobinhoodClient(apiKey:"fixture",blockscoutKey:"index",transport:transport)
                    .history(owner:robinOwner,stream:.transfers,through:2_000_000_000)
                XCTFail("Mismatched receipt must not advance history")
            } catch { XCTAssertEqual(error as? AnkrError,expected) }
        }
    }
    func testNativeHistoryFeeUsesExactReceiptUnits() async throws {
        let row: [String:Any] = ["hash":robinHash,"block_number":100,"timestamp":"2026-10-12T00:00:00Z",
            "from":["hash":robinOwner],"to":["hash":robinOther],"status":"ok","value":"123","fee":["value":"999"]]
        let client = try RobinhoodClient(apiKey:"fixture",blockscoutKey:"index",transport:RobinhoodHistoryTransport(indexed:page([row])))
        let result = try await client.history(owner:robinOwner,stream:.transactions,through:2_000_000_000)
        XCTAssertEqual(result.events.first?.fee,"21000000000000")
        XCTAssertEqual(result.events.first?.amount,"123")
    }
    func testCatalogAndPricesUseExactChainContractsNeverTickerMatches() throws {
        let raw = try JSONSerialization.data(withJSONObject:[
            ["id":"real","symbol":"FAKE","platforms":["robinhood":robinToken]],
            ["id":"wrong-network","symbol":"FAKE","platforms":["ethereum":robinOther]]])
        let catalog = try RobinhoodMarkets.decodeCatalog(raw)
        XCTAssertTrue(catalog.contains(robinToken)); XCTAssertFalse(catalog.contains(robinOther))
        let now = Date(timeIntervalSince1970:2_000_000_000)
        let prices = try JSONSerialization.data(withJSONObject:["real":["usd":1.25,"last_updated_at":1_999_999_990],"wrong-network":["usd":1000,"last_updated_at":1_999_999_990]])
        let result = try RobinhoodMarkets.decodePrices(prices,references:[robinToken,robinOther],catalog:catalog,now:now)
        XCTAssertEqual(result.count,1); XCTAssertEqual(result.first?.usd,"1.25")
        XCTAssertTrue(try RobinhoodMarkets.decodePrices(prices,references:[robinToken],catalog:catalog,now:now.addingTimeInterval(3600)).isEmpty)
    }
    func testDEXPricesRejectWrongChainQuoteSideAndShallowLiquidity() throws {
        func pair(_ chain:String,_ base:String,_ liquidity:Int,_ price:String)->[String:Any] {
            ["chainId":chain,"baseToken":["address":base],"quoteToken":["address":robinToken],"priceUsd":price,"liquidity":["usd":liquidity]]
        }
        let raw = try JSONSerialization.data(withJSONObject:[pair("ethereum",robinToken,1_000_000,"10000"),pair("robinhood",robinOther,1_000_000,"700"),pair("robinhood",robinToken,100,"20"),pair("robinhood",robinToken,20_000,"2")])
        let prices = try RobinhoodMarkets.decodeDEX(raw,references:[robinToken])
        XCTAssertEqual(prices.count,1); XCTAssertEqual(prices.first?.usd,"2")
    }
    func testLiveANKRAndPriceReads() async throws {
        guard ProcessInfo.processInfo.environment["OATH_ROBINHOOD_LIVE"] == "1" else { throw XCTSkip("Opt-in public mainnet reads") }
        let config = try XCTUnwrap(ProcessInfo.processInfo.environment["OATH_ANKR_CONFIG"])
        let secrets = try PropertyListSerialization.propertyList(from:Data(contentsOf:URL(fileURLWithPath:config)),format:nil) as! [String:String]
        let samples = ProcessInfo.processInfo.environment["OATH_ROBINHOOD_SAMPLES"] ?? Bundle.module.url(forResource:"robinhood-public-accounts",withExtension:"json",subdirectory:"Fixtures")!.path
        struct Sample: Decodable { let owner:String; let tokens:[RobinhoodToken] }
        let values = try JSONDecoder().decode([Sample].self,from:Data(contentsOf:URL(fileURLWithPath:samples)))
        let client = try RobinhoodClient(apiKey:XCTUnwrap(secrets["AnkrAPIKey"]),blockscoutKey:secrets["BlockscoutAPIKey"])
        let markets = RobinhoodMarkets(), catalog = try await markets.catalog()
        XCTAssertFalse(catalog.ids.isEmpty)
        let native = try await markets.nativePrice(); XCTAssertFalse(native.usd.isEmpty)
        for sample in values {
            let value = try await client.inventory(owner:sample.owner,tracked:sample.tokens)
            XCTAssertEqual(value.owner,sample.owner); XCTAssertTrue(value.block > 0)
            XCTAssertTrue(Set(sample.tokens.map(\.reference)).isSubset(of:Set(value.holdings.map { $0.token.reference })))
            if secrets["BlockscoutAPIKey"] != nil { XCTAssertTrue(value.complete) }
            XCTAssertTrue(value.holdings.allSatisfy{$0.amount != nil})
            XCTAssertTrue(value.holdings.contains{$0.token.reference != "native" && $0.amount != "0"})
        }
        let refs = values.flatMap(\.tokens).map(\.reference)
        let prices = try await markets.prices(references:Array(Set(refs).prefix(30)),catalog:catalog)
        XCTAssertFalse(prices.isEmpty)
    }
    func testLiveExplorerPagesAgainstANKRReceipts() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["OATH_ROBINHOOD_LIVE"] == "1" else { throw XCTSkip("Opt-in indexed Robinhood history") }
        let config = try XCTUnwrap(environment["OATH_ANKR_CONFIG"])
        let values = try PropertyListSerialization.propertyList(from:Data(contentsOf:URL(fileURLWithPath:config)),format:nil) as! [String:String]
        guard let indexKey = values["BlockscoutAPIKey"], !indexKey.isEmpty else {
            throw XCTSkip("Blockscout key required; ANKR Advanced API does not index Robinhood")
        }
        let client = try RobinhoodClient(apiKey:XCTUnwrap(values["AnkrAPIKey"]),blockscoutKey:indexKey)
        let owners = ["0x8366a39cc670b4001a1121b8f6a443a643e40951","0xec9aa0a6c2372131a0502aba6188269ab52cacb5"]
        let through = Date().timeIntervalSince1970
        var total = 0
        for owner in owners {
            for stream in RobinhoodHistoryStream.allCases {
                let first = try await client.history(owner:owner,stream:stream,through:through)
                total += first.events.count
                if let cursor = first.next {
                    let second = try await client.history(owner:owner,stream:stream,cursor:cursor,through:through)
                    XCTAssertTrue(Set(first.events.map(\.id)).isDisjoint(with:Set(second.events.map(\.id))))
                    total += second.events.count
                }
            }
        }
        XCTAssertGreaterThan(total,0)
        print("Robinhood indexed history: \(total) events checked with ANKR receipts across two public accounts")
    }
}
