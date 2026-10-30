import XCTest
@testable import OathAnkr

final class ZeroGLiveTests: XCTestCase, @unchecked Sendable {
    private func read(_ url: String, body: Any? = nil) async throws -> SolanaJSON {
        var request = URLRequest(url: URL(string:url)!); request.timeoutInterval = 45
        request.setValue("OathWallet/1.0",forHTTPHeaderField:"User-Agent")
        if let body { request.httpMethod = "POST"; request.setValue("application/json",forHTTPHeaderField:"Content-Type"); request.httpBody = try JSONSerialization.data(withJSONObject:body) }
        let (data,status) = try await AnkrHTTPTransport().send(request)
        guard status == 200 else { throw AnkrError.http(status) }
        return try JSONDecoder().decode(SolanaJSON.self,from:data)
    }
    func testFundedMainnetAccountsAgainstRPCExplorerAndMarkets() async throws {
        guard ProcessInfo.processInfo.environment["OATH_ZEROG_LIVE"] == "1" else { throw XCTSkip("Opt-in public 0G reads") }
        let config = try XCTUnwrap(ProcessInfo.processInfo.environment["OATH_ANKR_CONFIG"])
        let keys = try PropertyListSerialization.propertyList(from:Data(contentsOf:URL(fileURLWithPath:config)),format:nil) as! [String:String]
        let client = try IndexedEVMClient(chain:.zerog,apiKey:XCTUnwrap(keys["AnkrAPIKey"]))
        let markets = IndexedEVMMarkets(chain:.zerog)
        async let nativeTask = markets.nativePrice()
        async let catalogTask = markets.catalog()
        let (native,catalog) = try await (nativeTask,catalogTask)
        var evidence: [[String:Any]] = []
        for owner in ["0x464fc339add314932920d3e060745bd7ea3e92ad", "0xb143f6ca55358fac056eca7ac1a228a1f018b048"] {
            let inventory = try await client.inventory(owner:owner)
            XCTAssertTrue(inventory.complete)
            let holdings = inventory.holdings, tokens = holdings.filter { $0.token.reference != "native" }
            XCTAssertGreaterThanOrEqual(tokens.count,4)
            let block = "0x" + String(inventory.block,radix:16)
            let calls: [[String:Any]] = [["jsonrpc":"2.0","id":0,"method":"eth_chainId","params":[]]] + holdings.enumerated().map { i,h in
                ["jsonrpc":"2.0","id":i+1,"method":h.token.reference == "native" ? "eth_getBalance":"eth_call",
                 "params":h.token.reference == "native" ? [owner,block] : [["to":h.token.reference,"data":"0x70a08231"+String(repeating:"0",count:24)+owner.dropFirst(2)],block]]
            }
            async let independentTask = read("https://evmrpc.0g.ai",body:calls)
            async let explorerTask = read("https://chainscan.0g.ai/v1/token?accountAddress="+owner)
            let (independent,explorer) = try await (independentTask,explorerTask)
            let rows = try XCTUnwrap(independent.array)
            XCTAssertEqual(rows.first{$0["id"].integer == 0}?["result"].string,"0x4115")
            for (i,h) in holdings.enumerated() {
                let row = try XCTUnwrap(rows.first{$0["id"].integer == UInt64(i+1)})
                XCTAssertEqual(try IndexedEVMIdentity.amount(row["result"]),h.amount)
            }
            let explorerNative = try await read("https://chainscan.0g.ai/open/api?module=account&action=balancehistory&address="+owner+"&blockno="+String(inventory.block))
            XCTAssertEqual(explorerNative["status"].string,"1")
            XCTAssertEqual(explorerNative["result"].text,holdings.first{$0.token.reference == "native"}?.amount)
            let explorerRows = try XCTUnwrap(explorer["result"]["list"].array)
            let indexed = Dictionary(uniqueKeysWithValues:try explorerRows.map { (try XCTUnwrap($0["address"].string).lowercased(),$0) })
            XCTAssertEqual(Set(tokens.map{$0.token.reference}),Set(indexed.keys))
            for holding in tokens {
                let row = try XCTUnwrap(indexed[holding.token.reference])
                XCTAssertEqual(holding.amount,row["balance"].text)
                XCTAssertEqual(String(holding.token.decimals),row["decimals"].text)
            }
            let refs = tokens.map{$0.token.reference}
            var quotes = try await markets.prices(references:refs,catalog:catalog)
            let missing = refs.filter { ref in !quotes.contains{$0.reference == ref} }
            if !missing.isEmpty { quotes += try await markets.dexPrices(references:missing) }
            XCTAssertFalse(quotes.isEmpty)
            let terminal = try await read("https://api.geckoterminal.com/api/v2/networks/0g/tokens/multi/"+refs.joined(separator:","))
            var compared = 0
            for quote in quotes {
                let match = try XCTUnwrap(terminal["data"].array?.first{$0["id"].string == "0g_"+quote.reference})
                let reference = try XCTUnwrap(match["attributes"]["price_usd"].text.flatMap(Double.init))
                XCTAssertLessThan(abs(try XCTUnwrap(Double(quote.usd))/reference-1),0.10)
                if quote.reference == IndexedEVMChain.zerog.wrappedNative {
                    XCTAssertLessThan(abs(reference / (try XCTUnwrap(Double(native.usd))) - 1),0.10)
                }
                compared += 1
            }
            let end = Date().timeIntervalSince1970
            let history = try await withThrowingTaskGroup(of:(String,Int).self) { group in
                for stream in IndexedEVMChain.zerog.historyStreams {
                    group.addTask {
                        let first = try await client.history(owner:owner,stream:stream,through:end)
                        var count = first.events.count
                        if let next = first.next {
                            let second = try await client.history(owner:owner,stream:stream,cursor:next,through:end)
                            XCTAssertTrue(Set(first.events.map(\.id)).isDisjoint(with:Set(second.events.map(\.id))))
                            count += second.events.count
                        }
                        return (stream.rawValue,count)
                    }
                }
                var result: [String:Int] = [:]
                for try await (stream,count) in group { result[stream] = count }
                return result
            }
            XCTAssertGreaterThan(history["transactions"] ?? 0,0)
            XCTAssertGreaterThan(history["transfers"] ?? 0,0)
            evidence.append(["address":owner,"block":inventory.block,"blockHash":inventory.blockHash,
                "holdings":holdings.map{["reference":$0.token.reference,"symbol":$0.token.symbol,"decimals":String($0.token.decimals),"amount":$0.amount ?? "unknown"]},
                "balancesMatchIndependentRPC":true,"nativeAndTokenBalancesMatchExplorer":true,
                "prices":quotes.map{["reference":$0.reference,"usd":$0.usd,"source":$0.source]},"pricesCompared":compared,
                "unpricedReferences":refs.filter { ref in !quotes.contains{$0.reference == ref} },"verifiedHistoryEventsFirstTwoPages":history])
        }
        // Exercise contract-internal native transfers on the official storage contract.
        let internalPage = try await client.history(owner:"0x62d4144db0f0a6fbbaeb6296c785c71b3d57c526",stream:.internalTransactions)
        XCTAssertGreaterThan(internalPage.events.count,0)
        if let output = ProcessInfo.processInfo.environment["OATH_ZEROG_REPORT"] {
            let report: [String:Any] = ["network":"zerog","chainID":16661,"symbol":"0G","checkedAt":Date().ISO8601Format(),
                "nativePriceUSD":native.usd,"nativePriceSource":native.source,"accounts":evidence,
                "storageContractVerifiedInternalTransfers":internalPage.events.count,
                "explorerPriceNote":"ChainScan reports null prices; compared contract-specific quotes against GeckoTerminal instead."]
            try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:output))
        }
    }
    func testLiveFallbacks() async throws {
        guard ProcessInfo.processInfo.environment["OATH_ZEROG_LIVE"] == "1" else { throw XCTSkip("Opt-in public 0G fallbacks") }
        let transport = ZeroGFallbackTransport()
        let client = try IndexedEVMClient(chain:.zerog,apiKey:"fixture",transport:transport)
        let markets = IndexedEVMMarkets(chain:.zerog,transport:transport)
        async let inventoryTask = client.inventory(owner:"0x464fc339add314932920d3e060745bd7ea3e92ad")
        async let catalogTask = markets.catalog()
        async let nativeTask = markets.nativePrice()
        let (inventory,catalog,native) = try await (inventoryTask,catalogTask,nativeTask)
        XCTAssertTrue(inventory.complete); XCTAssertGreaterThan(inventory.holdings.count,4)
        XCTAssertEqual(catalog.ids[IndexedEVMChain.zerog.wrappedNative],"wrapped-0g")
        var quotes = try await markets.prices(references:[IndexedEVMChain.zerog.wrappedNative],catalog:catalog)
        if quotes.isEmpty { quotes = try await markets.dexPrices(references:[IndexedEVMChain.zerog.wrappedNative]) }
        XCTAssertTrue(["DefiLlama","GeckoTerminal"].contains(quotes.first?.source ?? ""))
        XCTAssertLessThan(abs(try XCTUnwrap(quotes.first.flatMap{Double($0.usd)})/XCTUnwrap(Double(native.usd))-1),0.10)
        let history = try await client.history(owner:"0xb143f6ca55358fac056eca7ac1a228a1f018b048",stream:.transactions)
        XCTAssertFalse(history.events.isEmpty)
    }
}
private struct ZeroGFallbackTransport: AnkrTransport {
    private let live = AnkrHTTPTransport()
    func send(_ request: URLRequest) async throws -> (Data,Int) {
        if request.url?.host == "rpc.ankr.com" { throw AnkrError.transport }
        if request.url?.host == "api.coingecko.com", !(request.url?.query?.contains("ids=zero-gravity&") ?? false) { return (Data(),429) }
        return try await live.send(request)
    }
}
