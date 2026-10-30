import XCTest
@testable import OathAnkr
import OathDiagnostics

private actor SeiLiveDiagnostics: DiagnosticTransport {
    func upload(_ events: [DiagnosticEvent]) async throws {
        for event in events { print("Sei validation diagnostic: \(event.sourceFile):\(event.sourceLine) \(event.operation) \(event.context["reason"] ?? event.error.message)") }
    }
}

final class SeiLiveTests: XCTestCase, @unchecked Sendable {
    private func read(_ url: String, body: Any? = nil) async throws -> SolanaJSON {
        var request = URLRequest(url: URL(string: url)!); request.timeoutInterval = 40
        request.setValue("OathWallet/1.0", forHTTPHeaderField: "User-Agent")
        if let body {
            request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data,status) = try await AnkrHTTPTransport().send(request)
        guard status == 200 else { throw AnkrError.http(status) }
        return try JSONDecoder().decode(SolanaJSON.self, from: data)
    }
    func testFundedMainnetAccountsWithIndependentRPCAndExplorer() async throws {
        guard ProcessInfo.processInfo.environment["OATH_SEI_LIVE"] == "1" else { throw XCTSkip("Opt-in public Sei reads") }
        OathDiagnostics.configure(file: FileManager.default.temporaryDirectory.appendingPathComponent("sei-live-diagnostics.json"), transport: SeiLiveDiagnostics())
        let config = try XCTUnwrap(ProcessInfo.processInfo.environment["OATH_ANKR_CONFIG"])
        let keys = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: config)), format: nil) as! [String:String]
        let client = try IndexedEVMClient(chain: .sei, apiKey: XCTUnwrap(keys["AnkrAPIKey"]), alchemyAPIKey: keys["AlchemyAPIKey"])
        let markets = IndexedEVMMarkets(chain: .sei)
        async let nativeTask = markets.nativePrice()
        async let catalogTask = markets.catalog()
        let (native,catalog) = try await (nativeTask,catalogTask)
        let comparison = try await read("https://coins.llama.fi/prices/current/coingecko:sei-network")
        let referencePrice = try XCTUnwrap(comparison["coins"]["coingecko:sei-network"]["price"].text.flatMap(Double.init))
        XCTAssertLessThan(abs(try XCTUnwrap(Double(native.usd)) / referencePrice - 1),0.05)
        var evidence: [[String:Any]] = []
        for owner in ["0x726b000328edc9ee56fa125b24c29b0e62b7b28b", "0xf977814e90da44bfa03b6295a0616a897441acec"] {
            let inventory = try await client.inventory(owner:owner)
            XCTAssertTrue(inventory.complete)
            let holdings = inventory.holdings, tokens = holdings.filter { $0.token.reference != "native" }
            XCTAssertGreaterThanOrEqual(tokens.count,2)
            let block = "0x" + String(inventory.block,radix:16)
            let calls: [[String:Any]] = holdings.enumerated().map { i,h in
                ["jsonrpc":"2.0","id":i + 1,"method":h.token.reference == "native" ? "eth_getBalance":"eth_call",
                 "params":h.token.reference == "native" ? [owner,block] : [["to":h.token.reference,"data":"0x70a08231" + String(repeating:"0",count:24) + owner.dropFirst(2)],block]]
            }
            let independent = try await read("https://evm-rpc.sei-apis.com",body:calls)
            let rows = try XCTUnwrap(independent.array)
            for (i,h) in holdings.enumerated() {
                let row = try XCTUnwrap(rows.first { $0["id"].integer == UInt64(i + 1) })
                XCTAssertEqual(try IndexedEVMIdentity.amount(row["result"]),h.amount)
            }
            var indexed: [String:SolanaJSON] = [:], query = "limit=50", pages = 0
            repeat {
                let page = try await read("https://api-v2.seistream.app/api/v2/evm/accounts/" + owner + "/tokens?" + query)
                for row in try XCTUnwrap(page["items"].array) where row["token"]["tokenType"].string == "erc20" {
                    indexed[try XCTUnwrap(row["token"]["hash"].string).lowercased()] = row
                }
                pages += 1; guard pages <= 20 else { throw AnkrError.paginationLoop }
                if page["pagination"]["hasMore"] == .bool(true) {
                    let normalized = try SeiIndex.normalize(page,resource:"tokens")
                    guard case .object(let params) = normalized["next_page_params"] else { throw AnkrError.invalidResponse }
                    var components = URLComponents(); components.queryItems = try SeiIndex.parameters(params); query = components.percentEncodedQuery!
                } else { query = "" }
            } while !query.isEmpty
            XCTAssertEqual(Set(tokens.map { $0.token.reference }),Set(indexed.keys))
            for h in tokens {
                let row = try XCTUnwrap(indexed[h.token.reference])
                XCTAssertEqual(h.amount,row["balance"].text)
                XCTAssertEqual(String(h.token.decimals),row["token"]["decimals"].text)
            }
            let refs = tokens.map { $0.token.reference }
            var quotes = try await markets.prices(references:refs,catalog:catalog)
            let missing = refs.filter { ref in !quotes.contains { $0.reference == ref } }
            if !missing.isEmpty { quotes += try await markets.dexPrices(references:missing) }
            XCTAssertFalse(quotes.isEmpty)
            var pricesCompared = 0
            var explorerPriceDifferences: [[String:String]] = []
            let independentPrices = try await read("https://api.geckoterminal.com/api/v2/networks/sei-evm/tokens/multi/" + refs.joined(separator:","))
            let independentTokens = try XCTUnwrap(independentPrices["data"].array)
            for q in quotes {
                if let price = indexed[q.reference]?["priceUsd"].text.flatMap(Double.init), price > 0 {
                    let value = try XCTUnwrap(Double(q.usd))
                    if abs(value / price - 1) < 0.15 { pricesCompared += 1 }
                    else {
                        let corroboration = try XCTUnwrap(independentTokens.first { $0["attributes"]["address"].string?.lowercased() == q.reference })
                        let independentPrice = try XCTUnwrap(corroboration["attributes"]["price_usd"].text.flatMap(Double.init))
                        XCTAssertLessThan(abs(value / independentPrice - 1),0.05,q.reference)
                        explorerPriceDifferences.append(["reference":q.reference,"appUSD":q.usd,"explorerUSD":String(price),"independentDEXUSD":String(independentPrice)])
                    }
                }
            }
            var history: [String:Int] = [:]
            var unavailableHistory: [String:String] = [:]
            for stream in IndexedEVMChain.sei.historyStreams {
                print("Sei public history check: \(owner) \(stream.rawValue)")
                let first = try await client.history(owner:owner,stream:stream)
                var events = first.events
                if let next = first.next {
                    do {
                        let second = try await client.history(owner:owner,stream:stream,cursor:next)
                        XCTAssertTrue(Set(first.events.map(\.id)).isDisjoint(with:Set(second.events.map(\.id))))
                        events += second.events
                    } catch {
                        // This public account received three January Grit airdrops.
                        // Live archive nodes currently fail to decode those blocks.
                        // Assert and report incomplete coverage; never call it empty.
                        guard owner == "0xf977814e90da44bfa03b6295a0616a897441acec", stream == .transfers,
                              [.rpc(-32603), .rpc(-32000)].contains(error as? AnkrError) else { throw error }
                        unavailableHistory[stream.rawValue] = "Older page unavailable: archive RPC cannot decode January 2026 blocks. Cursor remains incomplete."
                    }
                }
                history[stream.rawValue] = events.count
            }
            XCTAssertGreaterThan(history.values.reduce(0,+),0)
            evidence.append(["address":owner,"block":inventory.block,"blockHash":inventory.blockHash,
                "holdings":holdings.map { ["reference":$0.token.reference,"symbol":$0.token.symbol,"decimals":String($0.token.decimals),"amount":$0.amount ?? "unknown"] },
                "allBalancesMatchIndependentRPC":true,"allTokenBalancesMatchExplorer":true,"pricesCompared":pricesCompared,"explorerPriceDifferences":explorerPriceDifferences,
                "prices":quotes.map { ["reference":$0.reference,"usd":$0.usd,"source":$0.source] },"verifiedHistoryEventsFirstTwoPages":history,"unavailableHistory":unavailableHistory])
        }
        if let output = ProcessInfo.processInfo.environment["OATH_SEI_REPORT"] {
            let report: [String:Any] = ["network":"sei","chainID":1329,"checkedAt":ISO8601DateFormatter().string(from:Date()),
                "nativePriceUSD":native.usd,"nativePriceSource":native.source,"independentNativePriceUSD":referencePrice,"accounts":evidence]
            try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:output))
        }
    }
}

private struct SeiForcedFallbackTransport: AnkrTransport {
    private let live = AnkrHTTPTransport()
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        switch request.url?.host {
        case "rpc.ankr.com": throw AnkrError.transport
        case "api.coinbase.com": return (Data(),503)
        case "api.coingecko.com": return (Data(),429)
        default: return try await live.send(request)
        }
    }
}
extension SeiLiveTests {
    func testLivePublicRPCAndPriceFallbacks() async throws {
        guard ProcessInfo.processInfo.environment["OATH_SEI_LIVE"] == "1" else { throw XCTSkip("Opt-in public Sei fallbacks") }
        let transport = SeiForcedFallbackTransport()
        let client = try IndexedEVMClient(chain:.sei,apiKey:"fixture",transport:transport)
        let markets = IndexedEVMMarkets(chain:.sei,transport:transport)
        async let inventoryTask = client.inventory(owner:"0x726b000328edc9ee56fa125b24c29b0e62b7b28b")
        async let quoteTask = markets.nativePrice()
        async let catalogTask = markets.catalog()
        let (inventory,quote,catalog) = try await (inventoryTask,quoteTask,catalogTask)
        XCTAssertTrue(inventory.complete)
        XCTAssertGreaterThan(inventory.holdings.count,5)
        XCTAssertEqual(quote.source,"DefiLlama")
        let usdc = "0xe15fc38f6d8c56af07bbcbe3baf5708a2bf42392"
        XCTAssertEqual(catalog.ids[usdc],"usd-coin")
        let prices = try await markets.prices(references:[usdc],catalog:catalog)
        XCTAssertEqual(prices.first?.source,"DefiLlama")
        let value = try XCTUnwrap(prices.first.flatMap { Double($0.usd) })
        XCTAssertGreaterThan(value,0.9); XCTAssertLessThan(value,1.1)
        let dex = try await markets.dexPrices(references:[IndexedEVMChain.sei.wrappedNative])
        XCTAssertEqual(dex.first?.source,"GeckoTerminal")
        XCTAssertLessThan(abs(try XCTUnwrap(dex.first.flatMap { Double($0.usd) }) / XCTUnwrap(Double(quote.usd)) - 1),0.05)
        print("Sei live fallbacks: \(inventory.holdings.count) official-RPC balances, bundled exact-contract catalog, DefiLlama SEI/USDC prices and GeckoTerminal WSEI price")
    }
}
