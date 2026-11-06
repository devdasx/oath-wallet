import Foundation
import GRDB

extension OathDatabase {
    /// Changes feature visibility without deleting accounts, balances or history.
    /// The app applies an explicit product decision, not inferred provider failure.
    public func setNetworkEnabled(_ networkID: String, enabled: Bool) async throws {
        try await pool.write { db in
            guard var network = try NetworkRecord.fetchOne(db, key: networkID) else { throw StoreError.missingRecord }
            guard network.enabled != enabled else { return }
            network.enabled = enabled
            try network.update(db)
        }
    }
}
