import XCTest
@testable import OathDiagnostics

final class WalletConnectAttestationTests: XCTestCase {
    private let identifier = String(repeating: "a", count: 64)
    private func request(_ suffix: String? = nil) -> URLRequest {
        var r = URLRequest(url: URL(string: "https://verify.walletconnect.org" + (suffix ?? "/attestation/\(identifier)?v2Supported=true"))!)
        r.httpMethod = "GET"; return r
    }
    func testOnlyScopedWellFormedAttestationAbsenceIsExcluded() {
        let r = request()
        XCTAssertFalse(DiagnosticHTTP.expectedWalletConnectAttestationAbsence(Data(), status: 404, request: r))
        DiagnosticHTTP.$walletConnectAttestationLookup.withValue(true) {
            XCTAssertTrue(DiagnosticHTTP.expectedWalletConnectAttestationAbsence(Data(), status: 404, request: r))
            for status in [200, 400, 401, 403, 429, 500] {
                XCTAssertFalse(DiagnosticHTTP.expectedWalletConnectAttestationAbsence(Data(), status: status, request: r))
            }
            for path in ["/v2/public-key", "/attestation/invalid?v2Supported=true", "/attestation/\(identifier)",
                         "/attestation/\(identifier)?v2Supported=false", "/attestation/\(identifier)?v2Supported=true&extra=true",
                         "/attestation/\(identifier)/?v2Supported=true", "/attestation/%61\(identifier.dropFirst())?v2Supported=true"] {
                XCTAssertFalse(DiagnosticHTTP.expectedWalletConnectAttestationAbsence(Data(), status: 404, request: request(path)))
            }
            for url in ["http://verify.walletconnect.org", "https://verify.walletconnect.org.invalid", "https://verify.walletconnect.org:8443", "https://user:password@verify.walletconnect.org"] {
                var other = r; other.url = URL(string: url + "/attestation/\(identifier)?v2Supported=true")!
                XCTAssertFalse(DiagnosticHTTP.expectedWalletConnectAttestationAbsence(Data(), status: 404, request: other))
            }
            var post = r; post.httpMethod = "POST"
            XCTAssertFalse(DiagnosticHTTP.expectedWalletConnectAttestationAbsence(Data(), status: 404, request: post))
            var body = r; body.httpBody = Data("unexpected".utf8)
            XCTAssertFalse(DiagnosticHTTP.expectedWalletConnectAttestationAbsence(Data(), status: 404, request: body))
            XCTAssertFalse(DiagnosticHTTP.expectedWalletConnectAttestationAbsence(Data(repeating: 0, count: 4097), status: 404, request: r))
        }
        XCTAssertFalse(DiagnosticHTTP.walletConnectAttestationLookup)
    }
    func testAmbiguousStoredHTTP404RemainsReportable() {
        let event = DiagnosticEvent(error: NSError(domain: "Oath.HTTP", code: 404), component: "network", operation: "response",
            context: ["host": "verify.walletconnect.org", "http_status": "404"], sessionID: UUID())
        XCTAssertFalse(DiagnosticUploadPolicy.excludes(event))
    }
}
