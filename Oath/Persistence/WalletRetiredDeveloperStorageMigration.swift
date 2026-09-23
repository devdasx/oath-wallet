import Foundation
import GRDB

extension WalletDatabase {
    static func registerLegacyWalletSyncDiagnosticsMigration(
        on migrator: inout DatabaseMigrator
    ) {
        migrator.registerMigration(
            "v61_wallet_sync_diagnostics"
        ) { _ in }
    }

    static func registerDeveloperLogRemovalMigration(
        on migrator: inout DatabaseMigrator
    ) {
        migrator.registerMigration(
            "v65_remove_developer_logs"
        ) { database in
            try database.execute(
                sql: "DROP TABLE IF EXISTS walletSyncDiagnosticEvents"
            )
        }
    }
}

enum WalletRetiredDeveloperStorageCleanup {
    private static let exportPrefix = "Aperture-Sync-Diagnostics-"
    private static let walletPreparationDirectoryName =
        "WalletPreparationDiagnostics"

    static func removeArtifacts(
        using fileManager: FileManager = .default,
        cacheDirectories: [URL]? = nil,
        temporaryDirectory: URL? = nil
    ) {
        let cacheRoots = cacheDirectories ?? fileManager.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        )
        for cacheRoot in cacheRoots {
            let preparationDirectory = cacheRoot.appendingPathComponent(
                walletPreparationDirectoryName,
                isDirectory: true
            )
            try? fileManager.removeItem(at: preparationDirectory)
        }

        let temporaryRoot = temporaryDirectory
            ?? fileManager.temporaryDirectory
        let performanceExports = temporaryRoot.appendingPathComponent(
            "Aperture-Performance-Exports",
            isDirectory: true
        )
        try? fileManager.removeItem(at: performanceExports)

        guard let contents = try? fileManager.contentsOfDirectory(
            at: temporaryRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for url in contents where
            url.lastPathComponent.hasPrefix(exportPrefix)
                && url.pathExtension.lowercased() == "txt" {
            try? fileManager.removeItem(at: url)
        }
    }
}
