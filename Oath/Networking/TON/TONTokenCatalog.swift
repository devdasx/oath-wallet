import Foundation

enum TONTokenCatalog {
    static var all: [TONTokenDefinition] {
        ReceiveAssetCatalog.tokens(for: TONConstants.networkID)
            .compactMap { token in
                guard
                    let variant = token.variants.first(where: {
                        $0.networkID == TONConstants.networkID
                    }),
                    let contractAddress = variant.contractAddress,
                    let address = TONAddress.rawAddress(
                        from: contractAddress
                    )
                else {
                    return nil
                }
                return TONTokenDefinition(
                    address: address,
                    name: token.name,
                    symbol: token.symbol,
                    decimals: variant.decimals,
                    rank: variant.networkRank ?? token.rank
                )
            }
    }

    static var byAddress: [String: TONTokenDefinition] {
        Dictionary(
            all.map { ($0.address, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }
}
