import GRDB

extension WalletDatabase {
    static func registerSecureCleanupJournalMigration(
        on migrator: inout DatabaseMigrator
    ) {
        migrator.registerMigration(
            "v26_secure_cleanup_journal"
        ) { database in
            try database.execute(
                sql: """
                CREATE TABLE secureCleanupOperations (
                    id TEXT PRIMARY KEY NOT NULL,
                    scope TEXT NOT NULL CHECK (
                        scope IN ('app_reset', 'wallet_removal')
                    ),
                    cleanupState TEXT NOT NULL CHECK (
                        cleanupState IN ('pending', 'complete')
                    ),
                    maintenanceState TEXT NOT NULL CHECK (
                        maintenanceState IN (
                            'not_required',
                            'pending',
                            'complete',
                            'failed'
                        )
                    ),
                    maintenanceErrorCode TEXT,
                    committedAt REAL NOT NULL,
                    updatedAt REAL NOT NULL
                );

                CREATE TABLE secureCleanupJobs (
                    id TEXT PRIMARY KEY NOT NULL,
                    operationID TEXT NOT NULL
                        REFERENCES secureCleanupOperations(id)
                        ON DELETE CASCADE,
                    kind TEXT NOT NULL CHECK (
                        kind IN (
                            'wallet_secret',
                            'passcode_credential',
                            'push_installation'
                        )
                    ),
                    opaqueReference TEXT,
                    attemptCount INTEGER NOT NULL DEFAULT 0
                        CHECK (attemptCount >= 0),
                    lastAttemptAt REAL,
                    lastErrorCode TEXT,
                    createdAt REAL NOT NULL,
                    updatedAt REAL NOT NULL
                );

                CREATE INDEX secure_cleanup_jobs_pending
                    ON secureCleanupJobs(kind, createdAt, id);

                CREATE INDEX secure_cleanup_operations_maintenance
                    ON secureCleanupOperations(
                        scope,
                        maintenanceState,
                        committedAt
                    );

                CREATE UNIQUE INDEX secure_cleanup_job_identity
                    ON secureCleanupJobs(
                        operationID,
                        kind,
                        COALESCE(opaqueReference, '')
                    );
                """
            )
        }
    }
}
