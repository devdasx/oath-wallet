import XCTest
@testable import OathDiagnostics

final class AccountAbsenceTests: XCTestCase, @unchecked Sendable {
    private func request(_ url: String, _ body: [String: Any]? = nil) throws -> URLRequest {
        var value = URLRequest(url: URL(string: url)!)
        if let body { value.httpMethod = "POST"; value.httpBody = try JSONSerialization.data(withJSONObject: body) }
        return value
    }
    func testXrplRequiresExactAccountValidatedLedgerAndCorrectMethod() throws {
        let hash = String(repeating: "A", count: 64)
        let call = try request("https://rpc.ankr.com/xrp_mainnet/fixture", ["method": "account_info", "params": [["account": "fixture-account", "ledger_hash": hash]]])
        let result: [String: Any] = ["error": "actNotFound", "error_code": 19, "account": "fixture-account", "ledger_hash": hash, "validated": true]
        XCTAssertEqual(DiagnosticHTTP.context(call)["chain"], "xrpl")
        XCTAssertTrue(DiagnosticHTTP.expectedAccountAbsence(["result": result], status: 200, request: call))
        for (key, value) in [("account", "different" as Any), ("validated", false), ("ledger_hash", String(repeating: "B", count: 64)), ("error", "lgrNotFound")] {
            var invalid = result; invalid[key] = value
            XCTAssertFalse(DiagnosticHTTP.expectedAccountAbsence(["result": invalid], status: 200, request: call))
        }
        let unrelated = try request("https://rpc.ankr.com/xrp_mainnet/fixture", ["method": "account_tx", "params": [["account": "fixture-account", "ledger_hash": hash]]])
        XCTAssertFalse(DiagnosticHTTP.expectedAccountAbsence(["result": result], status: 200, request: unrelated))
    }
    func testXrplFallbackRecognizesAbsenceButStillReportsBusyAndWrongLedger() throws {
        let hash = String(repeating: "A", count: 64)
        let call = try request("https://xrplcluster.com", ["method": "account_info", "params": [["account": "fixture", "ledger_hash": hash]]])
        var result: [String: Any] = ["error": "actNotFound", "error_code": 19, "account": "fixture", "ledger_hash": hash, "validated": true]
        XCTAssertEqual(DiagnosticHTTP.context(call)["chain"], "xrpl")
        XCTAssertTrue(DiagnosticHTTP.expectedAccountAbsence(["result": result], status: 200, request: call))
        result["ledger_hash"] = String(repeating: "B", count: 64)
        XCTAssertFalse(DiagnosticHTTP.expectedAccountAbsence(["result": result], status: 200, request: call))
        result["error"] = "tooBusy"; result["error_code"] = 9
        XCTAssertFalse(DiagnosticHTTP.expectedAccountAbsence(["result": result], status: 200, request: call))
        let foreign = try request("https://fixture.example", ["method": "account_info", "params": [["account": "fixture", "ledger_hash": hash]]])
        XCTAssertNil(DiagnosticHTTP.context(foreign)["chain"])
    }
    func testNearMissingAccountCannotHideContractFailureOrOtherAccount() throws {
        let call = try request("https://rpc.ankr.com/near/fixture", ["method": "query", "params": ["request_type": "view_account", "account_id": "fixture.near"]])
        let legacy: [String: Any] = ["error": ["code": -32000, "message": "Server error", "data": "account fixture.near does not exist while viewing"]]
        let typed: [String: Any] = ["error": ["code": -32000, "cause": ["name": "UNKNOWN_ACCOUNT", "info": ["requested_account_id": "fixture.near"]]]]
        XCTAssertTrue(DiagnosticHTTP.expectedAccountAbsence(legacy, status: 200, request: call))
        XCTAssertTrue(DiagnosticHTTP.expectedAccountAbsence(typed, status: 200, request: call))
        for error: [String: Any] in [
            ["code": -32000, "message": "Server error"],
            ["code": -32000, "data": "account other.near does not exist while viewing"],
            ["code": -32000, "cause": ["name": "CONTRACT_EXECUTION_ERROR"]]
        ] { XCTAssertFalse(DiagnosticHTTP.expectedAccountAbsence(["error": error], status: 200, request: call)) }
        let contract = try request("https://rpc.ankr.com/near/fixture", ["method": "query", "params": ["request_type": "call_function", "account_id": "fixture.near"]])
        XCTAssertFalse(DiagnosticHTTP.expectedAccountAbsence(typed, status: 200, request: contract))
    }
    func testStellarOnlySuppressesHorizonAccountNotFound() throws {
        let owner = "G" + String(repeating: "A", count: 55)
        let body: [String: Any] = ["type": "https://stellar.org/horizon-errors/not_found", "status": 404]
        for base in ["https://horizon.stellar.org", "https://rpc.ankr.com/http/stellar_horizon"] {
            XCTAssertTrue(DiagnosticHTTP.expectedAccountAbsence(body, status: 404, request: try request(base + "/accounts/" + owner)))
            XCTAssertFalse(DiagnosticHTTP.expectedAccountAbsence(body, status: 500, request: try request(base + "/accounts/" + owner)))
            XCTAssertFalse(DiagnosticHTTP.expectedAccountAbsence(body, status: 404, request: try request(base + "/accounts/" + owner + "/transactions")))
            XCTAssertFalse(DiagnosticHTTP.expectedAccountAbsence(["message": "proxy unavailable"], status: 404, request: try request(base + "/accounts/" + owner)))
        }
    }
    func testStellarPendingTransactionAbsenceIsExpectedButProxyFailuresAreNot() throws {
        let hash=String(repeating:"a",count:64), body:[String:Any]=["type":"https://stellar.org/horizon-errors/not_found","status":404]
        for base in ["https://horizon.stellar.org","https://horizon-testnet.stellar.org","https://rpc.ankr.com/http/stellar_horizon"] {
            XCTAssertTrue(DiagnosticHTTP.expectedAccountAbsence(body,status:404,request:try request(base+"/transactions/"+hash)))
            for path in ["/transactions/not-a-hash","/transactions/"+hash+"/effects","/accounts/"+hash] {
                XCTAssertFalse(DiagnosticHTTP.expectedAccountAbsence(body,status:404,request:try request(base+path)))
            }
            XCTAssertFalse(DiagnosticHTTP.expectedAccountAbsence(["status":404,"detail":"proxy failed"],status:404,request:try request(base+"/transactions/"+hash)))
            XCTAssertFalse(DiagnosticHTTP.expectedAccountAbsence(body,status:500,request:try request(base+"/transactions/"+hash)))
        }
        XCTAssertFalse(DiagnosticHTTP.expectedAccountAbsence(body,status:404,request:try request("https://unrelated.example/transactions/"+hash)))
    }
    func testLiveRecordedUnfundedAccountEnvelopes() throws {
        guard let path = ProcessInfo.processInfo.environment["OATH_ACCOUNT_ABSENCE_FIXTURES"] else { throw XCTSkip("Opt-in freshly fetched public synthetic account responses") }
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [[String: Any]])
        XCTAssertEqual(rows.count, 3)
        for row in rows {
            let call = try request(XCTUnwrap(row["url"] as? String), row["body"] as? [String: Any])
            XCTAssertTrue(DiagnosticHTTP.expectedAccountAbsence(try XCTUnwrap(row["response"] as? [String: Any]),
                status: try XCTUnwrap(row["status"] as? Int), request: call), row["chain"] as? String ?? "unknown")
        }
    }
}
