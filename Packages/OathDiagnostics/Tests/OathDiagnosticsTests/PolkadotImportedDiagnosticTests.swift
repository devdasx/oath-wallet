import XCTest
@testable import OathDiagnostics

final class PolkadotImportedDiagnosticTests: XCTestCase {
    func testAcknowledgementRequiresExactScopedHashAndCorrelatedEnvelope() throws {
        let hash = "0x" + String(repeating: "ab", count: 32)
        var request = URLRequest(url: URL(string: "https://polkadot.example/rpc")!)
        request.httpMethod = "POST"
        let body: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "author_submitExtrinsic", "params": ["0x0102"]]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let error: [String: Any] = ["code": 1013, "message": "Transaction Already Imported", "data": hash]
        let reply: [String: Any] = ["jsonrpc": "2.0", "id": 1, "error": error]
        let data = try JSONSerialization.data(withJSONObject: reply)
        XCTAssertFalse(DiagnosticHTTP.expectedPolkadotAlreadyImported(data, status: 200, request: request))
        try DiagnosticHTTP.$submittedPolkadotHash.withValue(hash) {
            XCTAssertTrue(DiagnosticHTTP.expectedPolkadotAlreadyImported(data, status: 200, request: request))
            for (key, value) in [("code", 1014 as Any), ("code", 1013.5), ("message", "Different failure"), ("data", "0x" + String(repeating: "cd", count: 32)), ("data", NSNull())] {
                var changed = error; changed[key] = value
                var envelope = reply; envelope["error"] = changed
                XCTAssertFalse(DiagnosticHTTP.expectedPolkadotAlreadyImported(try JSONSerialization.data(withJSONObject: envelope), status: 200, request: request))
            }
            for (key, value) in [("id", 2 as Any), ("id", true), ("id", "1"), ("jsonrpc", "1.0"), ("result", hash)] {
                var changed = reply; changed[key] = value
                XCTAssertFalse(DiagnosticHTTP.expectedPolkadotAlreadyImported(try JSONSerialization.data(withJSONObject: changed), status: 200, request: request))
            }
            for method in ["chain_getHeader", "eth_sendRawTransaction", "author_submitAndWatchExtrinsic"] {
                var changed = body; changed["method"] = method
                var other = request; other.httpBody = try JSONSerialization.data(withJSONObject: changed)
                XCTAssertFalse(DiagnosticHTTP.expectedPolkadotAlreadyImported(data, status: 200, request: other))
            }
            XCTAssertFalse(DiagnosticHTTP.expectedPolkadotAlreadyImported(data, status: 403, request: request))
            XCTAssertFalse(DiagnosticHTTP.expectedPolkadotAlreadyImported(data, status: 503, request: request))
        }
        XCTAssertNil(DiagnosticHTTP.submittedPolkadotHash)
    }
}
