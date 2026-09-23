import Foundation

enum XRPConstants {
    static let networkID = "xrp"
    static let databaseChainID = -144
    static let decimals = 6
    static let derivationPath = "m/44'/144'/0'/0/0"
    static let nativeAssetID = "xrp:native"
    static let nativeAssetNameKey = "asset.xrp.name"
    static let nativeSymbol = "XRP"
    static let accountLabel = "xrp-secp256k1"
    static let publicJSONRPCReadURLs = [
        URL(string: "https://xrplcluster.com")!,
        URL(string: "https://s1.ripple.com:51234")!,
        URL(string: "https://s2.ripple.com:51234")!
    ]
    static let maximumHistoryPages = 10
    static let maximumTrustLinePages = 20
    static let historyPageSize = 100
    static let trustLinePageSize = 400
    static let rippleEpochOffset: TimeInterval = 946_684_800
}
