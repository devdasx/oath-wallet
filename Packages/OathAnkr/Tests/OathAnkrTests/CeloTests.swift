import XCTest
@testable import OathAnkr

private let celoOwner = "0x1111111111111111111111111111111111111111"
private let celoOther = "0x2222222222222222222222222222222222222222"
private let celoToken = "0x3333333333333333333333333333333333333333"
private let celoHash = "0x" + String(repeating: "a", count: 64)

private actor CeloInventoryTransport: AnkrTransport {
    let unavailable: Bool
    var requests: [URLRequest] = []
    init(unavailable: Bool = false) { self.unavailable = unavailable }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        requests.append(request)
        if request.url?.host == "celo.blockscout.com" {
            if unavailable { return (Data(), 403) }
            let next = request.url?.query?.contains("items_count") == true
            let refs = next ? [celoToken] : [IndexedEVMChain.celo.nativeERC20!]
            let items = refs.map { ["token": ["type":"ERC-20", "address_hash":$0, "name":"Fixture", "symbol":"T", "decimals":"18"]] }
            return (try JSONSerialization.data(withJSONObject: ["items":items, "next_page_params":next ? NSNull() : ["items_count":1] as Any]), 200)
        }
        let calls = try JSONDecoder().decode(SolanaJSON.self, from: XCTUnwrap(request.httpBody)).array!
        let rows = calls.map { call -> [String:Any] in
            let value: Any
            switch call["method"].string {
            case "eth_chainId": value = "0xa4ec"
            case "eth_getBlockByNumber": value = ["number":"0x64", "hash":celoHash]
            case "eth_getBalance": value = "0x20000000000001"
            case "eth_call": value = call["params"].array?.first?["data"].string == "0x313ce567" ? "0x12":"0x2a"
            default: throwaway(); value = NSNull()
            }
            return ["jsonrpc":"2.0", "id":call["id"].integer!, "result":value]
        }
        return (try JSONSerialization.data(withJSONObject: rows.reversed().map { $0 }),200)
    }
    private func throwaway() { XCTFail("Unexpected inventory method") }
}

final class CeloTests: XCTestCase, @unchecked Sendable {
    func testIdentityAndNativeGasPolicy() throws {
        XCTAssertEqual(IndexedEVMChain.celo.chainID, 42220)
        XCTAssertEqual(IndexedEVMChain.celo.rpcPath, "celo")
        XCTAssertEqual(EVMSendNetwork.celo.chainID, 42220)
        XCTAssertEqual(EVMSendNetwork.celo.symbol, "CELO")
        XCTAssertNil(EVMSendNetwork.celo.oracle, "Celo has zero L1 and operator fees")
        XCTAssertEqual(IndexedEVMChain.celo.historyStreams, IndexedEVMHistoryStream.allCases)
        XCTAssertNil(AnkrChain(networkID: "celo"), "Never invent an Advanced API alias")
    }
    func testPaginatedDiscoveryDoesNotDoubleCountNativeERC20EvenWhenTracked() async throws {
        let transport = CeloInventoryTransport()
        let client = try IndexedEVMClient(chain: .celo, apiKey: "fixture", transport: transport)
        let alias = try IndexedEVMToken(reference: IndexedEVMChain.celo.nativeERC20!, name: "Celo", symbol: "CELO", decimals: 18)
        let result = try await client.inventory(owner: celoOwner, tracked: [alias])
        XCTAssertTrue(result.complete); XCTAssertEqual(result.holdings.count, 2)
        XCTAssertEqual(result.holdings.first { $0.token.reference == "native" }?.amount, "9007199254740993")
        XCTAssertEqual(result.holdings.first { $0.token.reference == celoToken }?.amount, "42")
        let requests = await transport.requests
        XCTAssertEqual(requests.filter { $0.httpBody == nil }.count, 2)
        for request in requests where request.httpBody != nil {
            XCTAssertTrue(request.url!.path.hasPrefix("/celo/"))
            let calls = try XCTUnwrap(JSONDecoder().decode(SolanaJSON.self, from: request.httpBody!).array)
            XCTAssertLessThanOrEqual(calls.count, 30)
            for call in calls where ["eth_call", "eth_getBalance"].contains(call["method"].string) {
                XCTAssertEqual(call["params"].array?.last?.string, "0x64")
            }
        }
    }
    func testIndexerFailureRetainsKnownContractsWithoutClaimingComplete() async throws {
        let token = try IndexedEVMToken(reference: celoToken, name: "Fixture", symbol: "T", decimals: 18)
        let result = try await IndexedEVMClient(chain: .celo, apiKey: "fixture", transport: CeloInventoryTransport(unavailable: true))
            .inventory(owner: celoOwner, tracked: [token])
        XCTAssertFalse(result.complete); XCTAssertEqual(result.holdings.count, 2)
        XCTAssertEqual(result.holdings.first { $0.token.reference == celoToken }?.amount, "42")
    }
    func testRealNativeERC20HistoryMapsToCeloAndSyntheticRowsAreRecognizedOnlyOnCelo() throws {
        var row: [String:Any] = ["transaction_hash":celoHash,"block_number":100,"timestamp":"2026-10-26T00:00:00Z",
            "from":["hash":celoOther], "to":["hash":celoOwner],"log_index":7,
            "token":["type":"ERC-20","address_hash":IndexedEVMChain.celo.nativeERC20!,"name":"Celo","symbol":"CELO","decimals":"18"],
            "total":["value":"9007199254740993","decimals":"18"]]
        let page = try IndexedEVMClient.decodeHistory(JSONSerialization.data(withJSONObject: ["items":[row],"next_page_params":NSNull()]), chain:.celo,owner:celoOwner,stream:.transfers)
        XCTAssertEqual(page.events.first?.token?.reference,"native")
        XCTAssertEqual(page.events.first?.amount,"9007199254740993")
        row["log_index"] = -40000
        let synthetic = try JSONDecoder().decode(SolanaJSON.self,from:JSONSerialization.data(withJSONObject:row))
        XCTAssertTrue(IndexedEVMClient.isSyntheticNativeTransfer(synthetic,chain:.celo,stream:.transfers))
        XCTAssertFalse(IndexedEVMClient.isSyntheticNativeTransfer(synthetic,chain:.unichain,stream:.transfers))
        XCTAssertFalse(IndexedEVMClient.isSyntheticNativeTransfer(synthetic,chain:.celo,stream:.transactions))
    }
    func testFeeAbstractionPreservesCurrencyWithoutCreatingNativeFee() throws {
        let row: [String:Any] = ["hash":celoHash,"block_number":100,"timestamp":"2026-10-26T00:00:00Z",
            "from":["hash":celoOwner],"to":["hash":celoOther],"status":"ok","value":"7","fee":NSNull(),
            "fee_currency_amount":"1234567890123456", "fee_currency_token":["type":"ERC-20","address_hash":celoToken,"name":"Dollar","symbol":"USD","decimals":"18"]]
        let page = try IndexedEVMClient.decodeHistory(JSONSerialization.data(withJSONObject:["items":[row],"next_page_params":NSNull()]),chain:.celo,owner:celoOwner,stream:.transactions)
        XCTAssertNil(page.events.first?.fee)
        XCTAssertEqual(page.events.first?.feeCurrency?.reference,celoToken)
        XCTAssertEqual(page.events.first?.feeCurrencyAmount,"1234567890123456")
    }
    func testCeloQuotesAreScopedToContractsNeverSymbols() throws {
        let data = Data("""
        [{"id":"dollar","platforms":{"celo":"\(celoToken)"}},{"id":"other-chain","platforms":{"ethereum":"\(celoToken)"}}]
        """.utf8)
        let catalog = try IndexedEVMMarkets.decodeCatalog(data,chain:.celo)
        XCTAssertEqual(catalog.ids[celoToken],"dollar")
        let now = Date(), raw = try JSONSerialization.data(withJSONObject:["dollar":["usd":0.997,"last_updated_at":now.timeIntervalSince1970]])
        let quotes = try IndexedEVMMarkets.decodePrices(raw,references:[celoToken,celoOther],catalog:catalog,now:now)
        XCTAssertEqual(quotes.count,1); XCTAssertEqual(quotes.first?.reference,celoToken)
        XCTAssertEqual(quotes.first?.usd,"0.997")
        let stale = try IndexedEVMMarkets.decodePrices(raw,references:[celoToken],catalog:catalog,now:now.addingTimeInterval(4000))
        XCTAssertTrue(stale.isEmpty)
    }
}
