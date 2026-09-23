import GRDB

extension WalletDatabase {
    static func registerCloudBackupRemoteDurabilityMigration(
        on migrator: inout DatabaseMigrator
    ) {
        migrator.registerMigration(
            "v23_cloud_backup_remote_durability"
        ) { database in
            try database.execute(
                sql: """
                ALTER TABLE wallets ADD COLUMN
                    iCloudBackupVerificationVersion INTEGER
                    NOT NULL DEFAULT 0
                    CHECK (
                        iCloudBackupVerificationVersion IN (0, 1)
                    );
                ALTER TABLE wallets ADD COLUMN
                    iCloudBackupRecordChangeTag TEXT;

                UPDATE wallets
                SET iCloudBackupUpdatedAt = NULL,
                    iCloudBackupVerificationVersion = 0,
                    iCloudBackupRecordChangeTag = NULL
                WHERE iCloudBackupUpdatedAt IS NOT NULL;
                """
            )
        }
    }

    static func registerCloudBackupIdentityMigration(
        on migrator: inout DatabaseMigrator
    ) {
        migrator.registerMigration(
            "v42_cloud_backup_remote_identity"
        ) { database in
            try database.execute(
                sql: """
                ALTER TABLE wallets ADD COLUMN
                    iCloudBackupWalletID TEXT;

                UPDATE wallets
                SET iCloudBackupWalletID = id
                WHERE iCloudBackupVerificationVersion = 1
                    AND iCloudBackupUpdatedAt IS NOT NULL;

                CREATE INDEX wallets_iCloudBackupWalletID
                    ON wallets(iCloudBackupWalletID)
                    WHERE iCloudBackupWalletID IS NOT NULL;
                """
            )
        }
    }
}
