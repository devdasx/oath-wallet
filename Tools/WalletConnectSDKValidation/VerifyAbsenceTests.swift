import XCTest
@testable import Schemas
@testable import HTTPClient
import OathDiagnostics

private actor VerifyCapture: DiagnosticTransport {
    var events: [DiagnosticEvent] = []
    func upload(_ events: [DiagnosticEvent]) async throws { self.events += events }
}
private final class Verify404Fixture: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@MainActor final class VerifyAbsenceTests: XCTestCase {
    func testMissingAttestationKeepsUnknownWithoutAnAppFailure() async throws {
        guard ProcessInfo.processInfo.environment["OATH_VERIFY_ABSENCE_TEST"] == "1" else {
            throw XCTSkip("Fresh process for production diagnostics reporter")
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        let sink = VerifyCapture()
        OathDiagnostics.configure(file: file, transport: sink)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [Verify404Fixture.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let http = HTTPNetworkClient(host: "verify.walletconnect.org", session: session)
        let verifier = OriginVerifier(httpClient: http), factory = VerifyContextFactory()
        let missingID = UUID(), invalidID = UUID()
        do {
            _ = try await OathDiagnostics.$operationID.withValue(missingID) {
                try await verifier.verifyOrigin(assertionId: String(repeating: "a", count: 64))
            }
            XCTFail("Missing attestation must not verify a site")
        } catch HTTPError.badStatusCode(let status) { XCTAssertEqual(status, 404) }
        XCTAssertEqual(factory.createVerifyContext(origin: nil, domain: "https://fixture.invalid", isScam: nil, isVerified: nil).validation, .unknown)
        XCTAssertEqual(factory.createVerifyContext(origin: "https://other.invalid", domain: "https://fixture.invalid", isScam: nil, isVerified: true).validation, .invalid)
        XCTAssertEqual(factory.createVerifyContext(origin: "https://fixture.invalid", domain: "https://fixture.invalid", isScam: true, isVerified: true).validation, .scam)
        // A malformed lookup remains an app failure, even in the same scope.
        do {
            _ = try await OathDiagnostics.$operationID.withValue(invalidID) { try await verifier.verifyOrigin(assertionId: "invalid") }
            XCTFail()
        } catch HTTPError.badStatusCode(let status) { XCTAssertEqual(status, 404) }
        for _ in 0..<100 {
            await OathDiagnostics.flush()
            if await sink.events.contains(where: { $0.operationID == invalidID }) { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let events = await sink.events
        XCTAssertFalse(events.contains(where: { $0.operationID == missingID }), "An absent attestation remains unknown; it is not an app defect")
        XCTAssertTrue(events.contains(where: { $0.operationID == invalidID && $0.error.code == 404 }))
        let encoded = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        XCTAssertFalse(encoded.contains(String(repeating: "a", count: 64)))
        XCTAssertFalse(encoded.contains("/attestation/"))
    }
}
