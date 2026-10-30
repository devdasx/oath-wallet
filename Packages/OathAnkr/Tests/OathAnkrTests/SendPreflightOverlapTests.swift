import Foundation
import XCTest
@testable import OathAnkr

/// A sequential implementation times out at the first request. Both requests
/// must actually be in flight before either fixture response is released.
actor SendPreflightOverlapTransport: AnkrTransport {
    let base: any AnkrTransport
    let required: Set<String>
    private(set) var seen: Set<String> = []
    init(base: any AnkrTransport, required: Set<String>) { self.base = base; self.required = required }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let payload = try JSONDecoder().decode(SolanaJSON.self, from: request.httpBody!)
        let methods = Set((payload.array ?? [payload]).compactMap { $0["method"].string })
        if !required.isDisjoint(with: methods) {
            seen.formUnion(required.intersection(methods))
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while seen != required {
                guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        return try await base.send(request)
    }
}

@MainActor final class SendPreflightOverlapTests: XCTestCase {
    func testSolanaBlockhashAndSimulationOverlap() async throws {
        let helper = SolanaSendTests()
        let plan = helper.plan(try helper.fixtures().vectors.first { $0.kind == "spl" }!)
        let transport = SendPreflightOverlapTransport(base: SolanaRPCFixture(plan: plan, mode: "normal"),
            required: ["isBlockhashValid", "simulateTransaction"])
        let client = try SolanaSendClient(network: .devnet, transport: transport)
        try await client.preflight(plan)
        let seen = await transport.seen
        XCTAssertEqual(seen, ["isBlockhashValid", "simulateTransaction"])
    }

    func testEVMHeadAndSimulationOverlap() async throws {
        let fixture = EVMSendFixtureTransport()
        let (_, plan) = try await EVMSendRPCRegressionTests().quote(fixture)
        let transport = SendPreflightOverlapTransport(base: fixture,
            required: ["eth_getBlockByNumber", "eth_estimateGas"])
        let client = try EVMSendClient(network: .arbitrum,
            endpoints: [URL(string: "https://test.example")!], transport: transport)
        try await client.preflight(plan)
        let seen = await transport.seen
        XCTAssertEqual(seen, ["eth_getBlockByNumber", "eth_estimateGas"])
    }
}
