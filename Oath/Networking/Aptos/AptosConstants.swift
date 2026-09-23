import Foundation
import WalletCore

enum AptosConstants {
    static let networkID = "aptos"
    static let databaseChainID = -637
    static let decimals = 8
    static let derivationPath = CoinType.aptos.derivationPath()
    static let nativeAssetID = "aptos:native"
    static let nativeCoinType = "0x1::aptos_coin::AptosCoin"
    static let nativeMetadataAddress = "0xa"
    static let nativeAssetNameKey = "asset.aptos.name"
    static let nativeSymbol = "APT"
    static let accountLabel = "aptos-ed25519"
    static let defaultRESTBaseURL = URL(
        string: "https://fullnode.mainnet.aptoslabs.com/v1"
    )!
    static let fallbackRESTBaseURL = URL(
        string: "https://api.mainnet.aptoslabs.com/v1"
    )!
    static let defaultIndexerURL = URL(
        string: "https://api.mainnet.aptoslabs.com/v1/graphql"
    )!
    static let fallbackIndexerURL = URL(
        string: "https://indexer.mainnet.aptoslabs.com/v1/graphql"
    )!
    static let chainID: UInt32 = 1
    static let balancePageSize = 100
    static let maximumBalancePages = 20
    static let historyPageSize = 100
    static let maximumHistoryPages = 10
    static let defaultMaximumGasAmount: UInt64 = 20_000
    static let transactionExpirationInterval: TimeInterval = 600
}
