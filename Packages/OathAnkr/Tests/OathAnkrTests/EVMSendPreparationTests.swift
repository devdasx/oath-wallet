import XCTest
import OathDiagnostics
@testable import OathAnkr

private actor EVMPreparationReports: DiagnosticTransport {
    var events = [DiagnosticEvent]()
    func upload(_ batch: [DiagnosticEvent]) async throws { events += batch }
}

private actor EVMPreparationGate {
    private var entered = false
    private var started: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    func wait() async {
        await withCheckedContinuation { continuation in
            release = continuation
            entered = true
            started?.resume(); started = nil
        }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { started = $0 }
    }
    func resume() { release?.resume(); release = nil }
}

@MainActor final class EVMSendPreparationTests: XCTestCase {
    func testSuccessPreservesValueAndScopesDiagnosticContext() async throws {
        let parent = UUID()
        try await OathDiagnostics.$operationID.withValue(parent) {
            try await OathDiagnostics.$chain.withValue("parent") {
                let result = try await EVMSendPreparation.run(network: .base) {
                    XCTAssertEqual(OathDiagnostics.chain, "base")
                    XCTAssertNotEqual(OathDiagnostics.operationID, parent)
                    return 42
                }
                XCTAssertEqual(result, 42)
                XCTAssertEqual(OathDiagnostics.operationID, parent)
                XCTAssertEqual(OathDiagnostics.chain, "parent")
            }
        }
    }

    func testCancelledPreparationNeverStartsQuoteWork() async {
        var called = false
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await EVMSendPreparation.run(network: .ethereum) {
                called = true
                return 42
            }
        }
        do { _ = try await task.value; XCTFail("Cancelled preparation succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(called)
    }

    func testCancellationResistantCompletionCannotReturnQuoteOrStaleFailure() async {
        for lateFailure in [false, true] {
            let gate = EVMPreparationGate()
            let task = Task {
                try await EVMSendPreparation.run(network: .ethereum) {
                    await gate.wait()
                    if lateFailure { throw EVMSendError.insufficientFunds }
                    return 42
                }
            }
            await gate.waitUntilEntered()
            task.cancel()
            await gate.resume()
            do { _ = try await task.value; XCTFail("Cancelled preparation returned a quote") }
            catch { XCTAssertTrue(error is CancellationError) }
        }
    }

    func testQuoteShortagesStayBlockedWhileOtherFailuresAndSubmissionRemainReported() async throws {
        guard ProcessInfo.processInfo.environment["OATH_EVM_PREPARATION_DIAGNOSTICS_TEST"] == "1" else {
            throw XCTSkip("Run alone to isolate the process-wide diagnostics outbox")
        }
        let reports = EVMPreparationReports()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        OathDiagnostics.configure(file: file, transport: reports)
        let sender = "0x" + String(repeating: "1", count: 40)
        let recipient = "0x" + String(repeating: "2", count: 40)
        let token = "0x" + String(repeating: "3", count: 40)
        for network in [EVMSendNetwork.ethereum, .base] {
            let transport = EVMSendFixtureTransport(network: network, nativeBalance: "1000000000000000000")
            let client = try EVMSendClient(network: network, endpoints: [URL(string: "https://fixture.invalid")!], transport: transport)
            for reference in ["native", token] {
                do {
                    _ = try await EVMSendPreparation.run(network: network) {
                        try await client.quote(sender: sender, recipient: recipient, reference: reference,
                            decimals: reference == "native" ? 18 : 6, amount: "1000000000000000000000000")
                    }
                    XCTFail("An amount above the available balance must not produce a quote")
                } catch { XCTAssertEqual(error as? EVMSendError, .insufficientFunds) }
            }
            await transport.fund("0")
            do {
                _ = try await EVMSendPreparation.run(network: network) {
                    try await client.quote(sender: sender, recipient: recipient, reference: token, decimals: 6, amount: "100")
                }
                XCTFail("Missing native fees must keep the token send blocked")
            } catch { XCTAssertEqual(error as? SendFeeFundingError, .insufficientNativeBalance) }
            let broadcasts = await transport.broadcasts
            XCTAssertEqual(broadcasts, 0)
        }
        for failure in [EVMSendError.malformed, .wrongNetwork, .expired, .transport, .feeTooHigh, .rpc(-32000)] {
            do {
                let _: Int = try await EVMSendPreparation.run(network: .ethereum) { throw failure }
                XCTFail("Unexpected errors must propagate")
            } catch { XCTAssertEqual(error as? EVMSendError, failure) }
        }
        let lookalike = NSError(domain: "OathAnkr.EVMSendError", code: 5,
            userInfo: [NSLocalizedDescriptionKey: "insufficientFunds"])
        do {
            let _: Int = try await EVMSendPreparation.run(network: .ethereum) { throw lookalike }
            XCTFail("Untyped errors must propagate")
        } catch { XCTAssertEqual(error as NSError, lookalike) }
        // The existing availability policy excludes ordinary Ethereum transport
        // reports but retains terminal send failures for Sei. Both must still
        // reject the quote; preparation does not change that policy.
        do {
            let _: Int = try await EVMSendPreparation.run(network: .sei) { throw EVMSendError.transport }
            XCTFail("Provider failure must reject the quote")
        } catch { XCTAssertEqual(error as? EVMSendError, .transport) }
        // The same typed failure after authorization is not a form rejection.
        OathDiagnostics.record(EVMSendError.insufficientFunds, component: "evm_send", operation: "submit",
            context: ["chain": "ethereum", "stage": "broadcast"])
        for _ in 0..<200 {
            if await reports.events.count >= 8 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(100))
        let events = await reports.events
        XCTAssertEqual(events.count, 8)
        XCTAssertEqual(events.filter { $0.operation == "quote" }.count, 7)
        XCTAssertEqual(events.filter { $0.operation == "submit" }.map(\.error.message), ["insufficientFunds"])
        XCTAssertEqual(events.filter { $0.context["chain"] == "ethereum" }.count, 7)
        XCTAssertEqual(events.filter { $0.error.message == "transport" }.map { $0.context["chain"] }, ["sei"])
        XCTAssertEqual(Set(events.filter { $0.operation == "quote" && $0.context["chain"] == "ethereum" }.map(\.error.message)),
                       ["malformed", "wrongNetwork", "expired", "feeTooHigh", "rpc(-32000)", "insufficientFunds"])
        XCTAssertEqual(Set(events.filter { $0.operation == "quote" }.map(\.operationID)).count, 7)
    }
}
