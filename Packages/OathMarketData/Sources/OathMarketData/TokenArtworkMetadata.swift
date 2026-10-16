import OathTokenImages
import OathDiagnostics

extension MarketDataService: TokenArtworkMetadata {
    public func sources(for token: TokenArtworkIdentity, cachedOnly: Bool) async -> [String] {
        let asset = MarketAsset(id: token.assetID, networkID: token.networkID,
            reference: token.reference, decimals: token.decimals)
        do {
            let info: CachedMarketValue<AssetInformation>?
            if !cachedOnly, token.networkID == "thorchain", MarketIdentity.thorchainProjects[token.reference] != nil {
                info = try await enrichedInformation(for: asset)
            } else {
                info = cachedOnly ? try await cachedInformation(for: asset) : try await information(for: asset)
            }
            return [info?.value.imageURL].compactMap { $0 }
        } catch {
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
