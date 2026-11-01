import XCTest
@testable import OathAnkr

private actor ScopeResponseTransport: AnkrTransport {
    private(set) var calls = 0
    private var held = true
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        calls += 1
        if held { await withCheckedContinuation { waiters.append($0) } }
        // Deliberately does not observe Task cancellation: a late provider reply
        // must not revive an invalidated refresh generation.
        return (Data(#"{"jsonrpc":"2.0","id":1,"result":{"assets":[],"totalBalanceUsd":"0","totalCount":0}}"#.utf8), 200)
    }
    func release() {
        held = false
        let pending = waiters; waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

@MainActor final class AnkrRequestScopeTests: XCTestCase {
    private let address = "0x1111111111111111111111111111111111111111"

    func testCancelledScopeCannotStartButFreshScopeCanReuseClient() async throws {
        let transport = ScopeResponseTransport(), scope = AnkrRequestScope()
        let client = try AnkrClient(apiKey: "fixture", transport: transport)
        scope.cancel(); scope.cancel()
        do {
            _ = try await client.balances(chain: .eth, address: address, requestScope: scope)
            XCTFail("Cancelled scope must reject admission")
        } catch is CancellationError { }
        let rejectedCalls = await transport.calls
        XCTAssertEqual(rejectedCalls, 0)
        await transport.release()
        _ = try await client.balances(chain: .eth, address: address, requestScope: AnkrRequestScope())
        let freshCalls = await transport.calls
        XCTAssertEqual(freshCalls, 1)
    }

    func testLateReplyIsRejectedWithoutCancellingUnrelatedClientCall() async throws {
        let transport = ScopeResponseTransport(), scope = AnkrRequestScope()
        let client = try AnkrClient(apiKey: "fixture", transport: transport)
        let invalidated = Task { try await client.balances(chain: .eth, address: address, requestScope: scope) }
        let unrelated = Task { try await client.balances(chain: .eth, address: address) }
        for _ in 0..<200 {
            if await transport.calls == 2 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let started = await transport.calls
        XCTAssertEqual(started, 2)
        scope.cancel()
        XCTAssertFalse(invalidated.isCancelled, "The scope alone must reject the late reply")
        await transport.release()
        do { _ = try await invalidated.value; XCTFail("Late reply must stay cancelled") }
        catch is CancellationError { }
        _ = try await unrelated.value
        let calls = await transport.calls
        XCTAssertEqual(calls, 2, "Cancellation must not trigger a provider retry")
    }
}
