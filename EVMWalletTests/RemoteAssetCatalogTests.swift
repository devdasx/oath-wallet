import Foundation
import GRDB
import Testing
@testable import Aperture

@Suite(.serialized)
struct RemoteAssetCatalogTests {
    private let storagePrefix =
        "oath-asset://catalog/"

    @Test
    func catalogArtworkAcceptsOnlyBundledAssets() {
        let expected = storagePrefix + "token-ethereum-usdc.png"
        let remote = AssetLogoSource.catalogToken(
            blockchain: .ethereum,
            contractAddress:
                "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
            logoURL: expected
        )
        let unrelated = AssetLogoSource.catalogToken(
            blockchain: .ethereum,
            contractAddress:
                "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
            logoURL: "https://example.invalid/token.png"
        )

        #expect(remote.remoteLogoURL?.absoluteString == expected)
        #expect(unrelated.remoteLogoURL == nil)
    }

    @Test
    func remoteRowsAreDurableAndIncremental() async throws {
        let database = try WalletDatabase.temporary()
        let first = entry(
            identity:
                "eth:0x0000000000000000000000000000000000000001",
            tokenID: "remote-one",
            contract:
                "0x0000000000000000000000000000000000000001",
            name: "Remote One",
            symbol: "ONE",
            tokenOrder: 1,
            revision: 1,
            source: .curated,
            isVerified: true,
            logoURL: storagePrefix + "token-ethereum-one.png"
        )
        try await database.pool.write { db in
            try WalletAssetCatalogPersistence.applyRemoteEntries(
                [first],
                nextRevision: 1,
                in: db,
                now: 10
            )
            try WalletAssetCatalogPersistence.finishRemoteSync(
                revision: 1,
                in: db,
                now: 11
            )
        }

        let second = entry(
            identity:
                "base:0x0000000000000000000000000000000000000002",
            tokenID: "community-two",
            networkID: "base",
            contract:
                "0x0000000000000000000000000000000000000002",
            name: "Community Two",
            symbol: "TWO",
            tokenOrder: 2,
            revision: 2,
            source: .community,
            isVerified: false,
            logoURL: nil
        )
        try await database.pool.write { db in
            try WalletAssetCatalogPersistence.applyRemoteEntries(
                [second],
                nextRevision: 2,
                in: db,
                now: 20
            )
            try WalletAssetCatalogPersistence.finishRemoteSync(
                revision: 2,
                in: db,
                now: 21
            )
        }

        let snapshot = try await database.pool.read { db in
            (
                tokens: try WalletAssetCatalogPersistence.loadCachedTokens(
                    in: db
                ),
                state: try WalletAssetCatalogPersistence.cacheState(in: db),
                metadata: try DBAssetCatalogMetadataRecord.fetchOne(
                    db,
                    key: WalletAssetCatalogPersistence.metadataID
                )
            )
        }
        #expect(Set(snapshot.tokens.map(\.id)) == ["remote-one", "community-two"])
        #expect(snapshot.state.revision == 2)
        #expect(snapshot.state.didCompleteInitialSync)
        #expect(snapshot.metadata?.version == "oath-bundled-v4")
        #expect(snapshot.metadata?.entryCount == 2)
    }

    @Test
    func atomicSnapshotRemovesDeletedRowsAndPreservesCommunityTrust()
        async throws
    {
        let database = try WalletDatabase.temporary()
        let removed = entry(
            identity:
                "eth:0x0000000000000000000000000000000000000010",
            tokenID: "removed-token",
            contract:
                "0x0000000000000000000000000000000000000010",
            name: "Removed Token",
            symbol: "OLD",
            tokenOrder: 0,
            revision: 1,
            source: .curated,
            isVerified: true,
            logoURL: nil
        )
        let community = entry(
            identity:
                "base:0x0000000000000000000000000000000000000011",
            tokenID: "community-token",
            networkID: "base",
            contract:
                "0x0000000000000000000000000000000000000011",
            name: "Community Token",
            symbol: "COMM",
            tokenOrder: 0,
            revision: 2,
            source: .community,
            isVerified: false,
            logoURL: nil
        )

        try await database.pool.write { db in
            try WalletAssetCatalogPersistence.replaceRemoteSnapshot(
                [removed],
                revision: 1,
                in: db
            )
            try WalletAssetCatalogPersistence.replaceRemoteSnapshot(
                [community],
                revision: 2,
                in: db
            )
        }
        let tokens = try await database.pool.read { db in
            try WalletAssetCatalogPersistence.loadCachedTokens(in: db)
        }
        let variant = try #require(tokens.first?.variants.first)
        #expect(tokens.count == 1)
        #expect(variant.assetIdentity == community.assetIdentity)
        #expect(!variant.isVerified)

        let previous = ReceiveAssetCatalogRuntime.snapshot
        defer {
            ReceiveAssetCatalogRuntime.install(
                previous.tokens,
                revision: previous.revision
            )
        }
        ReceiveAssetCatalogRuntime.install(tokens, revision: 2)
        let walletAsset = try #require(
            ReceiveAssetCatalog.walletAssets.first {
                $0.id == community.assetIdentity
            }
        )
        let choice = try #require(
            SendAssetChoiceCatalog.choices(
                from: [walletAsset],
                capabilities: .fullWallet
            ).first
        )
        #expect(!walletAsset.isVerified)
        #expect(!choice.isVerified)
    }

    @Test
    func staleManifestNeverDownloadsOrReplacesTheInstalledCatalog()
        async throws
    {
        let database = try WalletDatabase.temporary()
        let installed = ethereumEntry(
            suffix: "16",
            tokenID: "installed-token",
            name: "Installed Token",
            symbol: "SAFE",
            revision: 5
        )
        try await database.pool.write { db in
            try WalletAssetCatalogPersistence.replaceRemoteSnapshot(
                [installed],
                revision: 5,
                in: db
            )
        }
        let client = AssetCatalogRemoteFixtureClient(
            manifestRevision: 4,
            manifestEntryCount: 1
        )

        try await AssetCatalogSyncService(client: client)
            .synchronizeAndWait(database: database)

        let result = try await database.pool.read { db in
            (
                rows: try DBAssetCatalogEntryRecord.fetchAll(db),
                state: try WalletAssetCatalogPersistence.cacheState(in: db)
            )
        }
        #expect(await client.requestedActions() == ["manifest"])
        #expect(result.rows.map(\.assetIdentity) == [installed.assetIdentity])
        #expect(result.state.revision == 5)
        #expect(result.state.didCompleteInitialSync)
    }

    /// An app update that adds a network (or reads a new catalog field) must
    /// refetch the snapshot even though the server generation is unchanged:
    /// the cached rows were fetched for the old build's networks and fields.
    @Test
    func aWiderCatalogScopeRefetchesTheSnapshotAtTheSameRevision() async throws {
        let previous = ReceiveAssetCatalogRuntime.snapshot
        defer {
            ReceiveAssetCatalogRuntime.install(
                previous.tokens,
                revision: previous.revision
            )
        }
        let database = try WalletDatabase.temporary()
        let cached = entry(
            identity: "eth:0x0000000000000000000000000000000000000021",
            tokenID: "cached-token",
            contract: "0x0000000000000000000000000000000000000021",
            name: "Cached Token",
            symbol: "OLD",
            tokenOrder: 1,
            revision: 5,
            source: .curated,
            isVerified: true,
            logoURL: nil
        )
        let added = entry(
            identity: "eth:0x0000000000000000000000000000000000000022",
            tokenID: "added-token",
            contract: "0x0000000000000000000000000000000000000022",
            name: "Added Token",
            symbol: "NEW",
            tokenOrder: 2,
            revision: 5,
            source: .curated,
            isVerified: true,
            logoURL: nil
        )
        // A complete cache written by an older build at the same revision.
        try await database.pool.write { db in
            try WalletAssetCatalogPersistence.replaceRemoteSnapshot(
                [cached],
                revision: 5,
                in: db
            )
            try db.execute(
                sql: "UPDATE assetCatalogSyncState SET scope = 'older-build'"
            )
        }
        let stale = try await database.pool.read { db in
            try WalletAssetCatalogPersistence.cacheState(in: db)
        }
        #expect(stale.didCompleteInitialSync)
        #expect(!stale.coversCurrentScope)

        let client = AssetCatalogSnapshotFixtureClient(
            revision: 5,
            entries: [cached, added]
        )
        try await AssetCatalogSyncService(client: client)
            .synchronizeAndWait(database: database)

        let result = try await database.pool.read { db in
            (
                identities: try DBAssetCatalogEntryRecord.fetchAll(db)
                    .map(\.assetIdentity).sorted(),
                state: try WalletAssetCatalogPersistence.cacheState(in: db)
            )
        }
        #expect(await client.requestedActions() == ["manifest", "snapshot"])
        #expect(result.identities == [cached.assetIdentity, added.assetIdentity].sorted())
        #expect(result.state.revision == 5)
        #expect(result.state.coversCurrentScope)
        #expect(
            result.state.scope
                == WalletAssetCatalogPersistence.currentScope
        )

        // Now the cache covers this build's scope: the manifest is enough.
        try await AssetCatalogSyncService(client: client)
            .synchronizeAndWait(database: database)
        #expect(
            await client.requestedActions()
                == ["manifest", "snapshot", "manifest"]
        )
    }

    @Test
    func everyCatalogReadNamesTheNetworksThisBuildCanInstall() async throws {
        let database = try WalletDatabase.temporary()
        let client = AssetCatalogRemoteFixtureClient(
            manifestRevision: 4,
            manifestEntryCount: 1
        )
        try await database.pool.write { db in
            try WalletAssetCatalogPersistence.replaceRemoteSnapshot(
                [
                    ethereumEntry(
                        suffix: "18",
                        tokenID: "scoped-token",
                        name: "Scoped Token",
                        symbol: "SCOPE",
                        revision: 5
                    )
                ],
                revision: 5,
                in: db
            )
        }

        try await AssetCatalogSyncService(client: client)
            .synchronizeAndWait(database: database)

        let scopes = await client.requestedNetworkScopes()
        let expected = ReceiveNetworkCatalog.catalogNetworkIdentifiers
        #expect(scopes == [expected])
        #expect(expected == expected.sorted())
        #expect(Set(expected).count == expected.count)
        #expect(expected.contains("arc"))
        #expect(expected.contains("eth"))
        #expect(expected.contains("bitcoin"))
        #expect(expected.allSatisfy {
            ReceiveNetworkCatalog.catalogNetwork(for: $0) != nil
        })
    }

    @Test
    func staleInFlightSnapshotCannotRollbackANewerCommit() async throws {
        let database = try WalletDatabase.temporary()
        let newer = ethereumEntry(
            suffix: "17",
            tokenID: "newer-token",
            name: "Newer Token",
            symbol: "NEW",
            revision: 7
        )
        let stale = ethereumEntry(
            suffix: "18",
            tokenID: "stale-token",
            name: "Stale Token",
            symbol: "OLD",
            revision: 6
        )
        try await database.pool.write { db in
            try WalletAssetCatalogPersistence.replaceRemoteSnapshot(
                [newer],
                revision: 7,
                in: db
            )
        }

        await #expect(
            throws: ReceiveAssetCatalogStorageError.invalidRemoteCursor
        ) {
            try await database.pool.write { db in
                try WalletAssetCatalogPersistence.replaceRemoteSnapshot(
                    [stale],
                    revision: 6,
                    in: db
                )
            }
        }

        let result = try await database.pool.read { db in
            (
                rows: try DBAssetCatalogEntryRecord.fetchAll(db),
                state: try WalletAssetCatalogPersistence.cacheState(in: db),
                metadata: try DBAssetCatalogMetadataRecord.fetchOne(
                    db,
                    key: WalletAssetCatalogPersistence.metadataID
                )
            )
        }
        #expect(result.rows.map(\.assetIdentity) == [newer.assetIdentity])
        #expect(result.state.revision == 7)
        #expect(result.metadata?.entryCount == 1)
    }

    @Test
    func equalRevisionCannotReplaceACompletedCatalog() async throws {
        let database = try WalletDatabase.temporary()
        let installed = ethereumEntry(
            suffix: "19",
            tokenID: "completed-token",
            name: "Completed Token",
            symbol: "DONE",
            revision: 8
        )
        let equivocation = ethereumEntry(
            suffix: "20",
            tokenID: "equivocated-token",
            name: "Equivocated Token",
            symbol: "BAD",
            revision: 8
        )
        try await database.pool.write { db in
            try WalletAssetCatalogPersistence.replaceRemoteSnapshot(
                [installed],
                revision: 8,
                in: db
            )
        }

        await #expect(
            throws: ReceiveAssetCatalogStorageError.invalidRemoteCursor
        ) {
            try await database.pool.write { db in
                try WalletAssetCatalogPersistence.replaceRemoteSnapshot(
                    [equivocation],
                    revision: 8,
                    in: db
                )
            }
        }

        let rows = try await database.pool.read { db in
            try DBAssetCatalogEntryRecord.fetchAll(db)
        }
        #expect(rows.map(\.assetIdentity) == [installed.assetIdentity])
    }

    @Test
    func equalRevisionCanRepairOnlyAnIncompleteCatalog() async throws {
        let database = try WalletDatabase.temporary()
        let damaged = ethereumEntry(
            suffix: "21",
            tokenID: "damaged-token",
            name: "Damaged Token",
            symbol: "OLD",
            revision: 9
        )
        let repaired = ethereumEntry(
            suffix: "22",
            tokenID: "repaired-token",
            name: "Repaired Token",
            symbol: "FIX",
            revision: 9
        )
        try await database.pool.write { db in
            try WalletAssetCatalogPersistence.replaceRemoteSnapshot(
                [damaged],
                revision: 9,
                in: db
            )
            try DBAssetCatalogEntryRecord.deleteAll(db)
            try WalletAssetCatalogPersistence.replaceRemoteSnapshot(
                [repaired],
                revision: 9,
                allowSameRevisionRepair: true,
                in: db
            )
        }

        let result = try await database.pool.read { db in
            (
                rows: try DBAssetCatalogEntryRecord.fetchAll(db),
                state: try WalletAssetCatalogPersistence.cacheState(in: db),
                tokens: try WalletAssetCatalogPersistence
                    .loadCompleteCachedTokens(in: db)
            )
        }
        #expect(result.rows.map(\.assetIdentity) == [repaired.assetIdentity])
        #expect(result.state.revision == 9)
        #expect(result.state.didCompleteInitialSync)
        #expect(result.tokens.map(\.id) == [repaired.tokenID])
    }

    @Test
    func invalidAtomicSnapshotCannotEraseLastCompleteCatalog()
        async throws
    {
        let database = try WalletDatabase.temporary()
        let original = entry(
            identity:
                "eth:0x0000000000000000000000000000000000000012",
            tokenID: "original-token",
            contract:
                "0x0000000000000000000000000000000000000012",
            name: "Original Token",
            symbol: "SAFE",
            tokenOrder: 0,
            revision: 1,
            source: .curated,
            isVerified: true,
            logoURL: nil
        )
        let candidate = entry(
            identity:
                "eth:0x0000000000000000000000000000000000000013",
            tokenID: "invalid-token",
            contract:
                "0x0000000000000000000000000000000000000013",
            name: "Invalid Token",
            symbol: "BAD",
            tokenOrder: 0,
            revision: 2,
            source: .community,
            isVerified: false,
            logoURL: nil
        )
        let invalid = AssetCatalogRemoteEntry(
            assetIdentity: candidate.assetIdentity,
            tokenID: candidate.tokenID,
            networkID: candidate.networkID,
            contractAddress: candidate.contractAddress,
            name: candidate.name,
            symbol: candidate.symbol,
            decimals: candidate.decimals,
            globalRank: candidate.globalRank,
            networkRank: candidate.networkRank,
            isStablecoin: candidate.isStablecoin,
            logoURL: candidate.logoURL,
            marketDataID: candidate.marketDataID,
            tokenOrder: candidate.tokenOrder,
            variantOrder: candidate.variantOrder,
            source: candidate.source,
            isVerified: true,
            isActive: candidate.isActive,
            revision: candidate.revision
        )

        try await database.pool.write { db in
            try WalletAssetCatalogPersistence.replaceRemoteSnapshot(
                [original],
                revision: 1,
                in: db
            )
        }
        await #expect(throws: ReceiveAssetCatalogStorageError.self) {
            try await database.pool.write { db in
                try WalletAssetCatalogPersistence.replaceRemoteSnapshot(
                    [invalid],
                    revision: 2,
                    in: db
                )
            }
        }

        let snapshot = try await database.pool.read { db in
            (
                rows: try DBAssetCatalogEntryRecord.fetchAll(db),
                state: try WalletAssetCatalogPersistence.cacheState(in: db)
            )
        }
        #expect(snapshot.rows.map(\.assetIdentity) == [original.assetIdentity])
        #expect(snapshot.state.revision == 1)
        #expect(snapshot.state.didCompleteInitialSync)
    }

    @Test
    func incompletePersistedGenerationIsNeverInstalledAtLaunch()
        async throws
    {
        let database = try WalletDatabase.temporary()
        let first = entry(
            identity:
                "eth:0x0000000000000000000000000000000000000014",
            tokenID: "complete-one",
            contract:
                "0x0000000000000000000000000000000000000014",
            name: "Complete One",
            symbol: "ONE",
            tokenOrder: 0,
            revision: 1,
            source: .curated,
            isVerified: true,
            logoURL: nil
        )
        let second = entry(
            identity:
                "base:0x0000000000000000000000000000000000000015",
            tokenID: "complete-two",
            networkID: "base",
            contract:
                "0x0000000000000000000000000000000000000015",
            name: "Complete Two",
            symbol: "TWO",
            tokenOrder: 1,
            revision: 2,
            source: .curated,
            isVerified: true,
            logoURL: nil
        )
        try await database.pool.write { db in
            try WalletAssetCatalogPersistence.replaceRemoteSnapshot(
                [first, second],
                revision: 2,
                in: db
            )
            try db.execute(
                sql: "DELETE FROM assetCatalogEntries WHERE assetIdentity = ?",
                arguments: [second.assetIdentity]
            )
        }

        await #expect(throws: ReceiveAssetCatalogStorageError.self) {
            try await database.pool.read { db in
                try WalletAssetCatalogPersistence.loadCompleteCachedTokens(
                    in: db
                )
            }
        }

        let previous = ReceiveAssetCatalogRuntime.snapshot
        defer {
            ReceiveAssetCatalogRuntime.install(
                previous.tokens,
                revision: previous.revision
            )
        }
        try database.seedReferenceData()
        let state = try await database.pool.read { db in
            try WalletAssetCatalogPersistence.cacheState(in: db)
        }
        #expect(!state.didCompleteInitialSync)
        #expect(ReceiveAssetCatalogRuntime.tokens.isEmpty)
    }

    @Test
    func remoteMigrationRepairsLegacyCatalogWithoutOrderIndex() throws {
        let queue = try DatabaseQueue()
        let migrator = WalletDatabase.migrator
        try migrator.migrate(
            queue,
            upTo: "v42_normalized_send_receive_asset_catalog"
        )
        try queue.write { database in
            try database.execute(
                sql: "DROP INDEX assetCatalogEntries_order"
            )
        }

        try migrator.migrate(queue)

        try queue.read { database in
            let columns = try database.columns(
                in: "assetCatalogEntries"
            )
            let syncStateExists = try database.tableExists(
                "assetCatalogSyncState"
            )
            let appliedMigrations = try migrator.appliedMigrations(
                database
            )
            #expect(
                columns.contains { $0.name == "marketDataID" }
            )
            #expect(syncStateExists)
            #expect(
                appliedMigrations
                    .contains("v49_remote_asset_catalog_cache")
            )
        }
    }

    @Test
    func customTokenPublicationPersistsUntilAcknowledged() async throws {
        let database = try WalletDatabase.temporary()
        let identity =
            "eth:0x0000000000000000000000000000000000000003"
        try await database.pool.write { db in
            try WalletAssetCatalogPersistence.enqueuePublication(
                networkID: "eth",
                contractAddress:
                    "0x0000000000000000000000000000000000000003",
                name: "Shared Token",
                symbol: "SHARED",
                decimals: 18,
                in: db,
                now: 100
            )
        }

        let queued = try await database.pool.read { db in
            try WalletAssetCatalogPersistence.duePublications(
                in: db,
                now: 100
            )
        }
        let publication = try #require(queued.first)
        #expect(publication.assetIdentity == identity)

        try await database.pool.write { db in
            try WalletAssetCatalogPersistence.publicationDidFail(
                publication,
                errorCode: "catalog_service_unavailable",
                in: db,
                now: 100
            )
        }
        let retry = try await database.pool.read { db in
            try WalletAssetCatalogPersistence.duePublications(
                in: db,
                now: 160
            )
        }
        #expect(retry.first?.attemptCount == 1)

        try await database.pool.write { db in
            try WalletAssetCatalogPersistence.publicationDidSucceed(
                assetIdentity: identity,
                in: db
            )
        }
        let remaining = try await database.pool.read { db in
            try DBAssetCatalogPublicationRecord.fetchCount(db)
        }
        #expect(remaining == 0)
    }

    @Test
    func catalogRowsRejectRemoteArtwork() async throws {
        let database = try WalletDatabase.temporary()
        let invalid = entry(
            identity:
                "eth:0x0000000000000000000000000000000000000004",
            tokenID: "invalid-logo",
            contract:
                "0x0000000000000000000000000000000000000004",
            name: "Invalid Logo",
            symbol: "BAD",
            tokenOrder: 1,
            revision: 1,
            source: .curated,
            isVerified: true,
            logoURL: "https://example.invalid/token.png"
        )

        await #expect(throws: ReceiveAssetCatalogStorageError.self) {
            try await database.pool.write { db in
                try WalletAssetCatalogPersistence.applyRemoteEntries(
                    [invalid],
                    nextRevision: 1,
                    in: db
                )
            }
        }
    }

    @Test
    func curatedRowsPreserveLegitimateSpacedSymbols() async throws {
        let database = try WalletDatabase.temporary()
        let identity =
            "linea:0x5ec5b1e9b1bd5198343abb6e55fb695d2f7bb308"
        let remote = entry(
            identity: identity,
            tokenID: identity,
            networkID: "linea",
            contract:
                "0x5ec5b1e9b1bd5198343abb6e55fb695d2f7bb308",
            name: "SyncSwap USDC/WETH Classic LP",
            symbol: "USDC/WETH cSLP",
            tokenOrder: 1,
            revision: 1,
            source: .curated,
            isVerified: true,
            logoURL: nil
        )

        try await database.pool.write { db in
            try WalletAssetCatalogPersistence.applyRemoteEntries(
                [remote],
                nextRevision: 1,
                in: db
            )
        }

        let stored = try await database.pool.read { db in
            try DBAssetCatalogEntryRecord.fetchOne(db, key: identity)
        }
        #expect(stored?.symbol == "USDC/WETH cSLP")
    }

    @Test
    func nativePricesHaveExactFallbacksBeforeInitialCatalogSync() {
        let previous = ReceiveAssetCatalogRuntime.snapshot
        defer {
            ReceiveAssetCatalogRuntime.install(
                previous.tokens,
                revision: previous.revision
            )
        }
        ReceiveAssetCatalogRuntime.install([], revision: 0)
        let expectedByNetworkID = [
            "aptos": "aptos", "stellar": "stellar", "near": "near",
            "xrp": "ripple", "sui": "sui", "ton": "the-open-network",
            "tron": "tron", "solana": "solana", "bitcoin": "bitcoin",
            "bitcoin_cash": "bitcoin-cash", "litecoin": "litecoin",
            "dogecoin": "dogecoin",
            "eth": "ethereum",
            "bsc": "binancecoin", "polygon": "polygon-ecosystem-token",
            "arbitrum": "ethereum", "avalanche": "avalanche-2",
            "optimism": "ethereum", "base": "ethereum",
            "gnosis": "xdai", "scroll": "ethereum", "linea": "ethereum",
            "taiko": "ethereum", "telos": "telos", "xlayer": "okb",
            "arc": "usd-coin"
        ]
        let supported = AssetNetworkSelectorOption.allSupported

        #expect(Set(supported.map(\.id)) == Set(expectedByNetworkID.keys))
        for network in supported {
            let asset = WalletAsset(
                id: AssetIdentityKey.make(
                    networkID: network.id,
                    contractAddress: nil
                ),
                name: network.id,
                symbol: network.id,
                logoSource: .nativeCoin(blockchain: network.blockchain),
                network: network.blockchain,
                balance: 1,
                fiatValue: 0
            )
            #expect(
                AssetPriceClient.coinGeckoMarketID(for: asset)
                    == expectedByNetworkID[network.id]
            )
        }
    }

    @Test
    func remoteTokenMarketIDsRemainBoundToExactChainIdentity() {
        let fixtures: [(
            networkID: String,
            blockchain: WalletBlockchain,
            contract: String,
            symbol: String,
            marketID: String
        )] = [
            ("near", .near, "wrap.near", "wNEAR", "wrapped-near"),
            ("near", .near, "usdt.tether-token.near", "USDt", "tether"),
            (
                "near", .near, "token.v2.ref-finance.near", "REF",
                "ref-finance"
            ),
            (
                "xrp", .xrp,
                "RLUSD:rMxCKbEDwqr76QuheSUMdEGf4B9xJ8m5De", "RLUSD",
                "ripple-usd"
            ),
            (
                "stellar", .stellar,
                "USDC:GA5ZSEJYB37JRC5AVCIA5MOP4RHTM335X2KGX3IHOJAPP5RE34K4KZVN",
                "USDC", "usd-coin"
            ),
            (
                "ton", .ton,
                "0:b113a994b5024a16719f69139328eb759596c38a25f59028b146fecdc3621dfe",
                "USD₮", "tether"
            ),
            (
                "sui", .sui,
                "0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC",
                "USDC", "usd-coin"
            )
        ]
        let previous = ReceiveAssetCatalogRuntime.snapshot
        defer {
            ReceiveAssetCatalogRuntime.install(
                previous.tokens,
                revision: previous.revision
            )
        }
        ReceiveAssetCatalogRuntime.install(
            fixtures.enumerated().map { index, fixture in
                ReceiveToken(
                    id: "market-fixture-\(index)",
                    name: fixture.symbol,
                    symbol: fixture.symbol,
                    rank: index,
                    isStablecoin: nil,
                    variants: [
                        ReceiveTokenVariant(
                            networkID: fixture.networkID,
                            contractAddress: fixture.contract,
                            decimals: 18,
                            networkRank: index,
                            logoURL: nil,
                            marketDataID: fixture.marketID
                        )
                    ]
                )
            },
            revision: 1
        )

        for fixture in fixtures {
            let asset = WalletAsset(
                id: AssetIdentityKey.make(
                    networkID: fixture.networkID,
                    contractAddress: fixture.contract
                ),
                name: fixture.symbol,
                symbol: fixture.symbol,
                logoSource: .unavailable,
                network: fixture.blockchain,
                balance: 1,
                fiatValue: 0
            )
            #expect(
                AssetPriceClient.coinGeckoMarketID(for: asset)
                    == fixture.marketID
            )
        }
    }

    @Test
    func exactContractPriceDoesNotRequireAMarketDataID() async throws {
        let previous = ReceiveAssetCatalogRuntime.snapshot
        defer {
            ReceiveAssetCatalogRuntime.install(
                previous.tokens,
                revision: previous.revision
            )
        }
        let database = try WalletDatabase.temporary()
        ReceiveAssetCatalogRuntime.install([], revision: 0)
        let contract = ExactContractAssetPriceURLProtocol.contract
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [
            ExactContractAssetPriceURLProtocol.self
        ]
        let client = AssetPriceClient(
            session: URLSession(configuration: configuration),
            database: database
        )
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
        let quote = try await client.usdPrice(for: asset)
        #expect(quote.price == Decimal(string: "1.000123"))
        #expect(quote.provider == AssetPriceClient.exactContractPriceProvider)
    }

    @Test
    func missingArtworkRecoversByExactIdentityAcrossNetworks() throws {
        let previous = ReceiveAssetCatalogRuntime.snapshot
        defer { ReceiveAssetCatalogRuntime.install(previous.tokens, revision: previous.revision) }
        // Case-sensitive identities must survive without legacy Trust Wallet fields.
        let fixtures: [(String, WalletBlockchain, String)] = [
            ("tron", .tron, "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t"),
            ("solana", .solana, "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"),
            ("eth", .ethereum, "0x1111111111111111111111111111111111111111"),
            ("near", .near, "wrap.near"),
            ("sui", .sui, "0x2::sui::SUI"),
            ("aptos", .aptos, "0x1::aptos_coin::AptosCoin"),
            ("ton", .ton, "0:abc"),
            ("stellar", .stellar, "USDC:GISSUER"),
            ("xrp", .xrp, "RLUSD:rIssuer")
        ]
        for (networkID, blockchain, contract) in fixtures {
            let url = storagePrefix + "fixture-\(networkID).png"
            let identity = AssetIdentityKey.make(networkID: networkID, contractAddress: contract)
            let token = ReceiveToken(id: identity, name: "Fixture", symbol: "SAME",
                rank: 1, isStablecoin: nil, variants: [ReceiveTokenVariant(
                    networkID: networkID, contractAddress: contract, decimals: 6,
                    networkRank: 1, logoURL: url)])
            ReceiveAssetCatalogRuntime.install([token])
            let record = DBAssetRecord(id: identity, networkID: networkID,
                assetType: DatabaseAssetType.fungibleToken.rawValue,
                contractAddress: contract, normalizedContractAddress: contract,
                name: "Fixture", symbol: "SAME", decimals: 6,
                trustWalletBlockchain: nil, trustWalletContractAddress: nil,
                logoURL: nil, logoOrigin: nil, isVerified: false, isSpam: false,
                createdAt: 0, updatedAt: 0, metadataUpdatedAt: 0)
            #expect(WalletDatabase.logoSource(asset: record, fallbackNetwork: blockchain)
                .remoteLogoURL?.absoluteString == url)
            #expect(AssetLogoSource.unavailable.resolvingCatalogArtwork(assetIdentity: identity)
                .remoteLogoURL?.absoluteString == url)
            #expect(AssetLogoSource.unavailable.resolvingCatalogArtwork(
                assetIdentity: "\(networkID):different-contract") == .unavailable)
            if networkID == "tron" || networkID == "solana" {
                #expect(AssetLogoSource.unavailable.resolvingCatalogArtwork(
                    assetIdentity: identity.lowercased()) == .unavailable)
            }
        }
    }

    @Test
    func catalogWithoutAnImagePreservesProviderArtwork() {
        let previous = ReceiveAssetCatalogRuntime.snapshot
        defer { ReceiveAssetCatalogRuntime.install(previous.tokens, revision: previous.revision) }
        let contract = "0x1111111111111111111111111111111111111111"
        let url = "https://example.org/verified-contract.png"
        ReceiveAssetCatalogRuntime.install([ReceiveToken(id: "fixture", name: "Fixture",
            symbol: "ONE", rank: 1, isStablecoin: nil, variants: [ReceiveTokenVariant(
                networkID: "eth", contractAddress: contract, decimals: 18,
                networkRank: 1, logoURL: nil)])])
        #expect(AnkrAPIClient.logoSource(networkID: "eth", contractAddress: contract,
            ankrThumbnail: url).remoteLogoURL?.absoluteString == url)
        for origin in ["ankr", "provider", "catalog"] {
            let storedURL = origin == "catalog" ? storagePrefix + "saved.png" : url
            let record = DBAssetRecord(id: "eth:\(contract)", networkID: "eth",
                assetType: DatabaseAssetType.fungibleToken.rawValue,
                contractAddress: contract, normalizedContractAddress: contract,
                name: "Fixture", symbol: "ONE", decimals: 18,
                trustWalletBlockchain: "ethereum", trustWalletContractAddress: contract,
                logoURL: storedURL, logoOrigin: origin, isVerified: false, isSpam: false,
                createdAt: 0, updatedAt: 0, metadataUpdatedAt: 0)
            #expect(WalletDatabase.logoSource(asset: record, fallbackNetwork: .ethereum)
                .remoteLogoURL?.absoluteString == storedURL)
        }
    }

    @Test
    func freshZeroBalanceDoesNotEraseCatalogArtwork() {
        let contract = "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t"
        let id = "tron:\(contract)"
        let url = storagePrefix + "stablecoin-usdt.png"
        let catalog = WalletAsset(id: id, name: "Tether", symbol: "USDT",
            logoSource: .catalogToken(blockchain: .tron, contractAddress: contract, logoURL: url),
            network: .tron, balance: 500, fiatValue: 500)
        let holding = WalletAsset(id: id, name: "USDT", symbol: "USDT",
            logoSource: .unavailable, network: .tron, balance: 0, fiatValue: 0,
            balanceText: "0", receiveAddress: "current-address")
        let projected = WalletAssetBalanceSnapshot(assets: [holding]).resolved(catalog)
        #expect(projected.balance == 0)
        #expect(projected.receiveAddress == "current-address")
        #expect(projected.logoSource.remoteLogoURL?.absoluteString == url)
    }

    private func entry(
        identity: String,
        tokenID: String,
        networkID: String = "eth",
        contract: String,
        name: String,
        symbol: String,
        tokenOrder: Int64,
        revision: Int64,
        source: AssetCatalogEntrySource,
        isVerified: Bool,
        logoURL: String?
    ) -> AssetCatalogRemoteEntry {
        AssetCatalogRemoteEntry(
            assetIdentity: identity,
            tokenID: tokenID,
            networkID: networkID,
            contractAddress: contract,
            name: name,
            symbol: symbol,
            decimals: 18,
            globalRank: tokenOrder,
            networkRank: tokenOrder,
            isStablecoin: false,
            logoURL: logoURL,
            marketDataID: nil,
            tokenOrder: tokenOrder,
            variantOrder: 0,
            source: source,
            isVerified: isVerified,
            isActive: true,
            revision: revision
        )
    }

    private func ethereumEntry(
        suffix: String,
        tokenID: String,
        name: String,
        symbol: String,
        revision: Int64
    ) -> AssetCatalogRemoteEntry {
        let contract = "0x"
            + String(repeating: "0", count: 40 - suffix.count)
            + suffix
        return entry(
            identity: "eth:\(contract)",
            tokenID: tokenID,
            contract: contract,
            name: name,
            symbol: symbol,
            tokenOrder: 0,
            revision: revision,
            source: .curated,
            isVerified: true,
            logoURL: nil
        )
    }
}

/// Serves one snapshot generation: the manifest and the snapshot both report
/// `revision`, and the snapshot carries `entries`.
private actor AssetCatalogSnapshotFixtureClient:
    AssetCatalogRemoteDataClient
{
    private let manifest: Data
    private let snapshot: Data
    private var actions: [String] = []

    init(revision: Int64, entries: [AssetCatalogRemoteEntry]) {
        let rows = entries.map { entry -> [String: Any] in
            [
                "asset_identity": entry.assetIdentity,
                "token_id": entry.tokenID,
                "network_id": entry.networkID,
                "contract_address": entry.contractAddress as Any,
                "name": entry.name,
                "symbol": entry.symbol,
                "decimals": entry.decimals,
                "global_rank": String(entry.globalRank),
                "network_rank": entry.networkRank.map(String.init) as Any,
                "is_stablecoin": entry.isStablecoin as Any,
                "logo_url": entry.logoURL as Any,
                "market_data_id": entry.marketDataID as Any,
                "token_order": String(entry.tokenOrder),
                "variant_order": entry.variantOrder,
                "source": entry.source.rawValue,
                "is_verified": entry.isVerified,
                "is_active": entry.isActive,
                "revision": String(entry.revision),
                "asset_family": entry.assetFamily as Any
            ]
        }
        manifest = try! JSONSerialization.data(withJSONObject: [
            "snapshot_revision": String(revision),
            "entry_count": entries.count
        ])
        snapshot = try! JSONSerialization.data(withJSONObject: [
            "snapshot_revision": String(revision),
            "entry_count": entries.count,
            "entries": rows
        ])
    }

    func invokeData(
        functionPath _: String,
        payload: Data
    ) async throws -> Data {
        guard
            let dictionary = try JSONSerialization.jsonObject(with: payload)
                as? [String: Any],
            let action = dictionary["action"] as? String
        else {
            throw AssetCatalogSyncError.invalidResponse
        }
        actions.append(action)
        switch action {
        case "manifest": return manifest
        case "snapshot": return snapshot
        default: throw AssetCatalogSyncError.invalidResponse
        }
    }

    func requestedActions() -> [String] {
        actions
    }
}

private actor AssetCatalogRemoteFixtureClient:
    AssetCatalogRemoteDataClient
{
    private let manifestData: Data
    private var actions: [String] = []
    private var networkScopes: [[String]] = []

    init(manifestRevision: Int64, manifestEntryCount: Int) {
        let json = """
        {"snapshot_revision":"\(manifestRevision)","entry_count":\(manifestEntryCount)}
        """
        manifestData = Data(json.utf8)
    }

    func invokeData(
        functionPath _: String,
        payload: Data
    ) async throws -> Data {
        let object = try JSONSerialization.jsonObject(with: payload)
        guard
            let dictionary = object as? [String: Any],
            let action = dictionary["action"] as? String
        else {
            throw AssetCatalogSyncError.invalidResponse
        }
        actions.append(action)
        networkScopes.append(
            dictionary["network_ids"] as? [String] ?? []
        )
        guard action == "manifest" else {
            throw AssetCatalogSyncError.invalidResponse
        }
        return manifestData
    }

    func requestedActions() -> [String] {
        actions
    }

    func requestedNetworkScopes() -> [[String]] {
        networkScopes
    }
}

private final class ExactContractAssetPriceURLProtocol: URLProtocol,
    @unchecked Sendable
{
    static let contract =
        "0xdac17f958d2ee523a2206206994597c13d831ec7"

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
        let requestedContract = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        )?.queryItems?.first {
            $0.name == "contract_addresses"
        }?.value
        let isExactRoute =
            url.path == "/api/v3/simple/token_price/ethereum"
            && requestedContract?.caseInsensitiveCompare(Self.contract)
                == .orderedSame
        let statusCode = isExactRoute ? 200 : 503
        let body = isExactRoute
            ? "{\"\(Self.contract)\":{\"usd\":1.000123}}"
            : #"{"error":"unexpected price route"}"#
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
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
