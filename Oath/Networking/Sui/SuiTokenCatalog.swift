import Foundation

enum SuiTokenCatalog {
    static let native = SuiTokenMetadata(
        coinType: SuiConstants.nativeCoinType,
        name: WalletLocalization.string(SuiConstants.nativeAssetNameKey),
        symbol: SuiConstants.nativeSymbol,
        decimals: SuiConstants.decimals,
        iconURL: nil,
        isVerified: true,
        rank: 0
    )

    static var all: [SuiTokenMetadata] {
        ReceiveAssetCatalog.tokens(for: SuiConstants.networkID)
            .compactMap { token in
                guard
                    let variant = token.variants.first(where: {
                        $0.networkID == SuiConstants.networkID
                    }),
                    let rawCoinType = variant.contractAddress,
                    let coinType = SuiCoinType.canonical(rawCoinType)
                else {
                    return nil
                }
                return SuiTokenMetadata(
                    coinType: coinType,
                    name: token.name,
                    symbol: token.symbol,
                    decimals: variant.decimals,
                    iconURL: validatedLogoURL(variant.logoURL),
                    isVerified: variant.isVerified,
                    rank: variant.networkRank ?? token.rank
                )
            }
    }

    static var byCoinType: [String: SuiTokenMetadata] {
        Dictionary(
            ([native] + all).map { ($0.coinType, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    static func metadata(
        coinType: String,
        provider: SuiTokenMetadata?
    ) -> SuiTokenMetadata? {
        guard let canonical = SuiCoinType.canonical(coinType) else {
            return nil
        }
        if let catalog = byCoinType[canonical] {
            return catalog
        }
        guard let provider,
              provider.coinType == canonical,
              (0...255).contains(provider.decimals),
              !provider.name.isEmpty,
              !provider.symbol.isEmpty
        else {
            return nil
        }
        return provider
    }

    static func coinGeckoID(coinType: String) -> String? {
        guard let canonical = SuiCoinType.canonical(coinType) else {
            return nil
        }
        return ReceiveAssetCatalog.marketDataID(
            for: AssetIdentityKey.make(
                networkID: SuiConstants.networkID,
                contractAddress: canonical
            )
        )
    }

    static var receiveTokens: [ReceiveToken] {
        ReceiveAssetCatalog.tokens(for: SuiConstants.networkID).filter {
            $0.variants.contains {
                $0.networkID == SuiConstants.networkID
                    && $0.contractAddress != nil
            }
        }
    }

    private static func validatedLogoURL(_ value: String?) -> URL? {
        guard
            let value,
            let url = URL(string: value),
            url.scheme?.lowercased() == "https",
            url.host?.isEmpty == false
        else {
            return nil
        }
        return url
    }
}
