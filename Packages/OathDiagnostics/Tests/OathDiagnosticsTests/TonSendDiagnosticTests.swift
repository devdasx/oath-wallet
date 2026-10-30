import XCTest
@testable import OathDiagnostics
final class TonSendDiagnosticTests:XCTestCase {
    func testOnlyMissingTraceIsExcluded() {
        let hash=String(repeating:"a",count:64),body:[String:Any]=["error":"entity not found"]
        for host in ["tonapi.io","testnet.tonapi.io"] {
            var r=URLRequest(url:URL(string:"https://\(host)/v2/traces/\(hash)")!)
            XCTAssertEqual(DiagnosticHTTP.context(r)["chain"],"ton")
            XCTAssertTrue(DiagnosticHTTP.expectedAccountAbsence(body,status:404,request:r))
            for code in [200,400,401,429,500] { XCTAssertFalse(DiagnosticHTTP.expectedAccountAbsence(body,status:code,request:r)) }
            XCTAssertFalse(DiagnosticHTTP.expectedAccountAbsence(["error":"unauthorized"],status:404,request:r))
            r.httpMethod="POST";XCTAssertFalse(DiagnosticHTTP.expectedAccountAbsence(body,status:404,request:r))
        }
        for url in ["https://example.com/v2/traces/\(hash)","https://tonapi.io/v2/jettons/\(hash)","https://tonapi.io/v2/traces/malformed"] {
            XCTAssertFalse(DiagnosticHTTP.expectedAccountAbsence(body,status:404,request:URLRequest(url:URL(string:url)!)))
        }
    }
}
