import Foundation

enum WalletUniversalSearchAction: Hashable, Sendable {
    case send
    case receive
    case scan
    case allAssets
    case manageAssets
    case allActivity
    case walletSwitcher
    case settings(WalletSettingsSearchRoute)
}

struct WalletUniversalSearchActionItem:
    Identifiable,
    Hashable,
    Sendable
{
    let id: String
    let titleKey: String
    let subtitleKey: String
    let subtitleText: String?
    let action: WalletUniversalSearchAction

    init(
        id: String,
        titleKey: String,
        subtitleKey: String,
        subtitleText: String? = nil,
        action: WalletUniversalSearchAction
    ) {
        self.id = id
        self.titleKey = titleKey
        self.subtitleKey = subtitleKey
        self.subtitleText = subtitleText
        self.action = action
    }

    var resolvedSubtitle: String {
        subtitleText ?? WalletLocalization.string(subtitleKey)
    }

}

struct WalletUniversalSearchResults: Sendable {
    let actions: [WalletUniversalSearchActionItem]
    let wallets: [ManagedWallet]
    let networks: [AssetNetworkSelectorOption]
    let assets: [WalletAsset]
    let transactions: [WalletTransaction]

    static let empty = WalletUniversalSearchResults(
        actions: [],
        wallets: [],
        networks: [],
        assets: [],
        transactions: []
    )

    var isEmpty: Bool {
        actions.isEmpty
            && wallets.isEmpty
            && networks.isEmpty
            && assets.isEmpty
            && transactions.isEmpty
    }
}

struct WalletUniversalSearchSuggestions: Sendable {
    let actions: [WalletUniversalSearchActionItem]
    let features: [WalletUniversalSearchActionItem]
    let settings: [WalletUniversalSearchActionItem]
    let marketAssets: [WalletAsset]
    let assets: [WalletAsset]

    static let empty = WalletUniversalSearchSuggestions(
        actions: [],
        features: [],
        settings: [],
        marketAssets: [],
        assets: []
    )
}
