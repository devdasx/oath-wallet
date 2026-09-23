import Foundation

enum WalletHomeLiveAssetProjection {
    static func searchAssets(
        preparedAssets: [WalletAsset]?,
        currentAssets: [WalletAsset],
        capabilities: WalletCapabilities
    ) -> [WalletAsset] {
        let scopedCurrentAssets = capabilities.filteredAssets(currentAssets)
        guard let preparedAssets else { return scopedCurrentAssets }
        return capabilities.filteredAssets(
            WalletAssetBalanceSnapshot(
                assets: scopedCurrentAssets
            ).projecting(candidates: preparedAssets)
        )
    }
}
