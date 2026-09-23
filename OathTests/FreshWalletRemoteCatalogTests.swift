import Foundation
import Testing
@testable import Aperture

@Suite(.serialized)
struct FreshWalletRemoteCatalogTests {
    @Test
    func emptyUninstalledCatalogHasNoRows() {
        let available = WalletHomeAssetCatalog.availableAssets(
            from: [],
            remoteCatalogAssets: []
        )

        #expect(available.isEmpty)
    }

    @Test
    func installedSnapshotIsTheCatalogSource() {
        let remoteEthereum = WalletAsset(
            id: AssetIdentityKey.make(
                networkID: "eth",
                contractAddress: nil
            ),
            name: "Ethereum",
            symbol: "ETH",
            logoSource: .nativeCoin(blockchain: .ethereum),
            network: .ethereum,
            balance: 0,
            fiatValue: 0,
            decimals: 18
        )
        let remoteUSDC = WalletAsset(
            id: AssetIdentityKey.make(
                networkID: "eth",
                contractAddress:
                    "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"
            ),
            name: "USD Coin",
            symbol: "USDC",
            logoSource: .catalogToken(
                blockchain: .ethereum,
                contractAddress:
                    "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
                logoURL: nil
            ),
            network: .ethereum,
            balance: 0,
            fiatValue: 0,
            decimals: 6
        )
        let remoteSolanaToken = WalletAsset(
            id: AssetIdentityKey.make(
                networkID: "solana",
                contractAddress: "remote-solana-mint"
            ),
            name: "Remote Solana Token",
            symbol: "RST",
            logoSource: .catalogToken(
                blockchain: .solana,
                contractAddress: "remote-solana-mint",
                logoURL: nil
            ),
            network: .solana,
            balance: 0,
            fiatValue: 0,
            decimals: 9
        )
        let available = WalletHomeAssetCatalog.availableAssets(
            from: [],
            remoteCatalogAssets: [
                remoteEthereum,
                remoteUSDC,
                remoteSolanaToken
            ]
        )
        let availableIDs = Set(
            available.map { AssetIdentityKey.canonical($0.id) }
        )

        #expect(
            availableIDs == Set(
                [remoteEthereum, remoteUSDC, remoteSolanaToken].map {
                    AssetIdentityKey.canonical($0.id)
                }
            )
        )
        #expect(available.count == 3)
    }
}


@Suite(.serialized)
struct BundledCatalogSecurityTests {
    @Test
    func packagedCatalogInstallsWithoutAnHTTPClient() async throws {
        let database = try WalletDatabase.temporary()
        let service = AssetCatalogSyncService(client: BundledAssetCatalogClient())
        try await service.synchronizeAndWait(database: database)
        let installed = try await database.pool.read { db in
            try WalletAssetCatalogPersistence.cacheState(in: db)
        }
        #expect(installed.didCompleteInitialSync)
        #expect(installed.coversCurrentScope)
        #expect(installed.revision == 2026092304000)
        let rows = try await database.pool.read { db in
            try WalletAssetCatalogPersistence.loadCompleteCachedTokens(in: db)
        }
        #expect(!rows.isEmpty)
    }

    @Test
    func packagedCatalogIsScopedAndContainsOnlyBundledArtwork() async throws {
        let payload = try JSONSerialization.data(withJSONObject: [
            "action": "snapshot", "network_ids": ["eth"]
        ])
        let response = try await BundledAssetCatalogClient().invokeData(
            functionPath: "bundled-asset-catalog", payload: payload
        )
        let json = try #require(try JSONSerialization.jsonObject(with: response) as? [String: Any])
        let rows = try #require(json["entries"] as? [[String: Any]])
        #expect(rows.count > 100)
        #expect(rows.allSatisfy { $0["network_id"] as? String == "eth" })
        #expect(rows.allSatisfy {
            AssetCatalogEntryValidation.isValidCatalogLogoURL($0["logo_url"] as? String)
        })
        for row in rows {
            guard let value = row["logo_url"] as? String else { continue }
            let url = try #require(URL(string: value))
            let file = try #require(Bundle.main.url(
                forResource: url.lastPathComponent, withExtension: nil, subdirectory: "CatalogLogos"
            ))
            let data = try Data(contentsOf: file)
            #expect(data.prefix(8) == Data([137, 80, 78, 71, 13, 10, 26, 10]))
        }
    }

    @Test(arguments: ["publish", "upload", "sync", "import-credential-drafts"])
    func catalogRejectsEveryWriteOperation(_ operation: String) async throws {
        let payload = try JSONSerialization.data(withJSONObject: [
            "action": operation, "network_ids": ["eth"]
        ])
        await #expect(throws: AssetCatalogSyncError.invalidResponse) {
            _ = try await BundledAssetCatalogClient().invokeData(
                functionPath: "bundled-asset-catalog", payload: payload
            )
        }
    }

    @Test(arguments: [
        "https://example.com/logo.png",
        "file:///etc/passwd",
        "oath-asset://catalog/../secret.png",
        "oath-asset://catalog/%2e%2e/secret.png",
        "oath-asset://catalog/a/b.png",
        "oath-asset://catalog/logo.png?secret=value",
        "oath-asset://user:password@catalog/logo.png"
    ])
    func catalogRejectsRemoteOrUnsafeArtwork(_ value: String) {
        #expect(!AssetCatalogEntryValidation.isValidCatalogLogoURL(value))
    }
}
