import Foundation
import Testing
@testable import Aperture

@Suite(.serialized)
struct XRPBalancePerformanceTests {
    @Test
    func nativeAndIssuedBalanceReadsOverlapAndPublishProgressively()
        async throws
    {
        let fixture = XRPConcurrentBalanceFixture()
        let transport = try XRPJSONRPCTransport(
            endpoint: try #require(URL(string: "https://example.test/xrp")),
            router: AdaptiveProviderRouter(persistsHealth: false)
        ) { request in
            try await fixture.response(for: request)
        }
        let client = XRPAPIClient(transport: transport)
        let probe = XRPProgressiveBalanceProbe()

        let snapshot = try await client.loadSnapshot(
            material: XRPAccountMaterial(
                address: XRPConcurrentBalanceFixture.holder,
                publicKey: "fixture",
                derivationPath: XRPConstants.derivationPath
            )
        ) { partial in
            await probe.record(partial)
        }

        let partials = await probe.snapshots
        #expect(partials.count == 2)
        #expect(partials.first?.balances.count == 1)
        #expect(partials.first?.balances.first?.amountText == "35.223332")
        #expect(partials.first?.balancesAreAuthoritative == false)
        #expect(partials.last?.balances.count == 2)
        #expect(partials.last?.balancesAreAuthoritative == true)
        #expect(snapshot.balances.count == 2)
        #expect(
            snapshot.balances.first(where: { !$0.isNative })?.amountText
                == "12.3456789012345"
        )
        #expect(snapshot.historyIsAuthoritative)

        let methods = await fixture.recordedMethods
        #expect(methods.count == 3)
        #expect(Set(methods.prefix(2)) == ["account_info", "account_lines"])
        #expect(methods.last == "account_tx")
        #expect(await fixture.accountInfoObservedConcurrentTrustLineRead)
    }

    @Test
    func failedIssuedBalanceReadKeepsNativeSuccessAssetScoped()
        async throws
    {
        let fixture = XRPConcurrentBalanceFixture(failsAccountLines: true)
        let transport = try XRPJSONRPCTransport(
            endpoint: try #require(URL(string: "https://example.test/xrp")),
            router: AdaptiveProviderRouter(persistsHealth: false)
        ) { request in
            try await fixture.response(for: request)
        }
        let probe = XRPProgressiveBalanceProbe()
        let snapshot = try await XRPAPIClient(transport: transport)
            .loadSnapshot(
                material: XRPAccountMaterial(
                    address: XRPConcurrentBalanceFixture.holder,
                    publicKey: "fixture",
                    derivationPath: XRPConstants.derivationPath
                )
            ) { partial in
                await probe.record(partial)
            }

        #expect(await probe.snapshots.count == 1)
        #expect(snapshot.balances.count == 1)
        #expect(snapshot.balances.first?.amountText == "35.223332")
        #expect(!snapshot.balancesAreAuthoritative)
        #expect(
            snapshot.balanceFetchAuthority.successfulAssetIDs
                == [XRPConstants.nativeAssetID]
        )
        #expect(snapshot.providerFailureCodes == ["xrp_rejected_toobusy"])
        #expect(snapshot.historyIsAuthoritative)
    }
}

private actor XRPProgressiveBalanceProbe {
    private(set) var snapshots: [XRPWalletSnapshot] = []

    func record(_ snapshot: XRPWalletSnapshot) {
        snapshots.append(snapshot)
    }
}

private enum XRPConcurrencyFixtureError: Error {
    case accountLinesDidNotStart
}

private actor XRPConcurrentBalanceFixture {
    static let holder = "rMwNibdiFaEzsTaFCG1NnmAM3Rv3vHUy5L"
    private static let issuer = "rMxCKbEDwqr76QuheSUMdEGf4B9xJ8m5De"

    private var methods: [String] = []
    private var accountLinesStarted = false
    private var accountInfoWaiter: CheckedContinuation<Void, Error>?
    private(set) var accountInfoObservedConcurrentTrustLineRead = false
    private let failsAccountLines: Bool

    init(failsAccountLines: Bool = false) {
        self.failsAccountLines = failsAccountLines
    }

    var recordedMethods: [String] { methods }

    func response(for request: URLRequest) async throws
        -> (Data, URLResponse)
    {
        let body = try #require(request.httpBody)
        let object = try #require(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        let method = try #require(object["method"] as? String)
        methods.append(method)

        let result: [String: Any]
        switch method {
        case "account_info":
            try await waitForAccountLines()
            accountInfoObservedConcurrentTrustLineRead = accountLinesStarted
            result = [
                "account_data": [
                    "Account": Self.holder,
                    "Balance": "35223332",
                    "Flags": 0,
                    "OwnerCount": 14,
                    "Sequence": 1
                ],
                "ledger_index": 106_497_617,
                "validated": true
            ]
        case "account_lines":
            accountLinesStarted = true
            accountInfoWaiter?.resume()
            accountInfoWaiter = nil
            if failsAccountLines {
                result = ["status": "error", "error": "tooBusy"]
            } else {
                result = [
                    "lines": [[
                        "account": Self.issuer,
                        "balance": "12.3456789012345",
                        "currency":
                            "524C555344000000000000000000000000000000",
                        "limit": "1000000000",
                        "limit_peer": "0",
                        "quality_in": 0,
                        "quality_out": 0
                    ]],
                    "ledger_index": 106_497_617,
                    "validated": true
                ]
            }
        case "account_tx":
            result = [
                "ledger_index_max": 106_497_617,
                "transactions": [],
                "validated": true
            ]
        default:
            Issue.record("Unexpected XRP request: \(method)")
            result = ["status": "error", "error": "unexpectedFixture"]
        }
        return try Self.httpResponse(for: request, result: result)
    }

    private func waitForAccountLines() async throws {
        guard !accountLinesStarted else { return }
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            accountInfoWaiter = continuation
            Task { [self] in
                try? await Task.sleep(for: .seconds(2))
                expireAccountInfoWaiter()
            }
        }
    }

    private func expireAccountInfoWaiter() {
        accountInfoWaiter?.resume(
            throwing: XRPConcurrencyFixtureError.accountLinesDidNotStart
        )
        accountInfoWaiter = nil
    }

    private static func httpResponse(
        for request: URLRequest,
        result: [String: Any]
    ) throws -> (Data, URLResponse) {
        let url = try #require(request.url)
        let response = try #require(
            HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )
        )
        return (
            try JSONSerialization.data(
                withJSONObject: [
                    "jsonrpc": "2.0",
                    "id": 1,
                    "result": result
                ]
            ),
            response
        )
    }
}
