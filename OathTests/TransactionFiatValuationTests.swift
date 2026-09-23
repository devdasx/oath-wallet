import Foundation
import GRDB
import Testing
@testable import Aperture

@Suite(.serialized)
struct TransactionFiatValuationTests {
    @Test
    func customSolanaTokenWithoutLogoKeepsItsMintPriceIdentity() throws {
        let mint = "9BB6NFEcjBCtnNLFko2FqVQBq8HHM13kCyYcdQbgpump"
        let asset = WalletAsset(
            id: "solana:\(mint)",
            name: "Custom Solana Token",
            symbol: "$1",
            logoSource: .unavailable,
            network: .solana,
            balance: try #require(Decimal(string: "0.179636")),
            fiatValue: 0
        )

        #expect(AssetPriceClient.priceContractAddress(for: asset) == mint)
    }

    @Test
    func customSolanaTokenRejectsPreviouslyCachedNativeCoinPrice() throws {
        let previous = ReceiveAssetCatalogRuntime.snapshot
        defer {
            ReceiveAssetCatalogRuntime.install(
                previous.tokens,
                revision: previous.revision
            )
        }
        ReceiveAssetCatalogRuntime.install([], revision: 0)
        let mint = "9BB6NFEcjBCtnNLFko2FqVQBq8HHM13kCyYcdQbgpump"
        let asset = WalletAsset(
            id: "solana:\(mint)",
            name: "Custom Solana Token",
            symbol: "$1",
            logoSource: .unavailable,
            network: .solana,
            balance: try #require(Decimal(string: "0.179636")),
            fiatValue: 0
        )
        let invalidNativeQuote = AssetUSDPrice(
            assetID: asset.id,
            price: try #require(Decimal(string: "75.096")),
            provider: "coinbase",
            observedAt: Date()
        )
        let exactTokenQuote = AssetUSDPrice(
            assetID: asset.id,
            price: try #require(Decimal(string: "0.00052856")),
            provider: AssetPriceClient.exactContractPriceProvider,
            observedAt: Date()
        )
        let exactANKRQuote = AssetUSDPrice(
            assetID: asset.id,
            price: try #require(Decimal(string: "0.00052856")),
            provider: "ankr_getTokenPrice",
            observedAt: Date()
        )

        #expect(
            !AssetPriceClient.cachedPriceIsReusable(
                invalidNativeQuote,
                for: asset
            )
        )
        #expect(
            AssetPriceClient.cachedPriceIsReusable(
                exactTokenQuote,
                for: asset
            )
        )
        #expect(!AssetPriceClient.cachedPriceIsReusable(exactANKRQuote, for: asset))
    }

    @Test
    func nativeSolanaAssetDoesNotExposeATokenMint() {
        let asset = WalletAsset(
            id: "solana:native",
            name: "Solana",
            symbol: "SOL",
            logoSource: .unavailable,
            network: .solana,
            balance: 1,
            fiatValue: 0
        )

        #expect(AssetPriceClient.priceContractAddress(for: asset) == nil)
    }

    @Test
    func appAssetIdentityIsNeverUsedAsAProviderMarketIdentity() {
        let previous = ReceiveAssetCatalogRuntime.snapshot
        defer {
            ReceiveAssetCatalogRuntime.install(
                previous.tokens,
                revision: previous.revision
            )
        }
        ReceiveAssetCatalogRuntime.install([], revision: 0)
        let contract = "0xdac17f958d2ee523a2206206994597c13d831ec7"
        let asset = WalletAsset(
            id: AssetIdentityKey.make(
                networkID: "eth",
                contractAddress: contract
            ),
            name: "Tether USD",
            symbol: "USDT",
            logoSource: .unavailable,
            network: .ethereum,
            balance: 1,
            fiatValue: 0
        )

        #expect(AssetPriceClient.coinGeckoMarketID(for: asset) == nil)
        #expect(AssetPriceClient.priceContractAddress(for: asset) == contract)
    }

    @Test
    func catalogMarketIDNeverReplacesUnavailableContractPrice() async throws {
        let database = try WalletDatabase.temporary()
        let previous = ReceiveAssetCatalogRuntime.snapshot
        defer {
            ReceiveAssetCatalogRuntime.install(
                previous.tokens,
                revision: previous.revision
            )
        }
        ReceiveAssetCatalogRuntime.install(
            [
                ReceiveToken(
                    id: "near-wrap.near",
                    name: "Wrapped NEAR",
                    symbol: "wNEAR",
                    rank: 1,
                    isStablecoin: false,
                    variants: [
                        ReceiveTokenVariant(
                            networkID: "near",
                            contractAddress: "wrap.near",
                            decimals: 24,
                            networkRank: 1,
                            logoURL: nil,
                            marketDataID: "wrapped-near"
                        )
                    ]
                )
            ],
            revision: 1
        )
        AssetPriceFallbackURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [
            AssetPriceFallbackURLProtocol.self
        ]
        let client = AssetPriceClient(
            session: URLSession(configuration: configuration),
            database: database
        )
        let asset = WalletAsset(
            id: AssetIdentityKey.make(
                networkID: "near",
                contractAddress: "wrap.near"
            ),
            name: "Wrapped NEAR",
            symbol: "wNEAR",
            logoSource: .unavailable,
            network: .near,
            balance: 1,
            fiatValue: 0
        )

        do {
            _ = try await client.usdPrice(for: asset)
            Issue.record("A token must remain unpriced when every exact-contract route fails.")
        } catch {
            #expect(error is AssetPriceError || error is ProviderReliabilityError)
        }
        #expect(
            !AssetPriceFallbackURLProtocol.requestedPaths().contains(
                "/api/v3/simple/price"
            )
        )
    }

    @Test
    func providerFailureUsesLastValidPriceAndPruningRetainsIt()
        async throws
    {
        AssetPriceFallbackURLProtocol.reset(rejectAllRequests: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AssetPriceFallbackURLProtocol.self]
        let database = try WalletDatabase.temporary()
        let assetID = "polygon:native"
        let now = Date().timeIntervalSince1970
        let retainedObservedAt = now - (100 * 24 * 60 * 60)
        try await database.pool.write { database in
            try insertPolygonNativeAsset(
                in: database,
                now: now
            )
            for (price, observedAt) in [
                ("0.20", now - (120 * 24 * 60 * 60)),
                ("0.25", retainedObservedAt)
            ] {
                try DBAssetPriceRecord(
                    assetID: assetID,
                    quoteCurrency: "USD",
                    price: price,
                    provider: "coingecko",
                    observedAt: observedAt,
                    expiresAt: observedAt + 300
                ).insert(database)
            }
            try WalletDatabase.pruneCaches(now: now, database: database)
        }
        let client = AssetPriceClient(
            session: URLSession(configuration: configuration),
            database: database
        )
        let quote = try await client.usdPrice(for: WalletAsset(
            id: assetID,
            name: "Polygon",
            symbol: "POL",
            logoSource: .nativeCoin(blockchain: .polygon),
            network: .polygon,
            balance: 1,
            fiatValue: 0
        ))

        #expect(quote.price == Decimal(string: "0.25"))
        #expect(quote.observedAt.timeIntervalSince1970 == retainedObservedAt)
        #expect(AssetPriceFallbackURLProtocol.requestedPaths().count >= 1)
        let cachedRows = try await database.pool.read { database in
            try DBAssetPriceRecord
                .filter(Column("assetID") == assetID)
                .fetchAll(database)
        }
        #expect(cachedRows.count == 1)
        #expect(cachedRows.first?.price == "0.25")
    }

    @Test
    func cachedPriceValuesExistingNativeTransactionAndFreshPriceBackfills()
        async throws
    {
        let database = try WalletDatabase.temporary()
        let fixture = try await seedPolygonTransaction(database: database)

        let missingPriceAssets =
            try await database.assetsNeedingTransactionUSDPrices(
                walletID: fixture.walletID
            )
        #expect(missingPriceAssets.map(\.id) == [fixture.assetID])

        try await database.pool.write { database in
            try DBAssetPriceRecord(
                assetID: fixture.assetID,
                quoteCurrency: "USD",
                price: "0.25",
                provider: "existing-cache",
                observedAt: fixture.now,
                expiresAt: fixture.now + 300
            ).insert(database)
        }
        #expect(
            try await database.assetsNeedingTransactionUSDPrices(
                walletID: fixture.walletID
            ).isEmpty
        )

        let existingCacheSnapshot = try #require(
            try await database.cachedWalletSnapshot(
                walletID: fixture.walletID
            )
        )
        #expect(existingCacheSnapshot.transactions.count == 1)
        #expect(
            existingCacheSnapshot.transactions.first?.fiatValue
                == Decimal(string: "-2.5")
        )
        let persistedBeforeFreshQuote =
            try await database.pool.read { database in
                try DBTransactionRecord.fetchOne(
                    database,
                    key: fixture.transactionID
                )?.fiatUSDValue
            }
        #expect(persistedBeforeFreshQuote == nil)

        try await database.saveAssetUSDPrice(
            AssetUSDPrice(
                assetID: fixture.assetID,
                price: try #require(Decimal(string: "0.30")),
                provider: "fresh-quote",
                observedAt: Date()
            )
        )

        let backfilled = try await database.pool.read { database in
            (
                transaction: try DBTransactionRecord.fetchOne(
                    database,
                    key: fixture.transactionID
                ),
                transfer: try DBTransactionTransferRecord.fetchOne(
                    database,
                    key: "\(fixture.transactionID)|primary"
                ),
                holding: try DBAccountAssetRecord.fetchOne(
                    database,
                    key: [
                        "accountID": fixture.accountID,
                        "assetID": fixture.assetID
                    ]
                )
            )
        }
        #expect(backfilled.transaction?.fiatUSDValue == "3")
        #expect(backfilled.transaction?.networkFeeFiatUSDValue == "0.003")
        #expect(backfilled.transfer?.fiatUSDValue == "3")
        #expect(backfilled.holding?.fiatUSDValue == "0")

        let freshQuoteSnapshot = try #require(
            try await database.cachedWalletSnapshot(
                walletID: fixture.walletID
            )
        )
        #expect(
            freshQuoteSnapshot.transactions.first?.fiatValue
                == Decimal(string: "-3")
        )
    }

    @Test
    func positiveHoldingIsRevaluedEvenWhenActivityAlreadyHasFiat()
        async throws
    {
        let database = try WalletDatabase.temporary()
        let fixture = try await seedPolygonTransaction(database: database)
        try await database.pool.write { database in
            try database.execute(
                sql: """
                UPDATE accountAssets
                SET balance = '6.04222025', balanceAtomic = NULL,
                    fiatUSDValue = '0'
                WHERE accountID = ? AND assetID = ?
                """,
                arguments: [fixture.accountID, fixture.assetID]
            )
            try database.execute(
                sql: """
                UPDATE transactions
                SET fiatUSDValue = '2.5'
                WHERE id = ?
                """,
                arguments: [fixture.transactionID]
            )
        }

        #expect(
            try await database.assetsNeedingTransactionUSDPrices(
                walletID: fixture.walletID
            ).isEmpty
        )
        let candidates = try await database
            .walletAssetsRequiringUSDValuation(walletID: fixture.walletID)
        #expect(candidates.map(\.id) == [fixture.assetID])

        let price = try #require(Decimal(string: "1.6043266818147213"))
        #expect(
            try await database.applyAssetUSDPrices([
                fixture.assetID: price
            ]) == 1
        )
        let holdingFiat = try await database.pool.read { database in
            try DBAccountAssetRecord.fetchOne(
                database,
                key: [
                    "accountID": fixture.accountID,
                    "assetID": fixture.assetID
                ]
            )?.fiatUSDValue
        }
        #expect(holdingFiat == "9.693695164476215786966325")
    }

    @Test
    func priceFallbackUsesExactAssetIdentityInsteadOfSharedTicker() throws {
        let polygonUSDT =
            "polygon:0x0000000000000000000000000000000000000001"
        let ethereumUSDT =
            "eth:0x0000000000000000000000000000000000000001"
        let polygonTransaction = transaction(
            id: "polygon-usdt",
            networkID: "polygon",
            assetID: polygonUSDT,
            symbol: "USDT"
        )
        let ethereumTransaction = transaction(
            id: "ethereum-usdt",
            networkID: "eth",
            assetID: ethereumUSDT,
            symbol: "USDT"
        )
        let polygonPrice = try #require(Decimal(string: "1.0001"))

        let valuedPolygon =
            WalletDatabase.transactionByApplyingCachedUSDPrice(
                polygonTransaction,
                unitUSDPricesByAssetID: [polygonUSDT: polygonPrice]
            )
        let untouchedEthereum =
            WalletDatabase.transactionByApplyingCachedUSDPrice(
                ethereumTransaction,
                unitUSDPricesByAssetID: [polygonUSDT: polygonPrice]
            )

        #expect(valuedPolygon.fiatUSDValue == "10.001")
        #expect(untouchedEthereum.fiatUSDValue == nil)
    }

    @Test
    func unpricedTokenIsRetainedForPersistenceButNeverPresented() {
        let contract =
            "0x0000000000000000000000000000000000000001"
        let transaction = WalletTransaction(
            id: "unpriced-usdt",
            kind: .received(assetSymbol: "USDT"),
            detail: "",
            time: "",
            assetLogoSource: .catalogToken(
                blockchain: .ethereum,
                contractAddress: contract,
                logoURL: nil
            ),
            assetAmount: 10,
            assetSymbol: "USDT",
            fiatValue: nil,
            status: .confirmed
        )

        let snapshot = WalletHomeSnapshot(
            totalBalance: 0,
            assets: [],
            transactions: [transaction]
        )

        #expect(snapshot.transactions.isEmpty)
        #expect(snapshot.persistenceTransactions.map(\.id) == [transaction.id])
        #expect(snapshot.hasStoredActivity)
        #expect(
            WalletHomeUsagePolicy.isUsed(
                totalBalance: snapshot.totalBalance,
                hasStoredActivity: snapshot.hasStoredActivity
            )
        )
    }

    @Test
    func cachedUnpricedTokenActivityMarksZeroBalanceWalletUsed()
        async throws
    {
        try await assertCachedHiddenTokenActivityMarksWalletUsed(
            fixtureID: "unpriced",
            fiatUSDValue: nil
        )
    }

    @Test
    func cachedSubThresholdTokenActivityMarksZeroBalanceWalletUsed()
        async throws
    {
        try await assertCachedHiddenTokenActivityMarksWalletUsed(
            fixtureID: "sub-threshold",
            fiatUSDValue: "0.09"
        )
    }

    private func assertCachedHiddenTokenActivityMarksWalletUsed(
        fixtureID: String,
        fiatUSDValue: String?
    ) async throws {
        let database = try WalletDatabase.temporary()
        let walletID = "hidden-activity-\(fixtureID)-wallet"
        let accountID = "hidden-activity-\(fixtureID)-account"
        let assetID =
            "eth:0x0000000000000000000000000000000000000099"
        let now = Date().timeIntervalSince1970

        try await database.pool.write { database in
            try DBWalletRecord(
                id: walletID,
                profileID: WalletDatabase.defaultProfileID,
                name: "Hidden Activity Wallet",
                kind: DatabaseWalletKind.created.rawValue,
                secretKeyReference: nil,
                isSelected: false,
                sortOrder: 0,
                createdAt: now,
                updatedAt: now,
                lastOpenedAt: nil,
                archivedAt: nil
            ).insert(database)
            try DBWalletAccountRecord(
                id: accountID,
                walletID: walletID,
                networkID: "eth",
                address:
                    "0x71C7656EC7ab88b098defB751B7401B5f6d8976F",
                normalizedAddress:
                    "0x71c7656ec7ab88b098defb751b7401b5f6d8976f",
                label: nil,
                derivationPath: nil,
                accountIndex: nil,
                publicKey: nil,
                isWatchOnly: false,
                isEnabled: true,
                createdAt: now,
                updatedAt: now,
                lastSyncedAt: now
            ).insert(database)
            try DBAssetRecord(
                id: assetID,
                networkID: "eth",
                assetType: DatabaseAssetType.fungibleToken.rawValue,
                contractAddress:
                    "0x0000000000000000000000000000000000000099",
                normalizedContractAddress:
                    "0x0000000000000000000000000000000000000099",
                name: "Hidden Activity Token",
                symbol: "HIDE",
                decimals: 18,
                trustWalletBlockchain: "ethereum",
                trustWalletContractAddress:
                    "0x0000000000000000000000000000000000000099",
                isVerified: true,
                isSpam: false,
                createdAt: now,
                updatedAt: now,
                metadataUpdatedAt: now
            ).insert(database)
            try DBAccountAssetRecord(
                accountID: accountID,
                assetID: assetID,
                balance: "0",
                balanceAtomic: "0",
                fiatUSDValue: "0",
                isEnabled: true,
                isPinned: false,
                isHidden: false,
                sortOrder: 0,
                firstSeenAt: now,
                lastSeenAt: now,
                updatedAt: now
            ).insert(database)
            try transaction(
                id: "hidden-activity-\(fixtureID)-transaction",
                accountID: accountID,
                networkID: "eth",
                assetID: assetID,
                symbol: "HIDE",
                fiatUSDValue: fiatUSDValue,
                timestamp: now
            ).insert(database)
        }

        let snapshot = try #require(
            try await database.cachedWalletSnapshot(walletID: walletID)
        )

        #expect(snapshot.transactions.isEmpty)
        #expect(snapshot.hasStoredActivity)
        #expect(
            WalletHomeUsagePolicy.isUsed(
                totalBalance: snapshot.totalBalance,
                hasStoredActivity: snapshot.hasStoredActivity
            )
        )
    }

    private func seedPolygonTransaction(
        database: WalletDatabase
    ) async throws -> TransactionPriceFixture {
        let fixture = TransactionPriceFixture(
            walletID: "transaction-price-wallet",
            accountID: "transaction-price-polygon-account",
            assetID: "polygon:native",
            transactionID: "transaction-price-polygon-send",
            now: Date().timeIntervalSince1970
        )
        try await database.pool.write { database in
            try insertPolygonNativeAsset(
                in: database,
                now: fixture.now
            )
            let asset = try #require(
                try DBAssetRecord.fetchOne(
                    database,
                    key: fixture.assetID
                )
            )
            #expect(asset.networkID == "polygon")
            #expect(asset.assetType == DatabaseAssetType.native.rawValue)

            try DBWalletRecord(
                id: fixture.walletID,
                profileID: WalletDatabase.defaultProfileID,
                name: "Transaction Price Wallet",
                kind: DatabaseWalletKind.created.rawValue,
                secretKeyReference: nil,
                isSelected: false,
                sortOrder: 0,
                createdAt: fixture.now,
                updatedAt: fixture.now,
                lastOpenedAt: nil,
                archivedAt: nil
            ).insert(database)
            try DBWalletAccountRecord(
                id: fixture.accountID,
                walletID: fixture.walletID,
                networkID: "polygon",
                address:
                    "0x71C7656EC7ab88b098defB751B7401B5f6d8976F",
                normalizedAddress:
                    "0x71c7656ec7ab88b098defb751b7401b5f6d8976f",
                label: nil,
                derivationPath: nil,
                accountIndex: nil,
                publicKey: nil,
                isWatchOnly: false,
                isEnabled: true,
                createdAt: fixture.now,
                updatedAt: fixture.now,
                lastSyncedAt: fixture.now
            ).insert(database)
            try DBAccountAssetRecord(
                accountID: fixture.accountID,
                assetID: fixture.assetID,
                balance: "0",
                balanceAtomic: "0",
                fiatUSDValue: "0",
                isEnabled: true,
                isPinned: false,
                isHidden: false,
                sortOrder: 0,
                firstSeenAt: fixture.now,
                lastSeenAt: fixture.now,
                updatedAt: fixture.now
            ).insert(database)
            let transaction = transaction(
                id: fixture.transactionID,
                accountID: fixture.accountID,
                networkID: "polygon",
                assetID: fixture.assetID,
                symbol: "POL",
                amount: "-10",
                networkFee: "0.01",
                timestamp: fixture.now
            )
            try transaction.insert(database)
            try DBTransactionTransferRecord(
                id: "\(fixture.transactionID)|primary",
                transactionID: fixture.transactionID,
                logIndex: nil,
                assetID: fixture.assetID,
                fromAddress: nil,
                toAddress: nil,
                direction: "outgoing",
                amount: "-10",
                amountAtomic: nil,
                fiatUSDValue: nil,
                tokenName: "Polygon",
                tokenSymbol: "POL",
                tokenDecimals: 18
            ).insert(database)
        }
        return fixture
    }

    private func insertPolygonNativeAsset(
        in database: Database,
        now: Double
    ) throws {
        guard try DBAssetRecord.fetchOne(
            database,
            key: "polygon:native"
        ) == nil else { return }
        try DBAssetRecord(
            id: "polygon:native",
            networkID: "polygon",
            assetType: DatabaseAssetType.native.rawValue,
            contractAddress: "",
            normalizedContractAddress: "",
            name: "Polygon",
            symbol: "POL",
            decimals: 18,
            trustWalletBlockchain: WalletBlockchain.polygon.rawValue,
            trustWalletContractAddress: nil,
            isVerified: true,
            isSpam: false,
            createdAt: now,
            updatedAt: now,
            metadataUpdatedAt: now
        ).insert(database)
    }

    private func transaction(
        id: String,
        accountID: String = "account",
        networkID: String,
        assetID: String,
        symbol: String,
        amount: String = "10",
        fiatUSDValue: String? = nil,
        networkFee: String? = nil,
        timestamp: Double = 0
    ) -> DBTransactionRecord {
        DBTransactionRecord(
            id: id,
            accountID: accountID,
            networkID: networkID,
            transactionHash: "0x\(id)",
            normalizedTransactionHash: "0x\(id)",
            kind: "sent",
            status: "confirmed",
            direction: "outgoing",
            fromAddress: nil,
            toAddress: nil,
            counterpartyAddress: nil,
            blockNumber: 1,
            blockHash: nil,
            transactionIndex: nil,
            nonce: nil,
            transactionType: nil,
            timestamp: timestamp,
            assetID: assetID,
            assetSymbol: symbol,
            secondaryAssetSymbol: nil,
            assetAmount: amount,
            fiatUSDValue: fiatUSDValue,
            networkFee: networkFee,
            networkFeeFiatUSDValue: nil,
            networkFeeSymbol: symbol,
            gasPriceGwei: nil,
            gasLimit: nil,
            gasUsed: nil,
            inputData: nil,
            methodName: nil,
            displayDetail: "",
            displayTime: "",
            firstSeenAt: timestamp,
            updatedAt: timestamp
        )
    }
}

@Suite("Transaction explorer routes")
struct WalletTransactionExplorerTests {
    @Test
    func everySupportedNetworkBuildsItsMainnetTransactionURL() throws {
        let hash = "0xabc123"
        let expectedURLsByNetworkID = [
            "aptos":
                "https://explorer.aptoslabs.com/txn/0xabc123?network=mainnet",
            "stellar":
                "https://stellar.expert/explorer/public/tx/0xabc123",
            "near": "https://nearblocks.io/txns/0xabc123",
            "xrp": "https://livenet.xrpl.org/transactions/0xabc123",
            "sui": "https://suiscan.xyz/mainnet/tx/0xabc123",
            "ton": "https://tonviewer.com/transaction/0xabc123",
            "tron": "https://tronscan.org/#/transaction/0xabc123",
            "solana": "https://explorer.solana.com/tx/0xabc123",
            "bitcoin": "https://mempool.space/tx/0xabc123",
            "bitcoin_cash":
                "https://blockchair.com/bitcoin-cash/transaction/0xabc123",
            "litecoin": "https://litecoinspace.org/tx/0xabc123",
            "dogecoin": "https://dogechain.info/tx/0xabc123",
            "eth": "https://etherscan.io/tx/0xabc123",
            "bsc": "https://bscscan.com/tx/0xabc123",
            "polygon": "https://polygonscan.com/tx/0xabc123",
            "arbitrum": "https://arbiscan.io/tx/0xabc123",
            "avalanche": "https://snowtrace.io/tx/0xabc123?chainid=43114",
            "optimism": "https://optimistic.etherscan.io/tx/0xabc123",
            "base": "https://basescan.org/tx/0xabc123",
            "gnosis": "https://gnosisscan.io/tx/0xabc123",
            "scroll": "https://scrollscan.com/tx/0xabc123",
            "linea": "https://lineascan.build/tx/0xabc123",
            "taiko": "https://taikoscan.io/tx/0xabc123",
            "telos": "https://www.teloscan.io/tx/0xabc123",
            "xlayer": "https://www.oklink.com/xlayer/tx/0xabc123"
        ]
        let supportedNetworkIDs = Set(
            AssetNetworkSelectorOption.allSupported.map(\.id)
        )

        #expect(supportedNetworkIDs == Set(expectedURLsByNetworkID.keys))
        for (networkID, expectedURL) in expectedURLsByNetworkID {
            let url = try #require(
                WalletTransactionExplorer.url(
                    transactionHash: hash,
                    networkID: networkID
                )
            )
            #expect(url.absoluteString == expectedURL)
        }
    }

    @Test
    func aliasesResolveButMissingOrUnsafeEvidenceDoesNot() {
        #expect(
            WalletTransactionExplorer.url(
                transactionHash: "0xabc123",
                networkID: "ethereum"
            )?.absoluteString == "https://etherscan.io/tx/0xabc123"
        )
        #expect(
            WalletTransactionExplorer.url(
                transactionHash: nil,
                networkID: "eth"
            ) == nil
        )
        #expect(
            WalletTransactionExplorer.url(
                transactionHash: "  ",
                networkID: "eth"
            ) == nil
        )
        #expect(
            WalletTransactionExplorer.url(
                transactionHash: "0xabc?network=testnet",
                networkID: "aptos"
            ) == nil
        )
        #expect(
            WalletTransactionExplorer.url(
                transactionHash: "0xabc123",
                networkID: "unsupported"
            ) == nil
        )
    }

    @Test
    func base64HashRemainsOneEncodedPathComponent() throws {
        let url = try #require(
            WalletTransactionExplorer.url(
                transactionHash: "Ab+/cd==",
                networkID: "ton"
            )
        )

        #expect(
            url.absoluteString
                == "https://tonviewer.com/transaction/Ab%2B%2Fcd%3D%3D"
        )
    }

    @Test
    func copiedTransactionIDIncludesItsMainnetExplorerURL() {
        #expect(
            WalletTransactionExplorer.copyPayload(
                transactionHash: "  0xabc123  ",
                networkID: "eth"
            ) == "0xabc123\nhttps://etherscan.io/tx/0xabc123"
        )
        #expect(
            WalletTransactionExplorer.copyPayload(
                transactionHash: "0xabc123",
                networkID: "unsupported"
            ) == nil
        )
    }
}

private struct TransactionPriceFixture {
    let walletID: String
    let accountID: String
    let assetID: String
    let transactionID: String
    let now: Double
}

private final class AssetPriceFallbackURLProtocol: URLProtocol,
    @unchecked Sendable
{
    private static let lock = NSLock()
    nonisolated(unsafe) private static var paths: [String] = []
    nonisolated(unsafe) private static var rejectsAllRequests = false

    static func reset(rejectAllRequests: Bool = false) {
        lock.lock()
        paths = []
        rejectsAllRequests = rejectAllRequests
        lock.unlock()
    }

    static func requestedPaths() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return paths
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host != nil
    }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.badURL)
            )
            return
        }
        Self.lock.lock()
        Self.paths.append(url.path)
        let rejectsAllRequests = Self.rejectsAllRequests
        Self.lock.unlock()

        let isMarketFallback = !rejectsAllRequests
            && url.path == "/api/v3/simple/price"
        let statusCode = isMarketFallback ? 200 : 503
        let body = isMarketFallback
            ? #"{"wrapped-near":{"usd":1.6043266818147213}}"#
            : #"{"error":"contract route unavailable"}"#
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(
            self,
            didLoad: Data(body.utf8)
        )
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

extension TransactionFiatValuationTests {
    @Test(arguments: [true, false])
    func walletValuationPublishesBeforeSlowProviderAndHistory(cached: Bool) async throws {
        let database = try WalletDatabase.temporary()
        let fixture = try await seedPolygonTransaction(database: database)
        try await database.pool.write { db in
            try db.execute(sql: "UPDATE accountAssets SET balance = '4', balanceAtomic = NULL, fiatUSDValue = '0' WHERE accountID = ? AND assetID = ?", arguments: [fixture.accountID, fixture.assetID])
        }
        if cached {
            try await database.saveAssetUSDPrice(.init(assetID: fixture.assetID, price: 2, provider: "coinbase", observedAt: Date().addingTimeInterval(-86400)))
            // Simulates a later balance provider replacing its fiat field with zero.
            try await database.pool.write { db in
                try db.execute(sql: "UPDATE accountAssets SET fiatUSDValue = '0' WHERE accountID = ?", arguments: [fixture.accountID])
            }
            #expect(try await database.cachedWalletPortfolioSlice(walletID: fixture.walletID)?.totalBalance == 8)
        }
        let held = WalletAsset(id: fixture.assetID, name: "Polygon", symbol: "POL", logoSource: .nativeCoin(blockchain: .polygon), network: .polygon, balance: 4, fiatValue: 0)
        let slow = WalletAsset(id: "eth:native", name: "Ethereum", symbol: "ETH", logoSource: .nativeCoin(blockchain: .ethereum), network: .ethereum, balance: 0, fiatValue: 0)
        let release = AsyncStream<Void>.makeStream()
        let published = WalletValuationPublicationProbe()
        let work = Task {
            await WalletAssetPriceRefresh.refresh(database: database, assets: [held, slow], quoteProvider: { asset in
                if cached || asset.id == slow.id {
                    for await _ in release.stream {}
                    throw AssetPriceError.unavailable
                }
                return AssetUSDPrice(assetID: asset.id, price: 2, provider: "coinbase", observedAt: Date())
            }, onValuation: {
                if let snapshot = try? await database.cachedWalletPortfolioSlice(walletID: fixture.walletID) {
                    await published.append(snapshot.totalBalance)
                }
            })
        }
        for _ in 0..<100 {
            if await published.values.contains(8) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await published.values.contains(8))
        release.continuation.finish()
        await work.value
        #expect(try await database.cachedWalletPortfolioSlice(walletID: fixture.walletID)?.totalBalance == 8)
    }

    @Test(arguments: ["USD", "EUR", "GBP", "JPY", "SAR"])
    func zeroAndUnpricedHoldingsUseSelectedCurrency(code: String) {
        let currency = WalletCurrencyContext(code: code, ratePerUSD: 2)
        let expected = EnglishNumbers.currency(0, using: currency)
        #expect(expected.hasSuffix("0.00"))
        if code == "USD" { #expect(expected == "$0.00") }
        if code == "EUR" { #expect(expected == "€0.00") }
        if code == "GBP" { #expect(expected == "£0.00") }
        for balance: Decimal in [0, 1, 100] {
            let asset = WalletAsset(id: "eth:native", name: "Ethereum", symbol: "ETH", logoSource: .nativeCoin(blockchain: .ethereum), network: .ethereum, balance: balance, fiatValue: 0)
            #expect(asset.formattedWalletFiat(using: currency) == expected)
            // A display fallback must not alter quantities or invent a quote.
            #expect(asset.balance == balance)
            #expect(asset.fiatValue == 0)
        }
    }

    @Test func mixedHoldingsKeepTheirPricedTotalAndDisplayUnpricedAsZero() {
        let currency = WalletCurrencyContext(code: "EUR", ratePerUSD: 2)
        let priced = WalletAsset(id: "eth:native", name: "Ethereum", symbol: "ETH", logoSource: .nativeCoin(blockchain: .ethereum), network: .ethereum, balance: 1, fiatValue: 125)
        let unpriced = WalletAsset(id: "token", name: "Token", symbol: "TOKEN", logoSource: .unavailable, network: .ethereum, balance: 100, fiatValue: 0)
        let snapshot = WalletHomeSnapshot(totalBalance: 125, assets: [priced, unpriced], transactions: [])
        #expect(EnglishNumbers.currency(snapshot.totalBalance, using: currency) == "€250.00")
        #expect(priced.formattedWalletFiat(using: currency) == "€250.00")
        #expect(unpriced.formattedWalletFiat(using: currency) == "€0.00")
    }

    @Test func emptyAndUnpricedPortfoliosBothDisplayZero() {
        let currency = WalletCurrencyContext(code: "USD", ratePerUSD: 1)
        let unpriced = WalletAsset(id: "eth:native", name: "Ethereum", symbol: "ETH", logoSource: .nativeCoin(blockchain: .ethereum), network: .ethereum, balance: 1, fiatValue: 0)
        for assets in [[], [unpriced]] {
            let snapshot = WalletHomeSnapshot(totalBalance: 0, assets: assets, transactions: [])
            #expect(EnglishNumbers.currency(snapshot.totalBalance, using: currency) == "$0.00")
        }
    }

    @Test func positiveDustValueStillRemainsVisible() {
        let currency = WalletCurrencyContext(code: "USD", ratePerUSD: 1)
        let dust = WalletAsset(id: "eth:native", name: "Ethereum", symbol: "ETH", logoSource: .nativeCoin(blockchain: .ethereum), network: .ethereum, balance: 1, fiatValue: Decimal(string: "0.00001")!)
        #expect(dust.formattedWalletFiat(using: currency) == "< $0.01")
        #expect(EnglishNumbers.unitPrice(dust.fiatValue, using: currency) == "$0.00001000")
    }

}

private actor WalletValuationPublicationProbe {
    var values: [Decimal] = []
    func append(_ value: Decimal) { values.append(value) }
}
