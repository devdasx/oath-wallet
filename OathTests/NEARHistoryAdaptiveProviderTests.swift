import Foundation
import Testing
@testable import Aperture

struct NEARHistoryAdaptiveProviderTests {
    @Test
    func completeHistoryFallsBackAfterPrimaryTimeout() async throws {
        let serviceID = "near_history_\(UUID().uuidString)"
        let router = NEARHistoryProviderRouter(
            router: AdaptiveProviderRouter(),
            serviceID: serviceID,
            timeoutSeconds: 0.02
        )
        let attempts = AttemptRecorder()
        let fallbackItem = Self.item(id: "fallback")

        let history = try await router.history(
            fastNEAR: {
                await attempts.record("fastnear")
                try await Task.sleep(for: .seconds(2))
                return []
            },
            nearBlocks: {
                await attempts.record("nearblocks")
                return [fallbackItem]
            }
        )

        #expect(history.map(\.id) == ["fallback"])
        #expect(await attempts.count("fastnear") == 1)
        #expect(await attempts.count("nearblocks") == 1)
    }

    @Test
    func nearBlocksDecodesNativeAndTokenHistoryIndependently() async throws {
        let address = "root.near"
        let client = NEARNearBlocksHistoryClient { request in
            let url = try #require(request.url)
            let payload: Data
            if url.path.hasSuffix("/txns") {
                payload = Self.nativePayload
            } else if url.path.hasSuffix("/receipts") {
                payload = Self.emptyPayload
            } else if url.path.hasSuffix("/ft-txns") {
                payload = Self.tokenPayload
            } else {
                Issue.record("Unexpected NearBlocks path: \(url.path)")
                payload = Self.emptyPayload
            }
            return (payload, Self.response(url: url, status: 200))
        }

        let history = try await client.history(address: address)

        #expect(history.count == 2)
        #expect(history.contains { $0.transactionHash == "native-hash" })
        let token = try #require(
            history.first { $0.transactionHash == "token-hash" }
        )
        #expect(token.metadata?.symbol == "TEST")
        #expect(token.signedAmountText == "1.5")
    }

    @Test
    func malformedUnknownTokenDoesNotDiscardValidNativeHistory() async throws {
        let client = NEARNearBlocksHistoryClient { request in
            let url = try #require(request.url)
            let payload: Data
            if url.path.hasSuffix("/txns") {
                payload = Self.nativePayload
            } else if url.path.hasSuffix("/ft-txns") {
                payload = Self.tokenWithoutMetadataPayload
            } else {
                payload = Self.emptyPayload
            }
            return (payload, Self.response(url: url, status: 200))
        }

        let history = try await client.history(address: "root.near")

        #expect(history.count == 1)
        #expect(history.first?.transactionHash == "native-hash")
    }

    @Test
    func historyDetailsRunConcurrentlyWithinTheConfiguredBound() async throws {
        let probe = ConcurrencyProbe()
        let hashes = (0..<19).map { "hash-\($0)" }

        let values = try await NEARHistoryDetailsBatchLoader.load(
            hashes: hashes,
            batchSize: 2,
            maximumConcurrency: 3
        ) { batch in
            await probe.begin()
            do {
                try await Task.sleep(for: .milliseconds(20))
                await probe.finish()
                return batch
            } catch {
                await probe.finish()
                throw error
            }
        }

        #expect(Set(values) == Set(hashes))
        #expect(await probe.peak == 3)
    }

    private actor AttemptRecorder {
        private var values: [String] = []

        func record(_ value: String) {
            values.append(value)
        }

        func count(_ value: String) -> Int {
            values.count { $0 == value }
        }
    }

    private actor ConcurrencyProbe {
        private var active = 0
        private(set) var peak = 0

        func begin() {
            active += 1
            peak = max(peak, active)
        }

        func finish() {
            active -= 1
        }
    }

    private static func item(id: String) -> NEARHistoryItem {
        NEARHistoryItem(
            id: id,
            transactionHash: id,
            timestamp: 1,
            failed: false,
            sender: "root.near",
            recipient: "alice.near",
            metadata: nil,
            signedAmountText: "-1",
            networkFeeAtomic: nil,
            blockHeight: 1,
            nonce: nil
        )
    }

    private static let emptyPayload = Data(
        #"{"data":[],"meta":{"next_page":null}}"#.utf8
    )

    private static let nativePayload = Data(
        #"{"data":[{"actions":[{"action":"TRANSFER"}],"actions_agg":{"deposit":"1000000000000000000000000"},"block":{"block_height":"123","block_timestamp":"1720000000000000000"},"outcomes":{"status":true},"outcomes_agg":{"transaction_fee":"100"},"receiver_account_id":"alice.near","signer_account_id":"root.near","transaction_hash":"native-hash"}],"meta":{"next_page":null}}"#.utf8
    )

    private static let tokenPayload = Data(
        #"{"data":[{"affected_account_id":"root.near","block":{"block_height":"124","block_timestamp":"1720000001000000000"},"block_timestamp":"1720000001000000000","contract_account_id":"test-token.near","delta_amount":"1500000","event_index":2,"involved_account_id":"bob.near","meta":{"contract":"test-token.near","decimals":6,"icon":null,"name":"Test Token","symbol":"TEST"},"receipt_id":"receipt","transaction_hash":"token-hash"}],"meta":{"next_page":null}}"#.utf8
    )

    private static let tokenWithoutMetadataPayload = Data(
        #"{"data":[{"affected_account_id":"root.near","block":{"block_height":"124","block_timestamp":"1720000001000000000"},"block_timestamp":"1720000001000000000","contract_account_id":"unknown.near","delta_amount":"1","event_index":null,"involved_account_id":null,"meta":null,"receipt_id":null,"transaction_hash":"ignored-token"}],"meta":{"next_page":null}}"#.utf8
    )

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
