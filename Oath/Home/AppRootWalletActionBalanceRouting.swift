import Foundation

extension AppRootView {
    @MainActor
    func preparedSendChoice(
        for asset: WalletAsset,
        preparation: WalletActionPresentationPreparation,
        capabilities: WalletCapabilities
    ) -> SendAssetChoice? {
        let identity = AssetIdentityKey.canonical(asset.id)
        let currentAsset = balanceResolvedFlowAssets(preparation)
            .first {
                AssetIdentityKey.canonical($0.id) == identity
            }
        return SendAssetChoiceCatalog.choice(
            for: asset,
            refreshedFrom: currentAsset.map { [$0] } ?? [],
            capabilities: capabilities
        )
    }

    @MainActor
    func balanceResolvedFlowAssets(
        _ preparation: WalletActionPresentationPreparation
    ) -> [WalletAsset] {
        guard let source = currentWalletActionBalanceSource,
              source.requestID == preparation.requestID,
              source.identity == preparation.identity else {
            return preparation.flowAssets
        }
        return WalletAssetBalanceSnapshot(
            assets: source.assets
        ).projecting(candidates: preparation.flowAssets)
    }

    @MainActor
    func balanceResolvedAsset(
        _ asset: WalletAsset,
        preparation: WalletActionPresentationPreparation
    ) -> WalletAsset {
        guard let source = currentWalletActionBalanceSource,
              source.requestID == preparation.requestID,
              source.identity == preparation.identity else {
            return asset
        }
        return WalletAssetBalanceSnapshot(
            assets: source.assets
        ).resolved(asset)
    }
}
