import Foundation
import Testing
@testable import Aperture

struct NEARRefundHistoryTests {
    @Test
    func refundCannotOverwriteOriginalTransfer() async throws {
        let history = try await fastHistory(sender: "alice.near", receiver: "bob.near", owner: "alice.near")
        #expect(history.count == 1)
        #expect(history.first?.sender == "alice.near")
        #expect(history.first?.signedAmountText == "-1")
    }

    @Test
    func selfTransferKeepsRealSender() async throws {
        let history = try await fastHistory(sender: "alice.near", receiver: "alice.near", owner: "alice.near")
        #expect(history.count == 1)
        #expect(history.first?.sender == "alice.near")
        #expect(history.first?.recipient == "alice.near")
    }

    @Test
    func incomingTransferKeepsActualSender() async throws {
        let history = try await fastHistory(sender: "bob.near", receiver: "alice.near", owner: "alice.near")
        #expect(history.count == 1)
        #expect(history.first?.sender == "bob.near")
        #expect(history.first?.signedAmountText == "1")
    }

    @Test
    func refundOnlyReceiptDoesNotCreateIncomingPayment() async throws {
        let history = try await fastHistory(sender: "alice.near", receiver: "contract.near", owner: "alice.near", includesTransfer: false)
        #expect(history.isEmpty)
    }

    @Test
    func nearBlocksIgnoresRefundButKeepsContractTransfer() async throws {
        let client = NEARNearBlocksHistoryClient { request in
            let url = try #require(request.url)
            let rows: [[String: Any]] = url.path.hasSuffix("/receipts")
                ? ["system", "contract.near"].map { sender in
                    ["actions": [["action": "TRANSFER"]],
                     "actions_agg": ["deposit": "1000000000000000000000000"],
                     "block": ["block_height": "123", "block_timestamp": "1789891050000000000"],
                     "included_in_block_timestamp": "1789891050000000000",
                     "outcome": ["status": true],
                     "predecessor_account_id": sender,
                     "receiver_account_id": "alice.near",
                     "receipt_id": sender + "-receipt",
                     "transaction_hash": "same-transaction"]
                } : []
            let data = try JSONSerialization.data(withJSONObject: ["data": rows])
            return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let history = try await client.history(address: "alice.near")
        #expect(history.count == 1)
        #expect(history.first?.sender == "contract.near")
        #expect(history.first?.signedAmountText == "1")
    }

    private func fastHistory(sender: String, receiver: String, owner: String, includesTransfer: Bool = true) async throws -> [NEARHistoryItem] {
        let transfer: [String: Any] = ["Transfer": ["deposit": "1000000000000000000000000"]]
        let receipts: [[String: Any]] = (includesTransfer ? [sender, "system"] : ["system"]).map { predecessor in
            ["receipt": ["predecessor_id": predecessor,
                         "receiver_id": predecessor == "system" ? owner : receiver,
                         "receipt": ["Action": ["actions": [transfer]]]]]
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "transaction": ["hash": "test-hash", "signer_id": sender,
                            "receiver_id": receiver, "actions": includesTransfer ? [transfer] : []],
            "receipts": receipts
        ])
        let detail = try JSONDecoder().decode(NEARJSONValue.self, from: data)
        return try await NEARAPIClient().historyItems(
            detail: detail, address: owner,
            pageItem: NEARFastAccountHistoryPage.Item(transactionHash: "test-hash", timestamp: "1789891050000000000", height: 123, index: 0, succeeded: true)
        )
    }
}
