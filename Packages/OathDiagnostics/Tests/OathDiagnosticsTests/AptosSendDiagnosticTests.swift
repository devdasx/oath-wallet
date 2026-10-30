import XCTest
@testable import OathDiagnostics

final class AptosSendDiagnosticTests:XCTestCase {
    func testOnlyExactPendingLookupAbsenceIsExcluded() {
        let hash="0x"+String(repeating:"a",count:64)
        var r=URLRequest(url:URL(string:"https://api.testnet.aptoslabs.com/v1/transactions/by_hash/"+hash)!)
        let envelope:[String:Any]=["error_code":"transaction_not_found","message":"pending lookup"]
        XCTAssertEqual(DiagnosticHTTP.context(r)["chain"],"aptos")
        XCTAssertTrue(DiagnosticHTTP.expectedAccountAbsence(envelope,status:404,request:r))
        let archive=URLRequest(url:URL(string:"https://archive.mainnet.aptoslabs.com/v1/transactions/by_hash/"+hash)!)
        XCTAssertEqual(DiagnosticHTTP.context(archive)["chain"],"aptos")
        XCTAssertTrue(DiagnosticHTTP.expectedAccountAbsence(envelope,status:404,request:archive))
        for code in [400,429,500] { XCTAssertFalse(DiagnosticHTTP.expectedAccountAbsence(envelope,status:code,request:r)) }
        XCTAssertFalse(DiagnosticHTTP.expectedAccountAbsence(["error_code":"account_not_found"],status:404,request:r))
        r.httpMethod="POST";XCTAssertFalse(DiagnosticHTTP.expectedAccountAbsence(envelope,status:404,request:r))
        r.httpMethod="GET";r.url=URL(string:"https://api.testnet.aptoslabs.com/v1/accounts/"+hash)
        XCTAssertFalse(DiagnosticHTTP.expectedAccountAbsence(envelope,status:404,request:r))
        r.url=URL(string:"https://unrelated.example/v1/transactions/by_hash/"+hash)
        XCTAssertFalse(DiagnosticHTTP.expectedAccountAbsence(envelope,status:404,request:r))
    }
    func testContextContainsNoCredentialTransactionOrWalletFields() {
        var r=URLRequest(url:URL(string:"https://rpc.ankr.com/premium-http/aptos/private-key-value/v1/transactions")!)
        r.httpMethod="POST";r.httpBody=Data(repeating:127,count:300)
        r.setValue("Bearer secret",forHTTPHeaderField:"Authorization")
        let c=DiagnosticHTTP.context(r)
        XCTAssertEqual(c["chain"],"aptos");XCTAssertEqual(c["host"],"rpc.ankr.com")
        XCTAssertEqual(Set(c.keys),["chain","host"])
    }
}
