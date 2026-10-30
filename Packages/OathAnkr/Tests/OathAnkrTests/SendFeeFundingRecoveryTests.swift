import XCTest
@testable import OathAnkr

@MainActor final class SendFeeFundingRecoveryTests: XCTestCase {
    func testBaseTokenQuoteRecoversAfterPartialThenSufficientETHWithoutBroadcasting() async throws {
        let transport = EVMSendFixtureTransport(network: .base, nativeBalance: "0", gasEstimate: 70_000)
        let client = try EVMSendClient(network: .base, endpoints: [URL(string: "https://fixture.invalid")!], transport: transport)
        let sender = "0x" + String(repeating: "1", count: 40)
        let recipient = "0x" + String(repeating: "2", count: 40)
        let contract = "0x" + String(repeating: "3", count: 40)
        func quote() async throws -> EVMSendPlan {
            try await client.quote(sender: sender, recipient: recipient, reference: contract, decimals: 6, amount: "1000000")
        }
        do { _ = try await quote(); XCTFail("No ETH must block the token quote") }
        catch { XCTAssertEqual(error as? SendFeeFundingError, .insufficientNativeBalance) }
        await transport.fund("1")
        var state = SendFeeFundingRecovery.State.waiting
        var attempts = 0
        var result: EVMSendPlan?
        var flight: Task<Void, Never>?
        await SendFeeFundingRecovery.run(interval: .milliseconds(2), state: { state }, refresh: {
            attempts += 1
            guard attempts <= 3 else { XCTFail("Funding did not recover"); state = .stopped; return }
            state = .preparing
            flight = Task {
                do {
                    result = try await quote()
                    state = .stopped
                } catch is SendFeeFundingError {
                    XCTAssertEqual(attempts, 1, "The partial deposit must stay blocked")
                    await transport.fund("1000000000000000000")
                    state = .waiting
                } catch {
                    XCTFail("Unexpected quote failure: \(error)")
                    state = .stopped
                }
            }
        })
        await flight?.value
        let plan = try XCTUnwrap(result)
        try plan.validate()
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(plan.network, .base)
        XCTAssertEqual(plan.sender, sender)
        XCTAssertEqual(plan.recipient, recipient)
        XCTAssertEqual(plan.reference, contract)
        XCTAssertEqual(plan.amount, "1000000")
        XCTAssertGreaterThan(plan.fee, 0)
        XCTAssertGreaterThan(plan.extraFee, 0, "Base must retain the L1 fee component")
        let broadcasts = await transport.broadcasts
        XCTAssertEqual(broadcasts, 0, "Receiving fee funds never authorizes a send")
    }

    func testBusyQuoteIsNotStartedAgainAndRecoveryStopsWhenReady() async {
        var state = SendFeeFundingRecovery.State.preparing
        var refreshes = 0
        let pending = Task {
            try? await Task.sleep(for: .milliseconds(20))
            XCTAssertEqual(refreshes, 0)
            state = .waiting
        }
        await SendFeeFundingRecovery.run(interval: .milliseconds(2), state: { state }, refresh: {
            refreshes += 1
            state = .stopped
        })
        await pending.value
        XCTAssertEqual(refreshes, 1)
    }

    func testClosingLockingOrBackgroundingDuringWaitDoesNotRefresh() async {
        var state = SendFeeFundingRecovery.State.waiting
        var refreshes = 0
        let monitor = Task {
            await SendFeeFundingRecovery.run(interval: .milliseconds(25), state: { state }, refresh: { refreshes += 1 })
        }
        await Task.yield()
        state = .stopped
        await monitor.value
        XCTAssertEqual(refreshes, 0)
    }

    func testCancelledMonitorCannotRefreshEvenIfSleepReturnsNormally() async {
        var refreshes = 0
        let monitor = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await SendFeeFundingRecovery.run(state: { .waiting }, refresh: { refreshes += 1 }, sleep: { _ in })
        }
        await monitor.value
        XCTAssertEqual(refreshes, 0)
    }
}
