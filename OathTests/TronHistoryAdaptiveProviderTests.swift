import Foundation
import Testing
@testable import Aperture

struct TronHistoryAdaptiveProviderTests {
    @Test
    func nativeHistoryUsesTronScanAsTheStableBaseline() async throws {
        let fixture = Fixture()
        let transport = fixture.transport { request in
            let url = try #require(request.url)
            await fixture.attempts.record(url)
            return (
                Self.nativeHistoryPayload,
                Self.response(url: url, status: 200)
            )
        }

        let history = try await transport.nativeHistory(
            address: "TLa2f6VPqDgRE67v1736s7bJ8Ray5wYjU7"
        )

        let item = try #require(history.first)
        #expect(item.transactionID == "native-transaction")
        #expect(item.amountText == "1")
        #expect(item.assetSymbol == "TRX")
        #expect(await fixture.attempts.count(host: fixture.scanURL.host) == 1)
        #expect(await fixture.attempts.count(host: fixture.gridURL.host) == 0)
    }

    @Test
    func nativeHistoryFallsBackFromTronScanOnHTTP429() async throws {
        let fixture = Fixture()
        let transport = fixture.transport { request in
            let url = try #require(request.url)
            await fixture.attempts.record(url)
            if url.host == fixture.scanURL.host {
                return (
                    Data(#"{"message":"rate limited"}"#.utf8),
                    Self.response(url: url, status: 429)
                )
            }
            return (
                Self.gridNativeHistoryPayload,
                Self.response(url: url, status: 200)
            )
        }

        let history = try await transport.nativeHistory(
            address: "TLa2f6VPqDgRE67v1736s7bJ8Ray5wYjU7"
        )

        let item = try #require(history.first)
        #expect(item.transactionID == "grid-native-transaction")
        #expect(item.amountText == "1")
        #expect(await fixture.attempts.count(host: fixture.scanURL.host) == 1)
        #expect(await fixture.attempts.count(host: fixture.gridURL.host) == 1)
    }

    @Test
    func tokenHistoryFallsBackAfterPrimaryTimeout() async throws {
        let decoded = try JSONDecoder().decode(
            TronScanTokenHistoryEnvelope.self,
            from: Self.tokenHistoryPayload
        )
        #expect(decoded.transfers.count == 1)
        #expect(
            try TronScanHistoryMapper.tokenTransfers(
                from: decoded.transfers
            ).count == 1
        )
        let fixture = Fixture(timeoutSeconds: 0.02)
        let transport = fixture.transport { request in
            let url = try #require(request.url)
            await fixture.attempts.record(url)
            if url.host == fixture.scanURL.host {
                try await Task.sleep(for: .seconds(2))
            }
            let data = url.host == fixture.gridURL.host
                ? Self.gridTokenHistoryPayload
                : Self.tokenHistoryPayload
            return (data, Self.response(url: url, status: 200))
        }

        let history = try await transport.tokenHistory(
            address: "TLa2f6VPqDgRE67v1736s7bJ8Ray5wYjU7"
        )

        let item = try #require(history.first)
        #expect(item.transactionID == "grid-token-transaction")
        #expect(item.amountText == "1.5")
        #expect(item.assetSymbol == "USDT")
        #expect(item.assetIdentity == Self.tokenContract)
        #expect(await fixture.attempts.count(host: fixture.scanURL.host) == 1)
        #expect(await fixture.attempts.count(host: fixture.gridURL.host) == 1)
    }

    @Test
    func tronGridFallbackIncludesUnconfirmedHistory() async throws {
        let fixture = Fixture()
        let transport = fixture.transport { request in
            let url = try #require(request.url)
            await fixture.attempts.record(url)
            if url.host == fixture.scanURL.host {
                return (
                    Data(#"{"message":"temporarily unavailable"}"#.utf8),
                    Self.response(url: url, status: 503)
                )
            }
            let components = try #require(
                URLComponents(
                    url: url,
                    resolvingAgainstBaseURL: false
                )
            )
            let onlyConfirmed = components.queryItems?.first {
                $0.name == "only_confirmed"
            }?.value
            #expect(onlyConfirmed == "false")
            return (
                Self.gridNativeHistoryPayload,
                Self.response(url: url, status: 200)
            )
        }

        let history = try await transport.nativeHistory(
            address: "TLa2f6VPqDgRE67v1736s7bJ8Ray5wYjU7"
        )

        #expect(history.first?.transactionID == "grid-native-transaction")
    }

    private struct Fixture {
        let gridURL: URL
        let scanURL: URL
        let timeoutSeconds: Double
        let attempts = AttemptRecorder()

        init(timeoutSeconds: Double = 0.2) {
            let testID = UUID().uuidString.lowercased()
            gridURL = URL(
                string: "https://tron-grid-\(testID).example"
            )!
            scanURL = URL(
                string: "https://tron-scan-\(testID).example"
            )!
            self.timeoutSeconds = timeoutSeconds
        }

        func transport(
            executor: @escaping TronHistoryAPITransport.RequestExecutor
        ) -> TronHistoryAPITransport {
            TronHistoryAPITransport(
                tronGridBaseURL: gridURL,
                tronScanBaseURL: scanURL,
                timeoutSeconds: timeoutSeconds,
                requestExecutor: executor
            )
        }
    }

    private actor AttemptRecorder {
        private var URLs: [URL] = []

        func record(_ url: URL) {
            URLs.append(url)
        }

        func count(host: String?) -> Int {
            URLs.count { $0.host == host }
        }
    }

    private static let tokenContract =
        "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t"

    private static let nativeHistoryPayload = Data(
        #"{"data":[{"amount":"1000000","block_timestamp":1720000000000,"block":64200000,"from":"TFromAddress","to":"TToAddress","hash":"native-transaction","confirmed":1,"contract_type":"TransferContract","revert":0,"contract_ret":"SUCCESS"}],"page_size":1}"#.utf8
    )

    private static let tokenHistoryPayload = Data(
        #"{"token_transfers":[{"transaction_id":"token-transaction","block_ts":1720000000000,"from_address":"TFromAddress","to_address":"TToAddress","block":64200001,"contract_address":"TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t","quant":"1500000","event_type":"Transfer","confirmed":true,"contractRet":"SUCCESS","revert":false,"tokenInfo":{"tokenId":"TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t","tokenAbbr":"USDT","tokenName":"Tether USD","tokenDecimal":6}}],"total":1}"#.utf8
    )

    private static let gridNativeHistoryPayload = Data(
        #"{"data":[{"txID":"grid-native-transaction","blockNumber":64200000,"block_timestamp":1720000000000,"ret":[{"contractRet":"SUCCESS","fee":0}],"raw_data":{"contract":[{"type":"TransferContract","parameter":{"value":{"owner_address":"TFromAddress","to_address":"TToAddress","amount":1000000}}}]}}],"success":true,"meta":{}}"#.utf8
    )

    private static let gridTokenHistoryPayload = Data(
        #"{"data":[{"transaction_id":"grid-token-transaction","token_info":{"symbol":"USDT","address":"TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t","decimals":6,"name":"Tether USD"},"block_timestamp":1720000000000,"from":"TFromAddress","to":"TToAddress","type":"Transfer","value":"1500000"}],"success":true,"meta":{}}"#.utf8
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
