import XCTest
@testable import OathDiagnostics

final class ClioHolderAbsenceTests: XCTestCase {
    func testOnlyExactScopedValidatedHolderAbsenceIsExpected() throws {
        let call: [String: Any] = ["method": "account_info", "params": [["account": "public-fixture", "ledger_index": "validated"]]]
        var request = URLRequest(url: URL(string: "https://s1.ripple.com:51234")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: call)
        let result: [String: Any] = ["error": "actNotFound", "error_code": 19, "status": "error", "type": "response", "request": call]
        let json: [String: Any] = ["result": result, "warnings": [["id": 2001]]]
        let data = try JSONSerialization.data(withJSONObject: json)
        XCTAssertFalse(DiagnosticHTTP.expectedClioHolderAbsence(data, status: 200, request: request))
        XCTAssertFalse(DiagnosticHTTP.expectedAccountAbsence(json, status: 200, request: request))
        try DiagnosticHTTP.$xrplHolderPolicyProbe.withValue(true) {
            XCTAssertTrue(DiagnosticHTTP.expectedClioHolderAbsence(data, status: 200, request: request))
            XCTAssertTrue(DiagnosticHTTP.expectedAccountAbsence(json, status: 200, request: request))
            for status in [400, 429, 500] {
                XCTAssertFalse(DiagnosticHTTP.expectedClioHolderAbsence(data, status: status, request: request))
            }
            for (field, value) in [("error", "tooBusy" as Any), ("error_code", 20), ("validated", false),
                                   ("status", "success"), ("request", [:] as [String: Any])] {
                var changed = result; changed[field] = value
                XCTAssertFalse(DiagnosticHTTP.expectedAccountAbsence(["result": changed, "warnings": [["id": 2001]]], status: 200, request: request))
            }
            for url in ["https://foreign.example:51234", "http://s1.ripple.com:51234", "https://s1.ripple.com:51234/other"] {
                var changed = request; changed.url = URL(string: url)
                XCTAssertFalse(DiagnosticHTTP.expectedClioHolderAbsence(data, status: 200, request: changed))
            }
            for params: [String: Any] in [["account": "other", "ledger_index": "validated"],
                                         ["account": "public-fixture", "ledger_index": "current"],
                                         ["account": "public-fixture", "ledger_index": 10]] {
                var changed = request
                changed.httpBody = try JSONSerialization.data(withJSONObject: ["method": "account_info", "params": [params]])
                XCTAssertFalse(DiagnosticHTTP.expectedClioHolderAbsence(data, status: 200, request: changed))
            }
            for warnings in [[], [["id": 2001], ["id": 2002]]] {
                XCTAssertFalse(DiagnosticHTTP.expectedAccountAbsence(["result": result, "warnings": warnings], status: 200, request: request))
            }
        }
    }
}
