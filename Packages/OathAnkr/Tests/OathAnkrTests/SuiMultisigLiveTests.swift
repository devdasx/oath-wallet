import XCTest
import Foundation
@testable import OathAnkr

@MainActor final class SuiMultisigLiveTests: XCTestCase {
    struct Fixture: Decodable {
        struct Wallet: Decodable {
            struct Key: Decodable { let key, publicKey: String }
            let required, count: Int; let address: String; let keys: [Key]
        }
        let recipient, token: String; let wallets: [Wallet]
    }
    func testTestnetTransfersBalancesAndHistory() async throws {
        guard ProcessInfo.processInfo.environment["OATH_SUI_MULTISIG_LIVE"] == "1" else { throw XCTSkip("Explicit disposable Testnet opt-in required") }
        let f = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: "/tmp/oath-sui-multisig-testnet.json")))
        let client = try SuiSendClient(network: .testnet)
        let portfolio = SuiClient(network: .testnet)
        for w in f.wallets {
            let policy = try SuiMultisigPolicy(required: w.required, publicKeys: w.keys.map { try TronIdentity.hex($0.publicKey) })
            XCTAssertEqual(policy.address, w.address)
            var keys = try w.keys.suffix(w.required).map { try TronIdentity.hex($0.key) }
            defer { for i in keys.indices { keys[i].resetBytes(in: 0..<keys[i].count) } }
            for reference in ["native",f.token] {
                let beforeSender = try await client.funds(owner: w.address, reference: reference).total
                let beforeNative = try await client.funds(owner: w.address, reference: "native").total
                let beforeReceiver = try await client.funds(owner: f.recipient, reference: reference).total
                let plan = try await client.quote(sender: w.address, recipient: f.recipient, reference: reference, amount: 12345, multisig: policy)
                let signed = try SuiSendCrypto.sign(plan, privateKeys: keys)
                let receipt = try await client.submit(signed, sender: w.address)
                XCTAssertEqual(receipt.outcome, .confirmed)
                var status = try await client.status(digest: signed.digest)
                for _ in 0..<20 where status.outcome == .unknown {
                    try await Task.sleep(for: .seconds(1)); status = try await client.status(digest: signed.digest)
                }
                XCTAssertEqual(status.outcome, .confirmed)
                let fee = try XCTUnwrap(status.fee)
                var afterReceiver = try await client.funds(owner: f.recipient, reference: reference).total
                for _ in 0..<20 where afterReceiver != beforeReceiver + 12345 {
                    try await Task.sleep(for: .seconds(1)); afterReceiver = try await client.funds(owner: f.recipient, reference: reference).total
                }
                XCTAssertEqual(afterReceiver, beforeReceiver + 12345)
                let afterSender = try await client.funds(owner: w.address, reference: reference).total
                let afterNative = try await client.funds(owner: w.address, reference: "native").total
                XCTAssertEqual(afterSender, beforeSender - 12345 - (reference == "native" ? fee : 0) + (reference == "native" ? status.gasRefund : 0))
                XCTAssertEqual(afterNative, beforeNative - (reference == "native" ? 12345 : 0) - fee + status.gasRefund)
                let replay = try await client.submit(signed, sender: w.address)
                XCTAssertEqual(replay.outcome, .confirmed)
                var page = try await portfolio.history(owner: w.address)
                for _ in 0..<20 where !page.transactions.contains(where: { $0.hash == signed.digest }) {
                    try await Task.sleep(for: .seconds(1)); page = try await portfolio.history(owner: w.address)
                }
                let tx = try XCTUnwrap(page.transactions.first { $0.hash == signed.digest })
                XCTAssertFalse(tx.failed); XCTAssertGreaterThan(tx.timestamp, 0)
                XCTAssertTrue(tx.movements.contains { $0.reference == reference && $0.direction == "outgoing" })
                let incoming = try await portfolio.history(owner: f.recipient)
                XCTAssertTrue(incoming.transactions.contains { $0.hash == signed.digest && !$0.failed && $0.movements.contains { $0.reference == reference && $0.direction == "incoming" && $0.amount == "12345" } })
                print("SUI_MULTISIG_TESTNET_CONFIRMED policy=\(w.required)/\(w.count) asset=\(reference == "native" ? "SUI" : "Token") hash=\(signed.digest) balances=true history=true replay=true")
                if w.required == 2 && w.count == 3 && reference == "native" {
                    // Public transaction bytes for separate SDK/node rejection checks. No keys.
                    let value = ["bytes": signed.bytes.base64EncodedString(), "signature": signed.signature.base64EncodedString(), "sender": w.address]
                    let url = URL(fileURLWithPath: "/tmp/oath-sui-multisig-rejection.json")
                    FileManager.default.createFile(atPath: url.path, contents: try JSONEncoder().encode(value), attributes: [.posixPermissions: 0o600])
                }
            }
            let inventory = try await portfolio.inventory(owner: w.address)
            XCTAssertNotNil(inventory.holdings.first { $0.reference == "native" })
            XCTAssertNotNil(inventory.holdings.first { $0.reference == f.token })
            for reference in ["native",f.token] {
                let value = try await client.funds(owner: w.address, reference: reference).total
                XCTAssertEqual(inventory.holdings.first { $0.reference == reference }?.amount, String(value))
            }
            print("SUI_MULTISIG_PORTFOLIO policy=\(w.required)/\(w.count) discovery=true balances=true")
        }
    }
}
