#if LIVE_MAINNET_TESTS
import Foundation
import Testing
@testable import Aperture

@Suite(.serialized)
struct LiveAssetCatalogIntegrationTests {
    @Test
    func remoteCatalogProvidesEverySupportedNativeAsset() async throws {
        let database = try WalletDatabase.temporary()

        try await AssetCatalogSyncService()
            .synchronizeAndWait(database: database)

        let tokens = try await database.pool.read { database in
            try WalletAssetCatalogPersistence.loadCachedTokens(
                in: database
            )
        }
        let remoteIdentities = Set(
            tokens.flatMap(\.variants).map {
                AssetIdentityKey.canonical($0.assetIdentity)
            }
        )
        let expectedNativeIdentities = Set(
            AssetNetworkSelectorOption.allSupported.map {
                AssetIdentityKey.make(
                    networkID: $0.id,
                    contractAddress: nil
                )
            }
        )

        #expect(expectedNativeIdentities.isSubset(of: remoteIdentities))
    }

    @Test
    func remoteCatalogSynchronizesAndCachesTronArtwork() async throws {
        let database = try WalletDatabase.temporary()
        let service = AssetCatalogSyncService()

        try await service.synchronizeAndWait(database: database)

        let tronAssetIdentities = [
            "tron:TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t",
            "tron:TFptbWaARrWTX5Yvy3gNG5Lm8BmhPx82Bt",
            "tron:TU3kjFuhtEo42tsCBtfYUAZxoqQ4yuSLQ5",
            "tron:TUPM7K8REVzD2UdV4R5fe5M8XbnR2DdoJ6",
            "tron:TNUC9Qb1rRpS5CbWLmNMxXBjyFoydXjWFR",
            "tron:TXDk8mbtRbXeYuMNS83CfKPaYYT8XWv9Hz",
            "tron:TCFLL5dx5ZJdKnWuesXxi1VPwjLVmWZZy9",
            "tron:TLeVfrdym8RoJreJ23dAGyfJDygRtiWKBZ"
        ]
        let result = try await database.pool.read { database in
            let state = try WalletAssetCatalogPersistence.cacheState(
                in: database
            )
            let entries = try tronAssetIdentities.map { identity in
                try DBAssetCatalogEntryRecord.fetchOne(
                    database,
                    key: identity
                )
            }
            let tokens = try WalletAssetCatalogPersistence.loadCachedTokens(
                in: database
            )
            return (state: state, entries: entries, tokens: tokens)
        }
        #expect(result.state.didCompleteInitialSync)
        #expect(result.state.revision > 0)

        let cache = AssetLogoCache(database: database)
        let variants = result.tokens.flatMap(\.variants)
        for entry in result.entries {
            let entry = try #require(entry)
            let logoURL = try #require(entry.logoURL.flatMap(URL.init))
            let variant = try #require(
                variants.first { $0.assetIdentity == entry.assetIdentity }
            )
            #expect(variant.logoSource.remoteLogoURL == logoURL)
            let data = try await cache.imageData(for: logoURL)
            #expect(!data.isEmpty)
            #expect(
                try await database.assetLogoCacheEntry(for: logoURL)
                    != nil
            )
        }
    }
}
#endif
