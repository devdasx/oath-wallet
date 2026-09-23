import Foundation

enum ReceiveAssetCatalogStorageError: Error, Equatable, Sendable {
    case duplicateTokenID(String)
    case duplicateAssetIdentity(String)
    case emptyCatalog
    case invalidPersistedEntry(String)
    case invalidRemoteEntry(String)
    case invalidRemoteCursor
}

struct ReceiveAssetCatalogRuntimeSnapshot: Sendable {
    let tokens: [ReceiveToken]
    let revision: Int64
    let generation: UInt64
    /// Canonical asset identity → curated family, for badge and filter
    /// lookups that must not walk the whole catalog.
    let familiesByAssetIdentity: [String: AssetFamily]

    init(tokens: [ReceiveToken], revision: Int64, generation: UInt64) {
        self.tokens = tokens
        self.revision = revision
        self.generation = generation
        var families: [String: AssetFamily] = [:]
        for token in tokens {
            for variant in token.variants {
                guard let family = variant.family else { continue }
                families[
                    AssetIdentityKey.canonical(variant.assetIdentity)
                ] = family
            }
        }
        familiesByAssetIdentity = families
    }
}

enum ReceiveAssetCatalogRuntime {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var installed =
        ReceiveAssetCatalogRuntimeSnapshot(
            tokens: [],
            revision: 0,
            generation: 0
        )

    static var snapshot: ReceiveAssetCatalogRuntimeSnapshot {
        lock.withLock { installed }
    }

    static var tokens: [ReceiveToken] {
        snapshot.tokens
    }

    @discardableResult
    static func install(
        _ tokens: [ReceiveToken],
        revision: Int64 = 0
    ) -> UInt64 {
        lock.withLock {
            let nextGeneration = installed.generation &+ 1
            installed = ReceiveAssetCatalogRuntimeSnapshot(
                tokens: tokens,
                revision: max(revision, 0),
                generation: nextGeneration
            )
            return nextGeneration
        }
    }
}
