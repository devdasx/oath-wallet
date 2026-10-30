import XCTest
@testable import OathAnkr

final class ChilizLiveTests: XCTestCase, @unchecked Sendable {
    private func json(_ url: URL, body: Any? = nil) async throws -> SolanaJSON {
        var request = URLRequest(url: url)
        request.setValue("OathWallet/1.0", forHTTPHeaderField: "User-Agent")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, status) = try await AnkrHTTPTransport().send(request)
        XCTAssertEqual(status, 200)
        return try JSONDecoder().decode(SolanaJSON.self, from: data)
    }
    func testPublicAccountsBalancesHistoryAndPrices() async throws {
        guard ProcessInfo.processInfo.environment["OATH_CHILIZ_LIVE"] == "1" else { throw XCTSkip("Opt-in public Chiliz reads") }
        let config = try XCTUnwrap(ProcessInfo.processInfo.environment["OATH_ANKR_CONFIG"])
        let keys = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: config)), format: nil) as! [String: String]
        let client = try IndexedEVMClient(chain: .chiliz, apiKey: XCTUnwrap(keys["AnkrAPIKey"]))
        let markets = IndexedEVMMarkets(chain: .chiliz)
        async let catalogTask = markets.catalog()
        async let nativeTask = markets.nativePrice()
        let (catalog, native) = try await (catalogTask, nativeTask)
        XCTAssertGreaterThan(catalog.ids.count, 10)
        let explorerStats = try await json(URL(string: "https://scan-api.chiliz.com/api/v2/stats")!)
        let explorerPrice = try XCTUnwrap(explorerStats["coin_price"].text.flatMap(Double.init))
        let nativePrice = try XCTUnwrap(Double(native.usd))
        XCTAssertLessThan(abs(nativePrice / explorerPrice - 1), 0.1)
        var evidence: [[String: Any]] = []
        for owner in ["0xf977814e90da44bfa03b6295a0616a897441acec", "0xc80afd311c9626528de66d86814770361fe92416", "0xf89d7b9c864f589bbf53a82105107622b35eaa40"] {
            let snapshot = try await client.inventory(owner: owner)
            XCTAssertTrue(snapshot.complete)
            XCTAssertGreaterThan(snapshot.holdings.count, 10)
            let block = "0x" + String(snapshot.block, radix: 16)
            var matched = 0
            for offset in stride(from: 0, to: snapshot.holdings.count, by: 20) {
                let holdings = Array(snapshot.holdings[offset..<min(offset + 20, snapshot.holdings.count)])
                let calls: [[String: Any]] = holdings.enumerated().map { i, holding in
                    let ref = holding.token.reference
                    return ["jsonrpc": "2.0", "id": i + 1, "method": ref == "native" ? "eth_getBalance" : "eth_call",
                            "params": ref == "native" ? [owner, block] : [["to": ref, "data": "0x70a08231" + String(repeating: "0", count: 24) + owner.dropFirst(2)], block]]
                }
                let replies = try await json(URL(string: "https://chiliz-rpc.publicnode.com")!, body: calls)
                let rows = try XCTUnwrap(replies.array)
                for (i, holding) in holdings.enumerated() {
                    let row = try XCTUnwrap(rows.first { $0["id"].integer == UInt64(i + 1) })
                    XCTAssertEqual(try IndexedEVMIdentity.amount(row["result"]), holding.amount)
                    matched += 1
                }
            }
            var indexed: [String: SolanaJSON] = [:], next: [URLQueryItem] = [.init(name: "type", value: "ERC-20")]
            var pages = 0
            repeat {
                var url = URLComponents(string: "https://scan-api.chiliz.com/api/v2/addresses/" + owner + "/tokens")!
                url.queryItems = next
                let page = try await json(url.url!)
                for row in try XCTUnwrap(page["items"].array) {
                    indexed[try XCTUnwrap(row["token"]["address_hash"].string).lowercased()] = row
                }
                pages += 1
                guard pages < 30 else { XCTFail("Unbounded pagination"); break }
                if case .object(let values) = page["next_page_params"] {
                    next = try values.map { key, value in .init(name: key, value: value.isNull ? "" : try XCTUnwrap(value.text)) }
                    next.append(.init(name: "type", value: "ERC-20"))
                } else { next = [] }
            } while !next.isEmpty
            let tokens = snapshot.holdings.filter { $0.token.reference != "native" }
            XCTAssertEqual(Set(tokens.map { $0.token.reference }), Set(indexed.keys))
            var explorerMatches = 0
            for holding in tokens {
                let row = try XCTUnwrap(indexed[holding.token.reference])
                XCTAssertEqual(row["token"]["decimals"].text, String(holding.token.decimals))
                if holding.amount == row["value"].text { explorerMatches += 1 }
            }
            XCTAssertEqual(explorerMatches, tokens.count, "Explorer balances changed during the live comparison")
            var quotes: [IndexedEVMPrice] = []
            let refs = tokens.map { $0.token.reference }
            for offset in stride(from: 0, to: refs.count, by: 30) {
                let chunk = Array(refs[offset..<min(offset + 30, refs.count)])
                let listed = try await markets.prices(references: chunk, catalog: catalog)
                quotes += listed
                let missing = chunk.filter { ref in !listed.contains { $0.reference == ref } }
                if !missing.isEmpty { quotes += try await markets.dexPrices(references: missing) }
            }
            XCTAssertGreaterThan(quotes.count, 5)
            var comparedPrices = 0
            for quote in quotes {
                if let rate = indexed[quote.reference]?["token"]["exchange_rate"].text.flatMap(Double.init), rate > 0,
                   let value = Double(quote.usd) {
                    // Independent providers update at different times; old explorer
                    // quotes are recorded separately rather than rewriting live prices.
                    if abs(value / rate - 1) < 0.15 { comparedPrices += 1 }
                }
            }
            XCTAssertGreaterThan(comparedPrices, 5)
            var counts: [String: Int] = [:]
            for stream in IndexedEVMHistoryStream.allCases {
                let first = try await client.history(owner: owner, stream: stream)
                var count = first.events.count
                if let cursor = first.next {
                    let second = try await client.history(owner: owner, stream: stream, cursor: cursor)
                    XCTAssertTrue(Set(first.events.map { $0.id }).isDisjoint(with: Set(second.events.map { $0.id })))
                    count += second.events.count
                }
                counts[stream.rawValue] = count
            }
            XCTAssertGreaterThan(counts.values.reduce(0, +), 0)
            print("Chiliz \(owner): \(matched) pinned RPC balances, \(explorerMatches) explorer token balances, \(pages) inventory pages, \(quotes.count) prices, \(counts) history events")
            evidence.append(["address": owner, "block": snapshot.block, "rpcBalancesMatched": matched,
                             "explorerTokenBalancesMatched": explorerMatches, "inventoryPages": pages,
                             "prices": quotes.map { ["reference": $0.reference, "usd": $0.usd, "source": $0.source,
                                                    "explorerUSD": indexed[$0.reference]?["token"]["exchange_rate"].text ?? "unavailable"] },
                             "unpricedTokens": refs.filter { ref in !quotes.contains { $0.reference == ref } },
                             "explorerPricesWithin15Percent": comparedPrices, "historyEvents": counts])
        }
        if let path = ProcessInfo.processInfo.environment["OATH_CHILIZ_EVIDENCE"] {
            let report: [String: Any] = ["chainID": 88888, "network": "chiliz", "checkedAt": Date().timeIntervalSince1970,
                                       "nativePrice": native.usd, "nativePriceSource": native.source, "explorerNativePrice": explorerPrice,
                                       "accounts": evidence, "readOnly": true, "liveTransferTested": false]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
        }
    }
}

private struct ChilizForcedFallbackTransport: AnkrTransport {
    let live = AnkrHTTPTransport()
    let failRPC: Bool
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        if failRPC && request.url?.host == "rpc.ankr.com" { return (Data(), 503) }
        if !failRPC && request.url?.host == "api.coinbase.com" { return (Data(), 503) }
        return try await live.send(request)
    }
}

extension ChilizLiveTests {
    func testLiveRPCAndNativePriceFallbacksAndInternalHistory() async throws {
        guard ProcessInfo.processInfo.environment["OATH_CHILIZ_LIVE"] == "1" else { throw XCTSkip("Opt-in public Chiliz fallback reads") }
        let fallback = try IndexedEVMClient(chain: .chiliz, apiKey: "unavailableFixture",
                                            transport: ChilizForcedFallbackTransport(failRPC: true))
        let owner = "0xf977814e90da44bfa03b6295a0616a897441acec"
        async let inventoryTask = fallback.inventory(owner: owner)
        async let priceTask = IndexedEVMMarkets(chain: .chiliz, transport: ChilizForcedFallbackTransport(failRPC: false)).nativePrice()
        let (inventory, price) = try await (inventoryTask, priceTask)
        XCTAssertTrue(inventory.complete)
        XCTAssertGreaterThan(inventory.holdings.count, 10)
        XCTAssertEqual(price.source, "DefiLlama")
        let internalPage = try await fallback.history(owner: "0x677f7e16c7dd57be1d4c8ad1244883214953dc47", stream: .internalTransactions)
        XCTAssertFalse(internalPage.events.isEmpty)
        let markets = IndexedEVMMarkets(chain: .chiliz)
        let dex = try await markets.dexPrices(references: [IndexedEVMChain.chiliz.wrappedNative])
        XCTAssertFalse(dex.isEmpty)
        XCTAssertEqual(dex.first?.chain, .chiliz)
        print("Chiliz live fallbacks: \(inventory.holdings.count) PublicNode balances, \(internalPage.events.count) internal history events, DefiLlama CHZ quote, \(dex.count) contract-bound DEX quote")
    }
}

extension ChilizLiveTests {
    func testLiveNativeAndFanTokenFeeQuotesWithoutBroadcast() async throws {
        guard ProcessInfo.processInfo.environment["OATH_CHILIZ_LIVE"] == "1" else { throw XCTSkip("Opt-in read-only Chiliz fee quotes") }
        let config = try XCTUnwrap(ProcessInfo.processInfo.environment["OATH_ANKR_CONFIG"])
        let keys = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: config)), format: nil) as! [String: String]
        let endpoint = URL(string: "https://rpc.ankr.com/chiliz")!.appendingPathComponent(try XCTUnwrap(keys["AnkrAPIKey"]))
        let client = try EVMSendClient(network: .chiliz, endpoints: [endpoint, URL(string: "https://chiliz-rpc.publicnode.com")!])
        let owner = "0xf977814e90da44bfa03b6295a0616a897441acec"
        let recipient = "0x0000000000000000000000000000000000000001"
        async let native = client.quote(sender: owner, recipient: recipient, reference: "native", decimals: 18, amount: "1000000000000000")
        async let token = client.quote(sender: owner, recipient: recipient, reference: "0xb3f2e39acc68f98229b2587361a8ce30acdf0442", decimals: 18, amount: "1000000000000000000")
        let plans = try await [native, token]
        for plan in plans {
            try plan.validate()
            XCTAssertEqual(plan.network, .chiliz)
            XCTAssertGreaterThan(plan.gasLimit, 0)
            XCTAssertGreaterThan(plan.fee, 0)
        }
        let balance = try await client.balance(owner: owner, reference: "native")
        let nearMax = try await client.quote(sender: owner, recipient: recipient, reference: "native", decimals: 18, amount: EVMSendAmount.subtract(balance, "1"))
        XCTAssertTrue(EVMSendAmount.less(nearMax.amount, nearMax.requestedAmount))
        XCTAssertEqual(try EVMSendAmount.add(nearMax.amount, String(nearMax.fee)), nearMax.nativeBalance)
        try await client.preflight(nearMax)
        print("Chiliz native, near-Max and OG fan-token fee quotes and simulations passed; no signing or broadcast.")
    }
}

extension ChilizLiveTests {
    func testSpicyPublicStateAndNearMaxQuoteWithoutBroadcast() async throws {
        guard ProcessInfo.processInfo.environment["OATH_CHILIZ_LIVE"] == "1" else { throw XCTSkip("Opt-in Spicy public reads") }
        let client = try EVMSendClient(network: .chilizSpicy, endpoints: [URL(string: "https://chiliz-spicy.publicnode.com")!])
        let owner = "0x0000000000000000000000000000000000000001"
        let recipient = "0x0000000000000000000000000000000000000002"
        let balance = try await client.balance(owner: owner, reference: "native")
        let plan = try await client.quote(sender: owner, recipient: recipient, reference: "native", decimals: 18,
                                         amount: EVMSendAmount.subtract(balance, "1"))
        XCTAssertEqual(plan.network.chainID, 88882)
        XCTAssertTrue(EVMSendAmount.less(plan.amount, plan.requestedAmount))
        XCTAssertEqual(try EVMSendAmount.add(plan.amount, String(plan.fee)), plan.nativeBalance)
        try await client.preflight(plan)
        print("Spicy live balance, fee deduction, simulation and preflight passed; no signing or broadcast.")
    }
}
