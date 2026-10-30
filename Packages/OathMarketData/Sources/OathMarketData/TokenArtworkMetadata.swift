import OathTokenImages
import OathDiagnostics
import Foundation

extension MarketDataService: TokenArtworkMetadata {
    public func sources(for token: TokenArtworkIdentity, cachedOnly: Bool) async -> [String] {
        // Search artwork can be resolved by the discovery catalog without a
        // known scale. Never manufacture market metadata for that presentation.
        guard let decimals = token.decimals else { return [] }
        let asset = MarketAsset(id: token.assetID, networkID: token.networkID,
            reference: token.reference, decimals: decimals)
        do {
            let info: CachedMarketValue<AssetInformation>?
            if !cachedOnly, token.networkID == "thorchain", MarketIdentity.thorchainProjects[token.reference] != nil {
                info = try await enrichedInformation(for: asset)
            } else {
                info = cachedOnly ? try await cachedInformation(for: asset) : try await information(for: asset)
            }
            return [info?.value.imageURL].compactMap { $0 }
        } catch {
            // A logo does not need a complete coin-information response. When
            // that provider is throttled/offline, recover through one shared
            // published list keyed by exact chain + contract. The market-load
            // boundary already recorded the original provider failure; cached
            // backoff and a successfully resolved optional image are not new
            // failures. Never turn malformed/identity-mismatched data into a
            // successful fallback, or issue network work for a cache-only read.
            if !cachedOnly, !Task.isCancelled, !OathDiagnostics.isExpectedCancellation(error),
               [.rateLimited, .unavailable, .notListed].contains(error as? MarketDataError)
                    || error is DiagnosticDeferral || error is URLError,
               let sources = await artworkCatalog.sources(for: token) {
                guard !Task.isCancelled else { return [] }
                return sources
            }
            // Cancellation may arrive while an unavailable catalog is awaited.
            guard !Task.isCancelled else { return [] }
            // Absent optional metadata is normal, not evidence of a failed
            // token lookup. Preserve outages/invalid identities before fallback.
            if error as? MarketDataError != .notListed {
                OathDiagnostics.record(error, component: "artwork", operation: "token_metadata",
                    context: ["chain": token.networkID, "stage": cachedOnly ? "cache" : "refresh"])
            }
            return []
        }
    }
}
