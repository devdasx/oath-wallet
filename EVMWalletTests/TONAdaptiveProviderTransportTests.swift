import Foundation
import Testing
@testable import Aperture

struct TONAdaptiveProviderTransportTests {
    @Test
    func proxyFailureFallsBackToDirectTONAPI() async throws {
        let testID = UUID().uuidString.lowercased()
        let proxyHost = "ton-proxy-\(testID).example"
        let directHost = "ton-direct-\(testID).example"
        let proxy = URL(string: "https://\(proxyHost)")!
        let direct = URL(string: "https://\(directHost)/v2")!
        let attempts = TONTransportAttemptRecorder()
        let transport = try TONAPITransport(
            baseURL: proxy,
            directReadBaseURL: direct
        ) { request in
            let url = try #require(request.url)
            await attempts.record(url)
            if url.host == proxyHost {
                return (
                    Data(#"{"error":{"code":"temporarily_unavailable"}}"#.utf8),
                    Self.response(url: url, status: 503)
                )
            }
            return (
                Data(#"{"seqno":42}"#.utf8),
                Self.response(url: url, status: 200)
            )
        }

        let result: TONAPISeqno = try await transport.request(
            path: "seqno",
            body: ["address": .string("UQTestAddress")]
        )

        #expect(result.seqno == 42)
        #expect(await attempts.count(host: proxyHost) == 1)
        #expect(await attempts.count(host: directHost) == 1)
        let directURL = try #require(
            await attempts.first(host: directHost)
        )
        #expect(directURL.path == "/v2/wallet/UQTestAddress/seqno")
    }

    @Test
    func deterministicProviderRejectionDoesNotFailOver() async throws {
        let testID = UUID().uuidString.lowercased()
        let proxyHost = "ton-rejection-\(testID).example"
        let directHost = "ton-unused-\(testID).example"
        let proxy = URL(string: "https://\(proxyHost)")!
        let direct = URL(string: "https://\(directHost)/v2")!
        let attempts = TONTransportAttemptRecorder()
        let transport = try TONAPITransport(
            baseURL: proxy,
            directReadBaseURL: direct
        ) { request in
            let url = try #require(request.url)
            await attempts.record(url)
            if url.host == proxyHost {
                return (
                    Data(#"{"error":{"code":"invalid_address"}}"#.utf8),
                    Self.response(url: url, status: 400)
                )
            }
            return (
                Data(#"{"seqno":99}"#.utf8),
                Self.response(url: url, status: 200)
            )
        }

        do {
            let _: TONAPISeqno = try await transport.request(
                path: "seqno",
                body: ["address": .string("invalid")]
            )
            Issue.record("Expected the definitive provider rejection.")
        } catch let error as TONProviderError {
            guard case let .server(status, code) = error else {
                Issue.record("Expected a structured TON server error.")
                return
            }
            #expect(status == 400)
            #expect(code == "invalid_address")
        }

        #expect(await attempts.count(host: proxyHost) == 1)
        #expect(await attempts.count(host: directHost) == 0)
    }

    private static func response(
        url: URL,
        status: Int
    ) -> HTTPURLResponse {
        HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
    }
}

private actor TONTransportAttemptRecorder {
    private var URLs: [URL] = []

    func record(_ url: URL) {
        URLs.append(url)
    }

    func count(host: String) -> Int {
        URLs.count { $0.host == host }
    }

    func first(host: String) -> URL? {
        URLs.first { $0.host == host }
    }
}
