import Foundation
import GRDB
import Testing
@testable import Aperture

@Suite(.serialized)
struct WalletUniversalSearchTests {
    private let ethereumUSDTContract =
        "0xdac17f958d2ee523a2206206994597c13d831ec7"

    @Test
    func localIndexFindsAssetsByIdentityAndQualifiedNetwork() async {
        let usdt = WalletAsset(
            id: AssetIdentityKey.make(
                networkID: "eth",
                contractAddress: ethereumUSDTContract
            ),
            name: "Tether USD",
            symbol: "USDT",
            logoSource: .catalogToken(
                blockchain: .ethereum,
                contractAddress: ethereumUSDTContract,
                logoURL: nil
            ),
            network: .ethereum,
            balance: 0,
            fiatValue: 0
        )
        let index = await WalletUniversalSearchIndex.make(
            assets: [usdt],
            transactions: [],
            wallets: [],
            unitUSDPricesByAssetID: [usdt.id: 1]
        )

        for query in [
            "USDT",
            "Tether USD",
            ethereumUSDTContract,
            "USDT ETH",
            "Tether USD Ethereum"
        ] {
            #expect(
                index.localResults(matching: query).assets.map(\.id)
                    == [usdt.id],
                "Universal asset lookup failed for \(query)"
            )
        }
        #expect(index.unitUSDPrice(for: usdt) == 1)
        #expect(
            index.localResults(matching: "1")
                .assets.map(\.id) == [usdt.id]
        )
    }

    @Test
    func hiddenAssetSearchResultPreservesPortfolioVisibility()
        async throws
    {
        let walletAddress =
            "0x0000000000000000000000000000000000000001"
        let usdt = WalletAsset(
            id: AssetIdentityKey.make(
                networkID: "eth",
                contractAddress: ethereumUSDTContract
            ),
            name: "Tether USD",
            symbol: "USDT",
            logoSource: .catalogToken(
                blockchain: .ethereum,
                contractAddress: ethereumUSDTContract,
                logoURL: nil
            ),
            network: .ethereum,
            balance: 1,
            fiatValue: 1
        )
        let hiddenPreferences = try #require(
            WalletHomeAssetVisibility.updatedPreferencesJSON(
                setting: false,
                for: usdt,
                walletAddress: walletAddress,
                preferencesJSON: ""
            )
        )
        let index = await WalletUniversalSearchIndex.make(
            assets: [usdt],
            transactions: [],
            wallets: []
        )

        let result = try #require(
            index.localResults(matching: "USDT").assets.first
        )

        #expect(result.id == usdt.id)
        #expect(
            WalletHomeAssetVisibility.visibleAssetIDs(
                from: [usdt],
                transactions: [],
                walletAddress: walletAddress,
                preferencesJSON: hiddenPreferences
            ).isEmpty
        )
    }

    @Test
    func localIndexFindsWalletsNetworksActionsAndSettings() async {
        let wallet = ManagedWallet(
            id: "search-wallet",
            name: "Travel Wallet",
            kind: .watchOnly,
            address: "0x0000000000000000000000000000000000000042",
            fiatUSDBalance: 0,
            isSelected: true,
            notificationsEnabledWhenInactive: false,
            backupState: .notVerified,
            backupVerifiedAt: nil,
            iCloudBackupUpdatedAt: nil,
            mnemonicWordCount: nil,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let index = await WalletUniversalSearchIndex.make(
            assets: [],
            transactions: [],
            wallets: [wallet]
        )

        #expect(
            index.localResults(matching: "Travel Wallet")
                .wallets.map(\.id) == [wallet.id]
        )
        #expect(
            index.localResults(matching: wallet.address)
                .wallets.map(\.id) == [wallet.id]
        )
        #expect(
            index.localResults(matching: "Ethereum")
                .networks.contains { $0.id == "eth" }
        )
        #expect(
            index.localResults(matching: "Face ID")
                .actions.contains { $0.action == .settings(.security) }
        )
        #expect(
            index.localResults(matching: "Notifications")
                .actions.contains {
                    $0.action == .settings(.notifications)
                }
        )
        #expect(
            index.localResults(matching: "transaction history")
                .actions.contains { $0.action == .allActivity }
        )
    }

    @Test
    func bitcoinCashNetworkResultUsesDisplayNameAndOfficialLogo() throws {
        let network = try #require(
            AssetNetworkSelectorOption.allSupported.first {
                $0.id == "bitcoin_cash"
            }
        )
        let title = WalletUniversalSearchNetworkPresentation.title(
            for: network
        )
        let englishFormat = WalletAppLanguage.localizedBundle(
            for: "en"
        ).localizedString(
            forKey: "wallet.search.network.subtitle",
            value: "",
            table: nil
        )

        #expect(title.contains(network.localizedName))
        #expect(!title.contains(network.id))
        #expect(network.officialLogoAssetName == "NetworkLogoBitcoinCash")
        #expect(
            String(format: englishFormat, network.localizedName)
                == "Bitcoin Cash Blockchain Network"
        )
    }

    @Test
    func quickActionsUseSendReceiveAndScanWithoutAddFunds() async {
        let index = await WalletUniversalSearchIndex.make(
            assets: [],
            transactions: [],
            wallets: []
        )

        let suggestions = index.suggestions()
        #expect(
            suggestions.actions.map(\.action)
                == [.send, .receive, .scan, .allAssets]
        )
        #expect(
            suggestions.actions.allSatisfy {
                $0.titleKey != "wallet.home.action.add_funds"
            }
        )
        #expect(
            index.localResults(matching: "incoming transfers")
                .actions.contains { $0.action == .receive }
        )
    }

    @Test
    func suggestionsExposeFeaturesSettingsAndMajorMarketAssets() async {
        let blockchains: [WalletBlockchain] = [
            .smartchain,
            .solana,
            .ethereum,
            .bitcoin
        ]
        let assets = blockchains.map { blockchain in
            WalletAsset(
                id: "market:\(blockchain.rawValue)",
                name: "Market \(blockchain.rawValue)",
                symbol: "MKT",
                logoSource: .nativeCoin(blockchain: blockchain),
                network: blockchain,
                balance: 0,
                fiatValue: 0
            )
        }
        let index = await WalletUniversalSearchIndex.make(
            assets: assets,
            transactions: [],
            wallets: []
        )

        let suggestions = index.suggestions()
        #expect(
            suggestions.features.map(\.action) == [
                .manageAssets,
                .allActivity,
                .walletSwitcher,
                .settings(.root)
            ]
        )
        #expect(
            suggestions.settings.map(\.action) == [
                .settings(.security),
                .settings(.appearance),
                .settings(.language),
                .settings(.currency),
                .settings(.notifications)
            ]
        )
        #expect(
            suggestions.marketAssets.compactMap(\.network) == [
                .bitcoin,
                .ethereum,
                .solana,
                .smartchain
            ]
        )
    }

    @Test
    func transactionFTSQueryIsPrefixBoundedAndInjectionSafe() {
        #expect(
            WalletDatabase.universalSearchFTSQuery(
                "Tether USD Ethereum"
            ) == "\"tether\"* AND \"usd\"* AND \"ethereum\"*"
        )
        #expect(
            WalletDatabase.universalSearchFTSQuery(
                "\" OR transactionSearchIndex MATCH \""
            )
                == "\"or\"* AND \"transactionsearchindex\"* "
                    + "AND \"match\"*"
        )
        #expect(
            WalletDatabase.universalSearchFTSQuery("  !!!  ") == nil
        )

        let tooManyTerms = (1...20)
            .map { "term\($0)" }
            .joined(separator: " ")
        let bounded = WalletDatabase.universalSearchFTSQuery(tooManyTerms)
        #expect(bounded?.components(separatedBy: " AND ").count == 12)
    }

    @Test
    func transactionIndexSearchesHistoryAndExcludesCalldata()
        async throws
    {
        let database = try WalletDatabase.temporary()
        let fixture = try await seedSearchableTransaction(
            database: database
        )

        for query in [
            fixture.transactionHash,
            fixture.counterparty,
            "monthly rent",
            "Polygon POL"
        ] {
            let results = try await database
                .universalSearchTransactions(matching: query)
            #expect(
                results.map(\.id) == [fixture.transactionID],
                "Transaction history lookup failed for \(query)"
            )
        }

        let sensitiveResults = try await database
            .universalSearchTransactions(
                matching: fixture.sensitiveCalldataMarker
            )
        #expect(sensitiveResults.isEmpty)
    }

    @Test
    func indexedLookupStaysBoundedAsCatalogGrows() async {
        let assets = (0..<500).map { index in
            WalletAsset(
                id: "eth:0x\(String(format: "%040x", index + 1))",
                name: "Indexed Token \(index)",
                symbol: "IDX\(index)",
                logoSource: .unavailable,
                network: .ethereum,
                balance: Decimal(index),
                fiatValue: Decimal(index) / 10
            )
        }

        let buildStart = DispatchTime.now().uptimeNanoseconds
        let index = await WalletUniversalSearchIndex.make(
            assets: assets,
            transactions: [],
            wallets: []
        )
        let buildMilliseconds = elapsedMilliseconds(since: buildStart)

        let lookupStart = DispatchTime.now().uptimeNanoseconds
        for value in 0..<100 {
            _ = index.localResults(matching: "IDX\(value)")
        }
        let lookupMilliseconds = elapsedMilliseconds(since: lookupStart)

        #expect(buildMilliseconds < 2_000)
        #expect(lookupMilliseconds < 1_000)
        #expect(
            index.localResults(matching: "IDX499")
                .assets.first?.symbol == "IDX499"
        )
    }

    @Test
    func preparationRevisionTracksEqualCountContentMutations() {
        let originalContentRevision = UUID()
        let originalDatabaseRevision = UUID()
        let original = preparationRequest(
            contentRevision: originalContentRevision,
            databaseDependenciesRevision: originalDatabaseRevision
        )
        let renamedCurrentWallet = preparationRequest(
            walletName: "Renamed Primary Wallet",
            contentRevision: originalContentRevision,
            databaseDependenciesRevision: originalDatabaseRevision
        )
        let updatedSnapshot = preparationRequest(
            contentRevision: UUID(),
            databaseDependenciesRevision: originalDatabaseRevision
        )
        let updatedDatabaseDependencies = preparationRequest(
            contentRevision: originalContentRevision,
            databaseDependenciesRevision: UUID()
        )
        for mutation in [
            renamedCurrentWallet,
            updatedSnapshot,
            updatedDatabaseDependencies
        ] {
            #expect(original != mutation)
        }
    }

    @Test
    func databaseDependenciesObserveWalletAndPriceChanges()
        async throws
    {
        let database = try WalletDatabase.temporary()
        let fixture = try await seedSearchableTransaction(
            database: database
        )
        let values = database.universalSearchDatabaseDependencies(
            assetIDs: [fixture.assetID]
        )
        var iterator = values.makeAsyncIterator()
        let initial = try #require(try await iterator.next())
        let now = Date().timeIntervalSince1970

        try await database.pool.write { database in
            var wallet = try #require(
                try DBWalletRecord.fetchOne(
                    database,
                    key: fixture.walletID
                )
            )
            wallet.name = "Renamed Universal Search Wallet"
            wallet.updatedAt = now
            try wallet.update(database)
            try DBAssetPriceRecord(
                assetID: fixture.assetID,
                quoteCurrency: "USD",
                price: "7.5",
                provider: "search-revision-test",
                observedAt: now,
                expiresAt: now + 300
            ).insert(database)
        }

        let updated = try #require(try await iterator.next())

        #expect(
            initial.wallets.first?.name
                != updated.wallets.first?.name
        )
        #expect(
            updated.wallets.first?.name
                == "Renamed Universal Search Wallet"
        )
        #expect(
            updated.unitUSDPricesByAssetID[fixture.assetID]
                == Decimal(string: "7.5")
        )
    }

    private func preparationRequest(
        walletName: String = "Primary Wallet",
        contentRevision: UUID,
        databaseDependenciesRevision: UUID
    ) -> UniversalSearchPreparationRequest {
        return UniversalSearchPreparationRequest(
            walletName: walletName,
            walletAddress:
                "0x0000000000000000000000000000000000000001",
            languageIdentifier: "en",
            contentRevision: contentRevision,
            databaseDependenciesRevision:
                databaseDependenciesRevision
        )
    }

    @Test
    func financialEnrichmentDoesNotRewriteSearchDocuments() async throws {
        let database = try WalletDatabase.temporary()
        let fixture = try await seedSearchableTransaction(database: database)
        try await database.pool.write { db in
            let before = try String.fetchOne(db, sql: "SELECT body FROM transactionSearchIndex WHERE transactionID = ?", arguments: [fixture.transactionID])
            var record = try #require(try DBTransactionRecord.fetchOne(db, key: fixture.transactionID))
            record.fiatUSDValue = "-2.1234567890123456789"
            record.networkFeeFiatUSDValue = "0.001234567890123456789"
            record.updatedAt += 1
            let changes = try #require(try Int.fetchOne(db, sql: "SELECT total_changes()"))
            try record.update(db)
            let afterChanges = try #require(try Int.fetchOne(db, sql: "SELECT total_changes()"))
            #expect(afterChanges - changes == 1)
            #expect(try String.fetchOne(db, sql: "SELECT body FROM transactionSearchIndex WHERE transactionID = ?", arguments: [fixture.transactionID]) == before)
            let saved = try #require(try DBTransactionRecord.fetchOne(db, key: fixture.transactionID))
            #expect(saved.fiatUSDValue == record.fiatUSDValue)
            #expect(saved.networkFeeFiatUSDValue == record.networkFeeFiatUSDValue)
        }
    }

    @Test
    func searchTriggersStillTrackStatusAssetNetworkAndNotes() async throws {
        let database = try WalletDatabase.temporary()
        let fixture = try await seedSearchableTransaction(database: database)
        try await database.pool.write { db in
            func body() throws -> String {
                try #require(try String.fetchOne(db, sql: "SELECT body FROM transactionSearchIndex WHERE transactionID = ?", arguments: [fixture.transactionID]))
            }
            try db.execute(sql: "UPDATE transactions SET status = 'failed', methodName = NULL WHERE id = ?", arguments: [fixture.transactionID])
            #expect(try body().contains("failed"))
            #expect(try body().contains("Monthly rent"))
            try db.execute(sql: "UPDATE assets SET name = 'Renamed Asset' WHERE id = ?", arguments: [fixture.assetID])
            #expect(try body().contains("Renamed Asset"))
            #expect(try body().contains("Monthly rent"))
            try db.execute(sql: "UPDATE networks SET nativeSymbol = 'NEW' WHERE id = 'polygon'")
            #expect(try body().contains("NEW"))
            try db.execute(sql: "UPDATE transactionNotes SET note = 'Updated memo' WHERE transactionID = ?", arguments: [fixture.transactionID])
            #expect(try body().contains("Updated memo"))
            #expect(try !body().contains("Monthly rent"))
            try db.execute(sql: "DELETE FROM transactionNotes WHERE transactionID = ?", arguments: [fixture.transactionID])
            #expect(try !body().contains("Updated memo"))
            #expect(try body().contains("Renamed Asset"))
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transactionSearchIndex WHERE transactionID = ?", arguments: [fixture.transactionID]) == 1)
            try db.execute(sql: "DELETE FROM transactions WHERE id = ?", arguments: [fixture.transactionID])
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transactionSearchIndex WHERE transactionID = ?", arguments: [fixture.transactionID]) == 0)
        }
    }

    private func seedSearchableTransaction(
        database: WalletDatabase
    ) async throws -> TransactionSearchFixture {
        let now = Date().timeIntervalSince1970
        let fixture = TransactionSearchFixture(
            walletID: "universal-search-wallet",
            accountID: "universal-search-polygon-account",
            assetID: "polygon:native",
            transactionID: "universal-search-transaction",
            transactionHash:
                "0x4f7de33803e9c84880dd9d14b0d19d22d1774c42",
            counterparty:
                "0x1111111111111111111111111111111111111111",
            sensitiveCalldataMarker: "sensitivecalldatamarker"
        )

        try await database.pool.write { database in
            try DBWalletRecord(
                id: fixture.walletID,
                profileID: WalletDatabase.defaultProfileID,
                name: "Universal Search Wallet",
                kind: DatabaseWalletKind.created.rawValue,
                secretKeyReference: nil,
                isSelected: true,
                sortOrder: 0,
                createdAt: now,
                updatedAt: now,
                lastOpenedAt: now,
                archivedAt: nil
            ).insert(database)
            try DBWalletAccountRecord(
                id: fixture.accountID,
                walletID: fixture.walletID,
                networkID: "polygon",
                address:
                    "0x2222222222222222222222222222222222222222",
                normalizedAddress:
                    "0x2222222222222222222222222222222222222222",
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
                id: fixture.assetID,
                networkID: "polygon",
                assetType: DatabaseAssetType.native.rawValue,
                contractAddress: "",
                normalizedContractAddress: "",
                name: "Polygon",
                symbol: "POL",
                decimals: 18,
                trustWalletBlockchain: "polygon",
                trustWalletContractAddress: nil,
                isVerified: true,
                isSpam: false,
                createdAt: now,
                updatedAt: now,
                metadataUpdatedAt: now
            ).save(database)
            try DBTransactionRecord(
                id: fixture.transactionID,
                accountID: fixture.accountID,
                networkID: "polygon",
                transactionHash: fixture.transactionHash,
                normalizedTransactionHash:
                    fixture.transactionHash.lowercased(),
                kind: "sent",
                status: "confirmed",
                direction: "outgoing",
                fromAddress:
                    "0x2222222222222222222222222222222222222222",
                toAddress: fixture.counterparty,
                counterpartyAddress: fixture.counterparty,
                blockNumber: 42,
                blockHash: nil,
                transactionIndex: nil,
                nonce: 1,
                transactionType: 2,
                timestamp: now,
                assetID: fixture.assetID,
                assetSymbol: "POL",
                secondaryAssetSymbol: nil,
                assetAmount: "-2",
                fiatUSDValue: "-1",
                networkFee: "0.01",
                networkFeeFiatUSDValue: "0.005",
                networkFeeSymbol: "POL",
                gasPriceGwei: "30",
                gasLimit: 21_000,
                gasUsed: 21_000,
                inputData: fixture.sensitiveCalldataMarker,
                methodName: "transfer",
                displayDetail: "Sent to rent account",
                displayTime: "Yesterday",
                firstSeenAt: now,
                updatedAt: now
            ).insert(database)
            try DBTransactionNoteRecord(
                transactionID: fixture.transactionID,
                note: "Monthly rent",
                createdAt: now,
                updatedAt: now
            ).insert(database)
        }
        return fixture
    }

    private func elapsedMilliseconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start)
            / 1_000_000
    }
}

private struct TransactionSearchFixture {
    let walletID: String
    let accountID: String
    let assetID: String
    let transactionID: String
    let transactionHash: String
    let counterparty: String
    let sensitiveCalldataMarker: String
}
