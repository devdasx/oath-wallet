import XCTest
@testable import OathDiagnostics

final class IndexedArchiveRecoveryPolicyTests: XCTestCase {
    func testOnlyMissingIndexDuringArchiveHandoffIsExcluded() {
        func excluded(_ domain: String = "OathAnkr.IndexedEVMClient.HistoryAvailability",
                      code: Int = 0, message: String = "missingRPCRecord", chain: String = "zerog",
                      operation: String = "history_rpc_recovery", component: String = "provider",
                      severity: String = "warning", file: String = "OathAnkr/IndexedEVMClient.swift") -> Bool {
            let event = DiagnosticEvent(error: NSError(domain: domain, code: code, userInfo: [NSLocalizedDescriptionKey: message]),
                component: component, operation: operation, severity: severity, context: ["chain": chain], sessionID: UUID(), file: file)
            return DiagnosticUploadPolicy.excludes(event)
        }
        for chain in ["celo", "filecoin", "sei", "zerog", "iotex"] {
            XCTAssertTrue(excluded(chain: chain), chain)
        }
        XCTAssertTrue(excluded("OathAnkr.IndexedEVMClient.unknowncontextat10d5ac4c4.HistoryAvailability"))
        XCTAssertFalse(excluded("Other.HistoryAvailability"))
        XCTAssertFalse(excluded(message: "filecoinWrappingEvidenceRequired"))
        XCTAssertFalse(excluded(code: 1))
        XCTAssertFalse(excluded(operation: "startHistory_:"))
        XCTAssertFalse(excluded(component: "sync"))
        XCTAssertFalse(excluded(file: "fixture.swift"))
        XCTAssertFalse(excluded(chain: "arc"))
        XCTAssertFalse(excluded(chain: "robinhood"))
        XCTAssertFalse(excluded(severity: "fatal"))
    }
}
