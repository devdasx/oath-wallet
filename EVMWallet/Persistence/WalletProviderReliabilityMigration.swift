import GRDB

extension WalletDatabase {
    static func registerProviderReliabilityMigration(
        on migrator: inout DatabaseMigrator
    ) {
        migrator.registerMigration(
            "v39_provider_endpoint_health"
        ) { database in
            try database.execute(
                sql: """
                CREATE TABLE providerEndpointHealth (
                    serviceID TEXT NOT NULL,
                    endpointID TEXT NOT NULL,
                    successCount INTEGER NOT NULL DEFAULT 0
                        CHECK (successCount >= 0),
                    failureCount INTEGER NOT NULL DEFAULT 0
                        CHECK (failureCount >= 0),
                    consecutiveFailures INTEGER NOT NULL DEFAULT 0
                        CHECK (consecutiveFailures >= 0),
                    ewmaLatencyMilliseconds INTEGER,
                    cooldownUntil REAL,
                    lastSuccessAt REAL,
                    lastFailureAt REAL,
                    updatedAt REAL NOT NULL,
                    PRIMARY KEY (serviceID, endpointID)
                ) WITHOUT ROWID;

                CREATE INDEX providerEndpointHealth_cooldown
                    ON providerEndpointHealth(serviceID, cooldownUntil);
                """
            )
        }
    }
}
