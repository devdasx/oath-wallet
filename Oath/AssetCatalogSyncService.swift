import Foundation

enum AssetCatalogSyncError: Error, Equatable, Sendable {
    case invalidResponse
    case invalidInteger(String)
    case nonAdvancingCursor
    case excessivePageCount
}

protocol AssetCatalogRemoteDataClient: Sendable {
    func invokeData(
        functionPath: String,
        payload: Data
    ) async throws -> Data
}

/// Reads only the catalog packaged with this app release. It has no network client,
/// credentials, wallet identifiers, or publication operation.
struct BundledAssetCatalogClient: AssetCatalogRemoteDataClient {
    private let bundle: Bundle

    init(bundle: Bundle = .main) { self.bundle = bundle }

    func invokeData(functionPath: String, payload: Data) async throws -> Data {
        try Task.checkCancellation()
        guard functionPath == "bundled-asset-catalog",
              let request = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let action = request["action"] as? String,
              action == "manifest" || action == "snapshot",
              let networkIDs = request["network_ids"] as? [String],
              let url = bundle.url(forResource: "asset-catalog", withExtension: "json"),
              let snapshot = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
              let revision = snapshot["snapshot_revision"] as? String,
              let allEntries = snapshot["entries"] as? [[String: Any]] else {
            throw AssetCatalogSyncError.invalidResponse
        }
        let scope = Set(networkIDs)
        let entries = allEntries.filter { entry in
            (entry["network_id"] as? String).map(scope.contains) == true
        }
        var response: [String: Any] = [
            "snapshot_revision": revision,
            "entry_count": entries.count
        ]
        if action == "snapshot" { response["entries"] = entries }
        return try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
    }
}

// Every read names the networks this build can install. The service scopes
// its answer to them, so a network added after this build shipped never
// reaches a client that would reject the whole page because of it.
private struct AssetCatalogManifestRequest: Encodable {
    let action = "manifest"
    let networkIDs = ReceiveNetworkCatalog.catalogNetworkIdentifiers

    enum CodingKeys: String, CodingKey {
        case action
        case networkIDs = "network_ids"
    }
}

private struct AssetCatalogSnapshotRequest: Encodable {
    let action = "snapshot"
    let networkIDs = ReceiveNetworkCatalog.catalogNetworkIdentifiers

    enum CodingKeys: String, CodingKey {
        case action
        case networkIDs = "network_ids"
    }
}

private struct AssetCatalogManifestResponse: Decodable {
    let snapshotRevision: String
    let entryCount: Int

    enum CodingKeys: String, CodingKey {
        case snapshotRevision = "snapshot_revision"
        case entryCount = "entry_count"
    }
}

private struct AssetCatalogSnapshotResponse: Decodable {
    let snapshotRevision: String
    let entryCount: Int
    let entries: [AssetCatalogRemoteEntryResponse]

    enum CodingKeys: String, CodingKey {
        case snapshotRevision = "snapshot_revision"
        case entryCount = "entry_count"
        case entries
    }
}

private struct AssetCatalogRemoteEntryResponse: Decodable {
    let assetIdentity: String
    let tokenID: String
    let networkID: String
    let contractAddress: String?
    let name: String
    let symbol: String
    let decimals: Int
    let globalRank: String
    let networkRank: String?
    let isStablecoin: Bool?
    let logoURL: String?
    let marketDataID: String?
    let tokenOrder: String
    let variantOrder: Int
    let source: String
    let isVerified: Bool
    let isActive: Bool
    let revision: String
    let assetFamily: String?

    enum CodingKeys: String, CodingKey {
        case assetIdentity = "asset_identity"
        case tokenID = "token_id"
        case networkID = "network_id"
        case contractAddress = "contract_address"
        case name
        case symbol
        case decimals
        case globalRank = "global_rank"
        case networkRank = "network_rank"
        case isStablecoin = "is_stablecoin"
        case logoURL = "logo_url"
        case marketDataID = "market_data_id"
        case tokenOrder = "token_order"
        case variantOrder = "variant_order"
        case source
        case isVerified = "is_verified"
        case isActive = "is_active"
        case revision
        case assetFamily = "asset_family"
    }

    func validatedEntry() throws -> AssetCatalogRemoteEntry {
        guard
            let globalRank = Int64(globalRank),
            let tokenOrder = Int64(tokenOrder),
            let revision = Int64(revision),
            revision > 0,
            AssetCatalogEntryValidation.isValidSafeInteger(globalRank),
            tokenOrder >= 0,
            AssetCatalogEntryValidation.isValidSafeInteger(tokenOrder),
            AssetCatalogEntryValidation.isValidSafeInteger(revision),
            variantOrder >= 0,
            AssetCatalogEntryValidation.isValidCatalogLogoURL(logoURL),
            AssetCatalogEntryValidation.isValidMarketDataID(marketDataID),
            AssetCatalogEntryValidation.isValidAssetFamily(assetFamily),
            let source = AssetCatalogEntrySource(rawValue: source),
            source != .legacy
        else {
            throw AssetCatalogSyncError.invalidInteger(assetIdentity)
        }
        let networkRank: Int64?
        if let rawNetworkRank = self.networkRank {
            guard
                let parsed = Int64(rawNetworkRank),
                AssetCatalogEntryValidation.isValidSafeInteger(parsed)
            else {
                throw AssetCatalogSyncError.invalidInteger(assetIdentity)
            }
            networkRank = parsed
        } else {
            networkRank = nil
        }
        return AssetCatalogRemoteEntry(
            assetIdentity: AssetIdentityKey.canonical(assetIdentity),
            tokenID: tokenID,
            networkID: networkID,
            contractAddress: contractAddress,
            name: name,
            symbol: symbol,
            decimals: decimals,
            globalRank: globalRank,
            networkRank: networkRank,
            isStablecoin: isStablecoin,
            logoURL: logoURL,
            marketDataID: marketDataID,
            tokenOrder: tokenOrder,
            variantOrder: variantOrder,
            source: source,
            isVerified: isVerified,
            isActive: isActive,
            revision: revision,
            assetFamily: assetFamily
        )
    }
}

extension Notification.Name {
    static let walletAssetCatalogDidChange = Notification.Name(
        "wallet.assetCatalog.didChange"
    )
}

actor AssetCatalogSyncService {
    static let shared = AssetCatalogSyncService()

    private static let functionPath = "bundled-asset-catalog"
    private static let maximumSnapshotEntries = 10_000

    private struct SynchronizationFlight {
        let id: UUID
        let requestedGeneration: UInt64
        let task: Task<Void, Error>
    }

    private let client: any AssetCatalogRemoteDataClient
    private var synchronizationFlights:
        [ObjectIdentifier: SynchronizationFlight] = [:]
    private var requestedGenerations: [ObjectIdentifier: UInt64] = [:]
    private var completedGenerations: [ObjectIdentifier: UInt64] = [:]

    init(
        client: any AssetCatalogRemoteDataClient =
            BundledAssetCatalogClient()
    ) {
        self.client = client
    }

    func synchronize(database: WalletDatabase) async {
        try? await synchronizeAndWait(database: database)
    }

    func synchronizeAndWait(database: WalletDatabase) async throws {
        let databaseID = ObjectIdentifier(database)
        let requestedGeneration = (requestedGenerations[databaseID] ?? 0) + 1
        requestedGenerations[databaseID] = requestedGeneration

        while (completedGenerations[databaseID] ?? 0) < requestedGeneration {
            let flight: SynchronizationFlight
            if let current = synchronizationFlights[databaseID] {
                flight = current
            } else {
                let client = client
                let flightID = UUID()
                let generation = requestedGenerations[databaseID] ?? 0
                let task = Task(priority: .utility) {
                    try await Self.performSynchronization(
                        database: database,
                        client: client
                    )
                }
                flight = SynchronizationFlight(
                    id: flightID,
                    requestedGeneration: generation,
                    task: task
                )
                synchronizationFlights[databaseID] = flight
            }

            do {
                try await flight.task.value
            } catch {
                if synchronizationFlights[databaseID]?.id == flight.id {
                    synchronizationFlights[databaseID] = nil
                }
                throw error
            }
            if synchronizationFlights[databaseID]?.id == flight.id {
                completedGenerations[databaseID] = max(
                    completedGenerations[databaseID] ?? 0,
                    flight.requestedGeneration
                )
                synchronizationFlights[databaseID] = nil
            }
        }
    }

    nonisolated static func schedule(database: WalletDatabase) {
        Task(priority: .utility) {
            await shared.synchronize(database: database)
        }
    }

    private static func performSynchronization(
        database: WalletDatabase,
        client: any AssetCatalogRemoteDataClient
    ) async throws {
        let state = try await database.pool.read { database in
            try WalletAssetCatalogPersistence.cacheState(in: database)
        }
        let manifestData = try await client.invokeData(
            functionPath: functionPath,
            payload: try JSONEncoder().encode(
                AssetCatalogManifestRequest()
            )
        )
        let manifest: AssetCatalogManifestResponse
        do {
            manifest = try JSONDecoder().decode(
                AssetCatalogManifestResponse.self,
                from: manifestData
            )
        } catch {
            throw AssetCatalogSyncError.invalidResponse
        }
        guard let manifestRevision = Int64(manifest.snapshotRevision),
              manifestRevision > 0,
              AssetCatalogEntryValidation.isValidSafeInteger(
                  manifestRevision
              ),
              (1...maximumSnapshotEntries).contains(
                  manifest.entryCount
              ) else {
            throw AssetCatalogSyncError.invalidResponse
        }

        // A full snapshot is destructive by design. Never download one for a
        // manifest that is older than the generation already installed.
        // Persistence repeats this check transactionally before deleting rows
        // so a stale in-flight response cannot win a race with a newer sync.
        guard manifestRevision >= state.revision else { return }

        let allowsSameRevisionRepair =
            manifestRevision == state.revision

        // The cache is only current when it was fetched by a build with the
        // same network list and catalog fields. After an app update that adds
        // a network, the server generation is unchanged but the cache lacks
        // the new rows, so the snapshot must be fetched again.
        if state.didCompleteInitialSync,
           state.coversCurrentScope,
           state.revision == manifestRevision {
            let hasCompleteGeneration = (
                try? await database.pool.read { database in
                    try !WalletAssetCatalogPersistence
                        .loadCompleteCachedTokens(in: database).isEmpty
                }
            ) == true
            if hasCompleteGeneration { return }
        }

        try Task.checkCancellation()
        let snapshotData = try await client.invokeData(
            functionPath: functionPath,
            payload: try JSONEncoder().encode(
                AssetCatalogSnapshotRequest()
            )
        )
        let snapshot: AssetCatalogSnapshotResponse
        do {
            snapshot = try JSONDecoder().decode(
                AssetCatalogSnapshotResponse.self,
                from: snapshotData
            )
        } catch {
            throw AssetCatalogSyncError.invalidResponse
        }
        guard let snapshotRevision = Int64(snapshot.snapshotRevision),
              snapshotRevision >= manifestRevision,
              snapshotRevision > state.revision
                || (
                    allowsSameRevisionRepair
                        && snapshotRevision == state.revision
                ),
              AssetCatalogEntryValidation.isValidSafeInteger(
                  snapshotRevision
              ),
              snapshot.entryCount == snapshot.entries.count,
              snapshotRevision != manifestRevision
                || snapshot.entryCount == manifest.entryCount,
              (1...maximumSnapshotEntries).contains(
                  snapshot.entryCount
              ) else {
            throw AssetCatalogSyncError.invalidResponse
        }
        let entries = try snapshot.entries.map {
            try $0.validatedEntry()
        }

        let installed = try await database.pool.write {
            database -> (tokens: [ReceiveToken], revision: Int64) in
            try WalletAssetCatalogPersistence.replaceRemoteSnapshot(
                entries,
                revision: snapshotRevision,
                allowSameRevisionRepair: allowsSameRevisionRepair,
                in: database
            )
            return (
                try WalletAssetCatalogPersistence.loadCachedTokens(
                    in: database
                ),
                snapshotRevision
            )
        }
        ReceiveAssetCatalogRuntime.install(
            installed.tokens,
            revision: installed.revision
        )
        await MainActor.run {
            NotificationCenter.default.post(
                name: .walletAssetCatalogDidChange,
                object: nil,
                userInfo: ["revision": installed.revision]
            )
        }
    }

}
