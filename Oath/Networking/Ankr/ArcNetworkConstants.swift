import Foundation

/// Circle's Arc mainnet. USDC is the gas token: `eth_getBalance` reports it
/// with 18 decimals while the ERC-20 interface at `usdcInterfaceContract`
/// reports the same balance with 6 decimals. The app shows one USDC asset —
/// the native one — and folds ERC-20 activity on that interface into it.
enum ArcNetworkConstants {
    static let networkID = "arc"
    static let chainID = 5_042
    static let usdcInterfaceContract =
        "0x3600000000000000000000000000000000000000"
    /// Transactions with `maxFeePerGas` under this floor never leave the
    /// mempool.
    static let minimumMaximumFeeWei: UInt64 = 20_000_000_000
}
