import Foundation

struct TronCatalogFile {
    struct Token: Sendable {
        let id: String
        let type: String
        let name: String
        let symbol: String
        let decimals: Int
        let rank: Int?
        let logoURL: String?
        let description: String?
        let projectSite: String?

        init(
            id: String,
            type: String,
            name: String,
            symbol: String,
            decimals: Int,
            rank: Int? = nil,
            logoURL: String? = nil,
            description: String? = nil,
            projectSite: String? = nil
        ) {
            self.id = id
            self.type = type
            self.name = name
            self.symbol = symbol
            self.decimals = decimals
            self.rank = rank
            self.logoURL = logoURL
            self.description = description
            self.projectSite = projectSite
        }
    }

    let tokens: [Token]
}

enum TronTokenCatalog {
    static var tokens: [TronCatalogFile.Token] {
        ReceiveAssetCatalog.tokens(for: TronConstants.networkID)
            .compactMap { token in
                guard
                    let variant = token.variants.first(where: {
                        $0.networkID == TronConstants.networkID
                    }),
                    let contractAddress = variant.contractAddress,
                    TronValueParser.hexAddress(contractAddress) != nil,
                    !TokenSafetyPolicy.isHardDenied(
                        networkID: TronConstants.networkID,
                        contractAddress: contractAddress
                    )
                else {
                    return nil
                }
                return TronCatalogFile.Token(
                    id: contractAddress,
                    type: "trc20",
                    name: token.name,
                    symbol: token.symbol,
                    decimals: variant.decimals,
                    rank: variant.networkRank ?? token.rank,
                    logoURL: variant.logoURL
                )
            }
    }

    static var byIdentity: [String: TronCatalogFile.Token] {
        Dictionary(
            tokens.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    static var receiveTokens: [ReceiveToken] {
        ReceiveAssetCatalog.tokens(for: TronConstants.networkID)
    }
}
