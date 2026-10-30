import XCTest
@testable import OathDiagnostics

final class ZeroGDiagnosticTests: XCTestCase {
    func testProviderContextExcludesCredentialsAndAccountQuery() throws {
        for url in ["https://rpc.ankr.com/0g_mainnet_evm/privateFixture", "https://evmrpc.0g.ai", "https://evmrpc-testnet.0g.ai",
                    "https://chainscan.0g.ai/v1/token?accountAddress=0x1111111111111111111111111111111111111111"] {
            let context = DiagnosticHTTP.context(URLRequest(url:URL(string:url)!))
            XCTAssertEqual(context["chain"],"zerog")
            XCTAssertFalse(context.values.contains{$0.contains("privateFixture") || $0.contains("11111111")})
            XCTAssertNil(context["url"])
        }
    }
}

extension ZeroGDiagnosticTests {
    func testSendFailureStagesRetainSafeDiagnostics() throws {
        for chain in ["zerog", "zerogGalileo"] {
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
        let report = DiagnosticEvent(error: DiagnosticFailure("RPC failure \(address) \(transaction)"), component: "evm_send", operation: "broadcast", context: ["chain": "zerog", "stage": "broadcast"], sessionID: UUID())
        let text = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        XCTAssertFalse(text.contains(address)); XCTAssertFalse(text.contains(transaction))
    }
}
