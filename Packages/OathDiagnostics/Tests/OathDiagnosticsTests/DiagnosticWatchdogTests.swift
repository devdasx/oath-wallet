import XCTest
import Dispatch
@testable import OathDiagnostics

final class DiagnosticWatchdogTests: XCTestCase, @unchecked Sendable {
    func testStartFromMainActorReportsOnBackgroundQueueEvenWhenMainActorIsBlocked() async {
        await MainActor.run {
            let reported = DispatchSemaphore(value: 0)
            let watchdog = DiagnosticWatchdog(threshold: 0.02, interval: .milliseconds(5), leeway: .milliseconds(1)) { duration in
                // Regression: the original callback inherited MainActor from
                // start() and trapped in dispatch_assert_queue on this queue.
                dispatchPrecondition(condition: .notOnQueue(.main))
                XCTAssertGreaterThanOrEqual(duration, 0.02)
                reported.signal()
            }
            watchdog.start()
            watchdog.start() // Starting twice must not install another timer.
            watchdog.setActive(true)
            defer { watchdog.stop() }
            // Intentionally block only the host's main actor. Moving the
            // watchdog callback to MainActor would time out instead of passing.
            XCTAssertEqual(reported.wait(timeout: .now() + 2), .success)
        }
    }

    func testStopAndRestartRearmsBackgroundCallback() async {
        let reported = DispatchSemaphore(value: 0)
        let watchdog = DiagnosticWatchdog(threshold: 0.02, interval: .milliseconds(5), leeway: .milliseconds(1)) { _ in
            reported.signal()
        }
        defer { watchdog.stop() }
        for _ in 0..<2 {
            await MainActor.run {
                watchdog.start()
                watchdog.setActive(true)
            }
            XCTAssertEqual(reported.wait(timeout: .now() + 2), .success)
            watchdog.stop()
            XCTAssertEqual(reported.wait(timeout: .now() + 0.05), .timedOut)
        }
    }

    func testTimerDoesNotRetainWatchdog() {
        weak var released: DiagnosticWatchdog?
        do {
            let watchdog = DiagnosticWatchdog { _ in XCTFail("Inactive watchdog must not report") }
            released = watchdog
            watchdog.start()
        }
        XCTAssertNil(released)
    }

    func testInactiveAndSubthresholdHeartbeatsDoNotReport() {
        var state = DiagnosticWatchdogState()
        XCTAssertNil(state.stallDuration(at: 100, threshold: 2))
        state.setActive(true, at: 100)
        XCTAssertNil(state.stallDuration(at: 101.9, threshold: 2))
        state.beat(at: 101.9)
        XCTAssertNil(state.stallDuration(at: 103, threshold: 2))
    }

    func testReportsOncePerStallAndRearmsAfterHeartbeat() {
        var state = DiagnosticWatchdogState()
        state.setActive(true, at: 100)
        XCTAssertEqual(state.stallDuration(at: 102, threshold: 2), 2)
        XCTAssertNil(state.stallDuration(at: 110, threshold: 2))
        state.beat(at: 111)
        XCTAssertNil(state.stallDuration(at: 112, threshold: 2))
        XCTAssertEqual(state.stallDuration(at: 114, threshold: 2), 3)
    }

    func testBackgroundTimeIsNotCountedAsForegroundStall() {
        var state = DiagnosticWatchdogState()
        state.setActive(true, at: 100)
        state.setActive(false, at: 101)
        XCTAssertNil(state.stallDuration(at: 500, threshold: 2))
        state.setActive(true, at: 500)
        XCTAssertNil(state.stallDuration(at: 501, threshold: 2))
        XCTAssertEqual(state.stallDuration(at: 502, threshold: 2), 2)
    }
}
