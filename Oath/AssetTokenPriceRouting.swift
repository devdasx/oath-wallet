import Foundation

extension AssetPriceClient {
    enum TokenPriceStage: String, Sendable { case dex, contractFallback }

    /// Separate service identities prevent adaptive ranking from promoting an
    /// aggregator ahead of a working DEX quote, regardless of prior latency.
    static func fetchTokenPrice(
        for asset: WalletAsset, session: URLSession
    ) async throws -> AssetUSDPrice {
        guard let network = asset.network,
              let networkID = ReceiveNetworkCatalog.catalogNetwork(for: network)?.id,
              asset.id.split(separator: ":", maxSplits: 1).first.map(String.init) == networkID else {
            throw AssetPriceError.unsupportedAsset
        }
        var lastError: Error = AssetPriceError.unsupportedAsset
        for stage in [TokenPriceStage.dex, .contractFallback] {
            try Task.checkCancellation()
            let serviceID = "token_usd_dex_first_v1_\(stage.rawValue)_"
                + AdaptiveProviderIdentity.opaqueID(asset.id)
            let attempts = tokenPriceAttempts(
                asset: asset, stage: stage, serviceID: serviceID, session: session
            )
            guard !attempts.isEmpty else { continue }
            do {
                return try await AdaptiveProviderRouter.shared.executeRead(
                    serviceID: serviceID, attempts: attempts,
                    timeoutSeconds: 4, overallTimeoutSeconds: stage == .dex ? 8 : 12,
                    shouldFallback: { priceProviderShouldFallback($0) }
                )
            } catch is CancellationError { throw CancellationError() }
            catch {
                guard priceProviderShouldFallback(error) else { throw error }
                lastError = error
            }
        }
        throw lastError
    }

    static func tokenPriceAttempts(
        asset: WalletAsset, stage: TokenPriceStage,
        serviceID: String, session: URLSession
    ) -> [AdaptiveProviderAttempt<AssetUSDPrice>] {
        guard priceContractAddress(for: asset) != nil, let network = asset.network else { return [] }
        var attempts: [AdaptiveProviderAttempt<AssetUSDPrice>] = []
        func append(
            _ url: String, _ provider: String,
            _ operation: @escaping @Sendable () async throws -> Decimal
        ) {
            attempts.append(priceAttempt(
                serviceID: serviceID, endpointURL: URL(string: url)!,
                priority: attempts.count, asset: asset, provider: provider,
                operation: operation
            ))
        }
        switch stage {
        case .dex:
            if dexScreenerNetworkID(network) != nil {
                append("https://api.dexscreener.com/token-pairs/v1", dexScreenerContractPriceProvider) {
                    try await dexScreenerContractPrice(asset: asset, session: session)
                }
            }
            if geckoTerminalNetworkID(network) != nil {
                append("https://api.geckoterminal.com/api/v2/simple/networks", geckoTerminalContractPriceProvider) {
                    try await geckoTerminalContractPrice(asset: asset, session: session)
                }
            }
        case .contractFallback:
            if defiLlamaChainID(network) != nil {
                append("https://coins.llama.fi/prices/current", defiLlamaContractPriceProvider) {
                    try await defiLlamaContractPrice(asset: asset, session: session)
                }
            }
            if coinGeckoPlatformID(network) != nil {
                append("https://api.coingecko.com/api/v3/simple/token_price", exactContractPriceProvider) {
                    try await coinGeckoContractPrice(asset: asset, session: session)
                }
            }
            if network == .ton {
                append("https://tonapi.io/v2/rates", tonAPIContractPriceProvider) {
                    try await tonAPIContractPrice(asset: asset, session: session)
                }
            }
        }
        return attempts
    }
}
