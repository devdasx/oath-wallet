import Foundation
import Testing
@testable import Aperture

@Suite(.serialized)
struct PublicNodeEVMBalanceClientTests {
    private static let walletAddress =
        "0x1111111111111111111111111111111111111111"
    private static let heldContract =
        "0xd29687c813d741e2f938f4ac377128810e217b1b"
    private static let emptyContract =
        "0x5300000000000000000000000000000000000004"

    @Test
    func liveCapabilityMatrixRoutesScrollAndArcBalancesToPublicNode() {
        let expectedAdvanced = Set([
            "arbitrum", "avalanche", "base", "bsc", "eth", "gnosis",
            "linea", "optimism", "polygon", "taiko", "telos", "xlayer"
        ])

        #expect(AnkrAPIClient.advancedBalanceMainnetChains == expectedAdvanced)
        #expect(
            AnkrAPIClient.advancedHistoryMainnetChains
                == Set(AnkrAPIClient.supportedMainnetChains).subtracting(["arc"])
        )
        #expect(!AnkrAPIClient.usesAdvancedBalance(networkID: "scroll"))
        #expect(AnkrAPIClient.usesAdvancedHistory(networkID: "scroll"))
        #expect(!AnkrAPIClient.usesAdvancedBalance(networkID: "arc"))
        #expect(!AnkrAPIClient.usesAdvancedHistory(networkID: "arc"))
        #expect(AnkrAPIClient.usesBlockscoutHistory(networkID: "arc"))
        #expect(
            Set(AnkrAPIClient.publicNodeClients(session: nil).keys)
                == ["scroll", "arc"]
        )
    }

    @Test
    func concurrentContractReadsPreserveExactAmountsAndExcludeZeroTokens()
        async throws
    {
        let previousCatalog = ReceiveAssetCatalogRuntime.snapshot
        defer { Self.restoreCatalog(previousCatalog) }
        ReceiveAssetCatalogRuntime.install(Self.fixtureCatalog)

        let rpc = PublicNodeBalanceRPCStub(
            nativeResult: "0x1bc16d674ec80000",
            tokenResults: [
                Self.heldContract:
                    "0x00000000000000000000000000000000000000000000000010a741a462780000",
                Self.emptyContract:
                    "0x0000000000000000000000000000000000000000000000000000000000000000"
            ]
        )
        let client = Self.client(rpc: rpc) { assets in
            Dictionary(uniqueKeysWithValues: assets.map { asset in
                if asset.id.hasSuffix(Self.heldContract) {
                    return (asset.id, Decimal(string: "0.25")!)
                }
                return (asset.id, Decimal(string: "2000")!)
            })
        }

        let result = try await client.accountBalance(
            address: Self.walletAddress
        )

        #expect(result.assets.count == 2)
        #expect(result.totalBalanceUsd == "4000.3")
        let native = try #require(result.assets.first { $0.tokenType == "NATIVE" })
        #expect(native.balanceRawInteger == "2000000000000000000")
        #expect(native.balance == "2")
        #expect(native.balanceUsd == "4000")
        let token = try #require(
            result.assets.first { $0.contractAddress == Self.heldContract }
        )
        #expect(token.balanceRawInteger == "1200000000000000000")
        #expect(token.balance == "1.2")
        #expect(token.balanceUsd == "0.3")
        #expect(
            result.assets.contains {
                $0.contractAddress == Self.emptyContract
            } == false
        )
        #expect(
            await rpc.requestedContracts()
                == Set([Self.heldContract, Self.emptyContract])
        )
        #expect(await rpc.nativeReadCount() == 1)
    }

    @Test
    func oneFailedKnownContractRejectsNetworkAuthority() async throws {
        let previousCatalog = ReceiveAssetCatalogRuntime.snapshot
        defer { Self.restoreCatalog(previousCatalog) }
        ReceiveAssetCatalogRuntime.install(Self.fixtureCatalog)

        let rpc = PublicNodeBalanceRPCStub(
            nativeResult: "0x0",
            tokenResults: [
                Self.heldContract:
                    "0x0000000000000000000000000000000000000000000000000000000000000000"
            ],
            failedContract: Self.emptyContract
        )
        let client = Self.client(rpc: rpc) { _ in [:] }

        do {
            _ = try await client.accountBalance(address: Self.walletAddress)
            Issue.record("Expected the incomplete contract inventory to fail")
        } catch let error as PublicNodeEVMBalanceError {
            guard case let .providerRead(
                operation,
                contractAddress,
                code,
                _
            ) = error else {
                Issue.record("Unexpected PublicNode error: \(error)")
                return
            }
            #expect(operation == "eth_call")
            #expect(contractAddress == Self.emptyContract)
            #expect(!code.isEmpty)
        }
    }

    @Test
    func unavailableContractCatalogRejectsNetworkAuthority() async throws {
        let previousCatalog = ReceiveAssetCatalogRuntime.snapshot
        defer { Self.restoreCatalog(previousCatalog) }
        ReceiveAssetCatalogRuntime.install([])
        let rpc = PublicNodeBalanceRPCStub(
            nativeResult: "0x0",
            tokenResults: [:]
        )
        let client = Self.client(rpc: rpc) { _ in [:] }

        do {
            _ = try await client.accountBalance(address: Self.walletAddress)
            Issue.record("Expected an unavailable contract catalog to fail")
        } catch let error as PublicNodeEVMBalanceError {
            guard case let .providerRead(operation, _, code, _) = error else {
                Issue.record("Unexpected PublicNode error: \(error)")
                return
            }
            #expect(operation == "catalog")
            #expect(code == "catalog_unavailable")
        }
        #expect(await rpc.nativeReadCount() == 0)
    }

    @Test
    func contractReadsUseBoundedStructuredConcurrency() async throws {
        let previousCatalog = ReceiveAssetCatalogRuntime.snapshot
        defer { Self.restoreCatalog(previousCatalog) }
        let contracts = (1...12).map {
            String(format: "0x%040llx", UInt64($0))
        }
        ReceiveAssetCatalogRuntime.install(
            contracts.enumerated().map { index, contract in
                ReceiveToken(
                    id: "parallel-scroll-token-\(index)",
                    name: "Parallel Token \(index)",
                    symbol: "P\(index)",
                    rank: index + 1,
                    isStablecoin: false,
                    variants: [
                        ReceiveTokenVariant(
                            networkID: "scroll",
                            contractAddress: contract,
                            decimals: 18,
                            networkRank: index + 1,
                            logoURL: nil
                        )
                    ]
                )
            }
        )

        let rpc = PublicNodeBalanceRPCStub(
            nativeResult: "0x0",
            tokenResults: Dictionary(
                uniqueKeysWithValues: contracts.map {
                    ($0, "0x" + String(repeating: "0", count: 64))
                }
            ),
            tokenReadDelay: .milliseconds(20)
        )
        let client = PublicNodeEVMBalanceClient(
            networkID: "scroll",
            expectedChainID: 534_352,
            maximumConcurrentReads: 4,
            rpcFactory: { rpc },
            priceLoader: { _ in [:] }
        )

        _ = try await client.accountBalance(address: Self.walletAddress)

        let peak = await rpc.peakConcurrentTokenReads()
        #expect(peak > 1)
        #expect(peak <= 4)
        #expect(await rpc.requestedContracts() == Set(contracts))
    }

    @Test
    func completeBatchIsPreferredOverIndividualHTTPReads() async throws {
        let previousCatalog = ReceiveAssetCatalogRuntime.snapshot
        defer { Self.restoreCatalog(previousCatalog) }
        ReceiveAssetCatalogRuntime.install(Self.fixtureCatalog)
        let rpc = PublicNodeBatchBalanceRPCStub(
            nativeResult: "0x1bc16d674ec80000",
            tokenResults: [
                Self.heldContract:
                    "0x00000000000000000000000000000000000000000000000010a741a462780000",
                Self.emptyContract:
                    "0x0000000000000000000000000000000000000000000000000000000000000000"
            ]
        )
        let client = PublicNodeEVMBalanceClient(
            networkID: "scroll",
            expectedChainID: 534_352,
            rpcFactory: { rpc },
            priceLoader: { _ in [:] }
        )

        let result = try await client.accountBalance(address: Self.walletAddress)

        #expect(result.assets.count == 2)
        #expect(await rpc.batchReadCount() == 1)
        #expect(await rpc.individualReadCount() == 0)
        #expect(await rpc.separateChainIDReadCount() == 0)
        #expect(
            await rpc.requestedContracts()
                == Set([Self.heldContract, Self.emptyContract])
        )
    }

    @Test
    func transientBatchFailureRetriesTheCompleteBatchBeforeFallback()
        async throws
    {
        let previousCatalog = ReceiveAssetCatalogRuntime.snapshot
        defer { Self.restoreCatalog(previousCatalog) }
        ReceiveAssetCatalogRuntime.install(Self.fixtureCatalog)
        let rpc = PublicNodeBatchBalanceRPCStub(
            nativeResult: "0x0",
            tokenResults: [
                Self.heldContract:
                    "0x0000000000000000000000000000000000000000000000000000000000000000",
                Self.emptyContract:
                    "0x0000000000000000000000000000000000000000000000000000000000000000"
            ],
            transientBatchFailures: 1
        )
        let client = PublicNodeEVMBalanceClient(
            networkID: "scroll",
            expectedChainID: 534_352,
            rpcFactory: { rpc },
            priceLoader: { _ in [:] }
        )

        _ = try await client.accountBalance(address: Self.walletAddress)

        #expect(await rpc.batchReadCount() == 2)
        #expect(await rpc.individualReadCount() == 0)
        #expect(await rpc.separateChainIDReadCount() == 0)
    }

    @Test
    func wrongChainIDInsideCompleteBatchRejectsAuthority() async throws {
        let previousCatalog = ReceiveAssetCatalogRuntime.snapshot
        defer { Self.restoreCatalog(previousCatalog) }
        ReceiveAssetCatalogRuntime.install(Self.fixtureCatalog)
        let rpc = PublicNodeBatchBalanceRPCStub(
            chainIDResult: "0x1",
            nativeResult: "0x0",
            tokenResults: [
                Self.heldContract:
                    "0x0000000000000000000000000000000000000000000000000000000000000000",
                Self.emptyContract:
                    "0x0000000000000000000000000000000000000000000000000000000000000000"
            ]
        )
        let client = PublicNodeEVMBalanceClient(
            networkID: "scroll",
            expectedChainID: 534_352,
            rpcFactory: { rpc },
            priceLoader: { _ in [:] }
        )

        do {
            _ = try await client.accountBalance(address: Self.walletAddress)
            Issue.record("Expected the wrong batched chain ID to fail")
        } catch let error as PublicNodeEVMBalanceError {
            #expect(
                error == .chainIDMismatch(expected: 534_352, actual: "1")
            )
        }
        #expect(await rpc.batchReadCount() == 1)
        #expect(await rpc.individualReadCount() == 0)
        #expect(await rpc.separateChainIDReadCount() == 0)
    }

    @Test
    func scrollUsesPublicNodeForBalanceAndAdvancedAPIForHistory()
        async throws
    {
        let previousCatalog = ReceiveAssetCatalogRuntime.snapshot
        defer { Self.restoreCatalog(previousCatalog) }
        ReceiveAssetCatalogRuntime.install(Self.fixtureCatalog)
        AnkrHistoryOnlyURLProtocol.reset()

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AnkrHistoryOnlyURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let rpc = PublicNodeBalanceRPCStub(
            nativeResult: "0xde0b6b3a7640000",
            tokenResults: [
                Self.heldContract:
                    "0x0000000000000000000000000000000000000000000000000000000000000000",
                Self.emptyContract:
                    "0x0000000000000000000000000000000000000000000000000000000000000000"
            ]
        )
        let publicNode = Self.client(rpc: rpc) { _ in [:] }
        let client = AnkrAPIClient(
            transport: AnkrRPCTransport(
                endpoint: URL(string: "https://ankr.unit.test")!,
                session: session
            ),
            publicNodeBalanceClient: publicNode
        )

        let outcome = try await client.loadNetworkWithOutcome(
            address: Self.walletAddress,
            networkID: "scroll"
        )

        #expect(outcome.failures.isEmpty)
        #expect(
            outcome.snapshot.evmBalanceAuthority?
                .authoritativeNetworkIDs == Set(["scroll"])
        )
        #expect(outcome.snapshot.assets.map(\.symbol) == ["ETH"])
        #expect(outcome.snapshot.assets.first?.balanceText == "1")
        #expect(
            AnkrHistoryOnlyURLProtocol.methods()
                == Set([
                    "ankr_getTokenTransfers",
                    "ankr_getTransactionsByAddress"
                ])
        )
    }

    private static func client(
        rpc: PublicNodeBalanceRPCStub,
        priceLoader: @escaping PublicNodeEVMBalanceClient.PriceLoader
    ) -> PublicNodeEVMBalanceClient {
        PublicNodeEVMBalanceClient(
            networkID: "scroll",
            expectedChainID: 534_352,
            maximumConcurrentReads: 8,
            rpcFactory: { rpc },
            priceLoader: priceLoader
        )
    }

    private static func restoreCatalog(
        _ snapshot: ReceiveAssetCatalogRuntimeSnapshot
    ) {
        ReceiveAssetCatalogRuntime.install(
            snapshot.tokens,
            revision: snapshot.revision
        )
    }

    private static var fixtureCatalog: [ReceiveToken] {
        [
            ReceiveToken(
                id: "held-scroll-token",
                name: "Held Token",
                symbol: "HELD",
                rank: 1,
                isStablecoin: false,
                variants: [
                    ReceiveTokenVariant(
                        networkID: "scroll",
                        contractAddress: heldContract,
                        decimals: 18,
                        networkRank: 1,
                        logoURL: nil
                    )
                ]
            ),
            ReceiveToken(
                id: "empty-scroll-token",
                name: "Empty Token",
                symbol: "EMPTY",
                rank: 2,
                isStablecoin: false,
                variants: [
                    ReceiveTokenVariant(
                        networkID: "scroll",
                        contractAddress: emptyContract,
                        decimals: 18,
                        networkRank: 2,
                        logoURL: nil
                    )
                ]
            )
        ]
    }
}

private enum PublicNodeBalanceRPCStubError: Error {
    case unavailable
}

private actor PublicNodeBalanceRPCStub: PublicNodeEVMBalanceRPC {
    private let nativeResult: String
    private let tokenResults: [String: String]
    private let failedContract: String?
    private let tokenReadDelay: Duration?
    private var contracts = Set<String>()
    private var nativeReads = 0
    private var inFlightTokenReads = 0
    private var peakTokenReads = 0

    init(
        nativeResult: String,
        tokenResults: [String: String],
        failedContract: String? = nil,
        tokenReadDelay: Duration? = nil
    ) {
        self.nativeResult = nativeResult
        self.tokenResults = tokenResults
        self.failedContract = failedContract
        self.tokenReadDelay = tokenReadDelay
    }

    func chainID() async throws -> String { "0x82750" }

    func nativeBalance(address _: String) async throws -> String {
        nativeReads += 1
        await Task.yield()
        return nativeResult
    }

    func tokenBalance(
        ownerAddress _: String,
        contractAddress: String
    ) async throws -> String {
        let normalized = contractAddress.lowercased()
        contracts.insert(normalized)
        inFlightTokenReads += 1
        peakTokenReads = max(peakTokenReads, inFlightTokenReads)
        do {
            if let tokenReadDelay {
                try await Task.sleep(for: tokenReadDelay)
            } else {
                await Task.yield()
            }
        } catch {
            inFlightTokenReads -= 1
            throw error
        }
        inFlightTokenReads -= 1
        if normalized == failedContract?.lowercased() {
            throw PublicNodeBalanceRPCStubError.unavailable
        }
        guard let value = tokenResults[normalized] else {
            throw PublicNodeBalanceRPCStubError.unavailable
        }
        return value
    }

    func requestedContracts() -> Set<String> { contracts }
    func nativeReadCount() -> Int { nativeReads }
    func peakConcurrentTokenReads() -> Int { peakTokenReads }
}

private actor PublicNodeBatchBalanceRPCStub: PublicNodeEVMBalanceRPC {
    private let chainIDResult: String
    private let nativeResult: String
    private let tokenResults: [String: String]
    private var transientBatchFailures: Int
    private var batches = 0
    private var individualReads = 0
    private var separateChainIDReads = 0
    private var contracts = Set<String>()

    init(
        chainIDResult: String = "0x82750",
        nativeResult: String,
        tokenResults: [String: String],
        transientBatchFailures: Int = 0
    ) {
        self.chainIDResult = chainIDResult
        self.nativeResult = nativeResult
        self.tokenResults = tokenResults
        self.transientBatchFailures = transientBatchFailures
    }

    func chainID() async throws -> String {
        separateChainIDReads += 1
        return chainIDResult
    }

    func nativeBalance(address _: String) async throws -> String {
        individualReads += 1
        throw PublicNodeBalanceRPCStubError.unavailable
    }

    func tokenBalance(
        ownerAddress _: String,
        contractAddress _: String
    ) async throws -> String {
        individualReads += 1
        throw PublicNodeBalanceRPCStubError.unavailable
    }

    func accountBalances(
        ownerAddress _: String,
        contractAddresses: [String]
    ) async throws -> PublicNodeEVMBalanceBatchResult {
        batches += 1
        contracts = Set(contractAddresses.map { $0.lowercased() })
        if transientBatchFailures > 0 {
            transientBatchFailures -= 1
            throw PublicNodeEVMBalanceError.providerRead(
                operation: "batch",
                contractAddress: nil,
                code: "url_-1001",
                message: "The request timed out."
            )
        }
        return PublicNodeEVMBalanceBatchResult(
            chainID: chainIDResult,
            nativeBalance: nativeResult,
            tokenBalancesByContract: tokenResults
        )
    }

    func batchReadCount() -> Int { batches }
    func individualReadCount() -> Int { individualReads }
    func separateChainIDReadCount() -> Int { separateChainIDReads }
    func requestedContracts() -> Set<String> { contracts }
}

private final class AnkrHistoryOnlyURLProtocol:
    URLProtocol,
    @unchecked Sendable
{
    private static let lock = NSLock()
    nonisolated(unsafe) private static var requestedMethods = Set<String>()

    static func reset() {
        lock.withLock { requestedMethods = [] }
    }

    static func methods() -> Set<String> {
        lock.withLock { requestedMethods }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        do {
            guard let body = request.httpBody
                    ?? Self.readBodyStream(request.httpBodyStream),
                  let payload = try JSONSerialization
                    .jsonObject(with: body) as? [String: Any],
                  let method = payload["method"] as? String,
                  let identifier = payload["id"] as? String,
                  method != "ankr_getAccountBalance"
            else {
                throw URLError(.cannotParseResponse)
            }
            Self.lock.withLock {
                _ = Self.requestedMethods.insert(method)
            }
            let result: [String: Any]
            switch method {
            case "ankr_getTokenTransfers":
                result = ["transfers": [], "nextPageToken": NSNull()]
            case "ankr_getTransactionsByAddress":
                result = ["transactions": [], "nextPageToken": NSNull()]
            default:
                throw URLError(.unsupportedURL)
            }
            let data = try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0",
                "id": identifier,
                "result": result
            ])
            guard let url = request.url,
                  let response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
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

    private static func readBodyStream(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4_096)
        defer { buffer.deallocate() }
        var data = Data()
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: 4_096)
            if count < 0 { return nil }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
