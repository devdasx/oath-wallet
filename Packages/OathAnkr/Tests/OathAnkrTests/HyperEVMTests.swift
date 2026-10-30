import XCTest
import OathDiagnostics
@testable import OathAnkr

private let hyperOwner = "0x1111111111111111111111111111111111111111"
private let hyperOther = "0x2222222222222222222222222222222222222222"
private let hyperToken = "0x3333333333333333333333333333333333333333"
private let hyperHash = "0x" + String(repeating: "a", count: 64)

private actor HyperEVMTransport: AnkrTransport {
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
        if request.url?.host == "trace.hypurrscan.io" {
            if paginated { return (Data("{}".utf8),503) }
            return (try JSONSerialization.data(withJSONObject:["success":true,"last_aggregated_block":100,
                "balances":[["token":hyperToken,"name":"Fixture","symbol":"FIX","decimals":6,"balance":"10e+20"]]]),200)
        }
        let calls = try JSONSerialization.jsonObject(with: request.httpBody!) as! [[String:Any]]
        let rows: [[String:Any]] = calls.map { call in
            let method = call["method"] as! String, params = call["params"] as! [Any]
            let result: Any
            switch method {
            case "eth_chainId": result = wrongChain ? "0xb626" : "0x3e7"
            case "eth_getBlockByNumber":
                blocks += 1
                result = ["number":"0x64","hash":reorg && blocks > 1 ? "0x" + String(repeating:"b",count:64) : hyperHash]
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

private actor HyperEVMHistoryTransport: AnkrTransport {
    let indexed: Data
    let wrongChain: Bool
    let wrongAmount: Bool
    let wrongBlock: Bool
    let missingMetadata: Bool
    let metadataReverts: Bool
    init(indexed: Data, wrongChain: Bool = false, wrongAmount: Bool = false, wrongBlock: Bool = false, missingMetadata: Bool = false, metadataReverts: Bool = false) {
        self.indexed = indexed; self.wrongChain = wrongChain; self.wrongAmount = wrongAmount; self.wrongBlock = wrongBlock
        self.missingMetadata = missingMetadata; self.metadataReverts = metadataReverts
    }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        if request.url?.host == "trace.hypurrscan.io" {
            let document = try JSONSerialization.jsonObject(with:indexed) as! [String:Any]
            let rows = (document["items"] as! [[String:Any]]).map { r -> [String:Any] in
                let token = r["token"] as? [String:Any] ?? [:], total = r["total"] as? [String:Any] ?? [:]
                return ["tx_hash":r["hash"] ?? r["transaction_hash"]!, "block_number":r["block_number"] ?? 100,
                    "timestamp":r["timestamp"]!, "from_address":(r["from"] as! [String:Any])["hash"]!,
                    "to_address":(r["to"] as! [String:Any])["hash"]!, "success":true, "value":total["value"] ?? r["value"] ?? "0",
                    "token_address":token["address_hash"] ?? hyperToken, "token_decimals":missingMetadata ? NSNull() : 6, "token_name":"Fixture", "token_symbol":"FIX", "log_index":7]
            }
            let name = request.url!.path.contains("erc20") ? "erc20_transfers" : "transactions"
            return (try JSONSerialization.data(withJSONObject:["success":true,"results":[hyperOwner:[name:rows,"has_more":false,"next_cursor":NSNull()]]]),200)
        }
        let calls = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as! [[String:Any]]
        let pad = String(repeating: "0", count: 24)
        let log: [String:Any] = ["address":hyperToken, "logIndex":"0x2a", "data":wrongAmount ? "0x1" : "0x20000000000001",
            "topics":["0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef",
                      "0x" + pad + hyperOther.dropFirst(2), "0x" + pad + hyperOwner.dropFirst(2)]]
        let receipt: [String:Any] = ["transactionHash":hyperHash,"blockNumber":wrongBlock ? "0x65":"0x64",
            "blockHash":hyperHash,"status":"0x1","gasUsed":"0x5208","effectiveGasPrice":"0x3b9aca00","logs":Array(repeating:[String:Any](),count:7)+[log]]
        let replies: [[String:Any]] = calls.map { call in
            let result: Any
            switch call["method"] as? String {
            case "eth_chainId": result = wrongChain ? "0x1":"0x3e7"
            case "eth_getTransactionByHash": result = ["hash":hyperHash,"blockHash":hyperHash,"from":hyperOwner,"to":hyperOther,"value":"0x7b"]
            case "eth_call":
                if metadataReverts { return ["jsonrpc":"2.0","id":call["id"]!,"error":["code":3,"message":"execution reverted"]] }
                result = "0x6"
            default: result = receipt
            }
            return ["jsonrpc":"2.0","id":call["id"]!,"result":result]
        }
        return (try JSONSerialization.data(withJSONObject:replies.reversed().map{$0}),200)
    }
}

final class HyperEVMTests: XCTestCase, @unchecked Sendable {
    func testRPCOnlyReportsPartialInventoryAndPreservesExactUnits() async throws {
        let transport = HyperEVMTransport(paginated:true), client = try HyperEVMClient(apiKey:"fixture",transport:transport)
        let inventory = try await client.inventory(owner:hyperOwner)
        XCTAssertEqual(inventory.block,100); XCTAssertEqual(inventory.holdings.first?.amount,"9007199254740993")
        XCTAssertFalse(inventory.complete)
        let requests = await transport.requests
        XCTAssertTrue(requests.contains{$0.url?.host == "rpc.ankr.com"})
        XCTAssertFalse(String(data:inventory.raw,encoding:.utf8)!.contains("fixture"))
    }
    func testIndexerAmountsAreIgnoredAndANKRBatchesArePinned() async throws {
        let transport = HyperEVMTransport(), client = try HyperEVMClient(apiKey:"fixture",transport:transport)
        let inventory = try await client.inventory(owner:hyperOwner)
        XCTAssertTrue(inventory.complete); XCTAssertEqual(inventory.holdings.count,2)
        XCTAssertEqual(inventory.holdings.first{$0.token.reference == hyperToken}?.amount,"3000000")
        let requests = await transport.requests
        XCTAssertEqual(requests.filter{$0.url?.host == "trace.hypurrscan.io"}.count,1)
        for request in requests where request.url?.host == "rpc.ankr.com" {
            let calls = try JSONSerialization.jsonObject(with:request.httpBody!) as! [[String:Any]]
            for call in calls where call["method"] as? String == "eth_call" || call["method"] as? String == "eth_getBalance" {
                XCTAssertEqual((call["params"] as? [Any])?.last as? String,"0x64")
            }
        }
        XCTAssertFalse(String(data:inventory.raw,encoding:.utf8)!.contains("index-fixture"))
    }
    func testMetadataMismatchNeverBecomesAZeroTokenBalance() async throws {
        let client = try HyperEVMClient(apiKey:"fixture",transport:HyperEVMTransport(badDecimals:true))
        let inventory = try await client.inventory(owner:hyperOwner)
        XCTAssertFalse(inventory.complete)
        XCTAssertNil(inventory.holdings.first{$0.token.reference == hyperToken}?.amount)
    }
    func testKnownManualContractsRefreshWithoutIndexer() async throws {
        let client = try HyperEVMClient(apiKey:"fixture",transport:HyperEVMTransport(paginated:true))
        let token = try HyperEVMToken(reference:hyperToken,name:"Manual",symbol:"FIX",decimals:6)
        let inventory = try await client.inventory(owner:hyperOwner,tracked:[token])
        XCTAssertFalse(inventory.complete); XCTAssertEqual(inventory.holdings.first{$0.token.reference == hyperToken}?.amount,"3000000")
    }
    func testRejectsTestnetMismatchedResponseIDsAndReorganization() async throws {
        for (transport,expected) in [(HyperEVMTransport(wrongChain:true),AnkrError.wrongChain),
                                    (HyperEVMTransport(badIDs:true),.invalidResponse),(HyperEVMTransport(reorg:true),.invalidResponse)] {
            do { _ = try await HyperEVMClient(apiKey:"fixture",transport:transport).inventory(owner:hyperOwner); XCTFail() }
            catch { XCTAssertEqual(error as? AnkrError,expected) }
        }
    }
    private func transfer(_ override: [String:Any] = [:]) -> [String:Any] {
        var result: [String:Any] = ["transaction_hash":hyperHash,"block_number":100,"timestamp":"2026-10-12T00:00:00.000000Z",
            "from":["hash":hyperOther],"to":["hash":hyperOwner],"log_index":7,
            "token":["type":"ERC-20","address_hash":hyperToken,"name":"Fixture","symbol":"FIX","decimals":"6"],
            "total":["decimals":"6","value":"9007199254740993"]]
        for (key,value) in override { result[key] = value }; return result
    }
    private func page(_ rows: [[String:Any]], next: Any = NSNull()) throws -> Data {
        try JSONSerialization.data(withJSONObject:["items":rows,"next_page_params":next])
    }
    func testHistoryKeepsContractIdentityExactAmountsAndPagination() throws {
        let data = try page([transfer()],next:["block_number":100,"index":7,"items_count":50])
        let page = try HyperEVMClient.decodeHistory(data,owner:hyperOwner,stream:.transfers,through:2_000_000_000)
        XCTAssertEqual(page.events.first?.amount,"9007199254740993")
        XCTAssertEqual(page.events.first?.token?.reference,hyperToken)
        XCTAssertNotNil(page.next); XCTAssertEqual(page.raw,data)
        XCTAssertThrowsError(try HyperEVMClient.decodeHistory(data,owner:hyperToken,stream:.transfers,through:2_000_000_000))
        XCTAssertThrowsError(try HyperEVMClient.decodeHistory(self.page([transfer(),transfer()]),owner:hyperOwner,stream:.transfers,through:2_000_000_000))
    }
    func testInternalIndexZeroIsNotDiscardedAndFailureHasZeroValue() throws {
        let row: [String:Any] = ["transaction_hash":hyperHash,"block_number":100,"timestamp":"2026-10-12T00:00:00Z",
            "from":["hash":hyperOther],"to":["hash":hyperOwner],"index":0,"value":"123","success":true,"type":"call"]
        var events = try HyperEVMClient.decodeHistory(page([row]),owner:hyperOwner,stream:.internalTransactions,through:2_000_000_000).events
        XCTAssertEqual(events.count,1); XCTAssertEqual(events.first?.amount,"123")
        var failed = row; failed["success"] = false
        events = try HyperEVMClient.decodeHistory(page([failed]),owner:hyperOwner,stream:.internalTransactions,through:2_000_000_000).events
        XCTAssertEqual(events.first?.amount,"0"); XCTAssertEqual(events.first?.failed,true)
    }
    func testHistoryWindowDoesNotStopAtNewerTransactionsOrAdvanceOnMalformedPage() throws {
        let timestamp = Date.ISO8601FormatStyle().parseStrategy
        let time = try timestamp.parse("2026-10-12T00:00:00Z").timeIntervalSince1970
        let raw = try page([transfer()],next:["block_number":100])
        let newer = try HyperEVMClient.decodeHistory(raw,owner:hyperOwner,stream:.transfers,through:time-1)
        XCTAssertTrue(newer.events.isEmpty); XCTAssertNotNil(newer.next)
        let older = try HyperEVMClient.decodeHistory(raw,owner:hyperOwner,stream:.transfers,from:time+1,through:time+100)
        XCTAssertTrue(older.events.isEmpty); XCTAssertNil(older.next)
        XCTAssertThrowsError(try HyperEVMClient.decodeHistory(Data("{\"items\":[]}".utf8),owner:hyperOwner,stream:.transfers))
    }
    func testIndexedTransfersAreVerifiedAgainstANKRReceiptsAndMissingHeightIsEnriched() async throws {
        var row = transfer(); row.removeValue(forKey:"block_number")
        let raw = try page([row])
        let client = try HyperEVMClient(apiKey:"fixture",transport:HyperEVMHistoryTransport(indexed:raw))
        let result = try await client.history(owner:hyperOwner,stream:.transfers,through:2_000_000_000)
        XCTAssertEqual(result.events.count,1)
        XCTAssertEqual(result.events.first?.block,100)
        XCTAssertEqual(result.events.first?.id,hyperHash + ":log:42")
        XCTAssertEqual(result.events.first?.amount,"9007199254740993")
        let archive = try JSONDecoder().decode([String:[Data]].self,from:result.raw)
        XCTAssertEqual(archive["index"]?.count, 1); XCTAssertEqual(archive["receipts"]?.count,1)
        XCTAssertFalse(String(data:result.raw,encoding:.utf8)!.contains("fixture"))
    }
    func testHistoryRejectsWrongChainTransferAmountAndReceiptBlock() async throws {
        let raw = try page([transfer()])
        for (transport, expected) in [
            (HyperEVMHistoryTransport(indexed:raw,wrongChain:true),AnkrError.wrongChain),
            (HyperEVMHistoryTransport(indexed:raw,wrongAmount:true),.invalidResponse),
            (HyperEVMHistoryTransport(indexed:raw,wrongBlock:true),.invalidResponse)
        ] {
            do {
                _ = try await HyperEVMClient(apiKey:"fixture",transport:transport)
                    .history(owner:hyperOwner,stream:.transfers,through:2_000_000_000)
                XCTFail("Mismatched receipt must not advance history")
            } catch { XCTAssertEqual(error as? AnkrError,expected) }
        }
    }
    func testNativeHistoryFeeUsesExactReceiptUnits() async throws {
        let row: [String:Any] = ["hash":hyperHash,"block_number":100,"timestamp":"2026-10-12T00:00:00Z",
            "from":["hash":hyperOwner],"to":["hash":hyperOther],"status":"ok","value":"123","fee":["value":"999"]]
        let client = try HyperEVMClient(apiKey:"fixture",transport:HyperEVMHistoryTransport(indexed:page([row])))
        let result = try await client.history(owner:hyperOwner,stream:.transactions,through:2_000_000_000)
        XCTAssertEqual(result.events.first?.fee,"21000000000000")
        XCTAssertEqual(result.events.first?.amount,"123")
    }
    func testCatalogAndPricesUseExactChainContractsNeverTickerMatches() throws {
        let raw = try JSONSerialization.data(withJSONObject:[
            ["id":"real","symbol":"FAKE","platforms":["hyperevm":hyperToken]],
            ["id":"wrong-network","symbol":"FAKE","platforms":["ethereum":hyperOther]]])
        let catalog = try HyperEVMMarkets.decodeCatalog(raw)
        XCTAssertTrue(catalog.contains(hyperToken)); XCTAssertFalse(catalog.contains(hyperOther))
        let now = Date(timeIntervalSince1970:2_000_000_000)
        let prices = try JSONSerialization.data(withJSONObject:["real":["usd":1.25,"last_updated_at":1_999_999_990],"wrong-network":["usd":1000,"last_updated_at":1_999_999_990]])
        let result = try HyperEVMMarkets.decodePrices(prices,references:[hyperToken,hyperOther],catalog:catalog,now:now)
        XCTAssertEqual(result.count,1); XCTAssertEqual(result.first?.usd,"1.25")
        XCTAssertTrue(try HyperEVMMarkets.decodePrices(prices,references:[hyperToken],catalog:catalog,now:now.addingTimeInterval(3600)).isEmpty)
    }
    func testDEXPricesRejectWrongChainQuoteSideAndShallowLiquidity() throws {
        func pair(_ chain:String,_ base:String,_ liquidity:Int,_ price:String)->[String:Any] {
            ["chainId":chain,"baseToken":["address":base],"quoteToken":["address":hyperToken],"priceUsd":price,"liquidity":["usd":liquidity]]
        }
        let raw = try JSONSerialization.data(withJSONObject:[pair("ethereum",hyperToken,1_000_000,"10000"),pair("hyperevm",hyperOther,1_000_000,"700"),pair("hyperevm",hyperToken,100,"20"),pair("hyperevm",hyperToken,20_000,"2")])
        let prices = try HyperEVMMarkets.decodeDEX(raw,references:[hyperToken])
        XCTAssertEqual(prices.count,1); XCTAssertEqual(prices.first?.usd,"2")
    }
    func testHypurrCursorAndInternalCallsHaveStrictBoundaries() throws {
        func document(_ more: Bool, _ cursor: Any, _ type: String = "CALL", _ depth: Int = 1) throws -> SolanaJSON {
            let row: [String:Any] = ["tx_hash":hyperHash,"block_number":100,"timestamp":"2026-10-12T00:00:00Z",
                "from_address":hyperOther,"to_address":hyperOwner,"value":"123","success":true,
                "call_type":type,"depth":depth,"call_index":0]
            return try JSONDecoder().decode(SolanaJSON.self,from:JSONSerialization.data(withJSONObject:[
                "success":true,"internal_calls":[row],"has_more":more,"next_cursor":cursor]))
        }
        let json = try HyperEVMClient.normalizeHistory(document(true,"v1:100:0:hash"),owner:hyperOwner,stream:.internalTransactions)
        let result = try HyperEVMClient.decodeHistory(JSONEncoder().encode(json),owner:hyperOwner,stream:.internalTransactions,through:2_000_000_000)
        XCTAssertEqual(result.events.first?.amount,"123"); XCTAssertNotNil(result.next)
        XCTAssertThrowsError(try HyperEVMClient.normalizeHistory(document(true,NSNull()),owner:hyperOwner,stream:.internalTransactions))
        XCTAssertThrowsError(try HyperEVMClient.normalizeHistory(document(false,NSNull(),"CALL",0),owner:hyperOwner,stream:.internalTransactions))
        let delegated = try HyperEVMClient.normalizeHistory(document(false,NSNull(),"DELEGATECALL"),owner:hyperOwner,stream:.internalTransactions)
        XCTAssertEqual(delegated["items"].array?.count,0)
    }
    func testMissingDecimalsResolvedFromContractAndNonstandardLogsRemainRaw() async throws {
        for reverts in [false,true] {
            let client = try HyperEVMClient(apiKey:"fixture", transport:HyperEVMHistoryTransport(indexed:page([transfer()]),missingMetadata:true,metadataReverts:reverts))
            let result = try await client.history(owner:hyperOwner,stream:.transfers,through:2_000_000_000)
            XCTAssertEqual(result.events.count,1)
            XCTAssertEqual(result.events.first?.token?.decimals,reverts ? nil : 6)
            XCTAssertEqual(result.events.first?.amount,"9007199254740993")
            XCTAssertFalse(result.events[0].raw.isEmpty)
        }
    }
    func testWrappedHYPEDepositAndWithdrawalRequireCanonicalContract() throws {
        let wrapper = "0x5555555555555555555555555555555555555555"
        let zero = "0x" + String(repeating:"0",count:40)
        for deposit in [true,false] {
            let row = SolanaJSON.object(["token":.object(["address_hash":.string(wrapper)]),"total":.object(["value":.string("10")]),
                "from":.object(["hash":.string(deposit ? zero:hyperOwner)]),"to":.object(["hash":.string(deposit ? hyperOwner:zero)])])
            let topics:SolanaJSON = .array([.string(deposit ? "0xe1fffcc4923d04b559f4d29a8bfc6cda04eb5b0d3c460751c2402c5c5cc9109c":"0x7fcf532c15f0a6db0bd6d0e038bea71d30d808c7d98cb3bf7268a95bf5081b65"),.string("0x"+String(repeating:"0",count:24)+hyperOwner.dropFirst(2))])
            try HyperEVMClient.verifyTransfer(row,log:.object(["address":.string(wrapper),"data":.string("0xa"),"topics":topics]))
            XCTAssertThrowsError(try HyperEVMClient.verifyTransfer(row,log:.object(["address":.string(hyperToken),"data":.string("0xa"),"topics":topics])))
        }
    }
    func testLiveFundedAccountsBalancesHistoryAndPrices() async throws {
        guard ProcessInfo.processInfo.environment["OATH_HYPEREVM_LIVE"] == "1" else { throw XCTSkip("Opt-in public mainnet read verification") }
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["OATH_ANKR_CONFIG"])
        let config = try PropertyListSerialization.propertyList(from:Data(contentsOf:URL(fileURLWithPath:path)),format:nil) as! [String:String]
        let client = try HyperEVMClient(apiKey:XCTUnwrap(config["AnkrAPIKey"]))
        let markets = HyperEVMMarkets()
        let independentTransport = AnkrHTTPTransport()
        async let catalogTask = markets.catalog()
        async let nativeTask = markets.nativePrice()
        let owners = ["0x8109ea0f4f8b4a63b97781b5a2bc58ff7a1aa26d", "0x5a69a60ca8a4d189855b33bd9f1bbe71095c1039"]
        let catalog = try await catalogTask, native = try await nativeTask
        XCTAssertGreaterThan(catalog.ids.count,20); XCTAssertNotEqual(native.usd,"0")
        for owner in owners {
            let inventory = try await client.inventory(owner:owner)
            XCTAssertEqual(inventory.complete, inventory.holdings.allSatisfy { $0.amount != nil }); XCTAssertGreaterThan(inventory.holdings.count,2)
            XCTAssertNotEqual(inventory.holdings.first{$0.token.reference == "native"}?.amount,"0")
            let refs = inventory.holdings.filter{$0.token.reference != "native"}.map{ $0.token.reference }
            var prices:[HyperEVMPrice] = [], dex:[HyperEVMPrice] = []
            for start in stride(from:0,to:refs.count,by:30) {
                let batch = Array(refs[start..<min(start+30,refs.count)])
                async let cg = markets.prices(references:batch,catalog:catalog)
                async let ds = markets.dexPrices(references:batch)
                prices += try await cg; dex += try await ds
            }
            XCTAssertFalse(prices.isEmpty); XCTAssertTrue((prices+dex).allSatisfy{refs.contains($0.reference)})
            // Independently compare ANKR's entire pinned snapshot to Alchemy.
            let endpoint = URL(string:"https://hyperliquid-mainnet.g.alchemy.com/v2/")!.appendingPathComponent(try XCTUnwrap(config["AlchemyAPIKey"]))
            let height = "0x" + String(inventory.block,radix:16)
            let holdings = inventory.holdings
            var request = URLRequest(url:endpoint); request.httpMethod = "POST"; request.setValue("application/json",forHTTPHeaderField:"Content-Type")
            let calls:[[String:Any]] = holdings.enumerated().map { i,h in
                let native = h.token.reference == "native"
                let params:[Any] = native ? [owner,height] : [["to":h.token.reference,"data":"0x70a08231"+String(repeating:"0",count:24)+owner.dropFirst(2)],height]
                return ["jsonrpc":"2.0","id":i,"method":native ? "eth_getBalance":"eth_call","params":params]
            }
            request.httpBody = try JSONSerialization.data(withJSONObject:calls)
            let (data,status) = try await independentTransport.send(request); XCTAssertEqual(status,200)
            let replies = try XCTUnwrap(JSONDecoder().decode(SolanaJSON.self,from:data).array)
            XCTAssertEqual(replies.count,holdings.count)
            for row in replies {
                let i = try XCTUnwrap(row["id"].integer)
                XCTAssertLessThan(Int(i),holdings.count)
                let amount = try? HyperEVMIdentity.amount(row["result"])
                if let expected = holdings[Int(i)].amount { XCTAssertEqual(amount,expected,"Pinned balance mismatch: " + holdings[Int(i)].token.reference + " at " + height) }
                else {
                    var check = request
                    check.httpBody = try JSONSerialization.data(withJSONObject:["jsonrpc":"2.0","id":1,"method":"eth_call","params":[["to":holdings[Int(i)].token.reference,"data":"0x313ce567"],height]])
                    let (body,_) = try await independentTransport.send(check)
                    let decimals = try JSONDecoder().decode(SolanaJSON.self,from:body)
                    XCTAssertTrue(amount == nil || (try? HyperEVMIdentity.amount(decimals["result"])) != String(holdings[Int(i)].token.decimals),"Unknown amount requires independently confirmed failed call or metadata mismatch")
                }
            }
            for stream in HyperEVMHistoryStream.allCases {
                let page = try await client.history(owner:owner,stream:stream)
                XCTAssertFalse(page.events.isEmpty,"Funded public fixture must exercise each stream")
                if let cursor = page.next {
                    let second = try await client.history(owner:owner,stream:stream,cursor:cursor)
                    XCTAssertTrue(Set(page.events.map(\.id)).isDisjoint(with:Set(second.events.map(\.id))))
                }
                print("HyperEVM live: \(owner), \(stream.rawValue), \(page.events.count) verified events, continuation=\(page.next != nil)")
            }
            print("HyperEVM live: \(owner), block \(inventory.block), \(holdings.filter { $0.amount != nil }.count) balances match independent RPC; \(holdings.filter { $0.amount == nil }.count) failed contracts remain unknown, \(prices.count) CoinGecko quotes and \(dex.count) DEX quotes")
        }
    }
}

/// Exercise URLSession's actual TLS error conversion before the client retries.
private final class HyperEVMTLSFailure: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.secureConnectionFailed)) }
    override func stopLoading() { }
}

private actor HyperEVMRecoveryTransport: AnkrTransport {
    enum Failure: Sendable { case tls, http(Int), cancelled, malformed, afterHead, both }
    let failure: Failure
    let primary = HyperEVMTransport()
    let secondary: HyperEVMTransport
    let tls: AnkrHTTPTransport
    var requests: [URLRequest] = []
    init(_ failure: Failure = .tls, wrongChain: Bool = false, badIDs: Bool = false, reorg: Bool = false) {
        self.failure = failure
        secondary = HyperEVMTransport(wrongChain: wrongChain, reorg: reorg, badIDs: badIDs)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HyperEVMTLSFailure.self]
        tls = AnkrHTTPTransport(session: URLSession(configuration: configuration))
    }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        requests.append(request)
        if request.url?.host == "trace.hypurrscan.io" { return try await primary.send(request) }
        if request.url?.host == "rpc.ankr.com" {
            switch failure {
            case .tls: return try await tls.send(request)
            case .http(let status): return (Data(), status)
            case .cancelled: throw CancellationError()
            case .malformed: return (Data("{}".utf8), 200)
            case .both: throw AnkrError.transport
            case .afterHead:
                let calls = try JSONDecoder().decode(SolanaJSON.self, from: XCTUnwrap(request.httpBody)).array!
                if calls.first?["method"].string == "eth_chainId" { return try await primary.send(request) }
                throw AnkrError.transport
            }
        }
        XCTAssertEqual(request.url?.host, "hyperliquid-mainnet.g.alchemy.com")
        if case .both = failure { throw AnkrError.transport }
        let result = try await secondary.send(request)
        // The secondary provider has advanced to a different block. A recovery
        // must discard the primary snapshot and pin ALL new reads to this head.
        let text = String(decoding: result.0, as: UTF8.self).replacingOccurrences(of: "0x64", with: "0x65")
        return (Data(text.utf8), result.1)
    }
}

final class HyperEVMRecoveryTests: XCTestCase, @unchecked Sendable {
    func testTLSFailureRecoversExactCompleteInventoryUsingIndependentProvider() async throws {
        let transport = HyperEVMRecoveryTransport()
        let client = try HyperEVMClient(apiKey: "fixture", alchemyAPIKey: "recovery-fixture", transport: transport)
        let result = try await client.inventory(owner: hyperOwner)
        XCTAssertTrue(result.complete)
        XCTAssertEqual(result.block, 101)
        XCTAssertEqual(result.holdings.first { $0.token.reference == "native" }?.amount, "9007199254740993")
        XCTAssertEqual(result.holdings.first { $0.token.reference == hyperToken }?.amount, "3000000")
        let requests = await transport.requests
        XCTAssertEqual(requests.filter { $0.url?.host == "rpc.ankr.com" }.count, 3)
        XCTAssertEqual(requests.filter { $0.url?.host == "hyperliquid-mainnet.g.alchemy.com" }.count, 3)
        for request in requests where request.url?.host == "hyperliquid-mainnet.g.alchemy.com" {
            XCTAssertEqual(request.url?.scheme, "https")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(request.url?.lastPathComponent, "recovery-fixture")
        }
        XCTAssertFalse(String(decoding: result.raw, as: UTF8.self).contains("fixture"))
    }

    func testFailureAfterHeadRestartsWholeSnapshotAndPinsEveryBalanceToNewBlock() async throws {
        let transport = HyperEVMRecoveryTransport(.afterHead)
        let result = try await HyperEVMClient(apiKey: "fixture", alchemyAPIKey: "fixture", transport: transport).inventory(owner: hyperOwner)
        XCTAssertEqual(result.block, 101)
        let requests = await transport.requests
        let recovered = requests.filter { $0.url?.host == "hyperliquid-mainnet.g.alchemy.com" }
        XCTAssertEqual(recovered.count, 3)
        for request in recovered {
            let calls = try JSONDecoder().decode(SolanaJSON.self, from: XCTUnwrap(request.httpBody)).array!
            for call in calls where ["eth_call", "eth_getBalance"].contains(call["method"].string ?? "") {
                XCTAssertEqual(call["params"].array?.last?.string, "0x65")
            }
        }
    }

    func testRecoveryStillRejectsWrongChainResponseIDsAndReorganization() async throws {
        for (transport, expected) in [(HyperEVMRecoveryTransport(wrongChain: true), AnkrError.wrongChain),
                                      (HyperEVMRecoveryTransport(badIDs: true), .invalidResponse),
                                      (HyperEVMRecoveryTransport(reorg: true), .invalidResponse)] {
            do {
                _ = try await HyperEVMClient(apiKey: "fixture", alchemyAPIKey: "fixture", transport: transport).inventory(owner: hyperOwner)
                XCTFail("Unverified recovery must fail")
            } catch { XCTAssertEqual(error as? AnkrError, expected) }
        }
    }

    func testCancellationMalformedResponsesAndAuthorizationErrorsDoNotFailOver() async throws {
        for failure in [HyperEVMRecoveryTransport.Failure.cancelled, .malformed, .http(401), .http(403)] {
            let transport = HyperEVMRecoveryTransport(failure)
            do {
                _ = try await HyperEVMClient(apiKey: "fixture", alchemyAPIKey: "fixture", transport: transport).inventory(owner: hyperOwner)
                XCTFail("Invalid/cancelled request succeeded")
            } catch {
                if case .cancelled = failure { XCTAssertTrue(error is CancellationError) }
                else { XCTAssertNotNil(error as? AnkrError) }
            }
            let requests = await transport.requests
            XCTAssertFalse(requests.contains { $0.url?.host == "hyperliquid-mainnet.g.alchemy.com" })
            XCTAssertEqual(requests.filter { $0.url?.host == "rpc.ankr.com" }.count, 1)
        }
    }

    func testPersistentOutageIsBoundedAndRemainsAnError() async throws {
        let transport = HyperEVMRecoveryTransport(.both)
        do {
            _ = try await HyperEVMClient(apiKey: "fixture", alchemyAPIKey: "fixture", transport: transport).inventory(owner: hyperOwner)
            XCTFail("An outage must not become a successful empty balance")
        } catch { XCTAssertEqual(error as? AnkrError, .transport) }
        let requests = await transport.requests
        XCTAssertEqual(requests.filter { $0.url?.host == "rpc.ankr.com" }.count, 3)
        XCTAssertEqual(requests.filter { $0.url?.host == "hyperliquid-mainnet.g.alchemy.com" }.count, 3)
    }

    func testMissingRecoveryConfigurationPreservesOriginalFailure() async throws {
        let transport = HyperEVMRecoveryTransport(.both)
        do { _ = try await HyperEVMClient(apiKey: "fixture", transport: transport).inventory(owner: hyperOwner); XCTFail() }
        catch { XCTAssertEqual(error as? AnkrError, .transport) }
        let requests = await transport.requests
        XCTAssertFalse(requests.contains { $0.url?.host == "hyperliquid-mainnet.g.alchemy.com" })
    }

    func testRateLimitAndServerOutageRecoverWithoutChangingValidation() async throws {
        for status in [429, 503] {
            let transport = HyperEVMRecoveryTransport(.http(status))
            let result = try await HyperEVMClient(apiKey: "fixture", alchemyAPIKey: "fixture", transport: transport).inventory(owner: hyperOwner)
            XCTAssertTrue(result.complete)
            XCTAssertEqual(result.block, 101)
        }
    }
}

private actor HyperEVMRecoveryReports: DiagnosticTransport {
    var events: [DiagnosticEvent] = []
    func upload(_ events: [DiagnosticEvent]) async throws { self.events += events }
}

final class HyperEVMRecoveryDiagnosticsTests: XCTestCase, @unchecked Sendable {
    func testRecoveredTLSFailureRetainsOriginalPrivacyFilteredDiagnostics() async throws {
        let reports = HyperEVMRecoveryReports(), operation = UUID()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        OathDiagnostics.configure(file: file, transport: reports)
        let result = try await OathDiagnostics.$operationID.withValue(operation) {
            try await OathDiagnostics.$chain.withValue("hyperevm") {
                try await HyperEVMClient(apiKey: "privatePrimaryFixture", alchemyAPIKey: "privateRecoveryFixture",
                                         transport: HyperEVMRecoveryTransport()).inventory(owner: hyperOwner)
            }
        }
        XCTAssertTrue(result.complete)
        for _ in 0..<100 {
            await OathDiagnostics.flush()
            if await reports.events.contains(where: { $0.operation == "inventory_rpc_recovery" }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let events = await reports.events.filter { $0.operationID == operation }
        XCTAssertTrue(events.contains { $0.error.domain == NSURLErrorDomain && $0.error.code == -1200 })
        XCTAssertEqual(events.filter { $0.operation == "inventory_rpc_recovery" }.count, 1)
        XCTAssertTrue(events.allSatisfy { $0.privacyFiltered && $0.context["chain"] == "hyperevm" })
        let serialized = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        for secret in ["privatePrimaryFixture", "privateRecoveryFixture", hyperOwner, hyperToken] {
            XCTAssertFalse(serialized.contains(secret), "Diagnostics must not contain keys or wallet data")
        }
    }
}

private struct HyperEVMLiveRecoveryTransport: AnkrTransport {
    let live = AnkrHTTPTransport()
    let tls: AnkrHTTPTransport
    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HyperEVMTLSFailure.self]
        tls = AnkrHTTPTransport(session: URLSession(configuration: configuration))
    }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        if request.url?.host == "rpc.ankr.com" { return try await tls.send(request) }
        if request.url?.host == "trace.hypurrscan.io" {
            // This opt-in test isolates live RPC recovery, not index coverage.
            return (Data("{\"success\":true,\"last_aggregated_block\":0,\"balances\":[]}".utf8), 200)
        }
        return try await live.send(request)
    }
}

final class HyperEVMLiveRecoveryTests: XCTestCase, @unchecked Sendable {
    func testLiveSnapshotRecoveryMatchesIndependentRPCAtIdenticalBlock() async throws {
        guard ProcessInfo.processInfo.environment["OATH_HYPEREVM_RECOVERY_LIVE"] == "1" else {
            throw XCTSkip("Opt-in read-only mainnet RPC recovery check")
        }
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["OATH_ANKR_CONFIG"])
        let config = try PropertyListDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let ankr = try XCTUnwrap(config["AnkrAPIKey"]), alchemy = try XCTUnwrap(config["AlchemyAPIKey"])
        // Existing public fixture account, never a user's wallet or signing key.
        let owner = "0x8109ea0f4f8b4a63b97781b5a2bc58ff7a1aa26d"
        let wrapped = try HyperEVMToken(reference: "0x5555555555555555555555555555555555555555", name: "Wrapped HYPE", symbol: "WHYPE", decimals: 18)
        let client = try HyperEVMClient(apiKey: ankr, alchemyAPIKey: alchemy, transport: HyperEVMLiveRecoveryTransport())
        let inventory = try await client.inventory(owner: owner, tracked: [wrapped])
        XCTAssertTrue(inventory.complete)
        XCTAssertEqual(inventory.holdings.count, 2)
        let height = "0x" + String(inventory.block, radix: 16)
        let calls: [[String: Any]] = [
            ["jsonrpc": "2.0", "id": 1, "method": "eth_chainId", "params": []],
            ["jsonrpc": "2.0", "id": 2, "method": "eth_getBlockByNumber", "params": [height, false]],
            ["jsonrpc": "2.0", "id": 3, "method": "eth_getBalance", "params": [owner, height]],
            ["jsonrpc": "2.0", "id": 4, "method": "eth_call", "params": [["to": wrapped.reference, "data": "0x70a08231" + String(repeating: "0", count: 24) + owner.dropFirst(2)], height]]
        ]
        var request = URLRequest(url: URL(string: "https://rpc.ankr.com/hyperevm")!.appendingPathComponent(ankr))
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: calls)
        let (data, status) = try await AnkrHTTPTransport().send(request)
        XCTAssertEqual(status, 200)
        let rows = try XCTUnwrap(JSONDecoder().decode(SolanaJSON.self, from: data).array)
        func result(_ id: UInt64) throws -> SolanaJSON { try XCTUnwrap(rows.first { $0["id"].integer == id })["result"] }
        XCTAssertEqual(try HyperEVMIdentity.amount(result(1)), "999")
        XCTAssertEqual(try result(2)["hash"].string, inventory.blockHash)
        XCTAssertEqual(try HyperEVMIdentity.amount(result(3)), inventory.holdings.first { $0.token.reference == "native" }?.amount)
        XCTAssertEqual(try HyperEVMIdentity.amount(result(4)), inventory.holdings.first { $0.token.reference == wrapped.reference }?.amount)
        print("Live HyperEVM recovery: chain, pinned block hash, native balance and ERC-20 balance match independent RPC")
    }
}
