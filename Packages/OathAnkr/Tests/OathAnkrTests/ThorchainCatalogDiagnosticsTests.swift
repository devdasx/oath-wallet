import Foundation
import XCTest
import OathDiagnostics
@testable import OathAnkr

private actor CatalogReports: DiagnosticTransport {
    var events: [DiagnosticEvent] = []
    func upload(_ events: [DiagnosticEvent]) async throws { self.events += events }
}

final class ThorchainCatalogDiagnosticsTests: XCTestCase, @unchecked Sendable {
    func testRealCatalogFailureRemainsReportedAndCancellationIsExcluded() async throws {
        let reports = CatalogReports()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        OathDiagnostics.configure(file: file, transport: reports)
        let cache = ThorchainCatalogRequests(), operation = UUID()
        do {
            _ = try await OathDiagnostics.$operationID.withValue(operation) {
                try await cache.value { throw ThorchainError.malformed }
            }
            XCTFail()
        } catch { XCTAssertEqual(error as? ThorchainError, .malformed) }
        do { _ = try await cache.value { throw CancellationError() }; XCTFail() }
        catch { XCTAssertTrue(error is CancellationError) }
        for _ in 0..<100 {
            if await reports.events.count > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(50))
        let events = await reports.events
        XCTAssertEqual(events.count, 1)
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event.error.message, "malformed")
        XCTAssertEqual(event.operation, "catalog_load")
        XCTAssertEqual(event.operationID, operation)
        XCTAssertEqual(event.context["chain"], "thorchain")
        XCTAssertEqual(event.context["stage"], "catalog")
        XCTAssertEqual(event.context["action"], "catalog_load")
        XCTAssertEqual(event.context["step"], "catalog")
        XCTAssertEqual(event.context["cause_status"], "original_error_only")
        XCTAssertEqual(Set(event.context.keys), ["chain", "stage", "action", "step", "cause_status",
            "origin_screen", "screen_source", "step_source", "app_state", "screen", "time_source"])
        XCTAssertTrue(event.privacyFiltered)
        _ = try await cache.value { ThorchainCatalog() }
    }
}
