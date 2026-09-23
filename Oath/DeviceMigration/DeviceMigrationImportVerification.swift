import Foundation
import GRDB

extension WalletDatabase {
    struct VerifiedDeviceMigrationImport: @unchecked Sendable {
        let source: DatabaseQueue
        let contents: MigrationDatabaseContents
        let secrets: [DeviceMigrationWalletSecret]
    }

    static func verifyDeviceMigration(
        _ package: DeviceMigrationIncomingPackage,
        against destinationPool: DatabasePool
    ) throws -> VerifiedDeviceMigrationImport {
        try validatePackageFiles(package)

        let destinationWalletCount = try destinationPool.read {
            database in
            try DBWalletRecord.fetchCount(database)
        }
        guard destinationWalletCount == 0 else {
            throw DeviceMigrationError.destinationNotEmpty
        }
        let supportedMigrations = try destinationPool.read {
            database in
            try migrationIdentifiers(database)
        }
        guard Set(package.manifest.databaseMigrationIdentifiers)
            .isSubset(of: Set(supportedMigrations)) else {
            throw DeviceMigrationError.incompatibleDatabase
        }

        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let source = try DatabaseQueue(
            path: package.databaseURL.path,
            configuration: configuration
        )
        try validateDatabase(source)
        try migrator.migrate(source)
        try seedReferenceData(in: source)
        try validateDatabase(source)
        try source.read { database in
            try DeviceMigrationTransferPolicy
                .validatePortableDatabase(database)
        }
        let contents = try migrationDatabaseContents(source)
        guard contents.wallets.count == package.manifest.walletCount else {
            throw DeviceMigrationError.invalidDatabase
        }
        try validateSecretCoverage(
            wallets: contents.wallets,
            muunRecoveryWalletIDs: contents.muunRecoveryWalletIDs,
            bitcoinImportedWalletIDs: contents.bitcoinImportedWalletIDs,
            secrets: package.secrets.walletSecrets
        )
        try DeviceMigrationAccountSecretVerifier.validate(
            source: source,
            secrets: package.secrets.walletSecrets
        )

        return VerifiedDeviceMigrationImport(
            source: source,
            contents: contents,
            secrets: package.secrets.walletSecrets
        )
    }
}
