import XCTest
import Foundation
@testable import OathAnkr

@MainActor final class AptosMultisigInventoryLiveTests: XCTestCase {
    func testTestnetPortfolioDiscoveryAndActivity() async throws {
        guard ProcessInfo.processInfo.environment["OATH_APTOS_MULTISIG_INVENTORY_LIVE"] == "1" else { throw XCTSkip("Explicit Testnet read-only opt-in required") }
        let f = try JSONDecoder().decode(AptosMultisigLiveTests.Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: "/tmp/oath-aptos-multisig-testnet.json")))
        let transport = AptosMultisigInventoryTransport()
        let client = AptosClient(network: .testnet, transport: transport)
        let balances = try AptosSendClient(network: .testnet, transport: transport)
        for w in f.wallets {
            let inventory = try await client.inventory(owner: w.address)
            XCTAssertTrue(inventory.discoveryComplete)
            XCTAssertTrue(inventory.failedReferences.isEmpty)
            for ref in ["native", f.coin, f.fa] {
                let expected = try await balances.balance(owner: w.address, reference: ref, version: UInt64(inventory.ledgerVersion))
                XCTAssertEqual(inventory.holdings.first(where: { $0.token.reference == ref })?.amount, String(expected))
            }
            let page = try await client.history(owner: w.address, limit: 20)
            XCTAssertGreaterThanOrEqual(page.transactions.count, 6)
            let outgoing = page.transactions.filter { $0.sender == w.address }
            XCTAssertGreaterThanOrEqual(outgoing.count, 3)
            XCTAssertTrue(outgoing.allSatisfy { !$0.failed && $0.timestamp > 0 && $0.fee != nil })
            for ref in ["native", f.coin, f.fa] {
                XCTAssertTrue(outgoing.flatMap(\.events).contains { (inventory.pairedReferences?[$0.token.reference] ?? $0.token.reference) == ref && $0.direction == "outgoing" && $0.amount == "12345" })
            }
            print("APTOS_MULTISIG_PORTFOLIO policy=\(w.required)/\(w.count) discovery=true exact_balances=true decoded_activity=true")
        }
    }
}
private actor AptosMultisigInventoryTransport: AnkrTransport {
    let base = AnkrHTTPTransport(); var next = Date.distantPast
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        guard request.url?.host == "api.testnet.aptoslabs.com", request.httpMethod != "POST" || ["/v1/view", "/v1/graphql"].contains(request.url!.path) else { throw AptosError.wrongNetwork }
        var routed = request
        var url = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        url.host = request.url!.path == "/v1/graphql" ? "api.testnet.aptoslabs.com" : "fullnode.testnet.aptoslabs.com"
        routed.url = url.url
        let start = max(Date.now, next); next = start.addingTimeInterval(1.5)
        if start > .now { try await Task.sleep(for: .seconds(start.timeIntervalSinceNow)) }
        for n in 0..<4 {
            let result = try await base.send(routed)
            if result.1 != 429 || n == 3 { return result }
            try await Task.sleep(for: .seconds(5 * (n + 1)))
        }
        throw AptosError.transport
    }
}
