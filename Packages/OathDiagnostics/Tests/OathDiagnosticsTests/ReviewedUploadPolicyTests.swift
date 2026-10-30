import XCTest
@testable import OathDiagnostics

private actor PolicyTransport: DiagnosticTransport {
    var events: [DiagnosticEvent] = []
    func upload(_ events: [DiagnosticEvent]) async throws { self.events += events }
}

final class ReviewedUploadPolicyTests: XCTestCase, @unchecked Sendable {
    private func event(_ rule: DiagnosticUploadPolicy.Rule, severity: String = "error",
                       runtime: String? = nil, code: Int? = nil, message: String? = nil,
                       component: String? = nil, context: [String: String]? = nil) -> DiagnosticEvent {
        var fields: [String: String] = [:]
        if !rule.chain.isEmpty { fields["chain"] = rule.chain }
        if !rule.host.isEmpty { fields["host"] = rule.host }
        if !rule.method.isEmpty { fields["method"] = rule.method }
        return DiagnosticEvent(error: NSError(domain: rule.domain, code: code ?? rule.code,
            userInfo: [NSLocalizedDescriptionKey: message ?? (rule.messagePrefix.isEmpty ? "Synthetic reviewed failure" : rule.messagePrefix + "123)")]),
            component: component ?? rule.component, operation: rule.operation, severity: severity,
            context: context ?? fields, runtimeReport: runtime, sessionID: UUID())
    }

    func testEveryReviewedRuleAndUnrelatedFailures() throws {
        XCTAssertEqual(DiagnosticUploadPolicy.rules.count, 73, "Missing/corrupt exclusion resource must fail validation")
        for rule in DiagnosticUploadPolicy.rules {
            XCTAssertEqual(DiagnosticUploadPolicy.excludesReviewed(event(rule)), true, "Reviewed rule: \(rule.component)/\(rule.operation)")
            XCTAssertFalse(DiagnosticUploadPolicy.excludesReviewed(event(rule, severity: "fatal")))
            XCTAssertFalse(DiagnosticUploadPolicy.excludesReviewed(event(rule, runtime: "{}")))
            XCTAssertFalse(DiagnosticUploadPolicy.excludesReviewed(event(rule, code: 987654)))
            XCTAssertFalse(DiagnosticUploadPolicy.excludesReviewed(event(rule, component: "unrelated_operation")))
            var changed = event(rule).context
            changed["host"] = "different-provider.example"
            XCTAssertFalse(DiagnosticUploadPolicy.excludesReviewed(event(rule, context: changed)))
            changed["chain"] = "arc"
            XCTAssertFalse(DiagnosticUploadPolicy.excludesReviewed(event(rule, context: changed)))
            if !rule.messagePrefix.isEmpty {
                XCTAssertFalse(DiagnosticUploadPolicy.excludesReviewed(event(rule, message: "Unrelated failure with the same numeric code")))
            }
        }
    }

    func testNewEventsAreConsumedWithoutDiskUploadOrLossReport() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("outbox.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let transport = PolicyTransport(), box = DiagnosticOutbox(file: file, transport: transport)
        for rule in DiagnosticUploadPolicy.rules {
            let accepted = await box.enqueue(event(rule)); XCTAssertTrue(accepted)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        await box.flush()
        let sent = await transport.events, status = await box.status()
        XCTAssertTrue(sent.isEmpty); XCTAssertEqual(status.pending, 0); XCTAssertEqual(status.dropped, 0)
    }

    func testReopenedQueueFiltersReviewedEventsAndRetainsUnrelatedReport() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("outbox.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let rule = try XCTUnwrap(DiagnosticUploadPolicy.rules.first)
        let retained = event(rule, code: 987654)
        let saved = DiagnosticUploadPolicy.rules.map { event($0) } + [retained]
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try DiagnosticEvent.encoder().encode(saved).write(to: file)
        let transport = PolicyTransport(), box = DiagnosticOutbox(file: file, transport: transport)
        let status = await box.status()
        let expected = saved.filter { !DiagnosticUploadPolicy.excludes($0) }.map(\.id)
        XCTAssertEqual(status.pending, expected.count); XCTAssertEqual(status.dropped, 0)
        let persisted = try DiagnosticEvent.decoder().decode([DiagnosticEvent].self, from: Data(contentsOf: file))
        XCTAssertEqual(persisted.map(\.id), expected)
        await box.flush()
        let sent = await transport.events
        XCTAssertEqual(sent.map(\.id), expected)
        let reopened = DiagnosticOutbox(file: file, transport: transport)
        await reopened.flush()
        let afterRetry = await transport.events
        XCTAssertEqual(afterRetry.map(\.id), expected)
    }
}
