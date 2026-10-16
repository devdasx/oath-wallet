import XCTest
@testable import OathDiagnostics

final class ThorchainDiagnosticTests: XCTestCase {
    func testProviderContextAndErrorEchoesDoNotExposePublicAccounts() throws {
        let address="thor1gm00vwsfcp48enm4uv9e5dhm37jtd0ye27wrx0"
        for base in ["https://gateway.liquify.com/chain/thorchain_api/cosmos/bank/v1beta1/balances/", "https://api.rujira.network/api/graphql?query="] {
            let request=URLRequest(url:URL(string:base+address)!)
            let context=DiagnosticHTTP.context(request)
            XCTAssertEqual(context["chain"],"thorchain")
            XCTAssertFalse(context.values.contains(where:{$0.contains(address)}))
            let report=DiagnosticEvent(error:DiagnosticFailure("Account lookup failed: "+address),component:"sync",operation:"inventory",context:context,sessionID:UUID())
            let data=String(decoding:try JSONEncoder().encode(report),as:UTF8.self)
            XCTAssertFalse(data.contains(address)); XCTAssertFalse(data.contains("?query="))
        }
        XCTAssertNil(DiagnosticHTTP.context(URLRequest(url:URL(string:"https://example.org/chain/thorchain_api")!))["chain"])
    }
}
