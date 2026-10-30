import XCTest
@testable import OathDiagnostics

private actor HistoryAvailabilityCapture: DiagnosticTransport {
    var events: [DiagnosticEvent] = []
    func upload(_ events: [DiagnosticEvent]) async throws { self.events += events }
}

final class HistoryAvailabilityTests: XCTestCase, @unchecked Sendable {
    private func event(_ domain: String, _ message: String, code: Int = 0,
                       context: [String: String] = [:], component: String = "provider",
                       operation: String = "history", severity: String = "error", runtime: String? = nil) -> DiagnosticEvent {
        .init(error: NSError(domain: domain, code: code, userInfo: [NSLocalizedDescriptionKey: message]),
              component: component, operation: operation, severity: severity, context: context,
              runtimeReport: runtime, sessionID: UUID())
    }
    func testExactTypedHistoryAvailabilityPreservesOtherFailuresAndFatalReports() {
        for (domain, message) in [("OathAnkr.SuiError", "checkpointUnavailable"),
                                  ("OathAnkr.StellarError", "indexUnavailable"),
                                  ("OathAnkr.SolanaError", "rpc(-32019)")] {
            XCTAssertTrue(DiagnosticUploadPolicy.excludes(event(domain, message)))
            XCTAssertFalse(DiagnosticUploadPolicy.excludes(event(domain, message, severity: "fatal")))
            XCTAssertFalse(DiagnosticUploadPolicy.excludes(event(domain, message, component: "runtime")))
            XCTAssertFalse(DiagnosticUploadPolicy.excludes(event(domain, message, runtime: "{}")))
            XCTAssertFalse(DiagnosticUploadPolicy.excludes(event("Fixture.Storage", message)))
        }
        for (domain, message) in [("OathAnkr.SuiError", "graphql"), ("OathAnkr.SuiError", "wrongNetwork"),
                                  ("OathAnkr.StellarError", "incompleteHistory"), ("OathAnkr.StellarError", "paginationLoop"),
                                  ("OathAnkr.SolanaError", "rpc(-32020)"), ("OathAnkr.SolanaSendError", "rpc(-32019)")] {
            XCTAssertFalse(DiagnosticUploadPolicy.excludes(event(domain, message)))
        }
    }
    func testProviderEnvelopeRequiresExactChainHostCodeAndMessage() {
        let sui = ["chain": "sui", "host": "rpc.ankr.com", "http_status": "200"]
        let message = "Checkpoint 339566727 in the future"
        let solana = ["chain": "solana", "host": "api.mainnet-beta.solana.com", "http_status": "200", "method": "getSignaturesForAddress"]
        let storage = "Failed to query long-term storage; please try again"
        for (code, text, context) in [(-1, message, sui), (-32019, storage, solana)] {
            let error = NSError(domain: "Oath.Provider", code: code, userInfo: [NSLocalizedDescriptionKey: text])
            XCTAssertTrue(DiagnosticAvailabilityPolicy.excludesBeforeAdmission(error, component: "network", severity: "error", context: context, runtimeReport: nil))
            XCTAssertTrue(DiagnosticUploadPolicy.excludes(event("Oath.Provider", text, code: code, context: context)))
            for key in ["chain", "host", "http_status"] {
                var wrong = context; wrong[key] = "unrelated"
                XCTAssertFalse(DiagnosticUploadPolicy.excludes(event("Oath.Provider", text, code: code, context: wrong)))
            }
            XCTAssertFalse(DiagnosticUploadPolicy.excludes(event("Oath.Provider", text + " unexpected", code: code, context: context)))
            XCTAssertFalse(DiagnosticUploadPolicy.excludes(event("Oath.Provider", text, code: code - 1, context: context)))
        }
        for value in ["0", "-1", "000123", "9007199254740992", "12345678901234567890", "unknown"] {
            XCTAssertFalse(DiagnosticUploadPolicy.excludes(event("Oath.Provider", "Checkpoint \(value) in the future", code: -1, context: sui)))
        }
        var send = solana; send["method"] = "sendTransaction"
        XCTAssertFalse(DiagnosticUploadPolicy.excludes(event("Oath.Provider", storage, code: -32019, context: send)))
    }
    func testLegacyStellarLagWithoutValidatedLedgerRemainsReportable() {
        let context = ["chain": "stellar", "stage": "history"]
        XCTAssertFalse(DiagnosticUploadPolicy.excludes(event("OathAnkr.StellarError", "incompleteHistory", context: context, operation: "history_index_lag")))
        for (component, operation, ctx) in [("sync", "history_index_lag", context),
                                           ("provider", "events", context),
                                           ("provider", "history_index_lag", ["chain": "stellar"]),
                                           ("provider", "history_index_lag", ["chain": "sui", "stage": "history"])] {
            XCTAssertFalse(DiagnosticUploadPolicy.excludes(event("OathAnkr.StellarError", "incompleteHistory", context: ctx, component: component, operation: operation)))
        }
    }
    func testSavedOutboxDiscardsAvailabilityButUploadsUnprovenIncompleteHistory() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        let bug = event("OathAnkr.StellarError", "incompleteHistory")
        try DiagnosticEvent.encoder().encode([event("OathAnkr.SuiError", "checkpointUnavailable"), bug]).write(to: file)
        let capture = HistoryAvailabilityCapture(), outbox = DiagnosticOutbox(file: file, transport: capture)
        await outbox.flush()
        let sent = await capture.events
        XCTAssertEqual(sent.map(\.id), [bug.id])
    }
}
