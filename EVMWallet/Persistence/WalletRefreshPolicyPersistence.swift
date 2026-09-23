import Foundation
import GRDB

extension WalletDatabase {
    static func registerWalletRefreshPolicyMigration(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v70_wallet_refresh_policy") { database in
            try database.execute(sql: """
                CREATE TABLE walletRefreshPolicies (
                    walletID TEXT PRIMARY KEY NOT NULL REFERENCES wallets(id) ON DELETE CASCADE,
                    blocked INTEGER NOT NULL CHECK (blocked IN (0, 1))
                );
                """)
        }
    }

}
