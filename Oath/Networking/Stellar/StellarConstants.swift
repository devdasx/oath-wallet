import Foundation

enum StellarConstants {
    static let networkID = "stellar"
    static let databaseChainID = -148
    static let decimals = 7
    static let derivationPath = "m/44'/148'/0'"
    static let nativeAssetID = "stellar:native"
    static let nativeAssetNameKey = "asset.stellar_lumen.name"
    static let nativeSymbol = "XLM"
    static let accountLabel = "stellar-ed25519"
    static let networkPassphrase =
        "Public Global Stellar Network ; September 2015"
    static let horizonBaseURL = URL(
        string: "https://rpc.ankr.com/http/stellar_horizon"
    )!
    static let horizonFallbackBaseURL = URL(
        string: "https://horizon.stellar.lobstr.co"
    )!
    static let historyPageSize = 100
    static let maximumHistoryPages = 10
    static let maximumTransactionEnrichment = 250
    static let maximumMemoTextBytes = 28
    static let minimumFeeStroops: Int64 = 100
}
