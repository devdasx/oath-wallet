import XCTest
import OathDiagnostics
@testable import RefreshActionCore

private actor RefreshReports: DiagnosticTransport {
    var events = [DiagnosticEvent]()
    func upload(_ events: [DiagnosticEvent]) async throws { self.events += events }
}

/// Holds a non-cooperative provider callback until the test changes ownership.
@MainActor private final class ActionGate {
    private var completion: CheckedContinuation<Void, Never>?
    private var ready: CheckedContinuation<Void, Never>?
    func wait() async {
        await withCheckedContinuation {
            completion = $0
            ready?.resume(); ready = nil
        }
    }
    func waitUntilStarted() async {
        guard completion == nil else { return }
        await withCheckedContinuation { ready = $0 }
    }
    func resume() { completion?.resume(); completion = nil }
}

@MainActor final class RefreshActionTests: XCTestCase {
    func testCancellationOwnershipAndFailureReporting() async throws {
        let reports = RefreshReports()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        OathDiagnostics.configure(file: file, transport: reports)

        let success = await RefreshAction.run(action: {}, isCurrent: { true })
        XCTAssertEqual(success, .succeeded)

        var starts = 0
        let preCancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await RefreshAction.run(action: { starts += 1 }, isCurrent: { true })
        }
        let cancelledBeforeStart = await preCancelled.value
        XCTAssertEqual(cancelledBeforeStart, .cancelled)
        XCTAssertEqual(starts, 0, "A cancelled refresh must not start new provider work")
        let staleBeforeStart = await RefreshAction.run(action: { starts += 1 }, isCurrent: { false })
        XCTAssertEqual(staleBeforeStart, .cancelled)
        XCTAssertEqual(starts, 0, "A superseded refresh must not start new provider work")

        for error in [CancellationError() as any Error, URLError(.cancelled)] {
            let outcome = await RefreshAction.run(action: { throw error }, isCurrent: { true })
            XCTAssertEqual(outcome, .cancelled, "Cancellation must not trigger failure feedback")
        }

        // A callback may return an ordinary domain error after its task was
        // cancelled or its screen/wallet owner was replaced. Neither may publish
        // a result, report a new UI failure or invalidate the new owner's work.
        for cancelTask in [false, true] {
            for lateFailure in [false, true] {
                let gate = ActionGate()
                let oldRequest = UUID(), newRequest = UUID()
                var currentRequest = oldRequest
                let old = Task {
                    await RefreshAction.run(action: {
                        await gate.wait()
                        if lateFailure { throw NSError(domain: "RefreshFixture.Late", code: 31) }
                    }, isCurrent: { currentRequest == oldRequest })
                }
                await gate.waitUntilStarted()
                currentRequest = newRequest
                if cancelTask { old.cancel() }
                let current = await RefreshAction.run(action: {}, isCurrent: { currentRequest == newRequest })
                gate.resume()
                let obsolete = await old.value
                XCTAssertEqual(obsolete, .cancelled)
                XCTAssertEqual(current, .succeeded)
                XCTAssertEqual(currentRequest, newRequest)
            }
        }
        // Task cancellation by itself is enough, even before the owner changes.
        let gate = ActionGate()
        let lateFailure = Task {
            await RefreshAction.run(action: {
                await gate.wait()
                throw NSError(domain: "RefreshFixture.Late", code: 32)
            }, isCurrent: { true })
        }
        await gate.waitUntilStarted()
        lateFailure.cancel(); gate.resume()
        let lateOutcome = await lateFailure.value
        XCTAssertEqual(lateOutcome, .cancelled)

        // Active failures remain failures and retain original, privacy-filtered
        // diagnostics. Each pull owns a correlation ID inherited by its action.
        var actionIDs = [UUID]()
        for code in [41, 42] {
            let outcome = await OathDiagnostics.$chain.withValue("ethereum") {
                await RefreshAction.run(action: {
                    actionIDs.append(try XCTUnwrap(OathDiagnostics.operationID))
                    throw NSError(domain: "RefreshFixture.Active", code: code,
                        userInfo: [NSLocalizedDescriptionKey:
                            "Failed for 0x1234567890123456789012345678901234567890 at https://example.invalid/private?api_key=not-a-real-secret"])
                }, isCurrent: { true })
            }
            XCTAssertEqual(outcome, .failed)
        }
        for _ in 0..<100 {
            if await reports.events.filter({ $0.error.domain == "RefreshFixture.Active" }).count == 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        // record() performs bounded asynchronous admission; allow earlier false
        // events to reach the capture too, rather than only checking return values.
        try await Task.sleep(for: .milliseconds(200))
        let events = await reports.events
        XCTAssertEqual(events.count, 2, "Only live failures may reach the outbox")
        XCTAssertFalse(events.contains { $0.error.domain == "RefreshFixture.Late" })
        let active = events.filter { $0.error.domain == "RefreshFixture.Active" }
        XCTAssertEqual(Set(active.map(\.error.code)), Set([41, 42]))
        XCTAssertEqual(Set(active.compactMap(\.operationID)), Set(actionIDs))
        XCTAssertEqual(Set(actionIDs).count, 2)
        XCTAssertTrue(active.allSatisfy {
            $0.component == "OathNativeRefresh" && $0.operation == "startRefresh" && $0.context["chain"] == "ethereum"
        })
        let encoded = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        for privateValue in ["0x1234567890123456789012345678901234567890", "not-a-real-secret", "/private?api_key="] {
            XCTAssertFalse(encoded.contains(privateValue))
        }
    }
}
