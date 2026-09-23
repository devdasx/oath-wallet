import Foundation
import GRDB

/// Describes exactly which balance reads completed successfully.
///
/// A partial provider response may prove that one asset is zero while another
/// asset failed to load. Keeping those outcomes separate prevents a failed
/// read from overwriting the last known balance without retaining stale values
/// for assets that were successfully observed at zero.
struct WalletBalanceFetchAuthority: Equatable, Sendable {
    let successfulAssetIDs: Set<String>
    let inventoryIsAuthoritative: Bool

    init(
        successfulAssetIDs: Set<String>,
        inventoryIsAuthoritative: Bool
    ) {
        self.successfulAssetIDs = successfulAssetIDs
        self.inventoryIsAuthoritative = inventoryIsAuthoritative
    }

    func permitsUpdate(assetID: String) -> Bool {
        successfulAssetIDs.contains(assetID)
    }
}

extension WalletDatabase {
    /// Clears only balances whose provider reads completed. A complete asset
    /// inventory can also clear omitted holdings because their absence is an
    /// authoritative zero; a partial inventory must leave unqueried rows alone.
    @discardableResult
    static func clearFetchedBalances(
        database: Database,
        accountID: String,
        authority: WalletBalanceFetchAuthority,
        now: Double
    ) throws -> Int {
        var request = DBAccountAssetRecord
            .filter(Column("accountID") == accountID)
        if !authority.inventoryIsAuthoritative {
            guard !authority.successfulAssetIDs.isEmpty else { return 0 }
            request = request.filter(
                authority.successfulAssetIDs.contains(Column("assetID"))
            )
        }
        return try request.updateAll(
            database,
            Column("balance").set(to: "0"),
            Column("balanceAtomic").set(to: "0"),
            Column("fiatUSDValue").set(to: "0"),
            Column("updatedAt").set(to: now)
        )
    }
}
