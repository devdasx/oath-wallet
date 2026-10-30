import Foundation

/// A general Alchemy key does not imply that its optional UTXO networks are
/// enabled. Selection must follow the separately configured network capabilities.
struct UTXOConfiguredSources: Sendable {
    let ankr: AnkrUTXOFeeAPI?
    let alchemy: AlchemyUTXOAPI?
    let alchemyNetworks: Set<UTXONetwork>

    init(ankrAPIKey: String? = nil, alchemyAPIKey: String? = nil,
         alchemyNetworks: Set<UTXONetwork> = []) {
        ankr = AnkrUTXOFeeAPI(apiKey: ankrAPIKey)
        alchemy = AlchemyUTXOAPI(apiKey: alchemyAPIKey)
        self.alchemyNetworks = alchemyNetworks
    }
    var hasAlchemy: Bool { alchemy != nil && !alchemyNetworks.isEmpty }
    func feePreferred(_ network: UTXONetwork) -> UTXOFeeProvider.Source? {
        if alchemyNetworks.contains(network), let alchemy { return alchemy.feeSource(network) }
        return ankr?.source(for: network)
    }
    func feeFallback(_ network: UTXONetwork) -> UTXOFeeProvider.Source? {
        guard alchemy != nil, alchemyNetworks.contains(network) else { return nil }
        return ankr?.source(for: network)
    }
    func broadcastPreferred(_ network: UTXONetwork) -> UTXOBroadcastProvider.Source? {
        guard alchemyNetworks.contains(network) else { return nil }
        return alchemy?.broadcastSource(network)
    }
}
