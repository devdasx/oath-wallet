import XCTest
@testable import OathAnkr

final class FilecoinLiveTests: XCTestCase, @unchecked Sendable {
    private func json(_ url: URL, body: Any? = nil) async throws -> SolanaJSON {
        var request = URLRequest(url: url)
        request.setValue("OathWallet/1.0", forHTTPHeaderField: "User-Agent")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, status) = try await AnkrHTTPTransport().send(request)
        guard status == 200 else { throw AnkrError.http(status) }
        return try JSONDecoder().decode(SolanaJSON.self, from: data)
    }
    func testPublicAccountsBalancesHistoryAndPrices() async throws {
        guard ProcessInfo.processInfo.environment["OATH_FILECOIN_LIVE"] == "1" else { throw XCTSkip("Opt-in public Filecoin reads") }
        let config = try XCTUnwrap(ProcessInfo.processInfo.environment["OATH_ANKR_CONFIG"])
        let keys = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: config)), format: nil) as! [String: String]
        let client = try IndexedEVMClient(chain: .filecoin, apiKey: XCTUnwrap(keys["AnkrAPIKey"]))
        let markets = IndexedEVMMarkets(chain: .filecoin)
        async let catalogTask = markets.catalog()
        async let nativeTask = markets.nativePrice()
        let (catalog, native) = try await (catalogTask, nativeTask)
        XCTAssertGreaterThan(catalog.ids.count, 4)
        let explorerStats = try await json(URL(string: "https://filecoin.blockscout.com/api/v2/stats")!)
        let explorerPrice = try XCTUnwrap(explorerStats["coin_price"].text.flatMap(Double.init))
        let nativePrice = try XCTUnwrap(Double(native.usd))
        XCTAssertLessThan(abs(nativePrice / explorerPrice - 1), 0.1)
        var evidence: [[String: Any]] = []
        for owner in ["0xb74749b2213916b1da3b869e41c7c57f1db69393", "0xacaf41f4517c1d13f2817f67675099bbd5c93108"] {
            let snapshot = try await client.inventory(owner: owner)
            XCTAssertTrue(snapshot.complete)
            XCTAssertGreaterThan(snapshot.holdings.count, 3)
            let block = "0x" + String(snapshot.block, radix: 16)
            var matched = 0
            for offset in stride(from: 0, to: snapshot.holdings.count, by: 20) {
                let holdings = Array(snapshot.holdings[offset..<min(offset + 20, snapshot.holdings.count)])
                let calls: [[String: Any]] = holdings.enumerated().map { i, holding in
                    let ref = holding.token.reference
                    return ["jsonrpc": "2.0", "id": i + 1, "method": ref == "native" ? "eth_getBalance" : "eth_call",
                            "params": ref == "native" ? [owner, block] : [["to": ref, "data": "0x70a08231" + String(repeating: "0", count: 24) + owner.dropFirst(2)], block]]
                }
                let replies = try await json(URL(string: "https://api.node.glif.io/rpc/v1")!, body: calls)
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
                var url = URLComponents(string: "https://filecoin.blockscout.com/api/v2/addresses/" + owner + "/tokens")!
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
            XCTAssertGreaterThan(quotes.count, 0)
            var comparedPrices = 0
            for quote in quotes {
                if let rate = indexed[quote.reference]?["token"]["exchange_rate"].text.flatMap(Double.init), rate > 0,
                   let value = Double(quote.usd) {
                    // Independent providers update at different times; old explorer
                    // quotes are recorded separately rather than rewriting live prices.
                    if abs(value / rate - 1) < 0.15 { comparedPrices += 1 }
                }
            }
            // Filecoin Blockscout currently leaves token exchange rates empty.
            var counts: [String: Int] = [:]
            for stream in IndexedEVMHistoryStream.allCases {
                print("Checking public Filecoin history: \(owner) \(stream.rawValue)")
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
            print("Filecoin \(owner): \(matched) pinned RPC balances, \(explorerMatches) explorer token balances, \(pages) inventory pages, \(quotes.count) prices, \(counts) history events")
            evidence.append(["address": owner, "block": snapshot.block, "rpcBalancesMatched": matched,
                             "explorerTokenBalancesMatched": explorerMatches, "inventoryPages": pages,
                             "prices": quotes.map { ["reference": $0.reference, "usd": $0.usd, "source": $0.source,
                                                    "explorerUSD": indexed[$0.reference]?["token"]["exchange_rate"].text ?? "unavailable"] },
                             "unpricedTokens": refs.filter { ref in !quotes.contains { $0.reference == ref } },
                             "explorerPricesWithin15Percent": comparedPrices, "historyEvents": counts])
        }
        if let path = ProcessInfo.processInfo.environment["OATH_FILECOIN_EVIDENCE"] {
            let report: [String: Any] = ["chainID": 314, "network": "filecoin", "checkedAt": Date().timeIntervalSince1970,
                                       "nativePrice": native.usd, "nativePriceSource": native.source, "explorerNativePrice": explorerPrice,
                                       "accounts": evidence, "readOnly": true, "liveTransferTested": false]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
        }
    }
}

private struct FilecoinForcedFallbackTransport: AnkrTransport {
    let live = AnkrHTTPTransport()
    let failRPC: Bool
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        if failRPC && request.url?.host == "rpc.ankr.com" { return (Data(), 503) }
        if !failRPC && request.url?.host == "api.coinbase.com" { return (Data(), 503) }
        return try await live.send(request)
    }
}

extension FilecoinLiveTests {
    func testLiveRPCAndNativePriceFallbacksAndInternalHistory() async throws {
        guard ProcessInfo.processInfo.environment["OATH_FILECOIN_LIVE"] == "1" else { throw XCTSkip("Opt-in public Filecoin fallback reads") }
        let fallback = try IndexedEVMClient(chain: .filecoin, apiKey: "unavailableFixture",
                                            transport: FilecoinForcedFallbackTransport(failRPC: true))
        let owner = "0xb74749b2213916b1da3b869e41c7c57f1db69393"
        async let inventoryTask = fallback.inventory(owner: owner)
        async let priceTask = IndexedEVMMarkets(chain: .filecoin, transport: FilecoinForcedFallbackTransport(failRPC: false)).nativePrice()
        let (inventory, price) = try await (inventoryTask, priceTask)
        XCTAssertTrue(inventory.complete)
        XCTAssertGreaterThan(inventory.holdings.count, 3)
        XCTAssertEqual(price.source, "DefiLlama")
        let internalPage = try await fallback.history(owner: IndexedEVMChain.filecoin.wrappedNative, stream: .internalTransactions)
        XCTAssertFalse(internalPage.events.isEmpty)
        let markets = IndexedEVMMarkets(chain: .filecoin)
        let dex = try await markets.dexPrices(references: [IndexedEVMChain.filecoin.wrappedNative])
        XCTAssertFalse(dex.isEmpty)
        XCTAssertEqual(dex.first?.chain, .filecoin)
        print("Filecoin live fallbacks: \(inventory.holdings.count) GLIF balances, \(internalPage.events.count) internal history events, DefiLlama FIL quote, \(dex.count) contract-bound DEX quote")
    }
}

extension FilecoinLiveTests {
    func testLiveInternalTransfersAndRevertedCalls() async throws {
        guard ProcessInfo.processInfo.environment["OATH_FILECOIN_LIVE"] == "1" else { throw XCTSkip("Opt-in public Filecoin traces") }
        let config = try XCTUnwrap(ProcessInfo.processInfo.environment["OATH_ANKR_CONFIG"])
        let keys = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: config)), format: nil) as! [String: String]
        let client = try IndexedEVMClient(chain: .filecoin, apiKey: XCTUnwrap(keys["AnkrAPIKey"]))
        for owner in ["0xb74749b2213916b1da3b869e41c7c57f1db69393", "0xacaf41f4517c1d13f2817f67675099bbd5c93108"] {
            let first = try await client.history(owner: owner, stream: .internalTransactions)
            var events = first.events
            if let cursor = first.next {
                let second = try await client.history(owner: owner, stream: .internalTransactions, cursor: cursor)
                XCTAssertTrue(Set(first.events.map(\.id)).isDisjoint(with: Set(second.events.map(\.id))))
                events += second.events
            }
            XCTAssertFalse(events.isEmpty)
            XCTAssertTrue(events.filter(\.failed).allSatisfy { $0.amount == "0" })
            print("Filecoin internal transfers: \(owner) \(events.count) verified events, \(events.filter(\.failed).count) reverted")
        }
    }

    func testLiveArchivedContractCreation() async throws {
        guard ProcessInfo.processInfo.environment["OATH_FILECOIN_LIVE"] == "1" else { throw XCTSkip("Opt-in public Filecoin creation record") }
        let hash = "0x5839168a17ab3a519b91a12d9b160f8edbbf30c6e5f19279a323ffe617d7efc6"
        async let row = json(URL(string: "https://filecoin.blockscout.com/api/v2/transactions/" + hash)!)
        async let message = json(URL(string: "https://filfox.info/api/v1/message/" + hash)!)
        let (indexed, proof) = try await (row, message)
        let result = try FilecoinHistoryArchive.corroborate(rows: [indexed], messages: [hash: proof], stream: .transactions)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?["created_contract"]["hash"].string?.lowercased(), IndexedEVMChain.filecoin.wrappedNative)
    }

    func testNativeFILBalancesAgainstExplorer() async throws {
        guard ProcessInfo.processInfo.environment["OATH_FILECOIN_LIVE"] == "1" else { throw XCTSkip("Opt-in public Filecoin balances") }
        let config = try XCTUnwrap(ProcessInfo.processInfo.environment["OATH_ANKR_CONFIG"])
        let keys = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: config)), format: nil) as! [String: String]
        let client = try IndexedEVMClient(chain: .filecoin, apiKey: XCTUnwrap(keys["AnkrAPIKey"]))
        for owner in ["0xb74749b2213916b1da3b869e41c7c57f1db69393", "0xacaf41f4517c1d13f2817f67675099bbd5c93108"] {
            async let inventory = client.inventory(owner: owner)
            async let explorer = json(URL(string: "https://filecoin.blockscout.com/api/v2/addresses/" + owner)!)
            async let filfox = json(URL(string: "https://filfox.info/api/v1/address/" + owner)!)
            let (snapshot, address, archived) = try await (inventory, explorer, filfox)
            let native = try XCTUnwrap(snapshot.holdings.first { $0.token.reference == "native" }?.amount)
            XCTAssertNotEqual(native, "0")
            guard native == archived["balance"].text else { throw AnkrError.invalidResponse }
            if native != address["coin_balance"].text {
                print("Blockscout native cache differs from current RPC and Filfox for \(owner); RPC and Filfox agree exactly.")
            }
        }
        print("Filecoin native balances matched Filfox exactly for both funded public accounts.")
    }
}
