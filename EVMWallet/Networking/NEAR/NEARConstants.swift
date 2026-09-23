import Foundation

enum NEARConstants {
    static let networkID = "near"
    static let databaseChainID = -397
    static let decimals = 24
    static let derivationPath = "m/44'/397'/0'"
    static let nativeAssetID = "near:native"
    static let nativeAssetNameKey = "asset.near.name"
    static let nativeSymbol = "NEAR"
    static let accountLabel = "near-ed25519"
    static let fastNEARAPIBase = URL(string: "https://api.fastnear.com")!
    static let fastNEARTxBase = URL(string: "https://tx.main.fastnear.com")!
    static let nearBlocksAPIBase = URL(string: "https://api.nearblocks.io")!
    static let publicJSONRPCEndpoints = [
        URL(string: "https://free.rpc.fastnear.com")!,
        URL(string: "https://near.drpc.org")!,
        URL(string: "https://archival-rpc.mainnet.near.org")!
    ]
    static let maximumHistoryPages = 5
    static let historyPageSize = 50
    static let historyDetailsBatchSize = 20
    static let historyDetailsConcurrencyLimit = 8
    static let metadataConcurrencyLimit = 8
    static let fungibleTokenGas: UInt64 = 30_000_000_000_000
    static let storageDepositGas: UInt64 = 30_000_000_000_000
    static let maximumTransactionGas: UInt64 = 100_000_000_000_000
    static let zeroBalanceAccountStorageLimit: UInt64 = 770
}
