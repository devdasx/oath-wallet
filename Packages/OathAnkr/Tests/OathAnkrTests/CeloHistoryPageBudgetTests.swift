import Foundation
import XCTest
@testable import OathAnkr

private actor CeloHistoryPageBudgetFeed: AnkrTransport {
    let owner = "0x1111111111111111111111111111111111111111"
    let recipient = "0x2222222222222222222222222222222222222222"
    let token = "0x3333333333333333333333333333333333333333"
    private(set) var pageSizes: [Int] = []
    private(set) var offsets: [Int] = []

    func hash(_ n: Int) -> String { "0x" + String(repeating: "0", count: 62) + String(format: "%02x", n + 1) }

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        if request.url?.host == "celo.blockscout.com" {
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
            let size = query.first { $0.name == "items_count" }?.value.flatMap(Int.init) ?? 50
            let offset = query.first { $0.name == "index" }?.value.flatMap(Int.init) ?? 0
            pageSizes.append(size); offsets.append(offset)
            XCTAssertEqual(query.first { $0.name == "type" }?.value, "ERC-20")
            if offset > 0 { XCTAssertEqual(query.first { $0.name == "block_number" }?.value, "100") }
            let end = min(20, offset + size)
            let rows: [[String: Any]] = (offset..<end).map { i in
                ["transaction_hash": hash(i), "block_number": 100 + i,
                 "timestamp": "2026-10-12T00:00:00Z", "log_index": 7,
                 "from": ["hash": owner], "to": ["hash": recipient],
                 "token": ["type": "ERC-20", "address_hash": token, "decimals": "6", "name": "Fixture", "symbol": "T"],
                 "total": ["value": "9007199254740993", "decimals": "6"]]
            }
            let next: Any = end < 20 ? ["index": end, "block_number": 100] : NSNull()
            return (try JSONSerialization.data(withJSONObject: ["items": rows, "next_page_params": next]), 200)
        }
        let calls = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as! [[String: Any]]
        let replies = try calls.map { call -> [String: Any] in
            let method = call["method"] as! String, params = call["params"] as! [Any]
            let result: Any
            switch method {
            case "eth_chainId": result = "0xa4ec"
            case "eth_getTransactionReceipt": result = NSNull()
            case "eth_getBlockByNumber", "eth_getBlockReceipts":
                let tag = params[0] as! String
                let height = try XCTUnwrap(Int(tag.dropFirst(2), radix: 16)), n = height - 100
                if method == "eth_getBlockByNumber" {
                    result = ["number": tag, "hash": hash(n), "transactions": [hash(n)]]
                } else {
                    result = [["transactionHash": hash(n), "blockHash": hash(n), "blockNumber": tag,
                               "transactionIndex": "0x0", "status": "0x1", "gasUsed": "0x5208", "effectiveGasPrice": "0x1",
                               "fixture_large_log": String(repeating: "a", count: 300 * 1024),
                               "logs": [["address": token, "logIndex": "0x7", "data": "0x20000000000001",
                                         "topics": ["0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef",
                                                    "0x" + String(repeating: "0", count: 24) + owner.dropFirst(2),
                                                    "0x" + String(repeating: "0", count: 24) + recipient.dropFirst(2)]]]]]
                }
            default: throw AnkrError.invalidResponse
            }
            return ["jsonrpc": "2.0", "id": call["id"]!, "result": result]
        }
        return (try JSONSerialization.data(withJSONObject: replies), 200)
    }
}

final class CeloHistoryPageBudgetTests: XCTestCase, @unchecked Sendable {
    func testLargeReceiptsAdvanceAcrossSmallerPagesWithoutLosingTransfers() async throws {
        let feed = CeloHistoryPageBudgetFeed()
        let client = try IndexedEVMClient(chain: .celo, apiKey: "fixture", transport: feed)
        let first = try await client.history(owner: feed.owner, stream: .transfers)
        XCTAssertEqual(first.events.count, 10)
        let next = try XCTUnwrap(first.next)
        let second = try await client.history(owner: feed.owner, stream: .transfers, cursor: next)
        XCTAssertEqual(second.events.count, 10)
        XCTAssertNil(second.next)
        XCTAssertEqual(Set((first.events + second.events).map(\.id)).count, 20)
        XCTAssertTrue((first.events + second.events).allSatisfy { $0.amount == "9007199254740993" })
        let sizes = await feed.pageSizes, offsets = await feed.offsets
        XCTAssertTrue(sizes.allSatisfy { $0 == 10 })
        XCTAssertEqual(Set(offsets), [0, 10])
    }

    func testExistingLargePageCursorKeepsItsPositionWhenPageSizeChanges() async throws {
        let feed = CeloHistoryPageBudgetFeed()
        let client = try IndexedEVMClient(chain: .celo, apiKey: "fixture", transport: feed)
        let cursor = try JSONSerialization.data(withJSONObject: ["index": 10, "block_number": 100, "items_count": 50]).base64EncodedString()
        let page = try await client.history(owner: feed.owner, stream: .transfers, cursor: cursor)
        XCTAssertEqual(page.events.count, 10)
        XCTAssertNil(page.next)
        let sizes = await feed.pageSizes, offsets = await feed.offsets
        XCTAssertTrue(sizes.allSatisfy { $0 == 10 })
        XCTAssertTrue(offsets.allSatisfy { $0 == 10 })
    }
}
