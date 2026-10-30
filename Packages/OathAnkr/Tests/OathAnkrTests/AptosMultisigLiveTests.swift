import XCTest
import Foundation
@testable import OathAnkr

@MainActor final class AptosMultisigLiveTests: XCTestCase {
    struct Fixture: Decodable {
        let recipient: String, coin: String, fa: String, wallets: [Wallet]
        struct Wallet: Decodable {
            let required: Int, count: Int, address: String, signers: [Signer]
            struct Signer: Decodable { let key: String, publicKey: String }
        }
    }
    func testTestnetPoliciesTransfersBalancesAndHistory() async throws {
        guard ProcessInfo.processInfo.environment["OATH_APTOS_MULTISIG_LIVE"] == "1" else { throw XCTSkip("Explicit disposable Testnet opt-in required") }
        let f = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: "/tmp/oath-aptos-multisig-testnet.json")))
        let client = try AptosSendClient(network: .testnet, transport: AptosMultisigTestnetTransport())
        for w in f.wallets {
            let policy = try AptosMultisigPolicy(required: w.required, publicKeys: w.signers.map { try TronIdentity.hex($0.publicKey) })
            XCTAssertEqual(policy.address, w.address)
            // Choose the last quorum, exercising nonzero bitmap offsets as well as all 32 bits.
            var keys = try w.signers.suffix(w.required).map { try TronIdentity.hex($0.key.replacingOccurrences(of: "ed25519-priv-", with: "")) }
            defer { for i in keys.indices { keys[i].resetBytes(in: 0..<keys[i].count) } }
            for ref in ["native", f.coin, f.fa] {
                let before = try await client.balance(owner: w.address, reference: ref)
                let toBefore = try await client.balance(owner: f.recipient, reference: ref)
                let nativeBefore = try await client.balance(owner: w.address, reference: "native")
                let p = try await client.quote(sender: w.address, recipient: f.recipient, reference: ref, publicKey: policy.bytes,
                    decimals: ref == "native" ? 8 : 6, amount: "12345", multisig: policy)
                try await client.preflight(p)
                XCTAssertThrowsError(try AptosSendCrypto.sign(p, privateKeys: Array(keys.dropLast())))
                let s = try AptosSendCrypto.sign(p, privateKeys: keys)
                var r = try await client.submit(s, plan: p)
                for _ in 0..<40 where ![.confirmed,.failed].contains(r.outcome) {
                    try await Task.sleep(for: .seconds(1)); r = try await client.status(s, plan: p)
                }
                XCTAssertEqual(r.outcome, .confirmed)
                let fee = try XCTUnwrap(r.fee), version = try XCTUnwrap(r.version)
                let after = try await client.balance(owner: w.address, reference: ref, version: version)
                let toAfter = try await client.balance(owner: f.recipient, reference: ref, version: version)
                let nativeAfter = try await client.balance(owner: w.address, reference: "native", version: version)
                XCTAssertEqual(toAfter - toBefore, p.amount)
                XCTAssertEqual(before - after, p.amount + (ref == "native" ? fee : 0))
                XCTAssertEqual(nativeBefore - nativeAfter, fee + (ref == "native" ? p.amount : 0))
                let replay = try await client.submit(s, plan: p)
                XCTAssertEqual(replay, r)
                // Confirm native account history contains the exact committed multisig transaction.
                let request = URLRequest(url: URL(string: "https://api.testnet.aptoslabs.com/v1/accounts/\(w.address)/transactions?start=\(p.sequence)&limit=1")!)
                let (data, status) = try await AptosMultisigTestnetTransport().send(request)
                XCTAssertEqual(status, 200)
                let rows = try JSONDecoder().decode([AptosJSON].self, from: data)
                XCTAssertEqual(rows.first?["hash"].string, s.hash)
                print("APTOS_MULTISIG_TESTNET_CONFIRMED policy=\(w.required)/\(w.count) asset=\(ref == "native" ? "APT" : ref.contains("::") ? "Coin" : "FA") hash=\(s.hash) version=\(version) balances=true history=true replay=true")
            }
        }
    }
}
private actor AptosMultisigTestnetTransport: AnkrTransport {
    let base = AnkrHTTPTransport()
    var next = Date.distantPast
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        guard request.url?.host == "api.testnet.aptoslabs.com" else { throw AptosSendError.wrongNetwork }
        // Official alternate fullnode, with chain identity checked by the production client.
        // Avoid the shared anonymous API gateway quota; never changes transaction bytes.
        var routed = request
        var url = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        url.host = "fullnode.testnet.aptoslabs.com"; routed.url = url.url
        let start = max(Date.now, next); next = start.addingTimeInterval(1.5)
        if start > .now { try await Task.sleep(for: .seconds(start.timeIntervalSinceNow)) }
        for attempt in 0..<4 {
            let result = try await base.send(routed)
            if result.1 != 429 || attempt == 3 { return result }
            try await Task.sleep(for: .seconds(3 * (attempt + 1)))
        }
        throw AptosSendError.transport
    }
}
