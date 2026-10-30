import XCTest
@testable import OathAnkr

/// Opt-in, public read-only mainnet checks. No wallet credentials or signing.
final class CeloLiveTests: XCTestCase, @unchecked Sendable {
    func testPublicFallbackAndRealTokenPaidFee() async throws {
        guard ProcessInfo.processInfo.environment["OATH_CELO_LIVE"] == "1" else { throw XCTSkip("Opt-in Celo mainnet reads") }
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["OATH_ANKR_CONFIG"])
        let keys = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: path)), format: nil) as! [String:String]
        let key = try XCTUnwrap(keys["AnkrAPIKey"])
        let fallback = try IndexedEVMClient(chain: .celo, apiKey: key, transport: CeloForcedFallback())
        let inventory = try await fallback.inventory(owner: "0xf6436829cf96ea0f8bc49d300c536fcc4f84c4ed")
        XCTAssertTrue(inventory.complete); XCTAssertGreaterThan(inventory.holdings.count, 6)
        XCTAssertTrue(inventory.holdings.allSatisfy { $0.amount != nil })
        let hash = "0x8111abdd9c3e5453a19d6c50d7ad45e46752ad9b181dfde067b2b80caa66a004"
        let raw = try await read("https://celo.blockscout.com/api/v2/transactions/" + hash)
        let row = try JSONDecoder().decode(SolanaJSON.self, from: raw)
        let owner = try XCTUnwrap(row["from"]["hash"].string)
        let client = try IndexedEVMClient(chain: .celo, apiKey: key, transport: CeloSinglePublicTransaction(row: row))
        let page = try await client.history(owner: owner, stream: .transactions)
        let event = try XCTUnwrap(page.events.first)
        XCTAssertEqual(event.hash, hash); XCTAssertNil(event.fee)
        XCTAssertEqual(event.feeCurrency?.reference, "0x0e2a3e05bc9a16f5292a6170456a710cb89c6f72")
        XCTAssertEqual(event.feeCurrency?.decimals, 18)
        XCTAssertEqual(event.feeCurrencyAmount, "3766603535631746")
        let checker = StablecoinRestrictionCheck(endpoints: ["celo": URL(string: "https://forno.celo.org")!])
        let restrictions = await checker.check(.init(network: "celo", address: owner), tokens: StablecoinRestrictionRegistry.tokens(network: "celo"))
        XCTAssertEqual(restrictions.count, 2)
        XCTAssertTrue(restrictions.allSatisfy { $0.outcome != .unavailable })
        print("Celo live fallback: \(inventory.holdings.count) balances recovered; real token-paid gas currency/units verified; USDC and USDT issuer checks responded.")
    }
    func testPublicAccountsBalancesTokensPricesAndHistory() async throws {
        guard ProcessInfo.processInfo.environment["OATH_CELO_LIVE"] == "1" else { throw XCTSkip("Opt-in Celo mainnet reads") }
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["OATH_ANKR_CONFIG"])
        let keys = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: path)), format: nil) as! [String:String]
        let client = try IndexedEVMClient(chain: .celo, apiKey: XCTUnwrap(keys["AnkrAPIKey"]), transport: CeloPublicCapture())
        let markets = IndexedEVMMarkets(chain: .celo)
        async let catalogTask = markets.catalog()
        async let priceTask = markets.nativePrice()
        let (catalog, native) = try await (catalogTask, priceTask)
        XCTAssertGreaterThan(catalog.ids.count, 10)
        let nativePrice = try XCTUnwrap(Double(native.usd)); XCTAssertGreaterThan(nativePrice, 0)
        // Public exchange/large holder accounts, selected from explorer holders.
        let owners = ["0xf6436829cf96ea0f8bc49d300c536fcc4f84c4ed", "0xf89d7b9c864f589bbf53a82105107622b35eaa40"]
        for (accountIndex, owner) in owners.enumerated() {
            let inventory = try await client.inventory(owner: owner)
            XCTAssertTrue(inventory.complete); XCTAssertGreaterThan(inventory.holdings.count, 6)
            XCTAssertEqual(inventory.chain, .celo)
            XCTAssertFalse(inventory.holdings.contains { $0.token.reference == IndexedEVMChain.celo.nativeERC20 })
            let block = "0x" + String(inventory.block, radix: 16)
            // Independent Forno reads at the exact Ankr block, not a moving latest head.
            var matched = 0
            for chunkStart in stride(from: 0, to: inventory.holdings.count, by: 10) {
                let chunk = Array(inventory.holdings[chunkStart..<min(chunkStart + 10, inventory.holdings.count)])
                let calls: [[String:Any]] = chunk.enumerated().map { i, holding in
                    let ref = holding.token.reference
                    return ["jsonrpc":"2.0", "id":i + 1, "method":ref == "native" ? "eth_getBalance":"eth_call",
                        "params":ref == "native" ? [owner, block] : [["to":ref, "data":"0x70a08231" + String(repeating:"0",count:24) + owner.dropFirst(2)], block]]
                }
                var data = try await read("https://forno.celo.org", body: calls)
                // Independent public RPC replicas can lag the Ankr head briefly.
                // Retry the same pinned block, never compare different heads.
                for _ in 0..<8 {
                    let rows = try JSONDecoder().decode(SolanaJSON.self, from: data).array ?? []
                    if rows.allSatisfy({ !$0["result"].isNull }) { break }
                    try await Task.sleep(for: .seconds(1))
                    data = try await read("https://forno.celo.org", body: calls)
                }
                let replies = try XCTUnwrap(JSONDecoder().decode(SolanaJSON.self, from: data).array)
                for (i, holding) in chunk.enumerated() {
                    let row = try XCTUnwrap(replies.first { $0["id"].integer == UInt64(i + 1) })
                    XCTAssertEqual(try IndexedEVMIdentity.amount(row["result"]), holding.amount)
                    matched += 1
                }
            }
            var indexed: [String:SolanaJSON] = [:], next: String? = nil
            repeat {
                var components = URLComponents(string: "https://celo.blockscout.com/api/v2/addresses/" + owner + "/tokens")!
                var items = [URLQueryItem(name: "type", value: "ERC-20")]
                if let next, let data = Data(base64Encoded: next),
                   let params = try JSONSerialization.jsonObject(with: data) as? [String:Any] {
                    items += params.map { .init(name: $0.key, value: $0.value is NSNull ? "" : String(describing: $0.value)) }
                }
                components.queryItems = items
                let response = try JSONDecoder().decode(SolanaJSON.self, from: await read(components.url!.absoluteString))
                for item in try XCTUnwrap(response["items"].array) {
                    let ref = try XCTUnwrap(item["token"]["address_hash"].string).lowercased()
                    indexed[ref] = item
                }
                next = try IndexedEVMClient.next(response)
            } while next != nil
            let expected = Set(indexed.keys).subtracting([IndexedEVMChain.celo.nativeERC20!])
            XCTAssertEqual(Set(inventory.holdings.map(\.token.reference)).subtracting(["native"]), expected)
            let refs = Array(expected).sorted()
            let cg = try await markets.prices(references: refs, catalog: catalog)
            let dex = try await markets.dexPrices(references: refs)
            XCTAssertFalse(cg.isEmpty); XCTAssertFalse(dex.isEmpty)
            var comparedPrices = 0, explorerBalanceMatches = 0, staleExplorerBalances = 0
            for holding in inventory.holdings where holding.token.reference != "native" {
                if indexed[holding.token.reference]?["value"].text == holding.amount { explorerBalanceMatches += 1 }
                else { staleExplorerBalances += 1 }
            }
            for price in cg {
                if let explorerPrice = indexed[price.reference]?["token"]["exchange_rate"].text.flatMap(Double.init), explorerPrice > 0,
                   let actual = Double(price.usd) {
                    XCTAssertLessThan(abs(actual / explorerPrice - 1), 0.10, "Independent quotes differ by more than 10 percent")
                    comparedPrices += 1
                }
            }
            if let explorerPrice = indexed[IndexedEVMChain.celo.nativeERC20!]?["token"]["exchange_rate"].text.flatMap(Double.init) {
                XCTAssertLessThan(abs(nativePrice / explorerPrice - 1), 0.10)
            }
            XCTAssertGreaterThan(comparedPrices, 0)
            var events = 0
            for stream in IndexedEVMChain.celo.historyStreams {
                let through = Date().timeIntervalSince1970
                print("Celo history check: fixture \(accountIndex + 1), \(stream.rawValue)")
                let first = try await client.history(owner: owner, stream: stream, through: through)
                events += first.events.count
                if let next = first.next {
                    let second = try await client.history(owner: owner, stream: stream, cursor: next, through: through)
                    XCTAssertTrue(Set(first.events.map(\.id)).isDisjoint(with: Set(second.events.map(\.id))))
                    events += second.events.count
                }
            }
            XCTAssertGreaterThan(events, 0)
            print("Celo public fixture \(accountIndex + 1): block \(inventory.block); \(matched) exact independent balances; \(expected.count) explorer contracts matched; \(explorerBalanceMatches) explorer units matched, \(staleExplorerBalances) lagging/moving explorer units; \(comparedPrices) explorer price comparisons; \(cg.count) CG / \(dex.count) DEX quotes; \(events) history events.")
        }
    }
    private func read(_ url: String, body: Any? = nil) async throws -> Data {
        var request = URLRequest(url: URL(string: url)!); request.timeoutInterval = 30
        request.setValue("OathWallet/1.0", forHTTPHeaderField: "User-Agent")
        if let body { request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, status) = try await AnkrHTTPTransport().send(request)
        guard status == 200 else { throw AnkrError.http(status) }
        return data
    }
}

private struct CeloForcedFallback: AnkrTransport {
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        if request.url?.host == "rpc.ankr.com" { throw AnkrError.transport }
        return try await AnkrHTTPTransport().send(request)
    }
}

/// Pin one public explorer transaction so the fee test is stable as newer blocks arrive.
/// All transaction, receipt and fee-currency metadata reads still use live RPC.
private struct CeloSinglePublicTransaction: AnkrTransport {
    let row: SolanaJSON
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        if request.url?.host == "celo.blockscout.com" {
            return (try JSONEncoder().encode(SolanaJSON.object(["items": .array([row]), "next_page_params": .null])), 200)
        }
        return try await AnkrHTTPTransport().send(request)
    }
}

/// Only this opt-in test captures public response fixtures, never headers or keys.
private actor CeloPublicCapture: AnkrTransport {
    private var number = 0
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let result = try await AnkrHTTPTransport().send(request)
        number += 1
        if ProcessInfo.processInfo.environment["OATH_CELO_CAPTURE"] == "1" {
            let root = URL(fileURLWithPath: "/tmp/oath-celo-public-fixtures")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let label = request.httpBody == nil ? request.url!.lastPathComponent : "rpc"
            try result.0.write(to: root.appendingPathComponent("\(number)-\(label).json"))
        }
        return result
    }
}
