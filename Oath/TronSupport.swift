import Foundation

/// Mainnet constants shared by Tron networking and persistence.
enum TronConstants {
    static let networkID = "tron"
    static let sunPerTRX = Decimal(1_000_000)
    static let transferTopic =
        "ddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
}

struct TronAccountMaterial: Sendable {
    let address: String
    let hexAddress: String
    let publicKey: String
}

struct TronTokenBalance: Sendable {
    let identity: String
    let type: String
    let name: String
    let symbol: String
    let decimals: Int
    /// Canonical user-unit text derived losslessly from `rawAmount`.
    let amountText: String
    /// Canonical atomic-unit text constrained to uint256 for TRC-20.
    let rawAmount: String
}

/// Explicitly pinned TRC-20 metadata that must remain in the next
/// authoritative balance-query universe even when it no longer appears in
/// transfer history.
struct TronTrackedToken: Sendable, Equatable {
    let identity: String
    let type: String
    let name: String
    let symbol: String
    let decimals: Int
}

struct TronHistoryItem: Sendable {
    let transactionID: String
    let timestamp: Double
    let blockNumber: Int64?
    let from: String
    let to: String
    /// Canonical, unsigned user-unit quantity from the provider payload.
    let amountText: String
    /// Canonical atomic-unit quantity from the provider payload.
    let rawAmount: String
    let assetIdentity: String
    let assetSymbol: String
    let assetName: String
    let decimals: Int
    let fee: Decimal?
    let failed: Bool
}

struct TronWalletSnapshot: Sendable {
    let material: TronAccountMaterial
    let trxBalance: Decimal
    let tokens: [TronTokenBalance]
    let history: [TronHistoryItem]
    let queriedTRC20Identities: Set<String>
    let providerFailures: [WalletChainSyncFailure]

    init(
        material: TronAccountMaterial,
        trxBalance: Decimal,
        tokens: [TronTokenBalance],
        history: [TronHistoryItem],
        queriedTRC20Identities: Set<String>,
        providerFailures: [WalletChainSyncFailure] = []
    ) {
        self.material = material
        self.trxBalance = trxBalance
        self.tokens = tokens
        self.history = history
        self.queriedTRC20Identities = queriedTRC20Identities
        self.providerFailures = providerFailures
    }
}
