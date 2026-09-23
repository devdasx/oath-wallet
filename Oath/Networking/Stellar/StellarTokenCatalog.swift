import Foundation

enum StellarTokenCatalog {
    static var verified: [StellarTokenMetadata] {
        ReceiveAssetCatalog.tokens(for: StellarConstants.networkID)
            .compactMap { token in
                guard
                    let variant = token.variants.first(where: {
                        $0.networkID == StellarConstants.networkID
                    }),
                    let contractAddress = variant.contractAddress,
                    let identity = StellarAssetIdentity.validated(
                        contractAddress: contractAddress
                    )
                else {
                    return nil
                }
                return StellarTokenMetadata(
                    identity: identity,
                    name: token.name,
                    symbol: token.symbol,
                    decimals: variant.decimals,
                    isVerified: variant.isVerified,
                    rank: variant.networkRank ?? token.rank
                )
            }
    }

    private static var byIdentity: [String: StellarTokenMetadata] {
        Dictionary(
            verified.map { ($0.identity.contractAddress, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    static func metadata(
        code: String,
        issuer: String
    ) -> StellarTokenMetadata? {
        guard let identity = StellarAssetIdentity.validated(
            code: code,
            issuer: issuer
        ) else {
            return nil
        }
        return byIdentity[identity.contractAddress]
            ?? StellarTokenMetadata(
                identity: identity,
                name: code,
                symbol: code,
                decimals: StellarConstants.decimals,
                isVerified: false,
                rank: 10_000
            )
    }

    static var receiveTokens: [ReceiveToken] {
        ReceiveAssetCatalog.tokens(for: StellarConstants.networkID).filter {
            $0.variants.contains {
                $0.networkID == StellarConstants.networkID
                    && $0.contractAddress != nil
            }
        }
    }
}
