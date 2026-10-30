import XCTest
@testable import OathDiagnostics

final class EVMDuplicateDiagnosticTests: XCTestCase {
    private let raw = "0x02" + String(repeating: "12", count: 100)
    private func calls() -> [[String: Any]] {
        [["jsonrpc": "2.0", "id": 0, "method": "eth_chainId", "params": []],
         ["jsonrpc": "2.0", "id": 1, "method": "eth_sendRawTransaction", "params": [raw]]]
    }
    private func replies() -> [[String: Any]] {
        [["jsonrpc": "2.0", "id": 0, "result": "0x2105"],
         ["jsonrpc": "2.0", "id": 1, "error": ["code": -32000, "message": "already known"]]]
    }
    private func check(_ replies: [[String: Any]], calls: [[String: Any]]? = nil, status: Int = 200, method: String = "POST") throws -> Bool {
        var request = URLRequest(url: URL(string: "https://rpc.example")!)
        request.httpMethod = method
        request.httpBody = try JSONSerialization.data(withJSONObject: calls ?? self.calls())
        return DiagnosticHTTP.expectedEVMDuplicateBroadcast(try JSONSerialization.data(withJSONObject: replies), status: status, request: request)
    }
    func testOnlyVerifiedAttemptScopeAllowsExactDuplicateControlFlow() throws {
        XCTAssertFalse(try check(replies()))
        let attempt = DiagnosticEVMBroadcastAttempt(transaction: raw, chainID: 8453)
        try DiagnosticHTTP.$submittedEVMBroadcast.withValue(attempt) {
            XCTAssertTrue(try check(replies()))
            var imported = replies(); imported[1]["error"] = ["code": -32003, "message": "transaction already imported"]
            XCTAssertTrue(try check(imported))
            XCTAssertTrue(try check(replies().reversed(), calls: calls().reversed()))
            for status in [201, 400, 429, 500] { XCTAssertFalse(try check(replies(), status: status)) }
            XCTAssertFalse(try check(replies(), method: "GET"))
        }
        XCTAssertNil(DiagnosticHTTP.submittedEVMBroadcast)
        XCTAssertFalse(String(describing: attempt).contains(raw))
        XCTAssertFalse(String(reflecting: attempt).contains(raw))
    }
    func testWrongChainRequestResponseOrEnvelopeIsNotSilenced() throws {
        try DiagnosticHTTP.$submittedEVMBroadcast.withValue(.init(transaction: raw, chainID: 8453)) {
            for (index, field, value) in [(0, "result", "0x1" as Any), (0, "id", 1), (1, "id", 0),
                                           (0, "id", false), (1, "id", true), (1, "jsonrpc", "1.0"),
                                           (0, "error", ["code": -32000, "message": "already known"]), (1, "result", NSNull())] {
                var rows = replies(); rows[index][field] = value
                XCTAssertFalse(try check(rows), "response \(index).\(field)")
            }
            for (index, field, value) in [(1, "method", "eth_call" as Any), (1, "params", ["0xdeadbeef"]),
                                           (0, "params", ["unexpected"]), (0, "method", "eth_blockNumber"),
                                           (1, "id", true), (0, "id", false), (1, "jsonrpc", "1.0")] {
                var rows = calls(); rows[index][field] = value
                XCTAssertFalse(try check(replies(), calls: rows), "request \(index).\(field)")
            }
            for error: [String: Any] in [["code": -32000, "message": "already known unexpected"],
                                        ["code": -32001, "message": "already known"],
                                        ["code": -32003, "message": "already known"],
                                        ["code": -32000, "message": "transaction already imported"],
                                        ["code": -32000, "message": "execution reverted"],
                                        ["code": true, "message": "already known"]] {
                var rows = replies(); rows[1]["error"] = error; XCTAssertFalse(try check(rows))
            }
            XCTAssertFalse(try check([replies()[1]]))
            XCTAssertFalse(try check(replies() + [replies()[1]]))
        }
    }
    func testHistoricalAndUnresolvedDuplicatesRemainReportable() {
        for domain in ["Oath.Provider", "OathDiagnostics.DiagnosticFailure"] {
            let event = DiagnosticEvent(error: NSError(domain: domain, code: -32000,
                userInfo: [NSLocalizedDescriptionKey: "already known"]), component: "evm_send", operation: "broadcast",
                context: ["chain": "base", "stage": "broadcast"], sessionID: UUID())
            XCTAssertFalse(DiagnosticUploadPolicy.excludes(event))
        }
    }
}
