import Foundation
import Testing
@testable import Aperture

struct SendStatusReadResolverTests {
    @Test
    func missingReceiptsDoNotHideAConfirmedThirdProvider() async throws {
        let result = try await resolve([.success(.pending), .success(.pending), .success(.confirmed)])
        #expect(result == .confirmed)
    }

    @Test
    func missingReceiptDoesNotHideExecutionFailure() async throws {
        #expect(try await resolve([.success(.pending), .success(.failed)]) == .failed)
    }

    @Test
    func missingEverywhereRemainsPending() async throws {
        #expect(try await resolve([.success(.pending), .success(.pending)]) == .pending)
    }

    @Test
    func oneUnavailableProviderCannotEraseAPendingObservation() async throws {
        #expect(try await resolve([.failure(ProbeError.unavailable), .success(.pending)]) == .pending)
    }

    @Test
    func allFailuresPreserveAnErrorInsteadOfInventingPending() async {
        await #expect(throws: ProbeError.unavailable) {
            try await resolve([.failure(ProbeError.unavailable), .failure(ProbeError.unavailable)])
        }
    }

    @Test
    func cancellationDoesNotBecomePending() async {
        await #expect(throws: CancellationError.self) {
            try await resolve([.failure(CancellationError())])
        }
    }

    @Test
    func solanaStatusChecksPastNullResponsesAndValidatesReceipt() async throws {
        let endpoints = ["https://missing.example", "https://also-missing.example", "https://confirmed.example"]
            .compactMap(URL.init(string:))
        let transport = SolanaRPCTransport(endpoints: endpoints) { request in
            let requests = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [[String: Any]])
            #expect(requests.count == 1)
            #expect(requests[0]["method"] as? String == "getSignatureStatuses")
            let params = try #require(requests[0]["params"] as? [Any])
            #expect((params[1] as? [String: Bool])?["searchTransactionHistory"] == true)
            let value: Any = request.url?.host == "confirmed.example"
                ? ["err": NSNull(), "confirmationStatus": "finalized"] as [String: Any] : NSNull()
            let data = try JSONSerialization.data(withJSONObject: [["id": 1, "jsonrpc": "2.0", "result": ["value": [value]]]])
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let signature = "3uqECqL29L4SCkKiFNYY1sMFf2Di74fjnTsF9EMt7bmLgWH8DhRw9PzLK62NcUW7e4TaGKCHWejtot3aevXMgPPY"
        #expect(try await SolanaTransactionStatusProvider(transport: transport).status(signature: signature) == .confirmed)
    }

    private enum ProbeError: Error { case unavailable }

    private func resolve(_ results: [Result<SendTransactionNetworkStatus, any Error>]) async throws -> SendTransactionNetworkStatus {
        let attempts = results.enumerated().map { index, result in
            AdaptiveProviderAttempt(endpoint: AdaptiveProviderEndpoint(serviceID: "status-fixture",
                endpointURL: URL(string: "https://status\(index).example")!, baselinePriority: index)) {
                    try result.get()
                }
        }
        return try await SendStatusReadResolver.resolve(attempts: attempts,
            router: AdaptiveProviderRouter(persistsHealth: false))
    }
}
