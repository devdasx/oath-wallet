import Foundation
import Testing
@testable import Aperture

struct TronAdaptiveProviderTransportTests {
    @Test
    func JSONRPCServerFailureFallsBackToPublicProvider() async throws {
        let testID = UUID().uuidString.lowercased()
        let firstHost = "tron-first-\(testID).example"
        let secondHost = "tron-second-\(testID).example"
        let first = URL(string: "https://\(firstHost)/jsonrpc")!
        let second = URL(string: "https://\(secondHost)/jsonrpc")!
        let recorder = TronTransportAttemptRecorder()
        let transport = TronAPITransport(
            jsonRPCEndpoints: [first, second],
            timeoutSeconds: 0.2
        ) { request in
            let url = try #require(request.url)
            await recorder.record(url.host ?? "missing")
            if url == first {
                return (
                    Data(#"{"message":"temporarily unavailable"}"#.utf8),
                    Self.response(url: url, status: 503)
                )
            }
            return (
                Data(#"{"jsonrpc":"2.0","id":1,"result":"0x2a"}"#.utf8),
                Self.response(url: url, status: 200)
            )
        }

        let result = try await transport.rpc(
            method: "eth_getBalance",
            params: [
                .string("0x0000000000000000000000000000000000000000"),
                .string("latest")
            ]
        )

        #expect(result == "0x2a")
        #expect(await recorder.count(firstHost) == 1)
        #expect(await recorder.count(secondHost) == 1)
    }

    @Test
    func JSONRPCTimeoutFallsBackWithoutWaitingForSlowProvider() async throws {
        let testID = UUID().uuidString.lowercased()
        let firstHost = "tron-timeout-\(testID).example"
        let secondHost = "tron-fast-\(testID).example"
        let first = URL(string: "https://\(firstHost)/jsonrpc")!
        let second = URL(string: "https://\(secondHost)/jsonrpc")!
        let recorder = TronTransportAttemptRecorder()
        let transport = TronAPITransport(
            jsonRPCEndpoints: [first, second],
            timeoutSeconds: 0.02
        ) { request in
            let url = try #require(request.url)
            await recorder.record(url.host ?? "missing")
            if url == first {
                try await Task.sleep(for: .seconds(2))
            }
            return (
                Data(#"{"jsonrpc":"2.0","id":1,"result":"0x7"}"#.utf8),
                Self.response(url: url, status: 200)
            )
        }

        let result = try await transport.rpc(
            method: "eth_blockNumber",
            params: []
        )

        #expect(result == "0x7")
        #expect(await recorder.count(firstHost) == 1)
        #expect(await recorder.count(secondHost) == 1)
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

private actor TronTransportAttemptRecorder {
    private var values: [String: Int] = [:]

    func record(_ value: String) {
        values[value, default: 0] += 1
    }

    func count(_ value: String) -> Int {
        values[value, default: 0]
    }
}
