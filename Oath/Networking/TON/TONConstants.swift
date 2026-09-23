import Foundation

enum TONConstants {
    static let networkID = "ton"
    static let databaseChainID = -607
    static let decimals = 9
    static let nanoGramPerGram = Decimal(
        sign: .plus,
        exponent: 9,
        significand: 1
    )
    static let derivationPath = "m/44'/607'/0'"
    static let walletID: UInt32 = 698_983_191
    static let nativeAssetID = "ton:native"
    static let nativeAssetNameKey = "asset.gram.name"
    static let nativeSymbol = "GRAM"
    static let providerRateSymbol = "TON"
    static let accountLabel = "wallet-v4r2"
}
