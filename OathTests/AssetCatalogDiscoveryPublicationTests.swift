import Foundation
import GRDB
import Testing
@testable import Aperture

@Suite(.serialized)
struct AssetCatalogDiscoveryPublicationTests {
    @Test
    func queuesOnlyUnknownHeldFungibleTokens() async throws {
        let database = try WalletDatabase.temporary()
        let knownContract =
            "0x0000000000000000000000000000000000000011"
        let unknownEVM =
            "0x0000000000000000000000000000000000000012"
        let unknownSui = "0xabc::coin::COIN"
        let unknownXRP =
            "TEST:rMxCKbEDwqr76QuheSUMdEGf4B9xJ8m5De"

        try await database.pool.write { db in
            try insertWallet(in: db)
            try insertHeldAsset(
                networkID: "eth",
                contract: knownContract,
                balance: "3",
                balanceAtomic: "3000000000000000000",
                in: db
            )
            try insertHeldAsset(
                networkID: "eth",
                contract: unknownEVM,
                balance: "1",
                balanceAtomic: "1000000000000000000",
                in: db
            )
            try insertHeldAsset(
                networkID: "sui",
                contract: unknownSui,
                balance: "2",
                balanceAtomic: "2000000",
                in: db
            )
            try insertHeldAsset(
                networkID: "xrp",
                contract: unknownXRP,
                balance: "1.25",
                balanceAtomic: nil,
                decimals: 15,
                in: db
            )
            try insertHeldAsset(
                networkID: "base",
                contract:
                    "0x0000000000000000000000000000000000000013",
                balance: "0",
                balanceAtomic: "0",
                in: db
            )
            try insertHeldAsset(
                networkID: "polygon",
                contract:
                    "0x0000000000000000000000000000000000000014",
                balance: "8",
                balanceAtomic: "8000000000000000000",
                isSpam: true,
                in: db
            )
            try DBAssetCatalogEntryRecord(
                assetIdentity: "eth:\(knownContract)",
                tokenID: "known-token",
                networkID: "eth",
                contractAddress: knownContract,
                name: "Known Token",
                symbol: "KNOWN",
                decimals: 18,
                globalRank: 1,
                networkRank: 1,
                isStablecoin: false,
                logoURL: nil,
                tokenOrder: 1,
                variantOrder: 0,
                marketDataID: nil,
                source: AssetCatalogEntrySource.curated.rawValue,
                isVerified: true,
                isActive: true,
                revision: 1
            ).insert(db)

            try WalletAssetCatalogPersistence
                .enqueueDiscoveredHeldTokenPublications(
                    in: db,
                    now: 100
                )
        }

        let publications = try await database.pool.read { db in
            try DBAssetCatalogPublicationRecord.fetchAll(db)
        }
        #expect(
            Set(publications.map(\.assetIdentity)) == [
                "eth:\(unknownEVM)",
                "sui:\(unknownSui)",
                "xrp:\(unknownXRP)",
            ]
        )
    }

    @Test
    func repeatedDiscoveryPreservesPublicationBackoff() async throws {
        let database = try WalletDatabase.temporary()
        let contract =
            "0x0000000000000000000000000000000000000021"
        try await database.pool.write { db in
            try insertWallet(in: db)
            try insertHeldAsset(
                networkID: "eth",
                contract: contract,
                balance: "1",
                balanceAtomic: "1",
                in: db
            )
            try WalletAssetCatalogPersistence.enqueuePublication(
                networkID: "eth",
                contractAddress: contract,
                name: "Retry Token",
                symbol: "RETRY",
                decimals: 18,
                in: db,
                now: 100
            )
            let queued = try #require(
                WalletAssetCatalogPersistence.duePublications(
                    in: db,
                    now: 100
                ).first
            )
            try WalletAssetCatalogPersistence.publicationDidFail(
                queued,
                errorCode: "metadata_verification_failed",
                in: db,
                now: 100
            )
            try WalletAssetCatalogPersistence
                .enqueueDiscoveredHeldTokenPublications(
                    in: db,
                    now: 101
                )
        }

        let publication = try await database.pool.read { db in
            let fetched = try DBAssetCatalogPublicationRecord.fetchOne(db)
            return try #require(fetched)
        }
        #expect(publication.attemptCount == 1)
        #expect(publication.nextAttemptAt == 160)
        #expect(publication.lastErrorCode == "metadata_verification_failed")
    }

    private func insertWallet(in database: Database) throws {
        try database.execute(
            sql: """
            INSERT INTO wallets (
                id, profileID, name, kind, isSelected, sortOrder,
                createdAt, updatedAt
            ) VALUES ('catalog-test-wallet', ?, 'Catalog Test', 'created',
                      0, 0, 1, 1)
            """,
            arguments: [WalletDatabase.defaultProfileID]
        )
    }

    private func insertHeldAsset(
        networkID: String,
        contract: String,
        balance: String,
        balanceAtomic: String?,
        decimals: Int = 18,
        isSpam: Bool = false,
        in database: Database
    ) throws {
        let suffix = UUID().uuidString.lowercased()
        let accountID = "catalog-account-\(suffix)"
        let assetID = "catalog-asset-\(suffix)"
        try database.execute(
            sql: """
            INSERT INTO walletAccounts (
                id, walletID, networkID, address, normalizedAddress,
                isWatchOnly, isEnabled, createdAt, updatedAt
            ) VALUES (?, 'catalog-test-wallet', ?, ?, ?, 0, 1, 1, 1)
            """,
            arguments: [accountID, networkID, suffix, suffix]
        )
        try database.execute(
            sql: """
            INSERT INTO assets (
                id, networkID, assetType, contractAddress,
                normalizedContractAddress, name, symbol, decimals,
                isVerified, isSpam, createdAt, updatedAt
            ) VALUES (?, ?, ?, ?, ?, 'Discovered Token', 'DISC', ?,
                      0, ?, 1, 1)
            """,
            arguments: [
                assetID,
                networkID,
                DatabaseAssetType.fungibleToken.rawValue,
                contract,
                contract,
                decimals,
                isSpam,
            ]
        )
        try database.execute(
            sql: """
            INSERT INTO accountAssets (
                accountID, assetID, balance, balanceAtomic, isEnabled,
                isPinned, isHidden, firstSeenAt, lastSeenAt, updatedAt
            ) VALUES (?, ?, ?, ?, 1, 0, 0, 1, 1, 1)
            """,
            arguments: [accountID, assetID, balance, balanceAtomic]
        )
    }
}
