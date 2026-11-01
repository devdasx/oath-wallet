import XCTest
import OathDiagnostics

/// Diagnostic records are produced concurrently. Wait for the entire set a test
/// asserts on, regardless of which producer or outbox batch arrives first.
actor CorrelatedDiagnosticTestCapture: DiagnosticTransport {
    private let operation: UUID
    private let ready: XCTestExpectation
    private let complete: @Sendable ([DiagnosticEvent]) -> Bool
    private var fulfilled = false
    private(set) var events: [DiagnosticEvent] = []

    init(operation: UUID, ready: XCTestExpectation, complete: @escaping @Sendable ([DiagnosticEvent]) -> Bool) {
        self.operation = operation
        self.ready = ready
        self.complete = complete
    }

    func upload(_ batch: [DiagnosticEvent]) async throws {
        events += batch.filter { $0.operationID == operation }
        if !fulfilled && complete(events) {
            fulfilled = true
            ready.fulfill()
        }
    }
}
