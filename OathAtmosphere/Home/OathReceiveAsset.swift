import Foundation
import OathDatabase

/// Bind each asset to its own persisted account, including tokens and alternate
/// receive paths. Matching only a network can send a second account's QR to the
/// first account, so an exact account/network match is required.
struct OathReceiveAsset: Identifiable {
    let holding: Holding
    let address: OathWalletAddress
    var id: String { holding.id }

    static func available(holdings: [Holding], addresses: [OathWalletAddress], query: String) -> [Self] {
        let accounts = Dictionary(grouping: addresses.compactMap { address in
            address.accountID.map { ($0, address) }
        }, by: { $0.0 })
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        // Preserve WalletSnapshot's shared portfolio order and exact quantities.
        // Empty search results and absent accounts are normal UI states.
        return holdings.compactMap { holding in
            guard let account = accounts[holding.accountID]?.first(where: {
                $0.1.chain.id == holding.networkID
            })?.1, words.allSatisfy({ word in
                [holding.name, holding.symbol, holding.networkID, holding.reference].contains {
                    $0.localizedStandardContains(word)
                }
            }) else { return nil }
            return Self(holding: holding, address: OathWalletAddress(
                chain: account.chain, address: holding.address, path: account.path,
                accountIndex: account.accountIndex, accountID: holding.accountID, assetID: holding.assetID,
                storedNetworkName: account.storedNetworkName, storedTicker: account.storedTicker,
                storedLogo: account.storedLogo))
        }
    }
}
