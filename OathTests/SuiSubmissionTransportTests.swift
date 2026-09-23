import Foundation
import Testing
@testable import Aperture

struct SuiSubmissionTransportTests {
    private static let digest = "6VyfefzvKoKBhHUY4eEnuVmaUkySep7YLushiY2vqU7h"
    private static let urls = [URL(string: "https://first.example")!, URL(string: "https://second.example")!]

    @Test(arguments: [401, 403, 404, 405, 429])
    func explicitGatewayDenialUsesIdenticalPayloadOnNextProvider(status: Int) async throws {
        let probe = SuiGRPCProbe(firstStatus: status)
        let client = SuiTransactionExecutor(endpoints: Self.urls, router: AdaptiveProviderRouter(persistsHealth: false)) {
            try await probe.respond($0)
        }
        #expect(try await client.execute(transaction: "AA==", signature: "AA==") == Self.digest)
        let bodies = await probe.submissions
        #expect(bodies.count == 2)
        #expect(bodies.first == bodies.last)
    }

    @Test(arguments: [500, 502, 503, 504, 408])
    func ambiguousHTTPFailureNeverResubmits(status: Int) async {
        let probe = SuiGRPCProbe(firstStatus: status)
        let client = SuiTransactionExecutor(endpoints: Self.urls, router: AdaptiveProviderRouter(persistsHealth: false)) {
            try await probe.respond($0)
        }
        await #expect(throws: SuiProviderError.self) {
            try await client.execute(transaction: "AA==", signature: "AA==")
        }
        #expect(await probe.submissions.count == 1)
    }

    @Test
    func timeoutAfterSubmissionNeverFailsOver() async {
        let probe = SuiGRPCProbe(timeout: true)
        let client = SuiTransactionExecutor(endpoints: Self.urls, router: AdaptiveProviderRouter(persistsHealth: false)) {
            try await probe.respond($0)
        }
        await #expect(throws: URLError.self) {
            try await client.execute(transaction: "AA==", signature: "AA==")
        }
        #expect(await probe.submissions.count == 1)
    }

    @Test
    func wrongChainDoesNotReceiveSignedBytes() async throws {
        let probe = SuiGRPCProbe(wrongChain: true)
        let client = SuiTransactionExecutor(endpoints: Self.urls, router: AdaptiveProviderRouter(persistsHealth: false)) {
            try await probe.respond($0)
        }
        #expect(try await client.execute(transaction: "AA==", signature: "AA==") == Self.digest)
        #expect(await probe.submissions.count == 1)
        #expect(await probe.submissionHosts == ["second.example"])
    }

    @Test
    func allPreflightFailuresAreKnownNotSubmitted() async {
        let probe = SuiGRPCProbe(preflightDenied: true)
        let client = SuiTransactionExecutor(endpoints: Self.urls, router: AdaptiveProviderRouter(persistsHealth: false)) {
            try await probe.respond($0)
        }
        do {
            _ = try await client.execute(transaction: "AA==", signature: "AA==")
            Issue.record("Expected unavailable provider")
        } catch let error as SuiProviderError {
            guard case .submissionUnavailable = error else { Issue.record("Lost preflight cause"); return }
        } catch { Issue.record("Unexpected error") }
        #expect(await probe.submissions.isEmpty)
    }

    @Test
    func liveMainnetReceiptProjectionMatchesGraphQLDigest() throws {
        // Read-only GetTransaction response captured from mainnet 2026-09-12.
        // GetTransaction and ExecuteTransaction wrap the same ExecutedTransaction field.
        let hex = "00000000360a340a2c3656796665667a764b6f4b42684855593465456e75566d61556b7953657037594c7573686959327671553768220422020801800000000f677270632d7374617475733a300d0a"
        let bytes = stride(from: 0, to: hex.count, by: 2).map { i -> UInt8 in
            let start = hex.index(hex.startIndex, offsetBy: i)
            return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
        }
        let http = HTTPURLResponse(url: Self.urls[0], statusCode: 200, httpVersion: nil,
                                   headerFields: ["Content-Type": "application/grpc-web+proto"])!
        #expect(try SuiRPCWire.executionDigest(SuiRPCWire.response(Data(bytes), http: http)) == Self.digest)
    }

    @Test
    func unsuccessfulEffectsPreserveFailedDigest() throws {
        let f = SuiRPCWire.field
        let status = Data([8, 0]) + f(2, Data([24, 1]))
        let result = f(1, f(1, Data(Self.digest.utf8)) + f(4, f(4, status)))
        do {
            _ = try SuiRPCWire.executionDigest(result)
            Issue.record("Failed execution reported as successful")
        } catch let error as SuiProviderError {
            guard case let .executionFailed(code, digest) = error else { Issue.record("Lost effects"); return }
            #expect(code == "grpc_execution_1")
            #expect(digest == Self.digest)
        }
    }

    @Test(arguments: [Data(), Data([255, 255]), Data(repeating: 255, count: 11), Data([10, 127, 0])])
    func malformedReceiptNeverBecomesSuccess(data: Data) {
        #expect(throws: SuiProviderError.self) { try SuiRPCWire.executionDigest(data) }
    }

    @Test
    func requestPreservesWalletCoreBytes() throws {
        let tx = Data(repeating: 0x92, count: 257)
        let sig = Data(repeating: 0x61, count: 97)
        let request = try SuiRPCWire.executionRequest(transaction: tx.base64EncodedString(), signature: sig.base64EncodedString())
        let bytes = SuiRPCWire.bytes
        #expect(try bytes(2, bytes(1, bytes(1, request))) == tx)
        #expect(try bytes(2, bytes(1, bytes(2, request))) == sig)
    }

    @Test(arguments: [7, 12, 16])
    func grpcDenialsAreEligibleForSafeFailover(code: Int) throws {
        let trailer = Data("grpc-status: \(code)\r\n".utf8)
        var framed = SuiRPCWire.frame(trailer)
        framed[0] = 128
        let http = HTTPURLResponse(url: Self.urls[0], statusCode: 200, httpVersion: nil, headerFields: [:])!
        do {
            _ = try SuiRPCWire.response(framed, http: http)
            Issue.record("Expected denial")
        } catch {
            #expect(SuiTransactionExecutor.isDefinitiveAccessDenial(error))
        }
    }
}

private actor SuiGRPCProbe {
    var submissions: [Data] = []
    var submissionHosts: [String] = []
    let firstStatus: Int
    let timeout: Bool
    let wrongChain: Bool
    let preflightDenied: Bool

    init(firstStatus: Int = 200, timeout: Bool = false, wrongChain: Bool = false, preflightDenied: Bool = false) {
        self.firstStatus = firstStatus
        self.timeout = timeout
        self.wrongChain = wrongChain
        self.preflightDenied = preflightDenied
    }

    func respond(_ request: URLRequest) throws -> (Data, URLResponse) {
        let url = request.url!
        let first = url.host == "first.example"
        let f = SuiRPCWire.field
        let payload: Data
        var status = 200
        if url.path.hasSuffix("GetServiceInfo") {
            let chain = wrongChain && first ? "wrong-chain" : SuiTransactionExecutor.mainnetChainIdentifier
            payload = f(1, Data(chain.utf8)) + f(2, Data("mainnet".utf8))
            if preflightDenied { status = 403 }
        } else {
            submissions.append(request.httpBody!)
            submissionHosts.append(url.host!)
            if timeout { throw URLError(.timedOut) }
            status = first ? firstStatus : 200
            payload = f(1, f(1, Data("6VyfefzvKoKBhHUY4eEnuVmaUkySep7YLushiY2vqU7h".utf8)) + f(4, f(4, Data([8, 1]))))
        }
        return (SuiRPCWire.frame(payload), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/grpc-web+proto", "grpc-status": "0"])!)
    }
}
