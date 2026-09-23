import Foundation

struct NEARTokenDefinition: Hashable, Sendable {
    let contractID: String
    let name: String
    let symbol: String
    let decimals: Int
    let rank: Int
}

enum NEARTokenCatalog {
    static var all: [NEARTokenDefinition] {
        ReceiveAssetCatalog.tokens(for: NEARConstants.networkID)
            .compactMap { token in
                guard
                    let variant = token.variants.first(where: {
                        $0.networkID == NEARConstants.networkID
                    }),
                    let contractID = variant.contractAddress
                else {
                    return nil
                }
                return NEARTokenDefinition(
                    contractID: contractID,
                    name: token.name,
                    symbol: token.symbol,
                    decimals: variant.decimals,
                    rank: variant.networkRank ?? token.rank
                )
            }
    }

    static var byContract: [String: NEARTokenDefinition] {
        Dictionary(
            all.map { ($0.contractID.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    static var receiveTokens: [ReceiveToken] {
        ReceiveAssetCatalog.tokens(for: NEARConstants.networkID)
    }
}
