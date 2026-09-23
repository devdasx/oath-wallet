import Foundation

struct SolanaCatalogFile {
    struct Token: Sendable {
        let id: String
        let rank: Int
        let mint: String?
        let tokenStandard: String
        let name: String
        let symbol: String
        let decimals: Int
        let isStablecoin: Bool
        let logoURL: String?

    }

    let tokens: [Token]
}

enum SolanaTokenCatalog {
    static var tokens: [SolanaCatalogFile.Token] {
        ReceiveAssetCatalog.tokens(for: SolanaConstants.networkID)
            .compactMap { token in
                guard
                    let variant = token.variants.first(where: {
                        $0.networkID == SolanaConstants.networkID
                    }),
                    let mint = variant.contractAddress,
                    !TokenSafetyPolicy.isHardDenied(
                        networkID: SolanaConstants.networkID,
                        contractAddress: mint
                    )
                else {
                    return nil
                }
                return SolanaCatalogFile.Token(
                    id: token.id,
                    rank: variant.networkRank ?? token.rank,
                    mint: mint,
                    tokenStandard: "spl",
                    name: token.name,
                    symbol: token.symbol,
                    decimals: variant.decimals,
                    isStablecoin: token.isStablecoin ?? false,
                    logoURL: variant.logoURL
                )
            }
    }

    static var byMint: [String: SolanaCatalogFile.Token] {
        Dictionary(
            tokens.compactMap { token in
                token.mint.map { ($0, token) }
            },
            uniquingKeysWith: { first, _ in first }
        )
    }

    static func contains(mint: String) -> Bool {
        byMint[mint] != nil
    }

    static var receiveTokens: [ReceiveToken] {
        ReceiveAssetCatalog.tokens(for: SolanaConstants.networkID)
    }
}
