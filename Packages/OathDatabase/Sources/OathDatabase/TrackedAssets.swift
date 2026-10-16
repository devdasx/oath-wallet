import Foundation
import GRDB

extension OathDatabase {
    /// Tracking is independent of balance discovery: an unknown balance is not
    /// persisted as a successful zero. Selection belongs to this wallet only.
    @discardableResult
    public func trackAsset(_ input: AssetRecord, walletID: String) async throws -> AssetRecord {
        guard input.reference != "native", (0...255).contains(input.decimals),
              !input.name.isEmpty, input.name.utf8.count <= 512,
              !input.symbol.isEmpty, input.symbol.utf8.count <= 512,
              !input.reference.isEmpty, input.reference.count <= 128 else { throw StoreError.invalidValue("token") }
        return try await pool.write { db in
            guard let network = try NetworkRecord.fetchOne(db, key: input.networkID), network.enabled,
                  try WalletRecord.fetchOne(db, key: walletID) != nil else { throw StoreError.missingRecord }
            let accounts = try AccountRecord.fetchAll(db, sql: "SELECT * FROM accounts WHERE walletID=? AND networkID=?",
                                                     arguments: [walletID, input.networkID])
            guard !accounts.isEmpty else { throw StoreError.conflictingIdentity }
            var asset = input
            if network.family == "evm" { asset.reference = asset.reference.lowercased() }
            if var existing = try AssetRecord.fetchOne(db, sql: "SELECT * FROM assets WHERE networkID=? AND reference=?",
                                                       arguments: [asset.networkID, asset.reference]) {
                guard existing.decimals == asset.decimals else { throw StoreError.conflictingIdentity }
                existing.name = asset.name; existing.symbol = asset.symbol; existing.logo = asset.logo
                try existing.update(db)
                asset = existing
            } else {
                try asset.insert(db)
            }
            for account in accounts {
                try db.execute(sql: """
                    INSERT INTO trackedAssets(accountID,assetID,networkID,addedAt) VALUES(?,?,?,?)
                    ON CONFLICT(accountID,assetID) DO NOTHING
                    """, arguments: [account.id, asset.id, asset.networkID, Date().timeIntervalSince1970])
            }
            return asset
        }
    }

    public func trackedAssets(walletID: String) async throws -> [AssetRecord] {
        try await pool.read { db in
            try AssetRecord.fetchAll(db, sql: """
                SELECT DISTINCT a.* FROM assets a JOIN trackedAssets t ON t.assetID=a.id
                JOIN accounts c ON c.id=t.accountID WHERE c.walletID=? ORDER BY a.networkID,a.id
                """, arguments: [walletID])
        }
    }
}
