import XCTest
@testable import OathDiagnostics

final class XrplPendingDiagnosticTests: XCTestCase {
    func testOnlyExactPendingTransactionAbsenceIsExpected() throws {
        let hash = String(repeating: "A", count: 64)
        var request = URLRequest(url: URL(string: "https://xrplcluster.com")!); request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: ["method": "tx", "params": [["transaction": hash, "binary": false]]])
        let result: [String: Any] = ["error": "txnNotFound", "error_code": 29, "status": "error", "request": ["command": "tx", "transaction": hash]]
        XCTAssertTrue(DiagnosticHTTP.expectedAccountAbsence(["result": result], status: 200, request: request))
        for (key, value) in [("error", "tooBusy" as Any), ("error_code", 30), ("status", "success"), ("request", ["command": "tx", "transaction": String(repeating: "B", count: 64)])] {
            var changed = result; changed[key] = value
            XCTAssertFalse(DiagnosticHTTP.expectedAccountAbsence(["result": changed], status: 200, request: request))
        }
        XCTAssertFalse(DiagnosticHTTP.expectedAccountAbsence(["result": result], status: 429, request: request))
        request.httpBody = try JSONSerialization.data(withJSONObject: ["method": "submit", "params": [["transaction": hash]]])
        XCTAssertFalse(DiagnosticHTTP.expectedAccountAbsence(["result": result], status: 200, request: request))
    }
}
