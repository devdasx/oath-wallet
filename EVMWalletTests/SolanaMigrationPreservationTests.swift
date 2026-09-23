import GRDB
import Testing
@testable import Aperture

@Suite(.serialized)
struct SolanaMigrationPreservationTests {
    private let profileID = "migration-profile"
    private let walletID = "migration-wallet"
    private let accountID = "migration-solana-account"
    private let assetID = "migration-solana-asset"
    private let transactionID = "migration-solana-transaction"

    @Test
    func versionTwelveDoesNotMutateVersionElevenSolanaGraph() throws {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: configuration)
        let migrator = WalletDatabase.migrator

        try migrator.migrate(
            queue,
            upTo: "v11_trust_wallet_dogecoin_identity"
        )
        try queue.write(seedVersionElevenFixture)
        try migrator.migrate(
            queue,
            upTo: "v12_remove_solana_and_ton"
        )

        try queue.read { database in
            try verifyPreservedGraph(
                database,
                expectedProvider: "ankr-solana",
                expectedBalance: "7.5",
                expectedAtomicBalance: "7500000",
                expectedFiatValue: "15"
            )
            #expect(
                try rowCount(
                    database,
                    table: "networks",
                    predicate: "id = 'ton'"
                ) == 0
            )
        }
    }

    @Test
    func versionElevenSolanaGraphSurvivesCurrentMigration() throws {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: configuration)
        let migrator = WalletDatabase.migrator

        try migrator.migrate(
            queue,
            upTo: "v11_trust_wallet_dogecoin_identity"
        )
        try queue.write(seedVersionElevenFixture)
        try migrator.migrate(queue)

        try queue.read { database in
            try verifyPreservedGraph(
                database,
                expectedProvider: "ankr-solana-jsonrpc",
                expectedBalance: "0",
                expectedAtomicBalance: "0",
                expectedFiatValue: "0"
            )
            let applied = try migrator.appliedMigrations(database)
            #expect(applied.contains("v12_remove_solana_and_ton"))
            #expect(applied.contains("v14_reintroduce_solana_mainnet"))
            #expect(applied.contains("v31_reintroduce_ton_mainnet"))
            #expect(try database.tableExists("solanaSyncState"))
            #expect(
                try rowCount(
                    database,
                    table: "networks",
                    predicate: "id = 'ton'"
                ) == 1
            )
        }
    }

    private func seedVersionElevenFixture(_ database: Database) throws {
        try database.execute(
            sql: """
            INSERT INTO profiles (
                id, displayName, createdAt, updatedAt, lastActiveAt
            ) VALUES (
                'migration-profile', 'Migration Profile', 100, 101, 102
            );

            INSERT INTO wallets (
                id, profileID, name, kind, secretKeyReference,
                isSelected, sortOrder, createdAt, updatedAt,
                lastOpenedAt, archivedAt, backupState,
                backupVerifiedAt, mnemonicWordCount,
                iCloudBackupUpdatedAt
            ) VALUES (
                'migration-wallet', 'migration-profile',
                'Migration Wallet', 'created',
                'opaque-keychain-reference', 1, 7, 110, 111,
                112, NULL, 'verified', 113, 12, 114
            );

            UPDATE networks
            SET isEnabled = 0,
                sortOrder = 4242,
                createdAt = 120,
                updatedAt = 121
            WHERE id = 'solana';

            INSERT INTO walletAccounts (
                id, walletID, networkID, address, normalizedAddress,
                label, derivationPath, accountIndex, publicKey,
                isWatchOnly, isEnabled, createdAt, updatedAt,
                lastSyncedAt
            ) VALUES (
                'migration-solana-account', 'migration-wallet',
                'solana', 'fixture-solana-address',
                'fixture-solana-address', 'Primary Solana',
                'm/44''/501''/0''/0''', 0, 'fixture-public-key',
                0, 0, 130, 131, 132
            );

            INSERT INTO assets (
                id, networkID, assetType, contractAddress,
                normalizedContractAddress, name, symbol, decimals,
                trustWalletBlockchain, trustWalletContractAddress,
                isVerified, isSpam, createdAt, updatedAt,
                metadataUpdatedAt
            ) VALUES (
                'migration-solana-asset', 'solana',
                'fungibleToken', 'fixture-solana-mint',
                'fixture-solana-mint', 'Migration Token', 'MIG', 6,
                'solana', 'fixture-solana-mint',
                1, 0, 140, 141, 142
            );

            INSERT INTO accountAssets (
                accountID, assetID, balance, balanceAtomic,
                fiatUSDValue, isEnabled, isPinned, isHidden,
                sortOrder, firstSeenAt, lastSeenAt, updatedAt
            ) VALUES (
                'migration-solana-account', 'migration-solana-asset',
                '7.5', '7500000', '15', 0, 1, 1, 9,
                150, 151, 152
            );

            INSERT INTO assetPrices (
                assetID, quoteCurrency, price, provider,
                observedAt, expiresAt
            ) VALUES (
                'migration-solana-asset', 'USD', '2',
                'migration-provider', 160, 260
            );

            INSERT INTO marketSnapshots (
                assetID, quoteCurrency, provider, observedAt,
                marketCap, fullyDilutedValue, volume24Hours,
                change24HoursPercent, high24Hours, low24Hours,
                circulatingSupply, totalSupply, maximumSupply,
                marketRank
            ) VALUES (
                'migration-solana-asset', 'USD',
                'migration-provider', 161, '1000', '1200', '100',
                '1.5', '2.1', '1.9', '500', '600', '700', 42
            );

            INSERT INTO transactions (
                id, accountID, networkID, transactionHash,
                normalizedTransactionHash, kind, status, direction,
                fromAddress, toAddress, counterpartyAddress,
                blockNumber, blockHash, transactionIndex, nonce,
                transactionType, timestamp, assetID, assetSymbol,
                secondaryAssetSymbol, assetAmount, fiatUSDValue,
                networkFee, networkFeeFiatUSDValue, networkFeeSymbol,
                gasPriceGwei, gasLimit, gasUsed, inputData,
                methodName, displayDetail, displayTime,
                firstSeenAt, updatedAt
            ) VALUES (
                'migration-solana-transaction',
                'migration-solana-account', 'solana',
                'fixture-signature', 'fixture-signature',
                'received', 'confirmed', 'incoming',
                'fixture-sender', 'fixture-solana-address',
                'fixture-sender', 1000, 'fixture-block', 4, 5,
                6, 170, 'migration-solana-asset', 'MIG',
                NULL, '1.25', '2.5', '0.000005', '0.00001',
                'SOL', NULL, NULL, NULL, NULL, 'transfer',
                'Received MIG', 'Migration time', 171, 172
            );

            INSERT INTO transactionTransfers (
                id, transactionID, logIndex, assetID,
                fromAddress, toAddress, direction, amount,
                amountAtomic, fiatUSDValue, tokenName,
                tokenSymbol, tokenDecimals
            ) VALUES (
                'migration-solana-transfer',
                'migration-solana-transaction', 1,
                'migration-solana-asset', 'fixture-sender',
                'fixture-solana-address', 'incoming', '1.25',
                '1250000', '2.5', 'Migration Token', 'MIG', 6
            );

            INSERT INTO nftCollections (
                id, networkID, contractAddress,
                normalizedContractAddress, name, symbol,
                standard, imageURL, isVerified, isSpam, updatedAt
            ) VALUES (
                'migration-solana-collection', 'solana',
                'fixture-collection', 'fixture-collection',
                'Migration Collection', 'MC', 'erc721',
                'https://example.invalid/collection.png', 1, 0, 180
            );

            INSERT INTO nftItems (
                id, collectionID, tokenID, name, description,
                imageURL, animationURL, metadataURL,
                metadataJSON, updatedAt
            ) VALUES (
                'migration-solana-item',
                'migration-solana-collection', '1',
                'Migration NFT', 'Preserved NFT',
                'https://example.invalid/item.png', NULL,
                'https://example.invalid/item.json',
                X'7B7D', 181
            );

            INSERT INTO accountNFTHoldings (
                accountID, nftItemID, quantity, isHidden, lastSeenAt
            ) VALUES (
                'migration-solana-account',
                'migration-solana-item', '1', 1, 182
            );

            INSERT INTO contacts (
                id, profileID, name, note, createdAt, updatedAt
            ) VALUES (
                'migration-contact', 'migration-profile',
                'Migration Contact', 'Preserve note', 190, 191
            );

            INSERT INTO contactAddresses (
                id, contactID, networkID, address,
                normalizedAddress, label, isFavorite, createdAt
            ) VALUES (
                'migration-contact-address', 'migration-contact',
                'solana', 'fixture-contact-address',
                'fixture-contact-address', 'Solana', 1, 192
            );

            INSERT INTO connectedDApps (
                id, profileID, origin, name, iconURL, sessionTopic,
                createdAt, lastUsedAt, expiresAt
            ) VALUES (
                'migration-dapp', 'migration-profile',
                'https://example.invalid', 'Migration DApp',
                NULL, 'fixture-session', 200, 201, 300
            );

            INSERT INTO dappPermissions (
                dappID, accountID, method, chainID, grantedAt
            ) VALUES (
                'migration-dapp', 'migration-solana-account',
                'signTransaction', -501, 202
            );

            INSERT INTO priceAlerts (
                id, profileID, assetID, quoteCurrency, comparison,
                threshold, isEnabled, createdAt, lastTriggeredAt
            ) VALUES (
                'migration-alert', 'migration-profile',
                'migration-solana-asset', 'USD',
                'above', '3', 1, 210, 211
            );

            INSERT INTO notifications (
                id, profileID, category, titleKey, bodyKey,
                argumentsJSON, relatedTransactionID,
                createdAt, readAt, deliveredAt
            ) VALUES (
                'migration-notification', 'migration-profile',
                'transaction', 'notification.title',
                'notification.body', X'7B7D',
                'migration-solana-transaction', 220, 221, 222
            );

            INSERT INTO syncStates (
                accountID, resource, cursor, lastAttemptAt,
                lastSuccessAt, nextAllowedAt,
                consecutiveFailureCount, lastErrorCode
            ) VALUES (
                'migration-solana-account', 'history',
                'fixture-cursor', 230, 231, 232, 2,
                'fixture-error'
            );

            INSERT INTO pendingOperations (
                id, accountID, operationType, state, payload,
                idempotencyKey, retryCount, createdAt, updatedAt,
                nextRetryAt, lastErrorCode
            ) VALUES (
                'migration-operation', 'migration-solana-account',
                'send', 'draft', X'0102',
                'migration-idempotency', 1, 240, 241, 242,
                'fixture-error'
            );

            INSERT INTO tags (
                id, profileID, name, createdAt
            ) VALUES (
                'migration-tag', 'migration-profile',
                'Migration Tag', 250
            );

            INSERT INTO transactionTags (
                transactionID, tagID
            ) VALUES (
                'migration-solana-transaction', 'migration-tag'
            );
            """
        )
    }

    private func verifyPreservedGraph(
        _ database: Database,
        expectedProvider: String,
        expectedBalance: String,
        expectedAtomicBalance: String,
        expectedFiatValue: String
    ) throws {
        let fetchedNetwork = try Row.fetchOne(
            database,
            sql: "SELECT * FROM networks WHERE id = 'solana'"
        )
        let network = try #require(fetchedNetwork)
        let fetchedAccount = try Row.fetchOne(
            database,
            sql: "SELECT * FROM walletAccounts WHERE id = ?",
            arguments: [accountID]
        )
        let account = try #require(fetchedAccount)
        let fetchedHolding = try Row.fetchOne(
            database,
            sql: """
            SELECT *
            FROM accountAssets
            WHERE accountID = ? AND assetID = ?
            """,
            arguments: [accountID, assetID]
        )
        let holding = try #require(fetchedHolding)
        let fetchedAsset = try Row.fetchOne(
            database,
            sql: "SELECT * FROM assets WHERE id = ?",
            arguments: [assetID]
        )
        let asset = try #require(fetchedAsset)

        let networkEnabled: Bool = network["isEnabled"]
        let networkSortOrder: Int = network["sortOrder"]
        let networkCreatedAt: Double = network["createdAt"]
        let networkProvider: String = network["rpcProviderIdentifier"]
        #expect(!networkEnabled)
        #expect(networkSortOrder == 4242)
        #expect(networkCreatedAt == 120)
        #expect(networkProvider == expectedProvider)

        let accountLabel: String? = account["label"]
        let derivationPath: String? = account["derivationPath"]
        let publicKey: String? = account["publicKey"]
        let accountEnabled: Bool = account["isEnabled"]
        #expect(accountLabel == "Primary Solana")
        #expect(derivationPath == "m/44'/501'/0'/0'")
        #expect(publicKey == "fixture-public-key")
        #expect(!accountEnabled)

        let assetName: String = asset["name"]
        let assetSymbol: String = asset["symbol"]
        let contract: String = asset["contractAddress"]
        let decimals: Int? = asset["decimals"]
        #expect(assetName == "Migration Token")
        #expect(assetSymbol == "MIG")
        #expect(contract == "fixture-solana-mint")
        #expect(decimals == 6)

        let balance: String = holding["balance"]
        let atomicBalance: String? = holding["balanceAtomic"]
        let fiatValue: String? = holding["fiatUSDValue"]
        let isEnabled: Bool = holding["isEnabled"]
        let isPinned: Bool = holding["isPinned"]
        let isHidden: Bool = holding["isHidden"]
        let sortOrder: Int? = holding["sortOrder"]
        #expect(balance == expectedBalance)
        #expect(atomicBalance == expectedAtomicBalance)
        #expect(fiatValue == expectedFiatValue)
        #expect(!isEnabled)
        #expect(isPinned)
        #expect(isHidden)
        #expect(sortOrder == 9)

        let preservedRows: [(String, String)] = [
            ("assetPrices", "assetID = 'migration-solana-asset'"),
            ("marketSnapshots", "assetID = 'migration-solana-asset'"),
            ("transactions", "id = 'migration-solana-transaction'"),
            (
                "transactionTransfers",
                "id = 'migration-solana-transfer'"
            ),
            (
                "nftCollections",
                "id = 'migration-solana-collection'"
            ),
            ("nftItems", "id = 'migration-solana-item'"),
            (
                "accountNFTHoldings",
                "accountID = 'migration-solana-account'"
            ),
            (
                "contactAddresses",
                "id = 'migration-contact-address'"
            ),
            (
                "dappPermissions",
                "accountID = 'migration-solana-account'"
            ),
            ("priceAlerts", "id = 'migration-alert'"),
            ("notifications", "id = 'migration-notification'"),
            (
                "syncStates",
                "accountID = 'migration-solana-account'"
            ),
            ("pendingOperations", "id = 'migration-operation'"),
            (
                "transactionTags",
                "transactionID = 'migration-solana-transaction'"
            )
        ]
        for (table, predicate) in preservedRows {
            #expect(
                try rowCount(
                    database,
                    table: table,
                    predicate: predicate
                ) == 1
            )
        }
    }

    private func rowCount(
        _ database: Database,
        table: String,
        predicate: String
    ) throws -> Int {
        try Int.fetchOne(
            database,
            sql: "SELECT COUNT(*) FROM \(table) WHERE \(predicate)"
        ) ?? 0
    }
}
