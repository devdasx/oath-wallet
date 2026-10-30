import Foundation
import XCTest
@testable import OathAnkr

final class AptosReceiptTests: XCTestCase {
    private let receiptHash = "0x" + String(repeating: "a", count: 64)
    private func address(_ value: String) throws -> String { try AptosIdentity.address(value) }
    private func event(_ type: String, _ fields: [String: Any], owner: String = "0x0") -> [String: Any] {
        ["type": type, "data": fields, "guid": ["account_address": owner]]
    }
    private func receipt(_ events: [[String: Any]], changes: [[String: Any]] = [], index: [[String: Any]] = []) throws -> AptosTransaction {
        let raw = try JSONSerialization.data(withJSONObject: ["receipt": ["hash": receiptHash, "version": "1", "events": events, "changes": changes],
                                                             "index": ["fungible_asset_activities": index]])
        return .init(hash: receiptHash, version: 1, timestamp: 1, failed: false, fee: "10", sender: try address("0xff"), events: [], raw: raw)
    }
    private func core(_ store: String, _ owner: String) -> [String: Any] {
        ["type": "write_resource", "address": store, "data": ["type": "0x1::object::ObjectCore", "data": ["owner": owner]]]
    }
    func testLegacyAndModuleCoinsKeepAllPeersAndIgnoreSpoofedEvents() throws {
        let tx = try receipt([
            event("0x1::coin::WithdrawEvent", ["amount": "20"], owner: "0x11"),
            event("0x1::coin::DepositEvent", ["amount": "10"], owner: "0x22"),
            event("0x0001::coin::CoinDeposit", ["amount": "10", "account": "0x33"]),
            event("0xbad::coin::DepositEvent", ["amount": "99"], owner: "0xbad"),
            event("0x1::coin::CoinDeposit", ["amount": "0", "account": "0x44"])
        ])
        let result = try AptosDecoding.parties(tx)
        XCTAssertEqual(result.from, [try address("0x11")])
        XCTAssertEqual(result.to, try ["0x22", "0x33"].map(address))
        XCTAssertFalse(result.from.contains(tx.sender), "The fee payer is not necessarily the asset sender")
    }
    func testFAUsesOwnersAndNeverExposesStoreIDsAsRecipients() throws {
        let events = [event("0x1::fungible_asset::Withdraw", ["store": "0x100", "amount": "10"]),
                      event("0x1::fungible_asset::Deposit", ["store": "0x200", "amount": "10"])]
        let result = try AptosDecoding.parties(receipt(events, changes: [core("0x100", "0x11"), core("0x200", "0x22")]))
        XCTAssertEqual(result.from, [try address("0x11")]); XCTAssertEqual(result.to, [try address("0x22")])
        let unknown = try AptosDecoding.parties(receipt(events))
        XCTAssertTrue(unknown.from.isEmpty); XCTAssertTrue(unknown.to.isEmpty)
    }
    func testTransferredObjectNeedsEventTimeOwnerNotFinalOwner() throws {
        let events = [event("0x1::fungible_asset::Withdraw", ["store": "0x100", "amount": "10"]),
                      event("0x1::object::Transfer", ["object": "0x100", "from": "0x11", "to": "0x99"])]
        let unknown = try AptosDecoding.parties(receipt(events, changes: [core("0x100", "0x99")]))
        XCTAssertTrue(unknown.from.isEmpty)
        let indexed: [String: Any] = ["is_gas_fee": false, "event_index": "0", "owner_address": "0x11", "amount": "10", "type": "0x1::fungible_asset::Withdraw"]
        let result = try AptosDecoding.parties(receipt(events, changes: [core("0x100", "0x99")], index: [indexed]))
        XCTAssertEqual(result.from, [try address("0x11")])
        var wrong = indexed; wrong["amount"] = "11"
        XCTAssertThrowsError(try AptosDecoding.parties(receipt(events, index: [wrong])))
    }
    func testCapturedMainnetReceiptsRecoverPeersFromOldOwnerFilteredCache() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "live-history", withExtension: "json", subdirectory: "Fixtures/Aptos"))
        let pairs = try XCTUnwrap(JSONDecoder().decode(AptosJSON.self, from: Data(contentsOf: url)).array)
        var complete = 0
        for pair in pairs {
            let owner = try XCTUnwrap(pair["index"]["account_address"].string)
            let tx = try AptosDecoding.transaction(row: pair["index"], detail: pair["receipt"], owner: owner)
            let result = try AptosDecoding.parties(tx)
            if !result.from.isEmpty && !result.to.isEmpty { complete += 1 }
            XCTAssertTrue(tx.events.allSatisfy { $0.owner == owner })
        }
        XCTAssertEqual(complete, pairs.count)
    }
}
