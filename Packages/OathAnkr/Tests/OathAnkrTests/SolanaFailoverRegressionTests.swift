import Foundation
import XCTest
@testable import OathAnkr

final class SolanaFailoverRegressionTests: XCTestCase, @unchecked Sendable {
    private let owner = "11111111111111111111111111111111"
    func testTimedOutPrimaryFallsBackWithoutThreeTimeoutWindows() async throws {
        let transport = SolanaFailoverTransport(mode: .timeout)
        let client = try SolanaClient(apiKey: "fixture", transport: transport)
        let inventory = try await client.inventory(owner: owner)
        XCTAssertEqual(inventory.lamports, "123456789")
        XCTAssertTrue(inventory.accounts.isEmpty)
        let calls = await transport.calls
        XCTAssertEqual(calls.filter { $0.primary && $0.method != "getGenesisHash" }.count, 1)
        XCTAssertTrue(calls.filter(\.primary).allSatisfy { $0.timeout == 8 })
        XCTAssertTrue(calls.filter { !$0.primary }.allSatisfy { $0.timeout == 15 })
        XCTAssertEqual(calls.filter { !$0.primary }.map(\.method),
                       ["getGenesisHash", "getBalance", "getTokenAccountsByOwner", "getTokenAccountsByOwner"])
    }
    func testPrimary503FallsBackWithoutRetryingEntireInventory() async throws {
        let transport = SolanaFailoverTransport(mode: .unavailable)
        _ = try await SolanaClient(apiKey: "fixture", transport: transport).inventory(owner: owner)
        let calls = await transport.calls
        XCTAssertEqual(calls.filter { $0.primary && $0.method != "getGenesisHash" }.count, 1)
    }
    func testIncompleteFallbackCannotEraseBalancesWithAnEmptyInventory() async throws {
        let transport = SolanaFailoverTransport(mode: .malformedFallback)
        do {
            _ = try await SolanaClient(apiKey: "fixture", transport: transport).inventory(owner: owner)
            XCTFail("A missing token-program response must not become an empty wallet")
        } catch { XCTAssertEqual(error as? SolanaError, .malformed) }
    }
    func testCancellationDoesNotStartAnotherProvider() async throws {
        let transport = SolanaFailoverTransport(mode: .cancelled)
        do {
            _ = try await SolanaClient(apiKey: "fixture", transport: transport).inventory(owner: owner)
            XCTFail("Cancellation was swallowed")
        } catch { XCTAssertTrue(error is CancellationError) }
        let calls = await transport.calls
        XCTAssertTrue(calls.allSatisfy(\.primary))
    }
}

private actor SolanaFailoverTransport: AnkrTransport {
    enum Mode { case timeout, unavailable, malformedFallback, cancelled }
    struct Call: Sendable { let primary: Bool; let method: String; let timeout: TimeInterval }
    let mode: Mode
    private(set) var calls: [Call] = []
    init(mode: Mode) { self.mode = mode }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let root = try JSONDecoder().decode(SolanaJSON.self, from: request.httpBody!)
        let row = root.array?.first ?? root
        let method = row["method"].string!
        let primary = request.url!.host == "rpc.ankr.com"
        calls.append(.init(primary: primary, method: method, timeout: request.timeoutInterval))
        if mode == .cancelled { throw CancellationError() }
        if primary, method != "getGenesisHash" {
            if mode == .unavailable { return (Data(), 503) }
            throw URLError(.timedOut)
        }
        let result: SolanaJSON
        switch method {
        case "getGenesisHash": result = .string(SolanaIdentity.genesis)
        case "getBalance": result = .object(["context": .object(["slot": .number("123")]), "value": .number("123456789")])
        default:
            let program = row["params"].array?[1]["programId"].string
            result = mode == .malformedFallback && program == SolanaIdentity.token2022Program ? .null :
                .object(["context": .object(["slot": .number("123")]), "value": .array([])])
        }
        return (try JSONEncoder().encode(SolanaJSON.object(["jsonrpc": .string("2.0"), "id": row["id"], "result": result])), 200)
    }
}
