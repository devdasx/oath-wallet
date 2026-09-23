import Foundation
import Testing
@testable import Aperture

struct ElectrumResponseHandlingTests {
    @Test(arguments: ["blockchain.scripthash.listunspent", "blockchain.scripthash.get_balance",
                      "blockchain.scripthash.get_history", "blockchain.headers.subscribe"])
    func applicationReadFailureUsesNextProvider(method: String) async throws {
        let serviceID = "electrum_read_\(UUID().uuidString)"
        let primary = AdaptiveProviderEndpoint(serviceID: serviceID,
            endpointURL: try #require(URL(string: "https://primary.invalid")), baselinePriority: 0)
        let fallback = AdaptiveProviderEndpoint(serviceID: serviceID,
            endpointURL: try #require(URL(string: "https://fallback.invalid")), baselinePriority: 1)
        let attempts = ElectrumReadAttempts()
        let result = try await AdaptiveProviderRouter().executeRead(
            serviceID: serviceID,
            attempts: [
                AdaptiveProviderAttempt<String>(endpoint: primary) {
                    await attempts.record("primary")
                    throw BitcoinFamilyElectrumError.rpc(1, "server could not complete read")
                },
                AdaptiveProviderAttempt<String>(endpoint: fallback) {
                    await attempts.record("fallback")
                    return "validated_read"
                }
            ], timeoutSeconds: 1,
            shouldFallback: { BitcoinFamilyElectrumClient.shouldFallbackRead($0, method: method) }
        )
        #expect(result == "validated_read")
        #expect(await attempts.values == ["primary", "fallback"])
    }

    @Test
    func readFallbackDoesNotRetryBroadcastOrInvalidParameters() {
        #expect(!BitcoinFamilyElectrumClient.shouldFallbackRead(
            BitcoinFamilyElectrumError.rpc(1, "transaction rejected"), method: "blockchain.transaction.broadcast"))
        #expect(!BitcoinFamilyElectrumClient.shouldFallbackRead(
            BitcoinFamilyElectrumError.unavailable, method: "blockchain.transaction.broadcast"))
        #expect(!BitcoinFamilyElectrumClient.shouldFallbackRead(
            BitcoinFamilyElectrumError.rpc(-32602, "invalid parameters"), method: "blockchain.scripthash.listunspent"))
    }

    @Test
    func exhaustedReadFallbackPreservesConcreteFailure() async throws {
        let serviceID = "electrum_exhausted_\(UUID().uuidString)"
        let endpoint = AdaptiveProviderEndpoint(serviceID: serviceID,
            endpointURL: try #require(URL(string: "https://unavailable.invalid")), baselinePriority: 0)
        do {
            let _: String = try await AdaptiveProviderRouter().executeRead(serviceID: serviceID,
                attempts: [AdaptiveProviderAttempt<String>(endpoint: endpoint) {
                    throw BitcoinFamilyElectrumError.rpc(1, "read limit")
                }], timeoutSeconds: 1,
                shouldFallback: { BitcoinFamilyElectrumClient.shouldFallbackRead($0, method: "blockchain.scripthash.listunspent") })
            Issue.record("An exhausted read must not fabricate successful output data")
        } catch let error as BitcoinFamilyElectrumError {
            guard case .rpc(1, "read limit") = error else {
                Issue.record("Expected the original RPC failure")
                return
            }
        }
    }

    @Test func unusedAddressNullIsSuccessfulRatherThanMissing() throws {
        let response = try decode(#"{"jsonrpc":"2.0","id":1,"result":null}"#)
        #expect(response.id?.value == 1)
        guard case .null? = response.result else {
            Issue.record("A valid unused-address status must preserve JSON null")
            return
        }
        #expect(response.error == nil)
    }

    @Test func missingResultAndRPCFailureRemainDistinctFromNull() throws {
        let missing = try decode(#"{"id":2}"#)
        #expect(missing.result == nil)
        let failed = try decode(#"{"id":3,"error":{"code":-32602,"message":"Invalid params"}}"#)
        #expect(failed.result == nil)
        #expect(failed.error?.code.value == -32602)
    }

    @Test func numericBalancesAndNotificationNullRemainLossless() throws {
        let balance = try decode(#"{"id":4,"result":{"confirmed":9007199254740993,"unconfirmed":-1}}"#)
        #expect(balance.result?.object?["confirmed"]?.string == "9007199254740993")
        #expect(balance.result?.object?["unconfirmed"]?.exactInt64 == -1)
        let notification = try decode(#"{"method":"blockchain.scripthash.subscribe","params":["public-test-hash",null]}"#)
        #expect(notification.id == nil)
        guard case .null? = notification.params?.last else {
            Issue.record("A notification may change an address status to null")
            return
        }
    }

    private func decode(_ json: String) throws -> ElectrumResponse {
        try JSONDecoder().decode(
            ElectrumResponse.self,
            from: BitcoinFamilyLosslessJSON.preservingNumberLexemes(in: Data(json.utf8))
        )
    }
}

private actor ElectrumReadAttempts {
    private(set) var values: [String] = []
    func record(_ value: String) { values.append(value) }
}
