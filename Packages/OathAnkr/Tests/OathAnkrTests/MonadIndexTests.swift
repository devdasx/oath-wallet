import XCTest
@testable import OathAnkr

private let monOwner = "0x1111111111111111111111111111111111111111"
private let monOther = "0x2222222222222222222222222222222222222222"
private let monToken = "0x3333333333333333333333333333333333333333"
private let monHash = "0x" + String(repeating: "a", count: 64)

private actor MonadIndexFeed: AnkrTransport {
    enum Fault: Sendable { case none, wrongOwner, wrongChain, wrongAmount, invalidPage, repeatedPage }
    let fault: Fault
    var directions: [String] = []
    var discoveryPages = 0
    init(_ fault: Fault = .none) { self.fault = fault }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody))
        if let call = body as? [String: Any] {
            XCTAssertEqual(request.url?.host, "monad-mainnet.g.alchemy.com")
            let method = call["method"] as! String, params = call["params"] as! [Any]
            let result: [String: Any]
            if method == "alchemy_getTokenBalances" {
                discoveryPages += 1
                result = ["address": fault == .wrongOwner ? monOther : monOwner,
                    "tokenBalances": [["contractAddress": monToken, "tokenBalance": "0x999"]],
                    "pageKey": fault == .invalidPage ? 1 : (discoveryPages == 1 || fault == .repeatedPage ? "next" as Any : NSNull())]
            } else {
                XCTAssertEqual(method, "alchemy_getAssetTransfers")
                let options = params[0] as! [String: Any]
                let incoming = options["toAddress"] != nil, category = (options["category"] as! [String])[0]
                directions.append(incoming ? "in" : "out")
                XCTAssertEqual(options["order"] as? String, "desc")
                let from = incoming ? monOther : monOwner, to = incoming ? monOwner : monOther
                result = ["transfers": [["hash": monHash, "uniqueId": monHash + ":log:7", "blockNum": "0x64",
                    "from": fault == .wrongOwner ? monToken : from, "to": to, "category": category,
                    "metadata": ["blockTimestamp": "2026-10-12T00:00:00Z"],
                    "rawContract": ["value": "0x20000000000001", "address": monToken]]],
                    "pageKey": fault == .invalidPage ? 1 : NSNull()]
            }
            return (try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": call["id"]!, "result": result]), 200)
        }
        XCTAssertEqual(request.url?.host, "rpc.ankr.com")
        let rows = (body as! [[String: Any]]).map { call -> [String: Any] in
            let method = call["method"] as! String
            let incoming = directions.last == "in"
            let from = incoming ? monOther : monOwner, to = incoming ? monOwner : monOther
            let result: Any
            switch method {
            case "eth_chainId": result = fault == .wrongChain ? "0x1" : "0x8f"
            case "eth_getBlockByNumber": result = ["number": "0x64", "hash": monHash]
            case "eth_getBalance": result = "0x20000000000001"
            case "eth_getTransactionByHash": result = ["hash": monHash, "blockHash": monHash, "from": from, "to": to, "value": "0x20000000000001"]
            case "eth_getTransactionReceipt":
                result = ["transactionHash": monHash, "blockHash": monHash, "blockNumber": "0x64", "status": "0x1", "gasUsed": "0x5208", "effectiveGasPrice": "0x1",
                    "logs": [["address": monToken, "logIndex": "0x7", "data": fault == .wrongAmount ? "0x1" : "0x20000000000001",
                        "topics": ["0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef", "0x" + String(repeating: "0", count: 24) + from.dropFirst(2), "0x" + String(repeating: "0", count: 24) + to.dropFirst(2)]]]]
            case "eth_call":
                let params = call["params"] as! [Any], selector = (params[0] as! [String: Any])["data"] as! String
                result = selector == "0x313ce567" ? "0x6" : (selector.hasPrefix("0x70a08231") ? "0x2dc6c0" : "0x")
            default: result = NSNull()
            }
            return ["jsonrpc": "2.0", "id": call["id"]!, "result": result]
        }
        return (try JSONSerialization.data(withJSONObject: rows.reversed().map { $0 }), 200)
    }
}

final class MonadIndexTests: XCTestCase, @unchecked Sendable {
    func testExpiredCursorRecoveryDoesNotTreatOutagesAsBadCursors() throws {
        let monad = try IndexedEVMClient(chain: .monad, apiKey: "fixture", alchemyAPIKey: "fixture")
        let unichain = try IndexedEVMClient(chain: .unichain, apiKey: "fixture")
        XCTAssertTrue(monad.canRestartHistory(after: AnkrError.rpc(-32602)))
        XCTAssertFalse(unichain.canRestartHistory(after: AnkrError.rpc(-32602)))
        for error in [AnkrError.http(429), .http(503), .wrongAccount, .invalidResponse, .transport] {
            XCTAssertFalse(monad.canRestartHistory(after: error))
        }
    }
    func testDiscoveryPaginatesAndUsesPinnedANKRBalanceInsteadOfIndexBalance() async throws {
        let feed = MonadIndexFeed(), client = try IndexedEVMClient(chain: .monad, apiKey: "fixture", alchemyAPIKey: "fixture", transport: feed)
        let inventory = try await client.inventory(owner: monOwner)
        XCTAssertTrue(inventory.complete)
        XCTAssertEqual(inventory.holdings.first { $0.token.reference == monToken }?.amount, "3000000")
        XCTAssertEqual(inventory.holdings.first { $0.token.reference == "native" }?.amount, "9007199254740993")
        let pages = await feed.discoveryPages; XCTAssertEqual(pages, 2)
    }
    func testNativeAndTokenHistoryVerifyReceiptsAndVisitBothDirections() async throws {
        for stream in IndexedEVMChain.monad.historyStreams {
            let feed = MonadIndexFeed(), client = try IndexedEVMClient(chain: .monad, apiKey: "fixture", alchemyAPIKey: "fixture", transport: feed)
            let outgoing = try await client.history(owner: monOwner, stream: stream, through: 2_000_000_000)
            XCTAssertEqual(outgoing.events.first?.amount, "9007199254740993")
            let incoming = try await client.history(owner: monOwner, stream: stream, cursor: XCTUnwrap(outgoing.next), through: 2_000_000_000)
            XCTAssertEqual(incoming.events.first?.amount, "9007199254740993"); XCTAssertNil(incoming.next)
            let directions = await feed.directions; XCTAssertEqual(directions, ["out", "in"])
            if stream == .transactions { XCTAssertEqual(outgoing.events.first?.fee, "21000") }
            else { XCTAssertEqual(outgoing.events.first?.token?.reference, monToken) }
        }
        XCTAssertFalse(IndexedEVMChain.monad.historyStreams.contains(.internalTransactions))
    }
    func testOutgoingWindowBoundaryStillVisitsIncoming() async throws {
        let client = try IndexedEVMClient(chain: .monad, apiKey: "fixture", alchemyAPIKey: "fixture", transport: MonadIndexFeed())
        let page = try await client.history(owner: monOwner, stream: .transactions, from: 2_000_000_000, through: 2_000_001_000)
        XCTAssertTrue(page.events.isEmpty); XCTAssertNotNil(page.next)
        let incoming = try await client.history(owner: monOwner, stream: .transactions, cursor: page.next, from: 2_000_000_000, through: 2_000_001_000)
        XCTAssertNil(incoming.next)
    }
    func testRejectsWrongOwnerWrongChainAmountAndMalformedPagination() async throws {
        for fault in [MonadIndexFeed.Fault.wrongOwner, .wrongChain, .wrongAmount, .invalidPage] {
            let client = try IndexedEVMClient(chain: .monad, apiKey: "fixture", alchemyAPIKey: "fixture", transport: MonadIndexFeed(fault))
            do { _ = try await client.history(owner: monOwner, stream: .transfers); XCTFail("Must reject mismatched or incomplete history") }
            catch { XCTAssertTrue(error is AnkrError) }
        }
        for fault in [MonadIndexFeed.Fault.wrongOwner, .invalidPage, .repeatedPage] {
            let client = try IndexedEVMClient(chain: .monad, apiKey: "fixture", alchemyAPIKey: "fixture", transport: MonadIndexFeed(fault))
            let inventory = try await client.inventory(owner: monOwner)
            XCTAssertFalse(inventory.complete, "A bad index must not clear cached tokens")
        }
    }
    func testLiveLatestMonadHistoryReadOnly() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let ankr = env["OATH_TEST_ANKR_KEY"], let alchemy = env["OATH_TEST_ALCHEMY_KEY"], let owner = env["OATH_TEST_MONAD_OWNER"] else { throw XCTSkip("Opt-in public mainnet reads only") }
        let client = try IndexedEVMClient(chain: .monad, apiKey: ankr, alchemyAPIKey: alchemy)
        let result = try await client.history(owner: owner, stream: .transactions)
        XCTAssertFalse(result.events.isEmpty)
        XCTAssertTrue(result.events.allSatisfy { $0.block > 0 })
    }
    func testLiveLatestMonadTokenHistoryReadOnly() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let ankr = env["OATH_TEST_ANKR_KEY"], let alchemy = env["OATH_TEST_ALCHEMY_KEY"] else { throw XCTSkip("Opt-in public mainnet reads only") }
        let client = try IndexedEVMClient(chain: .monad, apiKey: ankr, alchemyAPIKey: alchemy)
        let cursor = Data(#"{"direction":"in"}"#.utf8).base64EncodedString()
        let result = try await client.history(owner: monOwner, stream: .transfers, cursor: cursor)
        XCTAssertFalse(result.events.isEmpty)
        XCTAssertTrue(result.events.allSatisfy { $0.block > 0 })
    }
}
