import XCTest
@testable import OathDiagnostics

final class EVMMetadataDiagnosticTests: XCTestCase {
    func testStringRequestIDsAndTotalSupplyProbeAreMatchedExactly() throws {
        var request = URLRequest(url: URL(string: "https://fixture.invalid")!)
        request.httpMethod = "POST"
        let id = UUID().uuidString, target = "0x" + String(repeating: "2", count: 40)
        var call: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": "eth_call",
            "params": [["to": target, "data": "0x18160ddd"], "latest"]]
        var row: [String: Any] = ["jsonrpc": "2.0", "id": id, "error": ["code": 3, "message": "execution reverted"]]
        func matches() throws -> Bool {
            request.httpBody = try JSONSerialization.data(withJSONObject: call)
            return DiagnosticHTTP.expectedEVMMetadataAbsence(row, status: 200, request: request)
        }
        XCTAssertTrue(try matches())
        row["id"] = UUID().uuidString; XCTAssertFalse(try matches())
        row["id"] = 1; call["id"] = "1"; XCTAssertFalse(try matches())
        row["id"] = true; call["id"] = true; XCTAssertFalse(try matches())
        row["id"] = id; call["id"] = id
        row["result"] = "0x"; XCTAssertFalse(try matches()); row.removeValue(forKey: "result")
        call["method"] = "eth_estimateGas"; XCTAssertFalse(try matches()); call["method"] = "eth_call"
        call["params"] = [["to": target, "data": "0x18160ddd00"], "latest"]
        XCTAssertFalse(try matches())
    }

    func testRegistryDiagnosticContextDoesNotContainContractOrQuery() {
        let contract = "0x" + String(repeating: "a", count: 40)
        let request = URLRequest(url: URL(string: "https://sourcify.dev/server/v2/contract/1/\(contract)?fields=compilation.name")!)
        let context = String(describing: DiagnosticHTTP.context(request))
        XCTAssertFalse(context.contains(contract))
        XCTAssertFalse(context.contains("compilation.name"))
        XCTAssertFalse(context.contains("/v2/contract"))
    }
    func testOptionalProbeExclusionRequiresExactReadEnvelopeAndSelector() throws {
        var request = URLRequest(url: URL(string: "https://test.example")!)
        request.httpMethod = "POST"
        let target = "0x" + String(repeating: "2", count: 40)
        var call: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "eth_call",
            "params": [["to": target, "data": "0x313ce567"], "latest"]]
        var row: [String: Any] = ["jsonrpc": "2.0", "id": 1, "error": ["code": 3, "message": "execution reverted"]]
        func matches(_ status: Int = 200) throws -> Bool {
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                ["jsonrpc": "2.0", "id": 0, "method": "eth_chainId", "params": []], call])
            return DiagnosticHTTP.expectedEVMMetadataAbsence(row, status: status, request: request)
        }
        XCTAssertFalse(DiagnosticHTTP.optionalEVMMetadataProbe)
        XCTAssertTrue(try matches())
        for data in ["0x06fdde03", "0x95d89b41"] {
            call["params"] = [["to": target, "data": data], "latest"]
            XCTAssertTrue(try matches(), "Absent optional name/symbol is not a provider failure")
            call["params"] = [["to": target, "data": data + "00"], "latest"]
            XCTAssertFalse(try matches(), "The exclusion must not cover arbitrary calldata")
        }
        call["params"] = [["to": target, "data": "0x313ce567"], "latest"]
        for status in [400, 429, 500] { XCTAssertFalse(try matches(status)) }
        row["id"] = 0; XCTAssertFalse(try matches())
        row["id"] = 1; row["error"] = ["code": -32005, "message": "execution reverted"]
        XCTAssertFalse(try matches())
        row["error"] = ["code": 3, "message": "upstream unavailable"]
        XCTAssertFalse(try matches())
        row["error"] = ["code": 3, "message": "execution reverted"]
        call["method"] = "eth_estimateGas"; XCTAssertFalse(try matches())
        call["method"] = "eth_call"
        for data in ["0x095ea7b3" + String(repeating: "0", count: 128), "0x313ce56700", "0x70a08231", "0xdd62ed3e"] {
            call["params"] = [["to": target, "data": data], "latest"]
            XCTAssertFalse(try matches())
        }
        call["params"] = [["to": target, "data": "0x01ffc9a780ac58cd" + String(repeating: "0", count: 56)], "latest"]
        XCTAssertTrue(try matches())
        call["params"] = [["to": target, "data": "0x313ce567", "value": "0x0"], "latest"]
        XCTAssertFalse(try matches())
        XCTAssertFalse(String(describing: DiagnosticHTTP.context(request)).contains(target))
    }
}
