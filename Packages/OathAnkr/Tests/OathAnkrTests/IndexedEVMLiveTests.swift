import XCTest
@testable import OathAnkr

final class IndexedEVMLiveTests: XCTestCase, @unchecked Sendable {
    func testUnichainPublicAccountsAgainstIndependentRPCAndPrices() async throws {
        guard ProcessInfo.processInfo.environment["OATH_UNICHAIN_LIVE"] == "1" else { throw XCTSkip("Opt-in public Unichain reads") }
        let config = try XCTUnwrap(ProcessInfo.processInfo.environment["OATH_ANKR_CONFIG"])
        let keys = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: config)), format: nil) as! [String:String]
        let client = try IndexedEVMClient(chain:.unichain, apiKey:XCTUnwrap(keys["AnkrAPIKey"]))
        let transport = AnkrHTTPTransport(), markets = IndexedEVMMarkets(chain:.unichain)
        let catalog = try await markets.catalog(), native = try await markets.nativePrice()
        XCTAssertGreaterThan(catalog.ids.count, 10); XCTAssertEqual(native.chain,.unichain)
        let endpoint = URL(string:"https://unichain-mainnet.g.alchemy.com/v2/")!.appendingPathComponent(try XCTUnwrap(keys["AlchemyAPIKey"]))
        let owners = ["0xb5a2a236581dbd6bcecd8a25eebff140595f138c", "0xbeeb9c168ab8bd17e342abb0770c90855ed13221"]
        let through = Date().timeIntervalSince1970
        for owner in owners {
            let inventory = try await client.inventory(owner:owner)
            XCTAssertEqual(inventory.chain,.unichain); XCTAssertGreaterThan(inventory.holdings.count, 5)
            XCTAssertEqual(inventory.owner,owner)
            var matched = 0
            for holding in inventory.holdings {
                let ref = holding.token.reference
                let call: [String:Any] = ["jsonrpc":"2.0", "id":1,
                    "method":ref == "native" ? "eth_getBalance" : "eth_call",
                    "params":ref == "native" ? [owner, "0x" + String(inventory.block,radix:16)] :
                        [["to":ref,"data":"0x70a08231" + String(repeating:"0",count:24) + owner.dropFirst(2)], "0x" + String(inventory.block,radix:16)]]
                var request = URLRequest(url:endpoint); request.httpMethod = "POST"
                request.setValue("application/json",forHTTPHeaderField:"Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject:call)
                let (data,status) = try await transport.send(request); XCTAssertEqual(status,200)
                let json = try JSONDecoder().decode(SolanaJSON.self,from:data)
                if let amount = holding.amount {
                    XCTAssertEqual(try IndexedEVMIdentity.amount(json["result"]),amount,"Balance mismatch for " + ref)
                    matched += 1
                } else { XCTAssertFalse(inventory.complete) }
            }
            let refs = inventory.holdings.filter { $0.token.reference != "native" }.map { $0.token.reference }
            var cg = 0, dex = 0
            for offset in stride(from:0,to:refs.count,by:30) {
                let chunk = Array(refs[offset..<min(offset+30,refs.count)])
                cg += try await markets.prices(references:chunk,catalog:catalog).count
                dex += try await markets.dexPrices(references:chunk).count
            }
            XCTAssertGreaterThan(cg,0); XCTAssertGreaterThan(dex,0)
            var events = 0
            for stream in IndexedEVMHistoryStream.allCases {
                let first = try await client.history(owner:owner,stream:stream,through:through)
                events += first.events.count
                if let cursor = first.next {
                    let second = try await client.history(owner:owner,stream:stream,cursor:cursor,through:through)
                    XCTAssertTrue(Set(first.events.map(\.id)).isDisjoint(with:Set(second.events.map(\.id))))
                    events += second.events.count
                }
            }
            XCTAssertGreaterThan(events,0)
            print("Unichain public account \(owner): block \(inventory.block), \(matched) balances matched, \(cg) CoinGecko and \(dex) DEX quotes, \(events) history events checked")
        }
    }
}
