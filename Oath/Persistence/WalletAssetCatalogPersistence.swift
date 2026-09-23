import Foundation
import GRDB

struct DBAssetCatalogMetadataRecord:
    Codable,
    FetchableRecord,
    PersistableRecord,
    Sendable {
    static let databaseTableName = "assetCatalogMetadata"

    let id: String
    let version: String
    let entryCount: Int
    let updatedAt: Double
}

enum AssetCatalogEntrySource: String, Codable, Sendable {
    case legacy
    case curated
    case community
}

struct DBAssetCatalogEntryRecord:
    Codable,
    FetchableRecord,
    PersistableRecord,
    Sendable {
    static let databaseTableName = "assetCatalogEntries"

    let assetIdentity: String
    let tokenID: String
    let networkID: String
    let contractAddress: String?
    let name: String
    let symbol: String
    let decimals: Int
    let globalRank: Int64
    let networkRank: Int64?
    let isStablecoin: Bool?
    let logoURL: String?
    let tokenOrder: Int64
    let variantOrder: Int
    let marketDataID: String?
    let source: String
    let isVerified: Bool
    let isActive: Bool
    let revision: Int64
    /// Raw family identifier from the catalog; a value this build does not
    /// know stays stored and simply resolves to no family.
    var assetFamily: String? = nil
}

struct DBAssetCatalogSyncStateRecord:
    Codable,
    FetchableRecord,
    PersistableRecord,
    Sendable {
    static let databaseTableName = "assetCatalogSyncState"

    let id: String
    let revision: Int64
    let didCompleteInitialSync: Bool
    let updatedAt: Double
    /// What the cached snapshot covers (see `WalletAssetCatalogPersistence.currentScope`).
    /// Empty for caches written before scopes existed.
    var scope: String = ""
}

struct DBAssetCatalogPublicationRecord:
    Codable,
    FetchableRecord,
    PersistableRecord,
    Sendable {
    static let databaseTableName = "assetCatalogPublicationOutbox"

    let assetIdentity: String
    let networkID: String
    let contractAddress: String
    let name: String
    let symbol: String
    let decimals: Int
    let attemptCount: Int
    let nextAttemptAt: Double
    let lastErrorCode: String?
    let createdAt: Double
    let updatedAt: Double
}

struct AssetCatalogRemoteEntry: Equatable, Sendable {
    let assetIdentity: String
    let tokenID: String
    let networkID: String
    let contractAddress: String?
    let name: String
    let symbol: String
    let decimals: Int
    let globalRank: Int64
    let networkRank: Int64?
    let isStablecoin: Bool?
    let logoURL: String?
    let marketDataID: String?
    let tokenOrder: Int64
    let variantOrder: Int
    let source: AssetCatalogEntrySource
    let isVerified: Bool
    let isActive: Bool
    let revision: Int64
    var assetFamily: String? = nil
}

struct AssetCatalogCacheState: Equatable, Sendable {
    let revision: Int64
    let didCompleteInitialSync: Bool
    var scope: String = ""

    /// True when the cached snapshot was fetched for exactly the networks and
    /// entry fields this build understands. A build that adds a network or a
    /// field must refetch the snapshot even when the server generation has
    /// not moved; otherwise the cache silently lacks the new rows and columns
    /// and, because the generation matches, would never be refreshed.
    var coversCurrentScope: Bool {
        scope == WalletAssetCatalogPersistence.currentScope
    }
}

enum AssetCatalogEntryValidation {
    static let maximumSafeInteger: Int64 = 9_007_199_254_740_991

    static func isValidRemoteText(
        _ value: String,
        maximumLength: Int
    ) -> Bool {
        let trimmed = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return value == trimmed
            && !value.isEmpty
            && value.count <= maximumLength
            && !value.unicodeScalars.contains { scalar in
                CharacterSet.controlCharacters.contains(scalar)
                    || CharacterSet(charactersIn: "<>\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}")
                        .contains(scalar)
            }
    }

    static func isValidSafeInteger(_ value: Int64) -> Bool {
        (-maximumSafeInteger...maximumSafeInteger).contains(value)
    }

    static func isValidCatalogLogoURL(_ value: String?) -> Bool {
        guard let value else { return true }
        guard let url = URL(string: value),
              url.scheme == "oath-asset", url.host == "catalog",
              url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              url.pathComponents.count == 2,
              url.pathExtension == "png" else { return false }
        let filename = url.lastPathComponent
        return !filename.isEmpty && filename.count <= 200
            && filename.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") }
            && !filename.contains("..")
    }

    /// A family identifier is short, lowercase and machine-readable; a
    /// value this build does not know is still valid (it resolves to nil).
    static func isValidAssetFamily(_ value: String?) -> Bool {
        guard let value else { return true }
        guard (1...32).contains(value.count) else { return false }
        return value.allSatisfy {
            $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "_")
        }
    }

    static func isValidMarketDataID(_ value: String?) -> Bool {
        guard let value else { return true }
        return isValidRemoteText(value, maximumLength: 128)
            && !value.contains(where: \.isWhitespace)
    }
}

enum WalletAssetCatalogPersistence {
    static let metadataID = "send-receive"
    static let syncStateID = "primary"
    static let remoteVersion = "oath-bundled-v4"

    static func loadCachedTokens(
        in database: Database
    ) throws -> [ReceiveToken] {
        let entries = try DBAssetCatalogEntryRecord.fetchAll(
            database,
            sql: """
            SELECT *
            FROM assetCatalogEntries
            WHERE isActive = 1
            ORDER BY tokenOrder ASC, variantOrder ASC, assetIdentity ASC
            """
        )
        guard !entries.isEmpty else { return [] }

        struct TokenAccumulator {
            var firstOrder: Int64
            var name: String
            var symbol: String
            var rank: Int
            var isStablecoin: Bool?
            var variants: [(order: Int, variant: ReceiveTokenVariant)]
            var networkIDs: Set<String>
        }

        var tokenOrder: [String] = []
        var accumulators: [String: TokenAccumulator] = [:]
        var assetIdentities = Set<String>()

        for entry in entries {
            let identity = AssetIdentityKey.canonical(entry.assetIdentity)
            guard
                let source = AssetCatalogEntrySource(
                    rawValue: entry.source
                ),
                source != .legacy,
                (
                    source == .community
                        ? !entry.isVerified
                        : entry.isVerified
                ),
                entry.revision > 0,
                AssetCatalogEntryValidation.isValidSafeInteger(
                    entry.revision
                ),
                ReceiveNetworkCatalog.catalogNetwork(
                    for: entry.networkID
                ) != nil,
                (0...255).contains(entry.decimals),
                !entry.tokenID.isEmpty,
                !entry.name.isEmpty,
                !entry.symbol.isEmpty,
                AssetCatalogEntryValidation.isValidCatalogLogoURL(
                    entry.logoURL
                ),
                AssetCatalogEntryValidation.isValidMarketDataID(
                    entry.marketDataID
                ),
                AssetCatalogEntryValidation.isValidAssetFamily(
                    entry.assetFamily
                ),
                identity == AssetIdentityKey.canonical(
                    AssetIdentityKey.make(
                        networkID: entry.networkID,
                        contractAddress: entry.contractAddress
                    )
                ),
                assetIdentities.insert(identity).inserted,
                let globalRank = Int(exactly: entry.globalRank),
                entry.networkRank.flatMap(Int.init(exactly:)) != nil
                    || entry.networkRank == nil
            else {
                throw ReceiveAssetCatalogStorageError
                    .invalidPersistedEntry(entry.assetIdentity)
            }

            let variant = ReceiveTokenVariant(
                networkID: entry.networkID,
                contractAddress: entry.contractAddress,
                decimals: entry.decimals,
                networkRank: entry.networkRank.flatMap(Int.init(exactly:)),
                logoURL: entry.logoURL,
                marketDataID: entry.marketDataID,
                isVerified: entry.isVerified,
                family: entry.assetFamily.flatMap(AssetFamily.init(rawValue:))
            )

            if var accumulator = accumulators[entry.tokenID] {
                guard accumulator.networkIDs.insert(entry.networkID).inserted
                else {
                    throw ReceiveAssetCatalogStorageError
                        .invalidPersistedEntry(entry.assetIdentity)
                }
                if entry.tokenOrder < accumulator.firstOrder {
                    accumulator.firstOrder = entry.tokenOrder
                    accumulator.name = entry.name
                    accumulator.symbol = entry.symbol
                    accumulator.rank = globalRank
                    accumulator.isStablecoin = entry.isStablecoin
                }
                accumulator.variants.append((entry.variantOrder, variant))
                accumulators[entry.tokenID] = accumulator
            } else {
                tokenOrder.append(entry.tokenID)
                accumulators[entry.tokenID] = TokenAccumulator(
                    firstOrder: entry.tokenOrder,
                    name: entry.name,
                    symbol: entry.symbol,
                    rank: globalRank,
                    isStablecoin: entry.isStablecoin,
                    variants: [(entry.variantOrder, variant)],
                    networkIDs: [entry.networkID]
                )
            }
        }

        return tokenOrder.compactMap { tokenID in
            guard let accumulator = accumulators[tokenID] else {
                return nil
            }
            return ReceiveToken(
                id: tokenID,
                name: accumulator.name,
                symbol: accumulator.symbol,
                rank: accumulator.rank,
                isStablecoin: accumulator.isStablecoin,
                variants: accumulator.variants
                    .sorted { lhs, rhs in
                        if lhs.order != rhs.order {
                            return lhs.order < rhs.order
                        }
                        return lhs.variant.networkID
                            < rhs.variant.networkID
                    }
                    .map(\.variant)
            )
        }
        .sorted { lhs, rhs in
            let lhsOrder = accumulators[lhs.id]?.firstOrder ?? .max
            let rhsOrder = accumulators[rhs.id]?.firstOrder ?? .max
            if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
            return lhs.id < rhs.id
        }
    }

    /// The catalog fields this build reads, followed by the networks it asks
    /// the service for. Stored with every installed snapshot and compared on
    /// each sync; bump the schema part whenever the app starts reading a new
    /// catalog field so existing installs fetch it.
    static let catalogSchemaVersion = 2
    static let currentScope: String =
        "\(catalogSchemaVersion):"
        + ReceiveNetworkCatalog.catalogNetworkIdentifiers.joined(separator: ",")

    static func cacheState(
        in database: Database
    ) throws -> AssetCatalogCacheState {
        guard let state = try DBAssetCatalogSyncStateRecord.fetchOne(
            database,
            key: syncStateID
        ) else {
            return AssetCatalogCacheState(
                revision: 0,
                didCompleteInitialSync: false
            )
        }
        return AssetCatalogCacheState(
            revision: state.revision,
            didCompleteInitialSync: state.didCompleteInitialSync,
            scope: state.scope
        )
    }

    static func loadCompleteCachedTokens(
        in database: Database
    ) throws -> [ReceiveToken] {
        let state = try cacheState(in: database)
        guard state.didCompleteInitialSync else { return [] }
        guard
            state.revision > 0,
            let metadata = try DBAssetCatalogMetadataRecord.fetchOne(
                database,
                key: metadataID
            ),
            metadata.version == remoteVersion,
            metadata.entryCount > 0,
            metadata.entryCount
                == (try DBAssetCatalogEntryRecord.fetchCount(database)),
            try Int.fetchOne(
                database,
                sql: """
                SELECT COUNT(*)
                FROM assetCatalogEntries
                WHERE revision <= 0 OR revision > ?
                """,
                arguments: [state.revision]
            ) == 0
        else {
            throw ReceiveAssetCatalogStorageError
                .invalidPersistedEntry(metadataID)
        }
        let tokens = try loadCachedTokens(in: database)
        guard !tokens.isEmpty else {
            throw ReceiveAssetCatalogStorageError.emptyCatalog
        }
        return tokens
    }

    static func replaceRemoteSnapshot(
        _ entries: [AssetCatalogRemoteEntry],
        revision: Int64,
        allowSameRevisionRepair: Bool = false,
        in database: Database,
        now: Double = Date().timeIntervalSince1970
    ) throws {
        guard !entries.isEmpty,
              revision > 0,
              AssetCatalogEntryValidation.isValidSafeInteger(revision)
        else {
            throw ReceiveAssetCatalogStorageError.emptyCatalog
        }

        // This check must remain inside the caller's database write
        // transaction. A newer snapshot may have committed after the service
        // read its manifest but before this destructive replacement begins.
        let installedState = try cacheState(in: database)
        let repairsIncompleteCurrentRevision: Bool
        if allowSameRevisionRepair,
           revision == installedState.revision {
            let hasCompleteCurrentGeneration = (
                try? !loadCompleteCachedTokens(in: database).isEmpty
            ) == true
            // A complete cache from a narrower scope (an older build's
            // network list or fields) is still stale for this build.
            repairsIncompleteCurrentRevision =
                !hasCompleteCurrentGeneration
                || !installedState.coversCurrentScope
        } else {
            repairsIncompleteCurrentRevision = false
        }
        guard revision > installedState.revision
                || repairsIncompleteCurrentRevision else {
            throw ReceiveAssetCatalogStorageError.invalidRemoteCursor
        }

        var identities = Set<String>()
        var orderingKeys = Set<String>()
        var records: [DBAssetCatalogEntryRecord] = []
        records.reserveCapacity(entries.count)

        for entry in entries {
            let identity = AssetIdentityKey.canonical(entry.assetIdentity)
            let orderingKey = "\(entry.tokenOrder):\(entry.variantOrder)"
            guard
                entry.revision > 0,
                entry.revision <= revision,
                entry.source != .legacy,
                (
                    entry.source == .community
                        ? !entry.isVerified
                        : entry.isVerified
                ),
                entry.isActive,
                ReceiveNetworkCatalog.catalogNetwork(
                    for: entry.networkID
                ) != nil,
                (0...255).contains(entry.decimals),
                AssetCatalogEntryValidation.isValidRemoteText(
                    entry.tokenID,
                    maximumLength: 640
                ),
                AssetCatalogEntryValidation.isValidRemoteText(
                    entry.name,
                    maximumLength: 160
                ),
                AssetCatalogEntryValidation.isValidRemoteText(
                    entry.symbol,
                    maximumLength: 48
                ),
                entry.contractAddress.map({
                    !$0.isEmpty && $0.count <= 600
                }) ?? true,
                identity == entry.assetIdentity,
                identity == AssetIdentityKey.canonical(
                    AssetIdentityKey.make(
                        networkID: entry.networkID,
                        contractAddress: entry.contractAddress
                    )
                ),
                identities.insert(identity).inserted,
                orderingKeys.insert(orderingKey).inserted,
                AssetCatalogEntryValidation.isValidSafeInteger(
                    entry.globalRank
                ),
                entry.networkRank.map(
                    AssetCatalogEntryValidation.isValidSafeInteger
                ) ?? true,
                entry.tokenOrder >= 0,
                AssetCatalogEntryValidation.isValidSafeInteger(
                    entry.tokenOrder
                ),
                entry.variantOrder >= 0,
                AssetCatalogEntryValidation.isValidCatalogLogoURL(
                    entry.logoURL
                ),
                AssetCatalogEntryValidation.isValidMarketDataID(
                    entry.marketDataID
                ),
                AssetCatalogEntryValidation.isValidAssetFamily(
                    entry.assetFamily
                )
            else {
                throw ReceiveAssetCatalogStorageError
                    .invalidRemoteEntry(entry.assetIdentity)
            }

            let denied = entry.contractAddress.map {
                TokenSafetyPolicy.isHardDenied(
                    networkID: entry.networkID,
                    contractAddress: $0
                )
            } ?? false
            records.append(
                DBAssetCatalogEntryRecord(
                    assetIdentity: identity,
                    tokenID: entry.tokenID,
                    networkID: entry.networkID,
                    contractAddress: entry.contractAddress,
                    name: entry.name,
                    symbol: entry.symbol,
                    decimals: entry.decimals,
                    globalRank: entry.globalRank,
                    networkRank: entry.networkRank,
                    isStablecoin: entry.isStablecoin,
                    logoURL: entry.logoURL,
                    tokenOrder: entry.tokenOrder,
                    variantOrder: entry.variantOrder,
                    marketDataID: entry.marketDataID,
                    source: entry.source.rawValue,
                    isVerified: entry.isVerified,
                    isActive: !denied,
                    revision: entry.revision,
                    assetFamily: entry.assetFamily
                )
            )
        }

        try DBAssetCatalogEntryRecord.deleteAll(database)
        for record in records {
            try record.insert(database)
        }
        try DBAssetCatalogMetadataRecord(
            id: metadataID,
            version: remoteVersion,
            entryCount: records.count,
            updatedAt: now
        ).save(database)
        try saveSyncState(
            revision: revision,
            didCompleteInitialSync: true,
            in: database,
            now: now
        )
    }

    static func applyRemoteEntries(
        _ entries: [AssetCatalogRemoteEntry],
        nextRevision: Int64,
        in database: Database,
        now: Double = Date().timeIntervalSince1970
    ) throws {
        let state = try cacheState(in: database)
        guard nextRevision >= state.revision else {
            throw ReceiveAssetCatalogStorageError.invalidRemoteCursor
        }

        var previousRevision = state.revision
        for entry in entries {
            guard
                entry.revision > previousRevision,
                entry.revision <= nextRevision,
                entry.source != .legacy,
                entry.source == .community ? !entry.isVerified : entry.isVerified,
                ReceiveNetworkCatalog.catalogNetwork(
                    for: entry.networkID
                ) != nil,
                (0...255).contains(entry.decimals),
                AssetCatalogEntryValidation.isValidRemoteText(
                    entry.tokenID,
                    maximumLength: 640
                ),
                AssetCatalogEntryValidation.isValidRemoteText(
                    entry.name,
                    maximumLength: 160
                ),
                AssetCatalogEntryValidation.isValidRemoteText(
                    entry.symbol,
                    maximumLength: 48
                ),
                (entry.contractAddress.map {
                    !$0.isEmpty && $0.count <= 600
                } ?? true),
                entry.assetIdentity.count <= 640,
                AssetCatalogEntryValidation.isValidSafeInteger(
                    entry.globalRank
                ),
                entry.networkRank.map(
                    AssetCatalogEntryValidation.isValidSafeInteger
                ) ?? true,
                entry.tokenOrder >= 0,
                AssetCatalogEntryValidation.isValidSafeInteger(
                    entry.tokenOrder
                ),
                entry.variantOrder >= 0,
                AssetCatalogEntryValidation.isValidCatalogLogoURL(
                    entry.logoURL
                ),
                AssetCatalogEntryValidation.isValidMarketDataID(
                    entry.marketDataID
                ),
                AssetCatalogEntryValidation.isValidAssetFamily(
                    entry.assetFamily
                ),
                entry.assetIdentity == AssetIdentityKey.canonical(
                    AssetIdentityKey.make(
                        networkID: entry.networkID,
                        contractAddress: entry.contractAddress
                    )
                )
            else {
                throw ReceiveAssetCatalogStorageError
                    .invalidRemoteEntry(entry.assetIdentity)
            }
            previousRevision = entry.revision

            let denied = entry.contractAddress.map {
                TokenSafetyPolicy.isHardDenied(
                    networkID: entry.networkID,
                    contractAddress: $0
                )
            } ?? false
            let record = DBAssetCatalogEntryRecord(
                assetIdentity: entry.assetIdentity,
                tokenID: entry.tokenID,
                networkID: entry.networkID,
                contractAddress: entry.contractAddress,
                name: entry.name,
                symbol: entry.symbol,
                decimals: entry.decimals,
                globalRank: entry.globalRank,
                networkRank: entry.networkRank,
                isStablecoin: entry.isStablecoin,
                logoURL: entry.logoURL,
                tokenOrder: entry.tokenOrder,
                variantOrder: entry.variantOrder,
                marketDataID: entry.marketDataID,
                source: entry.source.rawValue,
                isVerified: entry.isVerified,
                isActive: entry.isActive && !denied,
                revision: entry.revision,
                assetFamily: entry.assetFamily
            )
            try record.save(database)
        }

        guard entries.isEmpty || previousRevision == nextRevision else {
            throw ReceiveAssetCatalogStorageError.invalidRemoteCursor
        }
        try saveSyncState(
            revision: nextRevision,
            didCompleteInitialSync: state.didCompleteInitialSync,
            in: database,
            now: now
        )
    }

    static func finishRemoteSync(
        revision: Int64,
        in database: Database,
        now: Double = Date().timeIntervalSince1970
    ) throws {
        let state = try cacheState(in: database)
        guard revision == state.revision else {
            throw ReceiveAssetCatalogStorageError.invalidRemoteCursor
        }

        try database.execute(
            sql: "DELETE FROM assetCatalogEntries WHERE revision = 0"
        )
        let count = try DBAssetCatalogEntryRecord.fetchCount(database)
        guard count > 0 else {
            throw ReceiveAssetCatalogStorageError.emptyCatalog
        }
        let metadata = DBAssetCatalogMetadataRecord(
            id: metadataID,
            version: remoteVersion,
            entryCount: count,
            updatedAt: now
        )
        try metadata.save(database)
        try saveSyncState(
            revision: revision,
            didCompleteInitialSync: true,
            in: database,
            now: now
        )
    }

    static func enqueuePublication(
        networkID: String,
        contractAddress: String,
        name: String,
        symbol: String,
        decimals: Int,
        in database: Database,
        now: Double = Date().timeIntervalSince1970
    ) throws {
        let identity = AssetIdentityKey.canonical(
            AssetIdentityKey.make(
                networkID: networkID,
                contractAddress: contractAddress
            )
        )
        let record = DBAssetCatalogPublicationRecord(
            assetIdentity: identity,
            networkID: networkID,
            contractAddress: contractAddress,
            name: name,
            symbol: symbol,
            decimals: decimals,
            attemptCount: 0,
            nextAttemptAt: now,
            lastErrorCode: nil,
            createdAt: now,
            updatedAt: now
        )
        try database.execute(
            sql: """
            INSERT INTO assetCatalogPublicationOutbox (
                assetIdentity, networkID, contractAddress, name, symbol,
                decimals, attemptCount, nextAttemptAt, lastErrorCode,
                createdAt, updatedAt
            ) VALUES (?, ?, ?, ?, ?, ?, 0, ?, NULL, ?, ?)
            ON CONFLICT(assetIdentity) DO UPDATE SET
                name = excluded.name,
                symbol = excluded.symbol,
                decimals = excluded.decimals,
                attemptCount = 0,
                nextAttemptAt = excluded.nextAttemptAt,
                lastErrorCode = NULL,
                updatedAt = excluded.updatedAt
            """,
            arguments: [
                record.assetIdentity,
                record.networkID,
                record.contractAddress,
                record.name,
                record.symbol,
                record.decimals,
                record.nextAttemptAt,
                record.createdAt,
                record.updatedAt
            ]
        )
    }

    static func duePublications(
        in database: Database,
        now: Double = Date().timeIntervalSince1970,
        limit: Int = 20
    ) throws -> [DBAssetCatalogPublicationRecord] {
        try DBAssetCatalogPublicationRecord.fetchAll(
            database,
            sql: """
            SELECT *
            FROM assetCatalogPublicationOutbox
            WHERE nextAttemptAt <= ?
            ORDER BY createdAt ASC, assetIdentity ASC
            LIMIT ?
            """,
            arguments: [now, max(1, min(limit, 50))]
        )
    }

    static func publicationDidSucceed(
        assetIdentity: String,
        in database: Database
    ) throws {
        try DBAssetCatalogPublicationRecord.deleteOne(
            database,
            key: assetIdentity
        )
    }

    static func publicationDidFail(
        _ publication: DBAssetCatalogPublicationRecord,
        errorCode: String,
        in database: Database,
        now: Double = Date().timeIntervalSince1970
    ) throws {
        let attemptCount = min(publication.attemptCount + 1, 20)
        let exponent = min(attemptCount, 10)
        let delay = min(pow(2, Double(exponent)) * 30, 86_400)
        try database.execute(
            sql: """
            UPDATE assetCatalogPublicationOutbox
            SET attemptCount = ?, nextAttemptAt = ?, lastErrorCode = ?,
                updatedAt = ?
            WHERE assetIdentity = ?
            """,
            arguments: [
                attemptCount,
                now + delay,
                String(errorCode.prefix(160)),
                now,
                publication.assetIdentity
            ]
        )
    }

    private static func saveSyncState(
        revision: Int64,
        didCompleteInitialSync: Bool,
        in database: Database,
        now: Double
    ) throws {
        try DBAssetCatalogSyncStateRecord(
            id: syncStateID,
            revision: revision,
            didCompleteInitialSync: didCompleteInitialSync,
            updatedAt: now,
            scope: didCompleteInitialSync ? currentScope : ""
        ).save(database)
    }
}

extension WalletDatabase {
    static func registerAssetCatalogMigration(
        on migrator: inout DatabaseMigrator
    ) {
        migrator.registerMigration(
            "v42_normalized_send_receive_asset_catalog"
        ) { database in
            try database.execute(
                sql: """
                CREATE TABLE assetCatalogMetadata (
                    id TEXT PRIMARY KEY NOT NULL,
                    version TEXT NOT NULL,
                    entryCount INTEGER NOT NULL CHECK (entryCount > 0),
                    updatedAt REAL NOT NULL
                ) WITHOUT ROWID;

                CREATE TABLE assetCatalogEntries (
                    assetIdentity TEXT PRIMARY KEY NOT NULL,
                    tokenID TEXT NOT NULL CHECK (length(tokenID) > 0),
                    networkID TEXT NOT NULL
                        REFERENCES networks(id) ON DELETE CASCADE,
                    contractAddress TEXT,
                    name TEXT NOT NULL CHECK (length(name) > 0),
                    symbol TEXT NOT NULL CHECK (length(symbol) > 0),
                    decimals INTEGER NOT NULL
                        CHECK (decimals BETWEEN 0 AND 255),
                    globalRank INTEGER NOT NULL,
                    networkRank INTEGER,
                    isStablecoin INTEGER
                        CHECK (isStablecoin IS NULL OR isStablecoin IN (0, 1)),
                    logoURL TEXT,
                    tokenOrder INTEGER NOT NULL CHECK (tokenOrder >= 0),
                    variantOrder INTEGER NOT NULL CHECK (variantOrder >= 0)
                ) WITHOUT ROWID;

                CREATE INDEX assetCatalogEntries_network_rank
                    ON assetCatalogEntries(
                        networkID,
                        networkRank,
                        globalRank,
                        tokenOrder
                    );

                CREATE INDEX assetCatalogEntries_token
                    ON assetCatalogEntries(tokenID, variantOrder);

                CREATE UNIQUE INDEX assetCatalogEntries_order
                    ON assetCatalogEntries(tokenOrder, variantOrder);
                """
            )
        }

    }

    static func registerAssetCatalogScopeMigration(
        on migrator: inout DatabaseMigrator
    ) {
        migrator.registerMigration(
            "v79_asset_catalog_sync_scope"
        ) { database in
            // Existing caches get an empty scope, which never matches the
            // current one, so the first sync after this update refetches the
            // snapshot for this build's networks and fields.
            try database.execute(
                sql: "ALTER TABLE assetCatalogSyncState ADD COLUMN scope TEXT NOT NULL DEFAULT '';"
            )
        }
    }

    static func registerAssetCatalogFamilyMigration(
        on migrator: inout DatabaseMigrator
    ) {
        migrator.registerMigration(
            "v53_asset_catalog_families"
        ) { database in
            try database.execute(
                sql: "ALTER TABLE assetCatalogEntries ADD COLUMN assetFamily TEXT;"
            )
        }
    }

    static func registerRemoteAssetCatalogMigration(
        on migrator: inout DatabaseMigrator
    ) {
        migrator.registerMigration(
            "v49_remote_asset_catalog_cache"
        ) { database in
            try database.execute(
                sql: """
                ALTER TABLE assetCatalogEntries
                    ADD COLUMN marketDataID TEXT;
                ALTER TABLE assetCatalogEntries
                    ADD COLUMN source TEXT NOT NULL DEFAULT 'legacy';
                ALTER TABLE assetCatalogEntries
                    ADD COLUMN isVerified INTEGER NOT NULL DEFAULT 1;
                ALTER TABLE assetCatalogEntries
                    ADD COLUMN isActive INTEGER NOT NULL DEFAULT 1;
                ALTER TABLE assetCatalogEntries
                    ADD COLUMN revision INTEGER NOT NULL DEFAULT 0;

                DROP INDEX IF EXISTS assetCatalogEntries_order;
                CREATE INDEX assetCatalogEntries_order
                    ON assetCatalogEntries(
                        tokenOrder, variantOrder, assetIdentity
                    );
                CREATE INDEX assetCatalogEntries_revision
                    ON assetCatalogEntries(revision);

                CREATE TABLE assetCatalogSyncState (
                    id TEXT PRIMARY KEY NOT NULL,
                    revision INTEGER NOT NULL DEFAULT 0
                        CHECK (revision >= 0),
                    didCompleteInitialSync INTEGER NOT NULL DEFAULT 0
                        CHECK (didCompleteInitialSync IN (0, 1)),
                    updatedAt REAL NOT NULL
                ) WITHOUT ROWID;

                CREATE TABLE assetCatalogPublicationOutbox (
                    assetIdentity TEXT PRIMARY KEY NOT NULL,
                    networkID TEXT NOT NULL
                        REFERENCES networks(id) ON DELETE CASCADE,
                    contractAddress TEXT NOT NULL,
                    name TEXT NOT NULL CHECK (length(name) > 0),
                    symbol TEXT NOT NULL CHECK (length(symbol) > 0),
                    decimals INTEGER NOT NULL
                        CHECK (decimals BETWEEN 0 AND 255),
                    attemptCount INTEGER NOT NULL DEFAULT 0
                        CHECK (attemptCount >= 0),
                    nextAttemptAt REAL NOT NULL,
                    lastErrorCode TEXT,
                    createdAt REAL NOT NULL,
                    updatedAt REAL NOT NULL
                ) WITHOUT ROWID;
                CREATE INDEX assetCatalogPublicationOutbox_due
                    ON assetCatalogPublicationOutbox(
                        nextAttemptAt, createdAt
                    );
                """
            )
        }
    }
}
