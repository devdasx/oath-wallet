import Foundation

enum AptosTokenCatalog {
    static let native = AptosTokenMetadata(
        assetType: AptosConstants.nativeCoinType,
        metadataAddress: AptosConstants.nativeMetadataAddress,
        name: WalletLocalization.string(AptosConstants.nativeAssetNameKey),
        symbol: AptosConstants.nativeSymbol,
        decimals: AptosConstants.decimals,
        iconURL: nil,
        tokenStandard: "v1",
        isVerified: true,
        rank: 0
    )

    static func metadata(
        assetType: String,
        provider: AptosIndexerMetadata?
    ) -> AptosTokenMetadata? {
        guard let canonical = AptosAssetType.canonical(assetType) else {
            return nil
        }
        if canonical == AptosConstants.nativeCoinType
            || canonical == AptosConstants.nativeMetadataAddress {
            return native
        }
        guard let provider,
              let providerType = AptosAssetType.canonical(provider.assetType),
              providerType == canonical,
              (0...255).contains(provider.decimals),
              !provider.name.trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty,
              !provider.symbol.trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        else { return nil }
        let metadataAddress = provider.tokenStandard == "v2"
            ? AptosAddress.canonical(providerType)
            : nil
        return AptosTokenMetadata(
            assetType: canonical,
            metadataAddress: metadataAddress,
            name: provider.name,
            symbol: provider.symbol,
            decimals: provider.decimals,
            iconURL: provider.iconURI.flatMap(URL.init(string:)),
            tokenStandard: provider.tokenStandard,
            isVerified: false,
            rank: 10_000
        )
    }
}
