import Foundation
import OathDiagnostics

/// The production recorder is configured once per process. Share its test
/// transport as well, and select each test's events by a fresh operation ID.
/// Per-test configuration silently keeps the first transport and makes later
/// diagnostics assertions depend on test order.
actor MarketTestDiagnostics: DiagnosticTransport {
    static let shared: MarketTestDiagnostics = {
        let capture = MarketTestDiagnostics()
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("oath-market-diagnostics-\(UUID().uuidString).json")
        OathDiagnostics.configure(file: file, transport: capture)
        return capture
    }()

    private var captured: [DiagnosticEvent] = []
    func upload(_ events: [DiagnosticEvent]) async throws { captured += events }
    func events(for operationID: UUID) -> [DiagnosticEvent] {
        captured.filter { $0.operationID == operationID }
    }
}
