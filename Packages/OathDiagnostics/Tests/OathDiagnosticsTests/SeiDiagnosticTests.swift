import XCTest
@testable import OathDiagnostics

final class SeiDiagnosticTests: XCTestCase {
    func testProviderContextKeepsChainWithoutCredentialsOrAddresses() {
        for url in ["https://rpc.ankr.com/sei_evm/privateFixture", "https://evm-rpc.sei-apis.com", "https://evm-rpc-testnet.sei-apis.com",
                    "https://sei-mainnet.g.alchemy.com/v2/privateFixture",
                    "https://api-v2.seistream.app/api/v2/evm/accounts/0x1111111111111111111111111111111111111111/tokens"] {
            let context = DiagnosticHTTP.context(URLRequest(url:URL(string:url)!))
            XCTAssertEqual(context["chain"],"sei")
            XCTAssertFalse(context.values.contains { $0.contains("privateFixture") || $0.contains("11111111") })
            XCTAssertNil(context["url"])
        }
    }
}

extension SeiDiagnosticTests {
    func testSendFailureStagesRetainSafeDiagnostics() throws {
        for chain in ["sei", "seiTestnet"] {
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
        let report = DiagnosticEvent(error: DiagnosticFailure("RPC failure \(address) \(transaction)"), component: "evm_send", operation: "broadcast", context: ["chain": "sei", "stage": "broadcast"], sessionID: UUID())
        let text = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        XCTAssertFalse(text.contains(address)); XCTAssertFalse(text.contains(transaction))
    }
}
