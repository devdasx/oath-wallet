import Foundation
import GRDB
import Testing
@testable import Aperture

struct SolanaTokenEligibilityTests {
    private let usdcMint =
        "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"
    private let unverifiedMint =
        "So11111111111111111111111111111111111111112"

    @Test
    func policyRequiresVerificationPositiveLiquidityAndCleanAudit() {
        #expect(
            SolanaTokenEligibilityPolicy.reason(
                isVerified: true,
                liquidityUSD: Decimal(string: "0.00000001"),
                isSuspicious: false
            ) == .eligible
        )
        #expect(
            SolanaTokenEligibilityPolicy.reason(
                isVerified: false,
                liquidityUSD: 1,
                isSuspicious: false
            ) == .unverified
        )
        #expect(
            SolanaTokenEligibilityPolicy.reason(
                isVerified: true,
                liquidityUSD: 0,
                isSuspicious: false
            ) == .noLiquidity
        )
        #expect(
            SolanaTokenEligibilityPolicy.reason(
                isVerified: true,
                liquidityUSD: 1,
                isSuspicious: true
            ) == .suspicious
        )
    }

    @Test
    func clientKeepsOnlyExactRequestedMintsAndLosslessLiquidity()
        async throws
    {
        let requestedMint = usdcMint
        let extraMint = unverifiedMint
        let payload = """
            [
              {
                "id": "\(requestedMint)",
                "name": "USD Coin",
                "symbol": "USDC",
                "decimals": 6,
                "isVerified": true,
                "liquidity": 123456.789012345678,
                "audit": { "isSus": false }
              },
              {
                "id": "\(extraMint)",
                "name": "Unexpected",
                "symbol": "EXTRA",
                "decimals": 9,
                "isVerified": true,
                "liquidity": 5,
                "audit": { "isSus": false }
              }
            ]
            """.data(using: .utf8)!
        let endpoint = URL(
            string: "https://example.com/tokens/v2/search"
        )!
        let client = SolanaTokenEligibilityClient(
            endpoints: [endpoint],
            requestExecutor: { request in
                #expect(request.httpMethod == "GET")
                #expect(
                    request.url?.query?
                        .contains("query=\(requestedMint)") == true
                )
                return (
                    payload,
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: [
                            "Content-Type": "application/json"
                        ]
                    )!
                )
            }
        )

        let result = try await client.fetch(mints: [requestedMint])

        #expect(result.count == 1)
        #expect(result[requestedMint]?.isEligible == true)
        #expect(result[requestedMint]?.decimals == 6)
        #expect(
            result[requestedMint]?.liquidityUSD
                == Decimal(string: "123456.789012345678")
        )
        #expect(result[extraMint] == nil)
    }

    @Test
    func customTokenAddressExtractionPreservesCaseSensitiveMint() {
        let mint = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"

        #expect(
            CustomTokenAddress.extracted(
                from: "solana:\(mint)?amount=1",
                networkID: SolanaConstants.networkID
            ) == mint
        )
        #expect(
            CustomTokenAddress.normalized(
                mint,
                networkID: SolanaConstants.networkID
            ) == mint
        )
    }

    @Test
    func customLookupRequiresMetadataToMatchInitializedMintAccount()
        async throws
    {
        let payload = Data(
            """
            [{
              "id":"\(usdcMint)",
              "name":"USD Coin",
              "symbol":"USDC",
              "decimals":6,
              "isVerified":true,
              "liquidity":1,
              "audit":{"isSus":false}
            }]
            """.utf8
        )
        let endpoint = URL(
            string: "https://example.com/tokens/v2/search"
        )!
        let executor: SolanaTokenEligibilityClient.RequestExecutor = {
            request in
            (
                payload,
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
            )
        }
        let accountInfo: @Sendable (Int) -> SolanaJSONValue = { decimals in
            .object([
                "value": .object([
                    "owner": .string(SolanaConstants.tokenProgramID),
                    "data": .object([
                        "parsed": .object([
                            "type": .string("mint"),
                            "info": .object([
                                "decimals": .number(Decimal(decimals)),
                                "supply": .string("1000000"),
                                "isInitialized": .bool(true)
                            ])
                        ])
                    ])
                ])
            ])
        }
        let network = try #require(
            ReceiveNetworkCatalog.network(for: SolanaConstants.networkID)
        )
        let client = SolanaTokenEligibilityClient(
            endpoints: [endpoint],
            requestExecutor: executor,
            accountInfoLoader: { _ in accountInfo(6) }
        )
        let token = try await client.lookupToken(
            network: network,
            mint: usdcMint
        )

        #expect(token.symbol == "USDC")
        #expect(token.decimals == 6)

        let mismatch = SolanaTokenEligibilityClient(
            endpoints: [endpoint],
            requestExecutor: executor,
            accountInfoLoader: { _ in accountInfo(9) }
        )
        await #expect(throws: SolanaCustomTokenLookupError.invalidMetadata) {
            try await mismatch.lookupToken(
                network: network,
                mint: usdcMint
            )
        }
    }

    @Test
    func snapshotEnrichmentKeepsUnverifiedTokensAvailableForManagement()
        throws
    {
        let accountSet = accounts()
        let snapshot = try SolanaWalletSnapshot(
            accounts: accountSet,
            addressSnapshots: [
                addressSnapshot(
                    material: accountSet.primary,
                    solBalance: 1,
                    solAtomicBalance: "1000000000",
                    tokens: [
                        token(
                            mint: usdcMint,
                            symbol: "USDC",
                            decimals: 6
                        ),
                        token(
                            mint: unverifiedMint,
                            symbol: "SPAM",
                            decimals: 9
                        )
                    ]
                ),
                addressSnapshot(
                    material: try #require(
                        accountSet.alternatives.first
                    ),
                    solBalance: 0,
                    solAtomicBalance: "0"
                )
            ],
            history: [
                history(mint: nil, symbol: "SOL", decimals: 9),
                history(mint: usdcMint, symbol: "USDC", decimals: 6),
                history(
                    mint: unverifiedMint,
                    symbol: "SPAM",
                    decimals: 9
                )
            ],
            historyCursors: []
        )
        let eligibility = SolanaTokenEligibility(
            mint: usdcMint,
            name: "USD Coin",
            symbol: "USDC",
            decimals: 6,
            isVerified: true,
            liquidityUSD: 1,
            isSuspicious: false,
            reason: .eligible,
            provider: SolanaTokenEligibilityClient.providerIdentifier,
            observedAt: 1,
            expiresAt: 2
        )

        let filtered = try SolanaTokenEligibilityPolicy.enrichedSnapshot(
            snapshot,
            eligibilityByMint: [usdcMint: eligibility]
        )

        #expect(
            Set(filtered.tokens.map(\.mint))
                == Set([usdcMint, unverifiedMint])
        )
        #expect(filtered.history.count == 3)
        #expect(filtered.history.contains { $0.mint == nil })
        #expect(filtered.history.contains { $0.mint == usdcMint })
        #expect(filtered.history.contains { $0.mint == unverifiedMint })
    }

    @Test
    func spendableSnapshotNeverAggregatesAlternativeDerivationBalances()
        throws
    {
        let accountSet = accounts()
        let alternative = try #require(accountSet.alternatives.first)
        let snapshot = try SolanaWalletSnapshot(
            accounts: accountSet,
            addressSnapshots: [
                addressSnapshot(
                    material: accountSet.primary,
                    solBalance: 1,
                    solAtomicBalance: "1000000000",
                    tokens: [
                        token(
                            mint: usdcMint,
                            symbol: "USDC",
                            decimals: 6,
                            amount: 2,
                            atomicAmount: "2000000"
                        )
                    ]
                ),
                addressSnapshot(
                    material: alternative,
                    solBalance: 5,
                    solAtomicBalance: "5000000000",
                    tokens: [
                        token(
                            mint: usdcMint,
                            symbol: "USDC",
                            decimals: 6,
                            amount: 8,
                            atomicAmount: "8000000"
                        ),
                        token(
                            mint: unverifiedMint,
                            symbol: "ALT",
                            decimals: 9,
                            amount: 4,
                            atomicAmount: "4000000000"
                        )
                    ]
                )
            ],
            history: [],
            historyCursors: []
        )

        #expect(snapshot.spendable.material.kind == .phantom)
        #expect(snapshot.spendable.material.address == accountSet.primary.address)
        #expect(snapshot.solBalance == 1)
        #expect(snapshot.solAtomicBalance == "1000000000")
        #expect(snapshot.tokens.count == 1)
        #expect(snapshot.tokens.first?.mint == usdcMint)
        #expect(snapshot.tokens.first?.amount == 2)
        #expect(snapshot.addressSnapshots.count == 2)
        #expect(
            snapshot.addressSnapshots.first {
                $0.material.kind == .trustWallet
            }?.solBalance == 5
        )
    }

    @Test
    func snapshotRejectsMissingOrDuplicateDerivationCoverage() throws {
        let accountSet = accounts()
        let primarySnapshot = addressSnapshot(
            material: accountSet.primary,
            solBalance: 1,
            solAtomicBalance: "1000000000"
        )

        #expect(throws: SolanaProviderError.self) {
            try SolanaWalletSnapshot(
                accounts: accountSet,
                addressSnapshots: [primarySnapshot],
                history: [],
                historyCursors: []
            )
        }
        #expect(throws: SolanaProviderError.self) {
            try SolanaWalletSnapshot(
                accounts: accountSet,
                addressSnapshots: [primarySnapshot, primarySnapshot],
                history: [],
                historyCursors: []
            )
        }
    }

    @Test
    func persistenceAndSendExposeOnlyTheExactSigningAccountBalance()
        async throws
    {
        let database = try WalletDatabase.temporary()
        let walletID = "solana-spendable-wallet"
        let accountSet = accounts()
        let alternative = try #require(accountSet.alternatives.first)
        try await seedWallet(
            walletID: walletID,
            accountSet: accountSet,
            database: database
        )
        try await seedStaleSolanaHoldings(
            walletID: walletID,
            database: database
        )

        let eligibility = eligibleUSDC()
        let snapshot = try SolanaWalletSnapshot(
            accounts: accountSet,
            addressSnapshots: [
                addressSnapshot(
                    material: accountSet.primary,
                    solBalance: 1,
                    solAtomicBalance: "1000000000",
                    tokens: [
                        token(
                            mint: usdcMint,
                            symbol: "USDC",
                            decimals: 6,
                            amount: 2,
                            atomicAmount: "2000000"
                        )
                    ]
                ),
                addressSnapshot(
                    material: alternative,
                    solBalance: 5,
                    solAtomicBalance: "5000000000",
                    tokens: [
                        token(
                            mint: usdcMint,
                            symbol: "USDC",
                            decimals: 6,
                            amount: 8,
                            atomicAmount: "8000000"
                        )
                    ]
                )
            ],
            history: [],
            historyCursors: []
        )

        try await database.saveSolanaSnapshot(
            snapshot,
            walletID: walletID,
            eligibilityByMint: [usdcMint: eligibility],
            resolvedPriceByIDOverride: [
                "solana:native": 10,
                "solana:\(usdcMint)": 1
            ]
        )

        let rows = try await database.pool.read { database in
            try DBAccountAssetRecord
                .filter(
                    [
                        WalletDatabase.solanaAccountID(
                            walletID: walletID,
                            kind: .phantom
                        ),
                        WalletDatabase.solanaAccountID(
                            walletID: walletID,
                            kind: .trustWallet
                        )
                    ].contains(Column("accountID"))
                )
                .fetchAll(database)
        }
        let primaryID = WalletDatabase.solanaAccountID(
            walletID: walletID,
            kind: .phantom
        )
        let alternativeID = WalletDatabase.solanaAccountID(
            walletID: walletID,
            kind: .trustWallet
        )
        let primaryNative = try #require(
            rows.first {
                $0.accountID == primaryID
                    && $0.assetID == "solana:native"
            }
        )
        let primaryToken = try #require(
            rows.first {
                $0.accountID == primaryID
                    && $0.assetID == "solana:\(usdcMint)"
            }
        )
        #expect(primaryNative.balance == "1")
        #expect(primaryNative.balanceAtomic == "1000000000")
        #expect(primaryToken.balance == "2")
        #expect(primaryToken.balanceAtomic == "2000000")
        #expect(
            rows.filter { $0.accountID == alternativeID }
                .allSatisfy {
                    $0.balance == "0"
                        && $0.balanceAtomic == "0"
                        && $0.fiatUSDValue == "0"
                }
        )

        let cached = try #require(
            try await database.cachedWalletSnapshot(walletID: walletID)
        )
        let cachedNativeAssets = cached.assets.filter {
            $0.id == "solana:native"
        }
        let cachedUSDCAssets = cached.assets.filter {
            $0.id == "solana:\(usdcMint)"
        }
        #expect(cachedNativeAssets.count == 1)
        #expect(cachedUSDCAssets.count == 1)
        #expect(Set(cached.assets.map(\.id)).count == cached.assets.count)
        #expect(
            cachedNativeAssets.first?.receiveAddress
                == accountSet.primary.address
        )
        #expect(
            cachedUSDCAssets.first?.receiveAddress
                == accountSet.primary.address
        )
        let choices = SendAssetChoiceCatalog.choices(
            from: cached.assets,
            capabilities: .fullWallet
        )
        let solChoice = try #require(
            choices.first { $0.id == "solana:native" }
        )
        let usdcChoice = try #require(
            choices.first { $0.id == "solana:\(usdcMint)" }
        )
        #expect(solChoice.balance == 1)
        #expect(solChoice.sourceAddress == accountSet.primary.address)
        #expect(usdcChoice.balance == 2)
        #expect(usdcChoice.sourceAddress == accountSet.primary.address)
        #expect(cached.totalBalance == 12)
    }

    @Test
    func spendableBalanceMigrationClearsValuesAndPreservesPreferences()
        async throws
    {
        let database = try WalletDatabase.temporary()
        let walletID = "solana-migration-wallet"
        let accountSet = accounts()
        try await seedWallet(
            walletID: walletID,
            accountSet: accountSet,
            database: database
        )
        try await seedStaleSolanaHoldings(
            walletID: walletID,
            database: database,
            isPinned: true,
            isHidden: true,
            sortOrder: 7
        )

        let repaired = try await database.pool.write { database in
            try WalletDatabase.repairHistoricalSolanaAggregatedBalances(
                database: database,
                now: 123
            )
        }
        let rows = try await database.pool.read { database in
            try DBAccountAssetRecord.fetchAll(database)
        }

        #expect(repaired == rows.count)
        #expect(!rows.isEmpty)
        #expect(
            rows.allSatisfy {
                $0.balance == "0"
                    && $0.balanceAtomic == "0"
                    && $0.fiatUSDValue == "0"
                    && $0.isEnabled
                    && $0.isPinned
                    && $0.isHidden
                    && $0.sortOrder == 7
                    && $0.updatedAt == 123
            }
        )
    }

    @Test
    func unverifiedSolanaAssetRequiresExplicitVisibilityOverride()
        throws
    {
        let walletAddress = "owner"
        let asset = WalletAsset(
            id: "solana:\(unverifiedMint)",
            name: "Unverified",
            symbol: "UNKNOWN",
            logoSource: .catalogToken(
                blockchain: .solana,
                contractAddress: unverifiedMint,
                logoURL: nil
            ),
            network: .solana,
            balance: 1,
            fiatValue: 0,
            decimals: 9,
            isVerified: false,
            isSpam: false
        )

        #expect(
            WalletHomeAssetVisibility.homeAssets(
                from: [asset],
                transactions: [],
                walletAddress: walletAddress,
                preferencesJSON: ""
            ).isEmpty
        )
        #expect(
            !WalletHomeAssetVisibility.isAvailableOutsideManagement(
                asset,
                walletAddress: walletAddress,
                preferencesJSON: ""
            )
        )

        let preferences = try #require(
            WalletHomeAssetVisibility.updatedPreferencesJSON(
                setting: true,
                for: asset,
                walletAddress: walletAddress,
                preferencesJSON: ""
            )
        )
        #expect(
            WalletHomeAssetVisibility.homeAssets(
                from: [asset],
                transactions: [],
                walletAddress: walletAddress,
                preferencesJSON: preferences
            ).map(\.id) == [asset.id]
        )
        #expect(
            WalletHomeAssetVisibility.isAvailableOutsideManagement(
                asset,
                walletAddress: walletAddress,
                preferencesJSON: preferences
            )
        )
    }

    @Test
    func suspiciousSolanaAssetCannotBeMadeVisible() throws {
        let asset = WalletAsset(
            id: "solana:\(unverifiedMint)",
            name: "Suspicious",
            symbol: "SPAM",
            logoSource: .unavailable,
            network: .solana,
            balance: 1,
            fiatValue: 0,
            decimals: 9,
            isVerified: false,
            isSpam: true
        )
        let preferences = try #require(
            WalletHomeAssetVisibility.updatedPreferencesJSON(
                setting: true,
                for: asset,
                walletAddress: "owner",
                preferencesJSON: ""
            )
        )

        #expect(
            WalletHomeAssetVisibility.homeAssets(
                from: [asset],
                transactions: [],
                walletAddress: "owner",
                preferencesJSON: preferences
            ).isEmpty
        )
        #expect(
            !WalletHomeAssetVisibility.isAvailableOutsideManagement(
                asset,
                walletAddress: "owner",
                preferencesJSON: preferences
            )
        )
    }

    @Test
    func eligibilityCacheStoresLiquidityAsTextAndUnknownMintsFailClosed()
        async throws
    {
        let database = try WalletDatabase.temporary()
        let now = Date().timeIntervalSince1970
        let verified = SolanaTokenEligibility(
            mint: usdcMint,
            name: "USD Coin",
            symbol: "USDC",
            decimals: 6,
            isVerified: true,
            liquidityUSD: Decimal(string: "987654.3210987654321"),
            isSuspicious: false,
            reason: .eligible,
            provider: SolanaTokenEligibilityClient.providerIdentifier,
            observedAt: now,
            expiresAt: now + 3_600
        )
        let fetcher = EligibilityStub(result: [usdcMint: verified])

        let resolved = await database.resolveSolanaTokenEligibility(
            mints: [usdcMint, unverifiedMint],
            fetcher: fetcher
        )
        let stored = try await database.pool.read { database in
            try Row.fetchAll(
                database,
                sql: """
                SELECT mint, liquidityUSD, typeof(liquidityUSD) AS valueType,
                       isEligible
                FROM solanaTokenEligibility
                ORDER BY mint
                """
            ).map { row -> (mint: String, liquidityUSD: String?, valueType: String, isEligible: Bool) in
                (row["mint"], row["liquidityUSD"], row["valueType"], row["isEligible"])
            }
        }

        #expect(resolved[usdcMint]?.isEligible == true)
        #expect(resolved[unverifiedMint]?.isEligible == false)
        #expect(stored.count == 2)
        let verifiedRow = try #require(
            stored.first { $0.mint == usdcMint }
        )
        #expect(
            verifiedRow.liquidityUSD
                == "987654.3210987654321"
        )
        #expect(verifiedRow.valueType == "text")
        #expect(verifiedRow.isEligible == true)
        #expect(
            try await database.eligibleSolanaTokenMints() == [usdcMint]
        )
    }

    @Test
    func staleVerifiedCacheRemainsAvailableDuringProviderOutage()
        async throws
    {
        let database = try WalletDatabase.temporary()
        let now = Date().timeIntervalSince1970
        let stale = SolanaTokenEligibility(
            mint: usdcMint,
            name: "USD Coin",
            symbol: "USDC",
            decimals: 6,
            isVerified: true,
            liquidityUSD: 1,
            isSuspicious: false,
            reason: .eligible,
            provider: SolanaTokenEligibilityClient.providerIdentifier,
            observedAt: now - 7_200,
            expiresAt: now - 3_600
        )
        try await database.pool.write { database in
            try DBSolanaTokenEligibilityRecord(
                eligibility: stale
            ).insert(database)
        }

        let resolved = await database.resolveSolanaTokenEligibility(
            mints: [usdcMint],
            fetcher: FailingEligibilityStub()
        )

        #expect(resolved[usdcMint] == stale)
    }

    private func token(
        mint: String,
        symbol: String,
        decimals: Int,
        amount: Decimal = 1,
        atomicAmount: String = "1"
    ) -> SolanaTokenBalance {
        SolanaTokenBalance(
            mint: mint,
            tokenAccountAddresses: ["token-account"],
            name: symbol,
            symbol: symbol,
            decimals: decimals,
            amount: amount,
            atomicAmount: atomicAmount,
            catalogRank: nil
        )
    }

    private func accounts() -> SolanaAccountSet {
        SolanaAccountSet(
            primary: SolanaAccountMaterial(
                kind: .phantom,
                address: usdcMint,
                publicKey: "primary-public-key",
                derivationPath: SolanaDerivationKind.phantom.derivationPath
            ),
            alternatives: [
                SolanaAccountMaterial(
                    kind: .trustWallet,
                    address: unverifiedMint,
                    publicKey: "alternative-public-key",
                    derivationPath:
                        SolanaDerivationKind.trustWallet.derivationPath
                )
            ]
        )
    }

    private func addressSnapshot(
        material: SolanaAccountMaterial,
        solBalance: Decimal,
        solAtomicBalance: String,
        tokens: [SolanaTokenBalance] = []
    ) -> SolanaAddressSnapshot {
        SolanaAddressSnapshot(
            material: material,
            solBalance: solBalance,
            solAtomicBalance: solAtomicBalance,
            tokenBalances: tokens,
            balanceAuthority: .complete
        )
    }

    private func eligibleUSDC() -> SolanaTokenEligibility {
        SolanaTokenEligibility(
            mint: usdcMint,
            name: "USD Coin",
            symbol: "USDC",
            decimals: 6,
            isVerified: true,
            liquidityUSD: 1,
            isSuspicious: false,
            reason: .eligible,
            provider: SolanaTokenEligibilityClient.providerIdentifier,
            observedAt: 1,
            expiresAt: 2
        )
    }

    private func seedWallet(
        walletID: String,
        accountSet: SolanaAccountSet,
        database: WalletDatabase
    ) async throws {
        let now = Date().timeIntervalSince1970
        try await database.pool.write { database in
            try DBWalletRecord(
                id: walletID,
                profileID: WalletDatabase.defaultProfileID,
                name: "Solana Spendable Fixture",
                kind: DatabaseWalletKind.created.rawValue,
                secretKeyReference: nil,
                isSelected: false,
                sortOrder: 0,
                createdAt: now,
                updatedAt: now,
                lastOpenedAt: nil,
                archivedAt: nil
            ).insert(database)
            for material in accountSet.all {
                try DBWalletAccountRecord(
                    id: WalletDatabase.solanaAccountID(
                        walletID: walletID,
                        kind: material.kind
                    ),
                    walletID: walletID,
                    networkID: SolanaConstants.networkID,
                    address: material.address,
                    normalizedAddress: material.address,
                    label: material.kind.rawValue,
                    derivationPath: material.derivationPath,
                    accountIndex: 0,
                    publicKey: material.publicKey,
                    isWatchOnly: false,
                    isEnabled: true,
                    createdAt: now,
                    updatedAt: now,
                    lastSyncedAt: nil
                ).insert(database)
            }
        }
    }

    private func seedStaleSolanaHoldings(
        walletID: String,
        database: WalletDatabase,
        isPinned: Bool = false,
        isHidden: Bool = false,
        sortOrder: Int = 0
    ) async throws {
        let now = Date().timeIntervalSince1970
        try await database.pool.write { database in
            try DBAssetRecord(
                id: "solana:native",
                networkID: SolanaConstants.networkID,
                assetType: DatabaseAssetType.native.rawValue,
                contractAddress: "",
                normalizedContractAddress: "",
                name: "Solana",
                symbol: "SOL",
                decimals: 9,
                trustWalletBlockchain: WalletBlockchain.solana.rawValue,
                trustWalletContractAddress: nil,
                isVerified: true,
                isSpam: false,
                createdAt: now,
                updatedAt: now,
                metadataUpdatedAt: now
            ).save(database)
            try DBAssetRecord(
                id: "solana:\(usdcMint)",
                networkID: SolanaConstants.networkID,
                assetType: DatabaseAssetType.fungibleToken.rawValue,
                contractAddress: usdcMint,
                normalizedContractAddress: usdcMint,
                name: "USD Coin",
                symbol: "USDC",
                decimals: 6,
                trustWalletBlockchain: WalletBlockchain.solana.rawValue,
                trustWalletContractAddress: usdcMint,
                isVerified: true,
                isSpam: false,
                createdAt: now,
                updatedAt: now,
                metadataUpdatedAt: now
            ).save(database)
            for kind in SolanaDerivationKind.allCases {
                let accountID = WalletDatabase.solanaAccountID(
                    walletID: walletID,
                    kind: kind
                )
                for (assetID, atomic) in [
                    ("solana:native", "6000000000"),
                    ("solana:\(usdcMint)", "10000000")
                ] {
                    try DBAccountAssetRecord(
                        accountID: accountID,
                        assetID: assetID,
                        balance: assetID == "solana:native" ? "6" : "10",
                        balanceAtomic: atomic,
                        fiatUSDValue: assetID == "solana:native"
                            ? "60" : "10",
                        isEnabled: true,
                        isPinned: isPinned,
                        isHidden: isHidden,
                        sortOrder: sortOrder,
                        firstSeenAt: now - 100,
                        lastSeenAt: now - 50,
                        updatedAt: now - 50
                    ).save(database)
                }
            }
        }
    }

    private func history(
        mint: String?,
        symbol: String,
        decimals: Int
    ) -> SolanaHistoryItem {
        SolanaHistoryItem(
            signature: UUID().uuidString,
            sourceAddress: "owner",
            slot: 1,
            timestamp: 1,
            failed: false,
            from: "source",
            to: "owner",
            mint: mint,
            symbol: symbol,
            decimals: decimals,
            amount: 1,
            atomicAmount: "1",
            fee: 0
        )
    }
}

private struct EligibilityStub: SolanaTokenEligibilityFetching {
    let result: [String: SolanaTokenEligibility]

    func fetch(
        mints: [String]
    ) async throws -> [String: SolanaTokenEligibility] {
        result.filter { mints.contains($0.key) }
    }
}

private struct FailingEligibilityStub: SolanaTokenEligibilityFetching {
    func fetch(
        mints: [String]
    ) async throws -> [String: SolanaTokenEligibility] {
        throw URLError(.cannotConnectToHost)
    }
}
