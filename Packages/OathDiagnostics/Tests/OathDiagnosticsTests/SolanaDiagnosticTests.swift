import XCTest
@testable import OathDiagnostics
final class SolanaDiagnosticTests:XCTestCase {
    func testRPCContextDoesNotCopyPayloadSignatureOrKeys() throws {
        for endpoint in ["https://rpc.ankr.com/solana/private-fixture-key", "https://api.devnet.solana.com", "https://api.testnet.solana.com", "https://api.mainnet-beta.solana.com"] {
            var request=URLRequest(url:URL(string:endpoint)!);request.httpMethod="POST"
            request.httpBody=Data(#"{"method":"sendTransaction","params":["private signed transaction",{"address":"private owner"}]}"#.utf8)
            request.setValue("secret-token",forHTTPHeaderField:"Authorization")
            let context=DiagnosticHTTP.context(request)
            XCTAssertEqual(context["chain"],"solana");XCTAssertEqual(context["method"],"sendTransaction")
            let text=String(decoding:try JSONEncoder().encode(context),as:UTF8.self)
            for hidden in ["private-fixture-key","private signed transaction","private owner","secret-token","https://"] { XCTAssertFalse(text.contains(hidden)) }
        }
    }
}
