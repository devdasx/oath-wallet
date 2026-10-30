import OathDiagnostics
import OathTokenImages

extension TokenDiscoveryCatalog: TokenArtworkMetadata {
    public func sources(for token: TokenArtworkIdentity, cachedOnly: Bool) async -> [String] {
        do {
            return try await artworkSource(network: token.networkID, reference: token.reference,
                                           cachedOnly: cachedOnly).map { [$0] } ?? []
        } catch {
            // Busy/cooling-down metadata work is expected backpressure, not a
            // fresh failure. Other errors retain the artwork recovery boundary.
            if !(error is CancellationError), error as? TokenDiscoveryError != .unavailable {
                OathDiagnostics.record(error, component: "artwork", operation: "catalog_metadata",
                    context: ["chain": token.networkID, "stage": cachedOnly ? "cache" : "refresh"])
            }
            return []
        }
    }
}
