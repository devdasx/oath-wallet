import XCTest
@testable import OathDiagnostics

final class PublicPolicyDiagnosticTests: XCTestCase {
    func testAbsentAptosPolicyOnlyExcludedForExactScopedPublicRead() {
        let url = "https://api.mainnet.aptoslabs.com/v1/accounts/0x123/resource/0x1::multisig_account::MultisigAccount"
        let request = URLRequest(url: URL(string: url)!)
        let envelope: [String: Any] = ["error_code": "resource_not_found"]
        XCTAssertFalse(DiagnosticHTTP.expectedAccountAbsence(envelope, status: 404, request: request))
        DiagnosticHTTP.$publicAccountPolicyProbe.withValue(true) {
            XCTAssertTrue(DiagnosticHTTP.expectedAccountAbsence(envelope, status: 404, request: request))
            for status in [400, 429, 500] {
                XCTAssertFalse(DiagnosticHTTP.expectedAccountAbsence(envelope, status: status, request: request))
            }
            XCTAssertFalse(DiagnosticHTTP.expectedAccountAbsence([:], status: 404, request: request))
            for foreign in [url.replacingOccurrences(of: "api.mainnet.aptoslabs.com", with: "unrelated.example"),
                            url.replacingOccurrences(of: "multisig_account::MultisigAccount", with: "account::Account")] {
                XCTAssertFalse(DiagnosticHTTP.expectedAccountAbsence(envelope, status: 404, request: URLRequest(url: URL(string: foreign)!)))
            }
            var mutation = request; mutation.httpMethod = "POST"
            XCTAssertFalse(DiagnosticHTTP.expectedAccountAbsence(envelope, status: 404, request: mutation))
        }
    }

    func testXRPPolicyAbsenceRequiresMatchingValidatedAccount() throws {
        var request = URLRequest(url: URL(string: "https://xrplcluster.com")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: ["method": "account_info", "params": [["account": "fixture", "ledger_index": "validated", "signer_lists": true]]])
        let result: [String: Any] = ["account": "fixture", "validated": true, "error": "actNotFound", "error_code": 19]
        XCTAssertFalse(DiagnosticHTTP.expectedAccountAbsence(["result": result], status: 200, request: request))
        DiagnosticHTTP.$publicAccountPolicyProbe.withValue(true) {
            XCTAssertTrue(DiagnosticHTTP.expectedAccountAbsence(["result": result], status: 200, request: request))
            for (key, value) in [("account", "another" as Any), ("validated", false), ("error", "tooBusy")] {
                var changed = result; changed[key] = value
                XCTAssertFalse(DiagnosticHTTP.expectedAccountAbsence(["result": changed], status: 200, request: request))
            }
            XCTAssertFalse(DiagnosticHTTP.expectedAccountAbsence(["result": result], status: 429, request: request))
        }
    }
}
