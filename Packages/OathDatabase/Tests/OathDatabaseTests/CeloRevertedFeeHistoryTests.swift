import XCTest
import OathAnkr
import GRDB
@testable import OathDatabase

private struct RevertedCeloFeeTransport: AnkrTransport {
    let owner = "0x" + String(repeating: "1", count: 40)
    let escrow = "0x000000000000000000000000000000000ce106a5"
    let contract = "0x" + String(repeating: "2", count: 40)
    let hash = "0x" + String(repeating: "3", count: 64)
    let block = "0x" + String(repeating: "4", count: 64)
    var removed = false
    var wrongBlock = false
    var receiptType = "0x7b"
    var wrongAmount = false

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let movement = [(5, owner, escrow, 2931), (8, escrow, owner, 1343)]
        var reply: Any
        if request.httpBody == nil {
            let rows: [[String: Any]] = movement.map { index, from, to, amount in
                ["transaction_hash": hash, "block_hash": block, "block_number": 100, "log_index": index,
                 "timestamp": "2026-11-01T00:00:00Z", "from": ["hash": from], "to": ["hash": to],
                 "token": ["type": "ERC-20", "address_hash": contract, "name": "Dollar", "symbol": "USD", "decimals": "6"],
                 "total": ["value": String(amount), "decimals": "6"]]
            }
            reply = ["items": rows, "next_page_params": NSNull()] as [String: Any]
        } else {
            let logs: [[String: Any]] = movement.map { index, from, to, amount in
                ["logIndex": "0x" + String(index, radix: 16), "transactionHash": hash, "blockNumber": "0x64",
                 "blockHash": wrongBlock ? hash : block, "removed": removed, "address": contract,
                 "data": "0x" + String(format: "%064x", wrongAmount ? 1 : amount),
                 "topics": ["0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef",
                            "0x" + String(repeating: "0", count: 24) + from.dropFirst(2),
                            "0x" + String(repeating: "0", count: 24) + to.dropFirst(2)]]
            }
            let calls = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [[String: Any]])
            reply = try calls.map { call -> [String: Any] in
                let result: Any
                switch call["method"] as? String {
                case "eth_chainId": result = "0xa4ec"
                case "eth_getTransactionReceipt":
                    result = ["transactionHash": hash, "blockHash": block, "blockNumber": "0x64", "type": receiptType, "status": "0x0", "logs": logs] as [String: Any]
                default: throw AnkrError.invalidResponse
                }
                return ["jsonrpc": "2.0", "id": try XCTUnwrap(call["id"]), "result": result]
            }
        }
        return (try JSONSerialization.data(withJSONObject: reply), 200)
    }
}

@MainActor final class CeloRevertedFeeHistoryTests: XCTestCase {
    func testCommittedGasDebitAndRefundKeepFailedParentAfterReopen() async throws {
        let transport = RevertedCeloFeeTransport()
        let client = try IndexedEVMClient(chain: .celo, apiKey: "fixture", transport: transport)
        let page = try await client.history(owner: transport.owner, stream: .transfers)
        XCTAssertEqual(page.events.map(\.amount), ["2931", "1343"])
        XCTAssertTrue(page.events.allSatisfy { !$0.failed && $0.parentTransactionFailed == true })
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("wallet.sqlite")
        let db = try await OathDatabase.open(at: file)
        try await db.seed(networks: [.init(id: "celo", name: "Celo", family: "evm", symbol: "CELO", decimals: 18,
                                          derivationPath: "fixture", logo: "fixture", sortOrder: 0)], assets: [])
        try await db.importWalletIfNeeded(.init(id: "w", name: "Fixture", kind: "hd", vaultReference: "fixture", createdAt: 1),
            accounts: [.init(id: "a", walletID: "w", networkID: "celo", address: transport.owner, derivationPath: "fixture")])
        let ticket = try await db.beginIndexedEVMSync(accountID: "a")
        let work = try await db.indexedEVMHistoryWork(ticket)
        let timestamp = try XCTUnwrap(page.events.first?.timestamp)
        let cursor = try XCTUnwrap(work.first { $0.stream == "transfers" && $0.startTime <= timestamp && timestamp <= $0.endTime })
        try await db.commitIndexedEVMPage(page, cursor: cursor, ticket: ticket)
        let reopened = try await OathDatabase.open(at: file)
        let transaction = try await reopened.transaction("celo:" + transport.hash)
        XCTAssertEqual(transaction?.state, "failed")
        let amounts = try await reopened.pool.read { db in
            try String.fetchAll(db, sql: "SELECT amountAtomic FROM transfers ORDER BY eventIndex")
        }
        XCTAssertEqual(amounts, ["2931", "1343"])
    }

    func testRevertedTransactionCannotSupplyRemovedMismatchedOrOrdinaryTransfer() async throws {
        for transport in [RevertedCeloFeeTransport(removed: true), .init(wrongBlock: true),
                          .init(receiptType: "0x2"), .init(wrongAmount: true)] {
            let client = try IndexedEVMClient(chain: .celo, apiKey: "fixture", transport: transport)
            do { _ = try await client.history(owner: transport.owner, stream: .transfers); XCTFail("Invalid evidence accepted") }
            catch { XCTAssertEqual(error as? AnkrError, .invalidResponse) }
        }
    }
}
