import Foundation
import XCTest
@testable import OathDiagnostics

final class DiagnosticTraceTests: XCTestCase {
    func testEveryCataloguedSourceSurvivesButLookalikesAndPrivatePathsDoNot() {
        XCTAssertFalse(DiagnosticPrivacy.appSourceFiles.isEmpty)
        for source in DiagnosticPrivacy.appSourceFiles {
            let value = source + ":222"
            XCTAssertEqual(DiagnosticPrivacy.context(["screen": value])["screen"], value)
        }
        let source = "OathAtmosphere/OathWalletConnectTransactionProgress.swift"
        for value in ["/Users/private/" + source + ":222", source + ":0", source + ":-1", source + ":222\npassword=PRIVATE_FIXTURE",
                      source + ":222 password=PRIVATE_FIXTURE", source + ":\"PRIVATE_FIXTURE\":222"] {
            let output = DiagnosticPrivacy.context(["screen": value])["screen"]!
            XCTAssertFalse(output.contains("/Users/private/"))
            XCTAssertFalse(output.contains("PRIVATE_FIXTURE"))
        }
    }
    func testKnownScreenSourceSurvivesContextFilteringWithoutTrustingArbitraryText() throws {
        let source = "OathAtmosphere/OathWalletConnectTransactionProgress.swift"
        let token = UUID()
        OathDiagnostics.screenAppeared(token, file: "OathAtmosphere/OathWalletConnectTransactionProgress.swift", line: 222)
        defer { OathDiagnostics.screenDisappeared(token) }
        let raw = OathDiagnostics.withAction(file: "OathAtmosphere/OathWalletConnectTransactionProgress.swift", function: "body", line: 223) {
            OathDiagnostics.failureContext([:], operation: "refresh", function: "read")
        }
        let event = DiagnosticEvent(error: NSError(domain: "Fixture", code: 1), component: "test", operation: "refresh",
                                    context: raw, sessionID: UUID())
        XCTAssertEqual(event.context["screen"], source + ":222")
        XCTAssertEqual(event.context["origin_screen"], source + ":222")
        XCTAssertEqual(event.context["action"], source + ":body:223")
        let reopened = try DiagnosticEvent.decoder().decode(DiagnosticEvent.self, from: DiagnosticEvent.encoder().encode(event))
        XCTAssertEqual(DiagnosticPrivacy.context(reopened.context), reopened.context)
        let secret = String(repeating: "abcdef01", count: 8)
        let malicious = DiagnosticPrivacy.context([
            "screen": "OathAtmosphere/" + secret + ".swift:222",
            "origin_screen": source + ":222 password=PRIVATE_FIXTURE",
            "action": source + ":" + secret + ":223",
            "step": source + ":mnemonic=PRIVATE_FIXTURE:223"
        ])
        let output = try String(decoding: JSONEncoder().encode(malicious), as: UTF8.self)
        XCTAssertFalse(output.contains(secret)); XCTAssertFalse(output.contains("PRIVATE_FIXTURE"))
        XCTAssertTrue(DiagnosticPrivacy.text(source).contains("[redacted]"), "Untrusted error text must retain its original privacy policy")
    }
    @MainActor func testRecordCapturesContextBeforeDetachedUpload() async throws {
        guard ProcessInfo.processInfo.environment["OATH_TRACE_OUTBOX_TEST"] == "1" else {
            throw XCTSkip("Run in a fresh process: the production reporter configures its transport once")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let sink = TraceTransport(), screen = UUID()
        OathDiagnostics.configure(file: folder.appendingPathComponent("events.json"), transport: sink)
        OathDiagnostics.screenAppeared(screen, file: "OathAtmosphere/OathWalletConnectTransactionProgress.swift", line: 10)
        OathDiagnostics.setLifecycle(.active)
        OathDiagnostics.withAction(file: "OathAtmosphere/OathWalletConnectTransactionProgress.swift", function: "confirm", line: 20) {
            let original = NSError(domain: "Fixture.Validation", code: 22)
            XCTAssertTrue(OathDiagnostics.failure(original, reason: "receipt_status_invalid",
                file: "Fixture/Client.swift", function: "verify", line: 40) === original)
            OathDiagnostics.record(DiagnosticFailure("preparation failed", cause: NSError(domain: "Fixture.Storage", code: 513)),
                                   operation: "prepare", context: ["stage": "read_receipt"], file: "Fixture/Send.swift", function: "decode", line: 30)
        }
        // The actual outbox work is detached. Navigating now must not rewrite
        // the failure's captured screen, lifecycle, step or original cause.
        OathDiagnostics.screenDisappeared(screen)
        OathDiagnostics.setLifecycle(.background)
        for _ in 0..<200 {
            if await sink.events.count >= 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let captured = await sink.events
        let event = try XCTUnwrap(captured.first { $0.operation == "prepare" })
        let validation = try XCTUnwrap(captured.first { $0.operation == "verify" })
        XCTAssertEqual(validation.context["reason"], "receipt_status_invalid")
        XCTAssertEqual(validation.context["step"], "response_validation")
        XCTAssertEqual(validation.sourceLine, 40)
        XCTAssertEqual(validation.operationID, event.operationID)
        XCTAssertEqual(event.context["screen"], "OathAtmosphere/OathWalletConnectTransactionProgress.swift:10")
        XCTAssertEqual(event.context["origin_screen"], "OathAtmosphere/OathWalletConnectTransactionProgress.swift:10")
        XCTAssertEqual(event.context["app_state"], "active")
        XCTAssertEqual(event.context["step"], "read_receipt")
        XCTAssertEqual(event.error.underlying.first?.code, 513)
        XCTAssertNotNil(event.operationID)
        XCTAssertEqual(event.sourceLine, 30)
    }
    func testEveryEventHasHonestDefaultsAndOriginalError() throws {
        let event = DiagnosticEvent(error: NSError(domain: "Fixture", code: 17), component: "test", operation: "read",
                                    sessionID: UUID(), occurredAt: Date(timeIntervalSince1970: 1_700_000_000), file: "Fixture/Store.swift", function: "readPage", line: 12)
        XCTAssertEqual(event.error.domain, "Fixture")
        XCTAssertEqual(event.error.code, 17)
        XCTAssertEqual(event.context["screen"], "unknown")
        XCTAssertEqual(event.context["cause_status"], "original_error_only")
        XCTAssertEqual(event.context["step"], "readPage")
        XCTAssertEqual(event.context["time_source"], "capture_time")
        XCTAssertEqual(try DiagnosticEvent.decoder().decode(DiagnosticEvent.self, from: DiagnosticEvent.encoder().encode(event)), event)
    }
    func testTypedCauseChainSurvivesWithoutCredentialsOrUnboundedRecursion() {
        let root = NSError(domain: "Fixture.Storage", code: 513, userInfo: [NSLocalizedDescriptionKey: "denied password=secret-fixture https://fixture.invalid/private", "wallet_name": "PRIVATE_WALLET"])
        var error: any Error = root
        for _ in 0..<6 { error = DiagnosticFailure("save failed", cause: error) }
        var captured = DiagnosticError(error), depth = 0
        while let child = captured.underlying.first { depth += 1; captured = child }
        XCTAssertEqual(depth, 3)
        let event = DiagnosticEvent(error: DiagnosticFailure("save failed", cause: root), component: "storage", operation: "save", sessionID: UUID())
        XCTAssertEqual(event.context["cause_status"], "underlying_preserved")
        XCTAssertEqual(event.error.underlying.first?.domain, "Fixture.Storage")
        XCTAssertEqual(event.error.underlying.first?.code, 513)
        let output = String(data: try! DiagnosticEvent.encoder().encode(event), encoding: .utf8)!
        for secret in ["secret-fixture", "fixture.invalid", "PRIVATE_WALLET"] { XCTAssertFalse(output.contains(secret)) }
    }
    func testPresentationRestoresParentAndIgnoresOutOfOrderDetach() {
        let state = DiagnosticPresentationState(), root = UUID(), sheet = UUID(), stale = UUID()
        state.appear(root, screen: "home"); state.appear(sheet, screen: "send")
        state.disappear(stale); XCTAssertEqual(state.snapshot()["screen"], "send")
        state.disappear(root); XCTAssertEqual(state.snapshot()["screen"], "send")
        state.appear(root, screen: "home"); state.appear(sheet, screen: "send")
        state.disappear(sheet); XCTAssertEqual(state.snapshot()["screen"], "home")
        for _ in 0..<100 { state.appear(UUID(), screen: "bounded") }
        state.setLifecycle("background"); XCTAssertEqual(state.snapshot()["app_state"], "background")
    }
    @MainActor func testConcurrentActionsKeepOriginsAndNestedStepsAfterNavigation() async {
        let token = UUID()
        OathDiagnostics.screenAppeared(token, file: "Fixture/Home.swift", line: 1)
        let first = OathDiagnostics.withAction(file: "Fixture/Home.swift", function: "refresh", line: 2) {
            Task { await OathDiagnostics.withStep("load_balance") {
                await Task.yield()
                return (OathDiagnostics.operationID, OathDiagnostics.failureContext([:], operation: "read", function: "decode"))
            } }
        }
        OathDiagnostics.screenDisappeared(token)
        let second = OathDiagnostics.withAction(file: "Fixture/Send.swift", function: "prepare", line: 3) {
            Task { OathDiagnostics.failureContext([:], operation: "send", function: "validate") }
        }
        let (id, a) = await first.value, b = await second.value
        XCTAssertNotNil(id); XCTAssertEqual(a["origin_screen"], "Fixture/Home.swift:1")
        XCTAssertEqual(a["step"], "load_balance")
        XCTAssertEqual(a["action"], "Fixture/Home.swift:refresh:2")
        XCTAssertEqual(b["origin_screen"], "unknown")
        XCTAssertNotEqual(a["action"], b["action"])
        XCTAssertNotNil(a["action_started_at"]); XCTAssertNotNil(Int(a["elapsed_ms"] ?? ""))
        XCTAssertNil(OathDiagnostics.trace); XCTAssertNil(OathDiagnostics.operationID)
    }
    func testExplicitStageAndHistoricalTimeAreNotMisattributed() {
        let context = OathDiagnostics.failureContext(["stage": "decode_receipt"], operation: "refresh", function: "query")
        XCTAssertEqual(context["step"], "decode_receipt")
        XCTAssertEqual(context["step_source"], "explicit_stage")
        OathDiagnostics.withAction {
            let delayed = OathDiagnostics.failureContext(["source": "MetricKit"], operation: "crash", function: "delivery")
            XCTAssertEqual(delayed["screen"], "unknown")
            XCTAssertEqual(delayed["origin_screen"], "unknown")
            XCTAssertNil(delayed["action_started_at"])
            XCTAssertEqual(delayed["time_source"], "metrickit_payload_end")
        }
    }
    func testNamedAttemptsRetainStepAndRestoreOuterScope() async {
        await OathDiagnostics.withStep("outer") {
            _ = await OathDiagnostics.attempt("prepare") {
                XCTAssertEqual(OathDiagnostics.trace?.step, "prepare")
                await OathDiagnostics.withStep("decode") { XCTAssertEqual(OathDiagnostics.trace?.step, "decode") }
                XCTAssertEqual(OathDiagnostics.trace?.step, "prepare")
                return true
            }
            XCTAssertEqual(OathDiagnostics.trace?.step, "outer")
        }
        XCTAssertNil(OathDiagnostics.trace)
    }
    func testAsyncStepPreservesCallingActorAndNonSendableResult() async {
        let probe = TraceIsolationProbe()
        let value = await probe.run()
        XCTAssertEqual(value, 1)
    }

    @MainActor func testThrowingAsyncStepRestoresCallerContext() async {
        enum FixtureError: Error { case expected }
        do {
            try await OathDiagnostics.withStep("throwing_step") {
                MainActor.preconditionIsolated()
                await Task.yield()
                MainActor.preconditionIsolated()
                XCTAssertEqual(OathDiagnostics.trace?.step, "throwing_step")
                throw FixtureError.expected
            }
            XCTFail("The original error must propagate")
        } catch FixtureError.expected {
            XCTAssertNil(OathDiagnostics.trace)
        } catch {
            XCTFail("Unexpected error type")
        }
    }
    func testExtendedContextIsBoundedFilteredAndNoPrivateKeysAreAccepted() {
        let fields = ["screen", "origin_screen", "action", "step", "app_state", "action_started_at", "elapsed_ms", "cause_status", "time_source"]
        var input = Dictionary(uniqueKeysWithValues: fields.map { ($0, String(repeating: "x", count: 2000) + " password=hidden") })
        input["wallet_name"] = "PRIVATE_WALLET"; input["request_body"] = "PRIVATE_BODY"
        let result = DiagnosticPrivacy.context(input)
        XCTAssertNil(result["wallet_name"]); XCTAssertNil(result["request_body"])
        XCTAssertTrue(result.values.allSatisfy { $0.utf8.count < 300 && !$0.contains("hidden") })
    }
}

private actor TraceIsolationProbe {
    private final class LocalValue { var count = 0 }

    func run() async -> Int {
        let result = await OathDiagnostics.withStep("actor_step") {
            self.preconditionIsolated()
            await Task.yield()
            self.preconditionIsolated()
            let value = LocalValue()
            value.count += 1
            return value
        }
        XCTAssertNil(OathDiagnostics.trace)
        return result.count
    }
}

private actor TraceTransport: DiagnosticTransport {
    var events: [DiagnosticEvent] = []
    func upload(_ events: [DiagnosticEvent]) async throws { self.events += events }
}
