import XCTest
@testable import OathDiagnostics
final class ArcDiagnosticTests:XCTestCase {
    func testRPCContextDoesNotCopyPayloadSignatureOrKeys() throws {
        for endpoint in ["https://rpc.ankr.com/arc/private-fixture-key", "https://rpc.blockdaemon.testnet.arc.io", "https://rpc.drpc.mainnet.arc.io", "https://rpc.mainnet.arc.io"] {
            var request=URLRequest(url:URL(string:endpoint)!);request.httpMethod="POST"
            request.httpBody=Data(#"{"method":"eth_sendRawTransaction","params":["private signed transaction",{"address":"private owner"}]}"#.utf8)
            request.setValue("secret-token",forHTTPHeaderField:"Authorization")
            let context=DiagnosticHTTP.context(request)
            XCTAssertEqual(context["chain"],"arc");XCTAssertEqual(context["method"],"eth_sendRawTransaction")
            let text=String(decoding:try JSONEncoder().encode(context),as:UTF8.self)
            for hidden in ["private-fixture-key","private signed transaction","private owner","secret-token","https://"] { XCTAssertFalse(text.contains(hidden)) }
        }
    }
}
