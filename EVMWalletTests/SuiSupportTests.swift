import Foundation
import GRDB
import Testing
import WalletCore
@testable import Aperture

private enum SuiRemoteTokenFixture {
    static let coinType =
        "0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC"
    static let logoURL =
        "oath-asset://catalog/token-sui-usdc.png"
    static let metadata = SuiTokenMetadata(
        coinType: coinType,
        name: "USD Coin",
        symbol: "USDC",
        decimals: 6,
        iconURL: URL(string: logoURL),
        isVerified: true,
        rank: 1
    )

    static func install() {
        ReceiveAssetCatalogRuntime.install(
            [
                ReceiveToken(
                    id: "sui-usdc",
                    name: metadata.name,
                    symbol: metadata.symbol,
                    rank: 2_000,
                    isStablecoin: true,
                    variants: [
                        ReceiveTokenVariant(
                            networkID: SuiConstants.networkID,
                            contractAddress: coinType,
                            decimals: metadata.decimals,
                            networkRank: metadata.rank,
                            logoURL: logoURL,
                            marketDataID: "usd-coin"
                        )
                    ]
                )
            ],
            revision: 1
        )
    }
}

@Suite(.serialized)
struct SuiSupportTests {
    private static let address =
        "0xdfc88cd008c89a4a4a60199b27e503cd5e248b5191be8e953856b43e87ae3393"

    @Test
    func coinTypesAndAddressesUseCanonicalSuiIdentity() throws {
        #expect(
            SuiCoinType.canonical(
                "0x0000000000000000000000000000000000000000000000000000000000000002::sui::SUI"
            ) == SuiConstants.nativeCoinType
        )
        #expect(
            SuiCoinType.canonical(
                "0x02::Module_Name::TokenType"
            ) == "0x2::Module_Name::TokenType"
        )
        #expect(
            SuiCoinType.assetID(
                "0x0002::sui::SUI"
            ) == SuiConstants.nativeAssetID
        )
        #expect(
            SuiCoinType.validatedAccountAddress(Self.address)
                == Self.address
        )
        #expect(
            SuiCoinType.validatedAccountAddress("0x0") == nil
        )
        #expect(
            SuiCoinType.canonical("0x2::bad-name::TOKEN") == nil
        )
    }

    @Test
    func historyTimestampsAcceptMainnetFractionalSeconds() {
        #expect(
            SuiAPIClient.historyTimestamp(
                "2026-08-20T04:10:30.298Z"
            ) != nil
        )
        #expect(
            SuiAPIClient.historyTimestamp(
                "2026-08-20T04:10:30Z"
            ) != nil
        )
        #expect(SuiAPIClient.historyTimestamp("not-a-timestamp") == nil)
    }

    @Test
    func catalogTokensUseBundledArtwork() throws {
        SuiRemoteTokenFixture.install()
        let token = try #require(SuiTokenCatalog.all.first)

        #expect(SuiTokenCatalog.all.count == 1)
        #expect(token.coinType == SuiRemoteTokenFixture.coinType)
        #expect(token.iconURL?.absoluteString == SuiRemoteTokenFixture.logoURL)
    }

    @Test
    func curatedTokensHaveExactPriceProviderIdentities() {
        SuiRemoteTokenFixture.install()
        let expectedIDs = [
            "USDC": "usd-coin",
            "USDT": "sui-bridged-usdt-sui",
            "DEEP": "deep",
            "CETUS": "cetus-protocol",
            "MMT": "momentum-3",
            "SCA": "scallop-2",
            "NAVX": "navi"
        ]
        for token in SuiTokenCatalog.all {
            #expect(
                SuiTokenCatalog.coinGeckoID(
                    coinType: token.coinType
                ) == expectedIDs[token.symbol]
            )
        }
        #expect(
            SuiTokenCatalog.coinGeckoID(
                coinType: "0x999::unknown::UNKNOWN"
            ) == nil
        )
    }

    @Test
    func suiPaymentURIIsPinnedToMainnetAndUsesNineDecimals()
        throws
    {
        let request = try SendPaymentRequestParser.parse(
            """
            sui:\(Self.address)?amount=1.250000000\
            &label=Coffee%20Shop&message=Invoice%2042
            """
        )

        #expect(request.source == .suiURI)
        #expect(request.recipient == Self.address)
        #expect(request.candidateNetworkIDs == [SuiConstants.networkID])
        #expect(request.requestedNetworkID == SuiConstants.networkID)
        #expect(request.requestedAsset == .native)
        #expect(request.requestedAmount == .userUnits("1.25"))
        #expect(request.label == "Coffee Shop")
        #expect(request.message == "Invoice 42")
        #expect(
            SendAddressValidator.isValid(
                Self.address,
                for: SuiConstants.networkID
            )
        )
    }

    @Test
    func suiPaymentURIRejectsZeroAndExcessPrecision() {
        #expect(
            throws: SendPaymentRequestError.invalidMainnetAddress
        ) {
            try SendPaymentRequestParser.parse("sui:0x0")
        }
        #expect(throws: SendPaymentRequestError.invalidAmount) {
            try SendPaymentRequestParser.parse(
                "sui:\(Self.address)?amount=0.0000000001"
            )
        }
    }

    @Test
    func emptyProviderAccountStillProducesNativeZeroBalance()
        async throws
    {
        let fixture = SuiProviderFixture(mode: .emptyAccount)
        let client = SuiAPIClient(
            transport: SuiGraphQLTransport { request in
                try await fixture.response(for: request)
            }
        )
        let progressiveProbe = SuiBalanceSnapshotProbe()
        let snapshot = try await client.loadSnapshot(
            material: SuiAccountMaterial(
                address: Self.address,
                publicKey: "fixture",
                derivationPath: SuiConstants.derivationPath
            )
        ) { balanceSnapshot in
            await progressiveProbe.record(balanceSnapshot)
        }

        #expect(await progressiveProbe.recordCount == 2)
        #expect(await progressiveProbe.nativeAtomicAmount == "0")
        #expect(await progressiveProbe.historyCount == 0)
        #expect(snapshot.balancesAreAuthoritative)
        #expect(snapshot.historyIsAuthoritative)
        #expect(snapshot.providerFailureCodes.isEmpty)
        #expect(snapshot.balances.count == 1)
        #expect(snapshot.balances[0].metadata == SuiTokenCatalog.native)
        #expect(snapshot.balances[0].atomicAmount == "0")
        #expect(snapshot.balances[0].amountText == "0")

        let pageSizes = await fixture.requestedPageSizes()
        #expect(pageSizes.contains(SuiConstants.balancePageSize))
        #expect(pageSizes.contains(SuiConstants.historyPageSize))
        #expect(!pageSizes.contains(100))
    }

    @Test
    func providerExecutionErrorIsDecodedWithoutLosingItsCause()
        async throws
    {
        let fixture = SuiProviderFixture(mode: .rejectedExecution)
        let client = SuiAPIClient(
            transport: SuiGraphQLTransport { request in
                try await fixture.response(for: request)
            }
        )

        do {
            _ = try await client.execute(
                transactionDataBCS: "AA==",
                signature: "AA=="
            )
            Issue.record("Expected the Sui provider to reject execution.")
        } catch let error as SuiProviderError {
            guard case let .executionFailed(_, digest) = error else {
                Issue.record("Unexpected Sui provider error: \(error)")
                return
            }
            #expect(digest == "fixture-failed-digest")
            #expect(
                error.diagnosticDescription.contains(
                    "insufficient_gas"
                )
            )
        }
        let query = try #require(await fixture.executeQuery())
        #expect(!query.contains("errors"))
    }

    @Test
    func signedSubmissionNeverFailsOverAfterAmbiguousTransportFailure()
        async
    {
        let probe = SuiSubmissionProbe()
        let client = SuiAPIClient(
            transport: SuiGraphQLTransport(
                router: AdaptiveProviderRouter(persistsHealth: false)
            ) { request in
                await probe.record(request.url?.host)
                throw URLError(.timedOut)
            }
        )

        do {
            _ = try await client.execute(
                transactionDataBCS: "AA==",
                signature: "AA=="
            )
            Issue.record("Timed-out Sui submission unexpectedly succeeded.")
        } catch let error as URLError {
            #expect(error.code == .timedOut)
        } catch {
            Issue.record("Unexpected Sui submission error: \(error)")
        }

        #expect(await probe.requestCount == 1)
        #expect(
            await probe.requestedHosts
                == [SuiConstants.defaultGraphQLURL.host]
        )
    }

    @Test
    func authoritativeBalancePaginationRejectsMissingCursor()
        async throws
    {
        let fixture = SuiProviderFixture(mode: .missingBalanceCursor)
        let client = SuiAPIClient(
            transport: SuiGraphQLTransport { request in
                try await fixture.response(for: request)
            }
        )
        do {
            _ = try await client.loadSnapshot(
                material: SuiAccountMaterial(
                    address: Self.address,
                    publicKey: "fixture",
                    derivationPath: SuiConstants.derivationPath
                )
            )
            Issue.record("Expected invalid pagination to fail closed.")
        } catch let error as SuiProviderError {
            #expect(
                error.diagnosticDescription
                    == "sui_invalid_response_balances_cursor"
            )
        }
    }

    @Test
    func malformedTokenBalanceCannotBecomeAuthoritativeZero()
        async throws
    {
        let fixture = SuiProviderFixture(mode: .malformedTokenBalance)
        let client = SuiAPIClient(
            transport: SuiGraphQLTransport { request in
                try await fixture.response(for: request)
            }
        )

        let snapshot = try await client.loadSnapshot(
            material: SuiAccountMaterial(
                address: Self.address,
                publicKey: "fixture",
                derivationPath: SuiConstants.derivationPath
            )
        )

        #expect(!snapshot.balancesAreAuthoritative)
        #expect(
            snapshot.providerFailureCodes.contains(
                "sui_balance_item_invalid"
            )
        )
        #expect(snapshot.balances.count == 1)
        #expect(snapshot.balances[0].metadata == SuiTokenCatalog.native)
        #expect(snapshot.balances[0].amountText == "1")
    }

    @Test
    func walletCoreMainnetVectorSignsAndDerivesPublishedDigest()
        throws
    {
        let privateKey = try #require(
            Data(
                hexString:
                    "7e6682f7bf479ef0f627823cffd4e1a940a7af33e5fb39d9e0f631d2ecc5daff"
            )
        )
        let output: SuiSigningOutput = AnySigner.sign(
            input: SuiSigningInput.with {
                $0.paySui = .with {
                    $0.inputCoins = [
                        .with {
                            $0.objectID =
                                "0x636020b3a7dc7b11c3aa6f419b17f8a9c12e7f79a31d1bdd2de670b4edd63005"
                            $0.version = 85_619_064
                            $0.objectDigest =
                                "2eKuWbZSVfpFVfg8FXY9wP6W5AFXnTchSoUdp7obyYZ5"
                        }
                    ]
                    $0.recipients = [
                        "0xa7175abdd5ed92ebe3ad390db366c6a706478cdf517cde6cf98630065cda377a",
                        "0x54e80d76d790c277f5a44f3ce92f53d26f5894892bf395dee6375988876be6b2"
                    ]
                    $0.amounts = [1_000, 50_000]
                }
                $0.privateKey = privateKey
                $0.gasBudget = 3_000_000
                $0.referenceGasPrice = 750
            },
            coin: .sui
        )

        #expect(output.error == .ok)
        #expect(
            output.signature ==
                "AEh44B7iGArEHF1wOLAQJMLNgGnaIwn3gKPC92vtDJqITDETAM5z9plaxio1xomt6/cZReQ5FZaQsMC6l7E0BwmF69FEH+T5VPvl3GB3vwCOEZpeJpKXxvcIPQAdKsh2/g=="
        )
        #expect(
            try SuiTransactionDigest.make(
                transactionDataBCS: output.unsignedTx
            ) == "D4Ay9TdBJjXkGmrZSstZakpEWskEQHaWURP6xWPRXbAm"
        )
    }

    @Test
    func gasSummaryUsesLosslessCheckedSuiFeeMath() {
        #expect(
            SuiGasCostSummary(
                computationCost: 5_200_000,
                storageCost: 35_104_400,
                storageRebate: 40_117_968,
                nonRefundableStorageFee: 405_232
            ).netFee == 186_432
        )
        #expect(
            SuiGasCostSummary(
                computationCost: 1,
                storageCost: 1,
                storageRebate: 3,
                nonRefundableStorageFee: 0
            ).netFee == nil
        )
    }

    @Test
    func historyOnlyTokenCreatesItsAssetBeforeTransactionPersistence()
        async throws
    {
        let database = try WalletDatabase.temporary()
        let walletID = "sui-history-wallet"
        let accountID = "\(walletID):sui:0"
        let now = Date().timeIntervalSince1970
        try await database.pool.write { connection in
            try DBWalletRecord(
                id: walletID,
                profileID: WalletDatabase.defaultProfileID,
                name: "Sui Test Wallet",
                kind: DatabaseWalletKind.created.rawValue,
                secretKeyReference: nil,
                isSelected: false,
                sortOrder: 0,
                createdAt: now,
                updatedAt: now,
                lastOpenedAt: nil,
                archivedAt: nil
            ).insert(connection)
            try DBWalletAccountRecord(
                id: accountID,
                walletID: walletID,
                networkID: SuiConstants.networkID,
                address: Self.address,
                normalizedAddress: Self.address,
                label: SuiConstants.accountLabel,
                derivationPath: SuiConstants.derivationPath,
                accountIndex: 0,
                publicKey: "fixture-public-key",
                isWatchOnly: false,
                isEnabled: true,
                createdAt: now,
                updatedAt: now,
                lastSyncedAt: nil
            ).insert(connection)
        }

        let token = SuiRemoteTokenFixture.metadata
        let assetID = try #require(SuiCoinType.assetID(token.coinType))
        try await database.saveSuiSnapshot(
            SuiWalletSnapshot(
                material: SuiAccountMaterial(
                    address: Self.address,
                    publicKey: "fixture-public-key",
                    derivationPath: SuiConstants.derivationPath
                ),
                balances: [
                    SuiAssetBalance(
                        metadata: SuiTokenCatalog.native,
                        amountText: "0",
                        atomicAmount: "0"
                    )
                ],
                history: [
                    SuiHistoryItem(
                        id: "fixture-digest:0",
                        transactionHash: "fixture-digest",
                        timestamp: now,
                        failed: false,
                        sender: Self.address,
                        counterparty:
                            "0x1111111111111111111111111111111111111111111111111111111111111111",
                        owner: Self.address,
                        metadata: token,
                        signedAtomicAmount: "-1000000",
                        amountText: "1",
                        networkFeeText: "0.001"
                    )
                ],
                balancesAreAuthoritative: true,
                historyIsAuthoritative: true,
                providerFailureCodes: []
            ),
            walletID: walletID
        )

        let stored = try await database.pool.read { connection in
            (
                asset: try DBAssetRecord.fetchOne(
                    connection,
                    key: assetID
                ),
                transaction: try DBTransactionRecord
                    .filter(Column("accountID") == accountID)
                    .filter(Column("assetID") == assetID)
                    .fetchOne(connection)
            )
        }
        #expect(stored.asset?.contractAddress == token.coinType)
        #expect(stored.asset?.isVerified == true)
        #expect(stored.transaction?.assetAmount == "1")
        #expect(stored.transaction?.status == "confirmed")
    }
}

private actor SuiSubmissionProbe {
    private(set) var requestedHosts: [String?] = []

    var requestCount: Int { requestedHosts.count }

    func record(_ host: String?) {
        requestedHosts.append(host)
    }
}

private actor SuiBalanceSnapshotProbe {
    private(set) var recordCount = 0
    private(set) var nativeAtomicAmount: String?
    private(set) var historyCount = -1

    func record(_ snapshot: SuiWalletSnapshot) {
        recordCount += 1
        nativeAtomicAmount = snapshot.balances.first {
            $0.metadata.coinType == SuiConstants.nativeCoinType
        }?.atomicAmount
        historyCount = snapshot.history.count
    }
}

private actor SuiProviderFixture {
    enum Mode: Sendable {
        case emptyAccount
        case missingBalanceCursor
        case malformedTokenBalance
        case rejectedExecution
    }

    private let mode: Mode
    private var pageSizes: [Int] = []
    private var lastExecuteQuery: String?

    init(mode: Mode) {
        self.mode = mode
    }

    func response(
        for request: URLRequest
    ) throws -> (Data, URLResponse) {
        let body = try #require(request.httpBody)
        let object = try #require(
            JSONSerialization.jsonObject(with: body)
                as? [String: Any]
        )
        let query = try #require(object["query"] as? String)
        if query.contains("mutation Execute") {
            lastExecuteQuery = query
        }
        if let variables = object["variables"] as? [String: Any] {
            for key in ["first", "last", "changeFirst"] {
                if let value = variables[key] as? Int {
                    pageSizes.append(value)
                }
            }
        }

        let responseObject: [String: Any]
        switch mode {
        case .emptyAccount where query.contains("query Balances"):
            responseObject = [
                "data": [
                    "address": [
                        "balances": [
                            "nodes": [],
                            "pageInfo": [
                                "hasNextPage": false,
                                "endCursor": NSNull()
                            ]
                        ]
                    ]
                ]
            ]
        case .emptyAccount where query.contains("query History"):
            responseObject = [
                "data": [
                    "address": [
                        "transactions": [
                            "nodes": [],
                            "pageInfo": [
                                "hasPreviousPage": false,
                                "startCursor": NSNull()
                            ]
                        ]
                    ]
                ]
            ]
        case .missingBalanceCursor where query.contains("query Balances"):
            responseObject = [
                "data": [
                    "address": [
                        "balances": [
                            "nodes": [],
                            "pageInfo": [
                                "hasNextPage": true,
                                "endCursor": NSNull()
                            ]
                        ]
                    ]
                ]
            ]
        case .missingBalanceCursor where query.contains("query History"):
            responseObject = [
                "data": [
                    "address": [
                        "transactions": [
                            "nodes": [],
                            "pageInfo": [
                                "hasPreviousPage": false,
                                "startCursor": NSNull()
                            ]
                        ]
                    ]
                ]
            ]
        case .malformedTokenBalance where query.contains("query Balances"):
            responseObject = [
                "data": [
                    "address": [
                        "balances": [
                            "nodes": [
                                [
                                    "coinType": [
                                        "repr": SuiConstants.nativeCoinType
                                    ],
                                    "totalBalance": "1000000000"
                                ],
                                [
                                    "coinType": [
                                        "repr": SuiRemoteTokenFixture.coinType
                                    ],
                                    "totalBalance": "provider-error"
                                ]
                            ],
                            "pageInfo": [
                                "hasNextPage": false,
                                "endCursor": NSNull()
                            ]
                        ]
                    ]
                ]
            ]
        case .malformedTokenBalance where query.contains("query History"):
            responseObject = [
                "data": [
                    "address": [
                        "transactions": [
                            "nodes": [],
                            "pageInfo": [
                                "hasPreviousPage": false,
                                "startCursor": NSNull()
                            ]
                        ]
                    ]
                ]
            ]
        case .rejectedExecution where query.contains("mutation Execute"):
            responseObject = [
                "data": [
                    "executeTransaction": [
                        "effects": [
                            "digest": "fixture-failed-digest",
                            "status": "FAILURE",
                            "executionError": [
                                "message": "Insufficient gas"
                            ]
                        ]
                    ]
                ]
            ]
        default:
            Issue.record("Unexpected Sui fixture request.")
            responseObject = [
                "errors": [["message": "unexpected fixture request"]]
            ]
        }

        let requestURL = try #require(request.url)
        let response = try #require(
            HTTPURLResponse(
                url: requestURL,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )
        )
        return (
            try JSONSerialization.data(withJSONObject: responseObject),
            response
        )
    }

    func requestedPageSizes() -> [Int] {
        pageSizes
    }

    func executeQuery() -> String? {
        lastExecuteQuery
    }
}
