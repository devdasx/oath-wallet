import XCTest
@testable import OathDiagnostics

final class IoTeXDiagnosticTests: XCTestCase {
    func testNativeAndEVMAccountsAreRemovedFromProviderMessages() {
        for account in ["io1d77dcytfk5fsck089eg7669gfpqunrx35ue5ln", "0x6fbcdc1169b5130c59e72e51ed68a84841c98cd1"] {
            let result = DiagnosticPrivacy.text("Account unavailable: " + account)
            XCTAssertFalse(result.contains(account))
            XCTAssertTrue(result.contains("[redacted]"))
        }
    }
    func testProviderContextContainsNoKeyOrAccountQuery() {
        for url in ["https://rpc.ankr.com/iotex/privateFixture", "https://babel-api.mainnet.iotex.io", "https://api.iotex.one/iotexapi.APIService/GetTransactionLogByBlockHeight", "https://dev.iotexscan.io/api?module=account&action=txlist&address=0x1111111111111111111111111111111111111111"] {
            let context = DiagnosticHTTP.context(URLRequest(url:URL(string:url)!))
            XCTAssertEqual(context["chain"],"iotex")
            XCTAssertFalse(context.values.contains{$0.contains("privateFixture") || $0.contains("11111111")})
            XCTAssertNil(context["url"])
        }
    }
}

extension IoTeXDiagnosticTests {
    func testSendFailureStagesRetainSafeDiagnostics() throws {
        for chain in ["iotex", "iotexTestnet"] {
            for stage in ["quote", "reserve", "authenticate", "persist", "broadcast", "status"] {
                let context = ["chain": chain, "stage": stage]
                XCTAssertFalse(DiagnosticAvailabilityPolicy.excludesBeforeAdmission(URLError(.timedOut), component: "evm_send", severity: "error", context: context, runtimeReport: nil))
                let report = DiagnosticEvent(error: URLError(.timedOut), component: "evm_send", operation: stage, context: context, sessionID: UUID())
                XCTAssertFalse(DiagnosticUploadPolicy.excludes(report))
                XCTAssertEqual(report.context["chain"], chain)
            }
        }
        let address = "0x" + String(repeating: "ab", count: 20)
        let transaction = "0x" + String(repeating: "cd", count: 256)
        let report = DiagnosticEvent(error: DiagnosticFailure("RPC failure \(address) \(transaction)"), component: "evm_send", operation: "broadcast", context: ["chain": "iotex", "stage": "broadcast"], sessionID: UUID())
        let text = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        XCTAssertFalse(text.contains(address)); XCTAssertFalse(text.contains(transaction))
    }
}
