import XCTest
import OathDiagnostics

/// Fulfill only on the correlated event, after it is available to the test.
actor MultisigSigningDiagnosticCapture: DiagnosticTransport {
    let operation: UUID
    let delivery: XCTestExpectation
    private(set) var event: DiagnosticEvent?

    init(operation: UUID, delivery: XCTestExpectation) {
        self.operation = operation
        self.delivery = delivery
    }

    func upload(_ events: [DiagnosticEvent]) async throws {
        guard event == nil, let matching = events.first(where: { $0.operationID == operation }) else { return }
        event = matching
        delivery.fulfill()
    }
}
