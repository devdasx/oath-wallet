import XCTest
import GRDB
import OathDiagnostics
@testable import OathDatabase

final class DatabaseDiagnosticsTests: XCTestCase {
    func testSQLiteDiagnosticsPreserveFailureWithoutSQLOrPrivateBindings() throws {
        let error = DatabaseError(resultCode: .SQLITE_CONSTRAINT, message: "UNIQUE constraint failed: wallets.id",
                                  sql: "INSERT INTO wallets VALUES ('fixture-private-input')", arguments: ["fixture-private-input"])
        let report = DiagnosticError(error)
        XCTAssertEqual(report.code, Int(error.extendedResultCode.rawValue))
        XCTAssertEqual(report.message, "UNIQUE constraint failed: wallets.id")
        let json = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        XCTAssertFalse(json.contains("fixture-private-input"))
        XCTAssertFalse(json.contains("INSERT INTO"))
    }
}

/// The production reporter is process-wide. All database diagnostics tests use
/// one sink and isolate assertions by operation ID, including parallel runs.
actor DatabaseDiagnosticProbe: DiagnosticTransport {
    static let shared = DatabaseDiagnosticProbe()
    private let file = FileManager.default.temporaryDirectory
        .appendingPathComponent("OathDatabaseDiagnostics-" + UUID().uuidString)
        .appendingPathComponent("outbox.json")
    private var received: [DiagnosticEvent] = []
    func configure() { OathDiagnostics.configure(file: file, transport: self) }
    func upload(_ events: [DiagnosticEvent]) async throws { received += events }
    func events() -> [DiagnosticEvent] { received }
}
