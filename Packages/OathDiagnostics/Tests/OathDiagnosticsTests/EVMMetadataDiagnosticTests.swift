import XCTest
@testable import OathDiagnostics

final class EVMMetadataDiagnosticTests: XCTestCase {
    func testArcOptionalLabelsExcludeOnlyExactRevertsAtPinnedOrLatestBlock() throws {
        var request = URLRequest(url: URL(string: "https://fixture.invalid/private-key")!)
        request.httpMethod = "POST"
        let target = "0x" + String(repeating: "2", count: 40)
        var row: [String: Any] = ["jsonrpc": "2.0", "id": 7, "error": ["code": 3, "message": "execution reverted"]]
        func matches(_ data: String, tag: String = "0x64", extra: Bool = false, duplicate: Bool = false) throws -> Bool {
            var tx = ["to": target, "data": data]
            if extra { tx["value"] = "0x0" }
            let call: [String: Any] = ["jsonrpc": "2.0", "id": 7, "method": "eth_call", "params": [tx, tag]]
            request.httpBody = try JSONSerialization.data(withJSONObject: duplicate ? [call, call] : [call])
            return DiagnosticHTTP.expectedEVMMetadataAbsence(row, status: 200, request: request, labelsOnly: true)
        }
        for tag in ["latest", "0x64"] {
            for selector in ["0x06fdde03", "0x95d89b41"] { XCTAssertTrue(try matches(selector, tag: tag)) }
        }
        for selector in ["0x313ce567", "0x18160ddd", "0x70a08231" + String(repeating: "0", count: 64), "0x06fdde0300"] {
            XCTAssertFalse(try matches(selector), "Decimals, balances and arbitrary calls remain failures")
        }
        for tag in ["pending", "0x", "0xsecret", "0x" + String(repeating: "f", count: 17)] {
            XCTAssertFalse(try matches("0x06fdde03", tag: tag))
        }
        XCTAssertFalse(try matches("0x06fdde03", extra: true))
        XCTAssertFalse(try matches("0x06fdde03", duplicate: true))
        row["id"] = 8; XCTAssertFalse(try matches("0x06fdde03")); row["id"] = 7
        row["error"] = ["code": 3, "message": "upstream error: revert"]
        XCTAssertFalse(try matches("0x06fdde03"))
        XCTAssertFalse(DiagnosticHTTP.optionalEVMTokenLabels)
    }

    func testBatchFailureAttributionUsesReplyIDAndOnlyPublicConstantLabels() throws {
        var request = URLRequest(url: URL(string: "https://fixture.invalid/private-key")!)
        request.httpMethod = "POST"
        let secret = "0x" + String(repeating: "b", count: 40)
        let calls: [[String: Any]] = ["0x06fdde03", "0x95d89b41", "0x313ce567", "private-calldata"].enumerated().map {
            ["jsonrpc": "2.0", "id": $0.offset, "method": "eth_call", "params": [["to": secret, "data": $0.element], "latest"]]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: calls)
        for (id, stage) in ["token_name", "token_symbol", "token_decimals", "contract_read"].enumerated().reversed() {
            let context = DiagnosticHTTP.rpcFailureContext(["jsonrpc": "2.0", "id": id], request: request)
            XCTAssertEqual(context, ["method": "eth_call", "stage": stage])
            XCTAssertEqual(DiagnosticPrivacy.context(context), context)
        }
        for id in [99, "1", true] as [Any] {
            XCTAssertTrue(DiagnosticHTTP.rpcFailureContext(["jsonrpc": "2.0", "id": id], request: request).isEmpty)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: [calls[0], calls[0]])
        XCTAssertTrue(DiagnosticHTTP.rpcFailureContext(["jsonrpc": "2.0", "id": 0], request: request).isEmpty)
    }
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
