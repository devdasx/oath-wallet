import XCTest
@testable import OathAnkr

final class IoTeXLiveTests: XCTestCase, @unchecked Sendable {
    private func read(_ url: String, body: Any? = nil) async throws -> SolanaJSON {
        var request = URLRequest(url: URL(string:url)!); request.timeoutInterval = 40
        request.setValue("OathWallet/1.0", forHTTPHeaderField:"User-Agent")
        request.setValue("application/json", forHTTPHeaderField:"Content-Type")
        if let body { request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject:body) }
        for attempt in 0..<4 {
            let (data,status) = try await AnkrHTTPTransport().send(request)
            if status == 429, attempt < 3 {
                try await Task.sleep(for: .seconds(8 * (attempt + 1)))
                continue
            }
            guard status == 200 else { throw AnkrError.http(status) }
            return try JSONDecoder().decode(SolanaJSON.self,from:data)
        }
        throw AnkrError.http(429)
    }
    func testFundedMainnetAccounts() async throws {
        guard ProcessInfo.processInfo.environment["OATH_IOTEX_LIVE"] == "1" else { throw XCTSkip("Opt-in public IoTeX reads") }
        let config = try XCTUnwrap(ProcessInfo.processInfo.environment["OATH_ANKR_CONFIG"])
        let keys = try PropertyListSerialization.propertyList(from:Data(contentsOf:URL(fileURLWithPath:config)),format:nil) as! [String:String]
        let client = try IndexedEVMClient(chain:.iotex,apiKey:XCTUnwrap(keys["AnkrAPIKey"]), transport:AnkrHTTPTransport())
        let markets = IndexedEVMMarkets(chain:.iotex)
        async let nativeTask = markets.nativePrice()
        async let catalogTask = markets.catalog()
        let (native,catalog) = try await (nativeTask,catalogTask)
        let explorerPrice = try await read("https://dev.iotexscan.io/api?module=stats&action=iotxprice")
        let benchmark = try XCTUnwrap(explorerPrice["result"]["ethusd"].text.flatMap(Double.init))
        XCTAssertLessThan(abs(try XCTUnwrap(Double(native.usd))/benchmark-1),0.05)
        var accounts: [[String:Any]] = []
        for owner in ["0xcf3aad8dc49158fd15b59a6dae41f1f52236aef3", "0xac37caedae8a33785f20839acd14a1f3682b89d8"] {
            let inventory = try await client.inventory(owner: owner)
            XCTAssertTrue(inventory.complete)
            XCTAssertGreaterThan(inventory.holdings.count,9)
            XCTAssertNotEqual(inventory.holdings.first{$0.token.reference == "native"}?.amount,"0")
            let tag = "0x" + String(inventory.block,radix:16)
            let holdings = inventory.holdings
            let calls: [[String:Any]] = [["jsonrpc":"2.0","id":0,"method":"eth_chainId","params":[]]] + holdings.enumerated().map { i,h in
                ["jsonrpc":"2.0","id":i+1,"method":h.token.reference == "native" ? "eth_getBalance":"eth_call",
                 "params":h.token.reference == "native" ? [owner,tag] : [["to":h.token.reference,"data":"0x70a08231"+String(repeating:"0",count:24)+owner.dropFirst(2)],tag]]
            }
            let other = try await read("https://archive-mainnet.iotex.io",body:calls)
            let responses = try XCTUnwrap(other.array)
            XCTAssertEqual(responses.first{$0["id"].integer == 0}?["result"].string,"0x1251")
            for (i,holding) in holdings.enumerated() {
                let row = try XCTUnwrap(responses.first{$0["id"].integer == UInt64(i+1)})
                XCTAssertEqual(holding.amount,try IndexedEVMIdentity.amount(row["result"]))
            }
            let explorer = try await read("https://dev.iotexscan.io/api?module=token&action=addresstokenbalance&address="+owner+"&page=1&offset=50")
            let index = try IoTeXIndex.rows(explorer)
            let tokens = holdings.filter{$0.token.reference != "native"}
            XCTAssertEqual(Set(tokens.map{$0.token.reference}),Set(index.compactMap{$0["TokenAddress"].string?.lowercased()}))
            var explorerDifferences: [[String:String]] = []
            for holding in tokens {
                let row = try XCTUnwrap(index.first{$0["TokenAddress"].string?.lowercased() == holding.token.reference})
                XCTAssertEqual(row["TokenDivisor"].text,String(holding.token.decimals))
                let indexed = try XCTUnwrap(row["TokenQuantity"].text), actual = try XCTUnwrap(holding.amount)
                // Explorer list quantities round large atomic balances. RPC remains exact.
                let ratio = abs(try XCTUnwrap(Double(indexed))/XCTUnwrap(Double(actual))-1)
                XCTAssertLessThan(ratio,0.000001)
                if indexed != actual { explorerDifferences.append(["reference":holding.token.reference,"index":indexed,"exactRPC":actual]) }
            }
            let refs = tokens.map{$0.token.reference}
            var quotes = try await markets.prices(references:refs,catalog:catalog)
            let missing = refs.filter{ref in !quotes.contains{$0.reference == ref}}
            if !missing.isEmpty { quotes += try await markets.dexPrices(references:missing) }
            XCTAssertTrue(quotes.contains { $0.reference == IndexedEVMChain.iotex.wrappedNative }, "The liquid wrapped IOTX market must have a verified quote")
            let terminal = try await read("https://api.geckoterminal.com/api/v2/networks/iotx/tokens/multi/"+refs.joined(separator:","))
            var comparisons: [[String:Any]] = []
            for quote in quotes {
                if let reference = terminal["data"].array?.first(where:{$0["id"].string == "iotx_"+quote.reference})?["attributes"]["price_usd"].text.flatMap(Double.init) {
                    let difference = abs(try XCTUnwrap(Double(quote.usd))/reference-1)
                    comparisons.append(["reference":quote.reference,"quoteUSD":quote.usd,"marketUSD":reference,"relativeDifference":difference])
                    XCTAssertLessThan(difference,0.15)
                }
            }
            XCTAssertGreaterThanOrEqual(comparisons.count,1)
            var history: [String:Int] = [:]
            for stream in IndexedEVMChain.iotex.historyStreams {
                print("Verifying IoTeX stream", stream.rawValue)
                let first = try await client.history(owner:owner,stream:stream)
                var ids = Set(first.events.map(\.id))
                if let next = first.next {
                    let second = try await client.history(owner:owner,stream:stream,cursor:next)
                    // A receipt spanning a page repeats stable IDs, not new entries.
                    ids.formUnion(second.events.map(\.id))
                    XCTAssertNotEqual(next,second.next)
                }
                history[stream.rawValue] = ids.count
            }
            XCTAssertGreaterThan(history["transactions"] ?? 0,0)
            XCTAssertGreaterThan(history["transfers"] ?? 0,0)
            accounts.append(["address":owner,"block":inventory.block,"blockHash":inventory.blockHash,
                "holdings":holdings.map{["reference":$0.token.reference,"symbol":$0.token.symbol,"decimals":String($0.token.decimals),"amount":$0.amount ?? "unknown"]},
                "balancesMatchIndependentRPC":true,"comparisonRPC":"archive-mainnet.iotex.io","tokenInventoryMatchesExplorer":true,"explorerRoundingDifferences":explorerDifferences,
                "prices":quotes.map{["reference":$0.reference,"usd":$0.usd,"source":$0.source]},"priceComparisons":comparisons,
                "unpricedReferences":refs.filter{ref in !quotes.contains{$0.reference == ref}},"verifiedHistoryEventsFirstTwoPages":history])
        }
        let internalPage = try await client.history(owner:"0xa6eb3902ca74265b7e5a1f66d39fa0cec0ca38ff",stream:.internalTransactions)
        XCTAssertGreaterThan(internalPage.events.count,0)
        if let output = ProcessInfo.processInfo.environment["OATH_IOTEX_REPORT"], testRun?.totalFailureCount == 0 {
            let report: [String:Any] = ["network":"iotex","chainID":4689,"symbol":"IOTX","checkedAt":Date().ISO8601Format(),
                "nativePriceUSD":native.usd,"explorerNativePriceUSD":benchmark,"nativePriceSource":native.source,"accounts":accounts,
                "verifiedRouterInternalTransfers":internalPage.events.count,
                "nativeHistoryEvidence":"Committed native transaction logs verified against RPC receipt block hashes. Replayed call traces were rejected after a live amount mismatch.",
                "explorerPrecisionNote":"IoTeXScan token-list quantities round large atomic values. App balances retain exact RPC integers, matched to a separate archive RPC at the same block."]
            try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:output))
        }
    }
    func testUnusedAccountAndExplorerPriceFallback() async throws {
        guard ProcessInfo.processInfo.environment["OATH_IOTEX_LIVE"] == "1" else { throw XCTSkip("Opt-in public IoTeX reads") }
        let transport = IoTeXFallbackTransport(blockLlama: true)
        let client = try IndexedEVMClient(chain: .iotex, apiKey: "fixture", transport: transport)
        let owner = "0x611f871a4026d06f2439ef0e7d22377be8599901"
        async let inventoryTask = client.inventory(owner: owner)
        async let priceTask = IndexedEVMMarkets(chain: .iotex, transport: transport).nativePrice()
        let (inventory, price) = try await (inventoryTask, priceTask)
        XCTAssertTrue(inventory.complete)
        XCTAssertEqual(inventory.holdings.count, 1)
        XCTAssertEqual(inventory.holdings.first?.amount, "0")
        XCTAssertEqual(price.source, "IoTeXScan")
        for stream in IndexedEVMChain.iotex.historyStreams {
            let page = try await client.history(owner: owner, stream: stream)
            XCTAssertTrue(page.events.isEmpty); XCTAssertNil(page.next)
        }
    }
    func testProviderFallbacks() async throws {
        guard ProcessInfo.processInfo.environment["OATH_IOTEX_LIVE"] == "1" else { throw XCTSkip("Opt-in public IoTeX reads") }
        let fallback = IoTeXFallbackTransport()
        let fallbackClient = try IndexedEVMClient(chain:.iotex,apiKey:"fixture",transport:fallback)
        let fallbackMarkets = IndexedEVMMarkets(chain:.iotex,transport:fallback)
        async let fallbackInventoryTask = fallbackClient.inventory(owner:"0xac37caedae8a33785f20839acd14a1f3682b89d8")
        async let fallbackCatalogTask = fallbackMarkets.catalog()
        async let fallbackPriceTask = fallbackMarkets.nativePrice()
        let (fallbackInventory, fallbackCatalog, fallbackPrice) = try await (fallbackInventoryTask, fallbackCatalogTask, fallbackPriceTask)
        XCTAssertTrue(fallbackInventory.complete)
        XCTAssertEqual(fallbackCatalog.ids[IndexedEVMChain.iotex.wrappedNative],"wrapped-iotex")
        XCTAssertGreaterThan(try XCTUnwrap(Double(fallbackPrice.usd)),0)
        let fallbackHistory = try await fallbackClient.history(owner:"0xac37caedae8a33785f20839acd14a1f3682b89d8",stream:.transactions)
        XCTAssertFalse(fallbackHistory.events.isEmpty)
        let fallbackQuotes = try await fallbackMarkets.prices(references:[IndexedEVMChain.iotex.wrappedNative],catalog:fallbackCatalog)
        XCTAssertEqual(fallbackQuotes.first?.source,"DefiLlama")
        if let output = ProcessInfo.processInfo.environment["OATH_IOTEX_REPORT"], testRun?.totalFailureCount == 0 {
            let report: [String:Any] = ["chain":"iotex", "checkedAt":Date().ISO8601Format(),
                "forcedAnkrOutageFallbackVerified":true,"forcedCatalogAndTokenQuoteFallbackVerified":true,
                "fallbackHoldings":fallbackInventory.holdings.count,"fallbackHistoryEvents":fallbackHistory.events.count,
                "nativePriceSource":fallbackPrice.source,"tokenPriceSource":fallbackQuotes.first?.source ?? ""]
            try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:output.replacingOccurrences(of:".json",with:"-fallbacks.json")))
        }
    }

}
private struct IoTeXFallbackTransport: AnkrTransport {
    var blockLlama = false
    private let live = AnkrHTTPTransport()
    func send(_ request: URLRequest) async throws -> (Data,Int) {
        if request.url?.host == "rpc.ankr.com" { throw AnkrError.transport }
        if request.url?.host == "api.coingecko.com" { return (Data(),429) }
        if blockLlama, request.url?.host == "coins.llama.fi" { return (Data(),429) }
        return try await live.send(request)
    }
}
