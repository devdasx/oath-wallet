import Foundation
import Testing
@testable import Aperture

@Suite(.serialized)
struct AnkrBalanceLoadingTests {
    @Test
    func balancePaginationCompletesWhenBothHistoryStreamsFail() async throws {
        AnkrBalanceURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AnkrBalanceURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
        }
        let endpoint = try #require(
            URL(string: "https://unit.test/ankr")
        )
        let client = AnkrAPIClient(
            transport: AnkrRPCTransport(
                endpoint: endpoint,
                session: session
            )
        )
        let progressiveProbe = AnkrBalanceSnapshotProbe()

        let outcome = try await client.loadWalletWithOutcome(
            address: "0x1111111111111111111111111111111111111111"
        ) { snapshot in
            await progressiveProbe.record(snapshot)
        }
        let snapshot = outcome.snapshot

        #expect(await progressiveProbe.recordCount == 1)
        #expect(
            await progressiveProbe.symbols == Set(["ETH", "POL"])
        )
        #expect(await progressiveProbe.transactionCount == 0)
        #expect(snapshot.assets.count == 2)
        #expect(Set(snapshot.assets.map(\.symbol)) == ["ETH", "POL"])
        #expect(snapshot.transactions.isEmpty)
        #expect(snapshot.evmBalanceAuthority?.isAuthoritative == true)
        #expect(outcome.failures.count == 2)
        #expect(
            outcome.failures.allSatisfy {
                $0.stage == .historyEnrichment
            }
        )
        #expect(
            AnkrBalanceURLProtocol.balancePageTokens()
                == ["<first>", "page-2"]
        )
    }

    @Test
    func incrementalHistoryUsesBoundedLargePagesAndPreservesCachedPrices()
        async throws {
        AnkrBalanceURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AnkrBalanceURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let endpoint = try #require(
            URL(string: "https://unit.test/ankr")
        )
        let client = AnkrAPIClient(
            transport: AnkrRPCTransport(
                endpoint: endpoint,
                session: session
            )
        )
        let cachedPrices = [
            "eth:0x3333333333333333333333333333333333333333":
                Decimal(string: "1.25")!
        ]

        let outcome = try await client.loadWalletWithOutcome(
            address: "0x1111111111111111111111111111111111111111",
            historyFromTimestamp: 1_700_000_000,
            cachedHistoricalTokenPrices: cachedPrices
        )

        #expect(outcome.historicalTokenPrices == cachedPrices)
        let requests = AnkrBalanceURLProtocol.historyRequests()
        #expect(
            requests["ankr_getTokenTransfers"]
                == AnkrBalanceHistoryRequest(
                    pageSize: 1_000,
                    fromTimestamp: 1_700_000_000
                )
        )
        #expect(
            requests["ankr_getTransactionsByAddress"]
                == AnkrBalanceHistoryRequest(
                    pageSize: 1_000,
                    fromTimestamp: 1_700_000_000
                )
        )
    }

    @Test
    func failedAggregateBalanceReadIsolatedByNetwork() async throws {
        AnkrBalanceURLProtocol.reset(mode: .partialNetworkRecovery)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AnkrBalanceURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let endpoint = try #require(
            URL(string: "https://unit.test/ankr")
        )
        let client = AnkrAPIClient(
            transport: AnkrRPCTransport(
                endpoint: endpoint,
                session: session
            )
        )

        let outcome = try await client.loadWalletWithOutcome(
            address: "0x1111111111111111111111111111111111111111"
        )
        let authority = try #require(
            outcome.snapshot.evmBalanceAuthority
        )

        #expect(outcome.snapshot.assets.map(\.symbol) == ["ETH"])
        #expect(authority.authoritativeNetworkIDs?.contains("eth") == true)
        #expect(
            authority.authoritativeNetworkIDs?.contains("polygon") == false
        )
        #expect(
            outcome.failures.contains {
                $0.stage == .providerRead
                    && $0.networkID == "polygon"
            }
        )
    }

    @Test
    func unpricedOpaqueTokenDoesNotRejectValidAuthoritativeBalances()
        async throws
    {
        AnkrBalanceURLProtocol.reset(mode: .unpricedOpaqueToken)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AnkrBalanceURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let endpoint = try #require(
            URL(string: "https://unit.test/ankr")
        )
        let client = AnkrAPIClient(
            transport: AnkrRPCTransport(
                endpoint: endpoint,
                session: session
            )
        )

        let outcome = try await client.loadNetworkWithOutcome(
            address: "0x1111111111111111111111111111111111111111",
            networkID: "eth"
        )
        let authority = try #require(
            outcome.snapshot.evmBalanceAuthority
        )

        #expect(outcome.snapshot.assets.map(\.symbol) == ["ETH"])
        #expect(outcome.snapshot.totalBalance == 1)
        #expect(authority.providerAssetCount == 1)
        #expect(authority.mappedAssetCount == 1)
        #expect(authority.isAuthoritative)
    }

    @Test
    func denseUnsolicitedTokenHistoryIsBoundedToRecentWindow()
        async throws
    {
        AnkrBalanceURLProtocol.reset(mode: .denseTokenHistory)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AnkrBalanceURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let endpoint = try #require(
            URL(string: "https://unit.test/ankr")
        )
        let client = AnkrAPIClient(
            transport: AnkrRPCTransport(
                endpoint: endpoint,
                session: session
            )
        )

        let outcome = try await client.loadNetworkWithOutcome(
            address: "0x1111111111111111111111111111111111111111",
            networkID: "eth"
        )

        #expect(
            AnkrBalanceURLProtocol.historyPageTokens(
                method: "ankr_getTokenTransfers"
            ).count == 5
        )
        #expect(
            AnkrBalanceURLProtocol.historyReportedItemCount(
                method: "ankr_getTokenTransfers"
            ) == AnkrAPIClient.maximumRecentHistoryItems
        )
        #expect(outcome.snapshot.assets.map(\.symbol) == ["ETH"])
        #expect(outcome.snapshot.evmBalanceAuthority?.isAuthoritative == true)
    }
}

private actor AnkrBalanceSnapshotProbe {
    private(set) var recordCount = 0
    private(set) var symbols: Set<String> = []
    private(set) var transactionCount = -1

    func record(_ snapshot: WalletHomeSnapshot) {
        recordCount += 1
        symbols = Set(snapshot.assets.map(\.symbol))
        transactionCount = snapshot.transactions.count
    }
}

private final class AnkrBalanceURLProtocol:
    URLProtocol,
    @unchecked Sendable
{
    enum Mode: Equatable, Sendable {
        case paginated
        case partialNetworkRecovery
        case unpricedOpaqueToken
        case denseTokenHistory
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var mode = Mode.paginated
    nonisolated(unsafe) private static var requestedPageTokens: [String] = []
    nonisolated(unsafe) private static var capturedHistoryRequests:
        [String: AnkrBalanceHistoryRequest] = [:]
    nonisolated(unsafe) private static var capturedHistoryPageTokens:
        [String: [String]] = [:]
    nonisolated(unsafe) private static var capturedHistoryItemCounts:
        [String: Int] = [:]

    static func reset(mode: Mode = .paginated) {
        lock.lock()
        self.mode = mode
        requestedPageTokens = []
        capturedHistoryRequests = [:]
        capturedHistoryPageTokens = [:]
        capturedHistoryItemCounts = [:]
        lock.unlock()
    }

    static func balancePageTokens() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return requestedPageTokens
    }

    static func historyRequests() -> [String: AnkrBalanceHistoryRequest] {
        lock.lock()
        defer { lock.unlock() }
        return capturedHistoryRequests
    }

    static func historyPageTokens(method: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return capturedHistoryPageTokens[method] ?? []
    }

    static func historyReportedItemCount(method: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return capturedHistoryItemCounts[method] ?? 0
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        do {
            let requestObject = try requestJSON()
            let method = requestObject["method"] as? String
            let identifier = requestObject["id"] as? String ?? "1"
            let responseObject: [String: Any]
            if method == "ankr_getAccountBalance" {
                let parameters = requestObject["params"]
                    as? [String: Any]
                let pageToken = parameters?["pageToken"] as? String
                Self.lock.lock()
                Self.requestedPageTokens.append(
                    pageToken ?? "<first>"
                )
                Self.lock.unlock()
                let blockchains = parameters?["blockchain"]
                    as? [String] ?? []
                let mode = Self.currentMode()
                responseObject = mode == .partialNetworkRecovery
                    || mode == .denseTokenHistory
                    ? isolatedBalanceResponse(
                        identifier: identifier,
                        blockchains: blockchains
                    )
                    : balanceResponse(
                        identifier: identifier,
                        pageToken: pageToken,
                        includesUnpricedOpaqueToken:
                            mode == .unpricedOpaqueToken
                    )
            } else {
                let parameters = requestObject["params"]
                    as? [String: Any]
                let pageSize = parameters?["pageSize"] as? Int ?? -1
                let fromTimestamp = parameters?["fromTimestamp"]
                    as? Int64
                    ?? (parameters?["fromTimestamp"] as? NSNumber)?
                        .int64Value
                if let method {
                    Self.lock.lock()
                    Self.capturedHistoryRequests[method] =
                        AnkrBalanceHistoryRequest(
                            pageSize: pageSize,
                            fromTimestamp: fromTimestamp
                        )
                    Self.capturedHistoryPageTokens[method, default: []]
                        .append(
                            parameters?["pageToken"] as? String ?? "<first>"
                        )
                    Self.lock.unlock()
                }
                if Self.currentMode() == .denseTokenHistory,
                   method == "ankr_getTokenTransfers" {
                    responseObject = denseTokenHistoryResponse(
                        identifier: identifier,
                        pageToken: parameters?["pageToken"] as? String
                    )
                } else {
                    responseObject = [
                        "jsonrpc": "2.0",
                        "id": identifier,
                        "error": [
                            "code": -32_001,
                            "message": "history unavailable"
                        ]
                    ]
                }
            }
            let data = try JSONSerialization.data(
                withJSONObject: responseObject
            )
            guard
                let url = request.url,
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: [
                        "Content-Type": "application/json"
                    ]
                )
            else {
                throw URLError(.badServerResponse)
            }
            client?.urlProtocol(
                self,
                didReceive: response,
                cacheStoragePolicy: .notAllowed
            )
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func currentMode() -> Mode {
        lock.lock()
        defer { lock.unlock() }
        return mode
    }

    private func requestJSON() throws -> [String: Any] {
        guard
            let body = request.httpBody
                ?? Self.readBodyStream(request.httpBodyStream),
            let object = try JSONSerialization.jsonObject(
                with: body
            ) as? [String: Any]
        else {
            throw URLError(.cannotParseResponse)
        }
        return object
    }

    private static func readBodyStream(
        _ stream: InputStream?
    ) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }

        var data = Data()
        let bufferSize = 4_096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(
            capacity: bufferSize
        )
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: bufferSize)
            if count < 0 { return nil }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    private func balanceResponse(
        identifier: String,
        pageToken: String?,
        includesUnpricedOpaqueToken: Bool = false
    ) -> [String: Any] {
        let isFirstPage = pageToken == nil
        let asset: [String: Any] = [
            "blockchain": isFirstPage ? "eth" : "polygon",
            "tokenName": isFirstPage ? "Ether" : "Polygon",
            "tokenSymbol": isFirstPage ? "ETH" : "POL",
            "tokenDecimals": 18,
            "tokenType": "NATIVE",
            "contractAddress": "",
            "balance": isFirstPage ? "1" : "2",
            "balanceRawInteger": isFirstPage
                ? "1000000000000000000"
                : "2000000000000000000",
            "balanceUsd": isFirstPage ? "1" : "2",
            "tokenPrice": "1",
            "thumbnail": ""
        ]
        let opaqueAsset: [String: Any] = [
            "blockchain": "eth",
            "tokenName": "",
            "tokenSymbol": "",
            "tokenDecimals": 0,
            "tokenType": "ERC20",
            "contractAddress":
                "0x62a56a4a2ef4d355d34d10fbf837e747504d38d4",
            "balance": "4500",
            "balanceRawInteger": "4500",
            "balanceUsd": "",
            "tokenPrice": "",
            "thumbnail": ""
        ]
        var result: [String: Any] = [
            "totalBalanceUsd": includesUnpricedOpaqueToken ? "1" : "3",
            "assets": includesUnpricedOpaqueToken && isFirstPage
                ? [asset, opaqueAsset]
                : [asset]
        ]
        if isFirstPage && !includesUnpricedOpaqueToken {
            result["nextPageToken"] = "page-2"
        }
        return [
            "jsonrpc": "2.0",
            "id": identifier,
            "result": result
        ]
    }

    private func isolatedBalanceResponse(
        identifier: String,
        blockchains: [String]
    ) -> [String: Any] {
        guard blockchains.count == 1,
              blockchains.first != "polygon"
        else {
            return [
                "jsonrpc": "2.0",
                "id": identifier,
                "error": [
                    "code": -32_001,
                    "message": "balance provider unavailable"
                ]
            ]
        }
        let assets: [[String: Any]]
        if blockchains.first == "eth" {
            assets = [[
                "blockchain": "eth",
                "tokenName": "Ether",
                "tokenSymbol": "ETH",
                "tokenDecimals": 18,
                "tokenType": "NATIVE",
                "contractAddress": "",
                "balance": "1",
                "balanceRawInteger": "1000000000000000000",
                "balanceUsd": "1",
                "tokenPrice": "1",
                "thumbnail": ""
            ]]
        } else {
            assets = []
        }
        return [
            "jsonrpc": "2.0",
            "id": identifier,
            "result": [
                "totalBalanceUsd": assets.isEmpty ? "0" : "1",
                "assets": assets
            ]
        ]
    }

    private func denseTokenHistoryResponse(
        identifier: String,
        pageToken: String?
    ) -> [String: Any] {
        let pageNumber = Int(pageToken?.dropFirst(5) ?? "0") ?? 0
        let item: [String: Any] = [
            "blockHeight": 1,
            "fromAddress": "0x2222222222222222222222222222222222222222",
            "toAddress": "0x1111111111111111111111111111111111111111",
            "contractAddress":
                "0x3333333333333333333333333333333333333333",
            "value": "1",
            "valueRawInteger": "1",
            "blockchain": "eth",
            "tokenName": "Unpriced unsolicited token",
            "tokenSymbol": "SPAM",
            "tokenDecimals": 0,
            "thumbnail": "",
            "transactionHash":
                "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "logIndex": 1,
            "timestamp": 1_700_000_000,
            "direction": "in"
        ]
        let items = Array(repeating: item, count: 1_000)
        Self.lock.lock()
        Self.capturedHistoryItemCounts[
            "ankr_getTokenTransfers",
            default: 0
        ] += items.count
        Self.lock.unlock()
        return [
            "jsonrpc": "2.0",
            "id": identifier,
            "result": [
                "transfers": items,
                "nextPageToken": "page-\(pageNumber + 1)"
            ]
        ]
    }
}

private struct AnkrBalanceHistoryRequest: Equatable, Sendable {
    let pageSize: Int
    let fromTimestamp: Int64?
}
