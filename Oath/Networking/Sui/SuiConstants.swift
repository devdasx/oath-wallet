import Foundation

enum SuiConstants {
    static let networkID = "sui"
    static let databaseChainID = -784
    static let decimals = 9
    static let derivationPath = "m/44'/784'/0'/0'/0'"
    static let nativeAssetID = "sui:native"
    static let nativeCoinType = "0x2::sui::SUI"
    static let nativeAssetNameKey = "asset.sui.name"
    static let nativeSymbol = "SUI"
    static let accountLabel = "sui-ed25519"
    static let defaultGraphQLURL = URL(
        string: "https://graphql.mainnet.sui.io/graphql"
    )!
    static let publicGraphQLURL = URL(
        string: "https://graphql.mainnet.sui.io/graphql"
    )!
    static let maximumHistoryPages = 10
    static let maximumBalancePages = 100
    static let maximumBalanceChangePages = 100
    static let maximumObjectPages = 100
    static let historyPageSize = 50
    static let balancePageSize = 50
    static let balanceChangePageSize = 50
    static let objectPageSize = 50
    static let metadataConcurrencyLimit = 8
    static let defaultGasBudget: UInt64 = 10_000_000
}
