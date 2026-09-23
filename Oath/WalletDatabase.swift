import Foundation
import GRDB

struct WalletDatabaseResetResidual: Equatable, Sendable {
    let tableName: String
    let recordCount: Int
}

enum WalletDatabaseResetError: Error, Equatable {
    case verificationFailed([WalletDatabaseResetResidual])
}

enum WalletApplicationSettingsWriteGate: String, Equatable, Sendable {
    case allowed
    case resetInProgress = "reset_in_progress"
    case staleGeneration = "stale_generation"
}

private enum WalletDatabaseResetErrorCode {
    static func failureCode(for error: Error) -> String {
        if let resetError = error as? WalletDatabaseResetError,
           case .verificationFailed = resetError
        {
            return "residual_records"
        }
        if let databaseError = error as? DatabaseError {
            return "sqlite_\(databaseError.extendedResultCode.rawValue)"
        }
        return String(reflecting: type(of: error))
    }
}

final class WalletDatabase: @unchecked Sendable {
    static let defaultProfileID = "local-default"

    let pool: DatabasePool
    private let appResetStateLock = NSLock()
    private var appResetInProgress = false
    private var appDataGeneration: UInt64 = 0

    private init(pool: DatabasePool) {
        self.pool = pool
    }

    static func live(
        fileManager: FileManager = .default
    ) throws -> WalletDatabase {
        let baseDirectory = try initialize(
            stage: .applicationSupportDirectory
        ) {
            try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        }
        let databaseDirectory = baseDirectory.appendingPathComponent(
            "WalletDatabase",
            isDirectory: true
        )
        return try applicationDatabase(
            at: databaseDirectory,
            fileManager: fileManager
        )
    }

    static func applicationDatabase(
        at databaseDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> WalletDatabase {
        try Task.checkCancellation()
        try initialize(stage: .databaseDirectory) {
            try fileManager.createDirectory(
                at: databaseDirectory,
                withIntermediateDirectories: true
            )
        }
        try initialize(stage: .databaseDirectoryProtection) {
            try fileManager.setAttributes(
                [
                    .protectionKey:
                        FileProtectionType
                            .completeUntilFirstUserAuthentication
                ],
                ofItemAtPath: databaseDirectory.path
            )
        }

        var configuration = Configuration()
        configuration.label = "Oath.GRDB"
        configuration.foreignKeysEnabled = true
        configuration.busyMode = .timeout(5)
        configuration.maximumReaderCount = 4
        configuration.prepareDatabase { database in
            try database.execute(sql: "PRAGMA temp_store = MEMORY")
            try database.execute(sql: "PRAGMA secure_delete = FAST")
        }

        let databaseURL = databaseDirectory.appendingPathComponent(
            "wallet.sqlite",
            isDirectory: false
        )
        let pool = try initialize(stage: .databaseOpen) {
            try DatabasePool(
                path: databaseURL.path,
                configuration: configuration
            )
        }
        try initialize(stage: .databaseFileProtection) {
            try fileManager.setAttributes(
                [
                    .protectionKey:
                        FileProtectionType
                            .completeUntilFirstUserAuthentication
                ],
                ofItemAtPath: databaseURL.path
            )
        }
        try initialize(stage: .migration) {
            try migrator.migrate(pool)
        }
        WalletRetiredDeveloperStorageCleanup.removeArtifacts(
            using: fileManager
        )
        let database = WalletDatabase(pool: pool)
        try initialize(stage: .referenceData) {
            try database.seedReferenceData()
            try database.discardAbandonedSendSpendPreparations()
        }
        try Task.checkCancellation()
        return database
    }

    static func temporary() throws -> WalletDatabase {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let pool = try DatabasePool(
            path: directory.appendingPathComponent("wallet.sqlite").path
        )
        try migrator.migrate(pool)
        WalletRetiredDeveloperStorageCleanup.removeArtifacts()
        let database = WalletDatabase(pool: pool)
        try database.seedReferenceData()
        try database.discardAbandonedSendSpendPreparations()
        return database
    }

    private static func initialize<Value>(
        stage: WalletDatabaseInitializationStage,
        operation: () throws -> Value
    ) throws -> Value {
        try Task.checkCancellation()
        do {
            let value = try operation()
            try Task.checkCancellation()
            return value
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw WalletDatabaseInitializationError(
                stage: stage,
                underlyingError: error
            )
        }
    }

    func releaseMemory() {
        pool.releaseMemoryEventually()
    }

    func beginAppReset() {
        appResetStateLock.withLock {
            appDataGeneration &+= 1
            appResetInProgress = true
        }
    }

    func finishAppReset() {
        appResetStateLock.withLock {
            appResetInProgress = false
        }
    }

    func isPerformingAppReset() -> Bool {
        appResetStateLock.withLock {
            appResetInProgress
        }
    }

    func applicationSettingsPersistenceGeneration() -> UInt64 {
        appResetStateLock.withLock {
            appDataGeneration
        }
    }

    func applicationSettingsWriteGate(
        expectedGeneration: UInt64
    ) -> WalletApplicationSettingsWriteGate {
        appResetStateLock.withLock {
            if appResetInProgress {
                return .resetInProgress
            }
            guard appDataGeneration == expectedGeneration else {
                return .staleGeneration
            }
            return .allowed
        }
    }

    func eraseAllData() async throws {
        let commit = try await commitAppReset(cleanupPlan: .empty)
        _ = await performPostResetMaintenance(
            operationID: commit.operationID
        )
    }

    func commitAppReset(
        cleanupPlan: WalletAppResetCleanupPlan,
        preservedPreferences: WalletAppResetPreservedPreferences? = nil,
        operationID: UUID = UUID()
    ) async throws -> WalletAppResetCommit {
        let now = Date().timeIntervalSince1970
        let resetSettings = preservedPreferences.map {
            WalletApplicationSettings.resetDefaults(preserving: $0)
        } ?? .default

        do {
            try await pool.write { database in
                try database.execute(sql: "PRAGMA secure_delete = ON")

                // Profiles own every wallet-scoped record. Deleting them first
                // cascades through wallets, accounts, NFT holdings,
                // transactions, security settings, contacts, and other
                // private user data.
                try database.execute(sql: "DELETE FROM profiles")

                // Collections belong to networks rather than profiles, so no
                // profile foreign-key cascade can remove them. Deleting the
                // collection root explicitly cascades through nftItems and
                // any remaining accountNFTHoldings.
                try database.execute(sql: "DELETE FROM nftCollections")

                try database.execute(sql: "DELETE FROM assets")
                for statement in [
                    "DELETE FROM networkFeeQuotes",
                    "DELETE FROM currencyConverterRates",
                    "DELETE FROM apiCache",
                    "DELETE FROM solanaTokenEligibility",
                    "DELETE FROM pendingOperations",
                    "DELETE FROM notificationOpenAudits"
                ] {
                    try database.execute(sql: statement)
                }

                try DBProfileRecord(
                    id: Self.defaultProfileID,
                    displayName: nil,
                    createdAt: now,
                    updatedAt: now,
                    lastActiveAt: now
                ).insert(database)
                try Self.defaultUserSettingsRecord(
                    updatedAt: now,
                    settings: resetSettings
                )
                    .insert(database)

                let residuals = try Self.resetResiduals(in: database)
                guard residuals.isEmpty else {
                    throw WalletDatabaseResetError
                        .verificationFailed(residuals)
                }

                // These retained values live in the normalized preferences
                // table rather than userSettings. Install them only after
                // residual verification so no other pre-reset preference can
                // be mistaken for an allowed survivor.
                if let preservedPreferences {
                    try DBPreferenceRecord(
                        profileID: Self.defaultProfileID,
                        key: UniHapticEngine.preferenceKey,
                        valueType: "bool",
                        value: resetSettings.hapticFeedbackEnabled
                            ? "true"
                            : "false",
                        updatedAt: now
                    ).insert(database)

                    if let version = AppReleaseVersion.normalized(
                        preservedPreferences
                            .lastPresentedWhatsNewVersion
                    ) {
                        try DBPreferenceRecord(
                            profileID: Self.defaultProfileID,
                            key: Self
                                .lastPresentedWhatsNewVersionPreferenceKey,
                            valueType: "string",
                            value: version,
                            updatedAt: now
                        ).insert(database)
                    }
                }

                var cleanupJobs = cleanupPlan.secretReferences.map {
                    (
                        kind: WalletSecureCleanupJobKind.walletSecret,
                        opaqueReference: Optional($0)
                    )
                }
                if cleanupPlan.requiresPushCleanup {
                    cleanupJobs.append(
                        (
                            kind: .pushInstallation,
                            opaqueReference: nil
                        )
                    )
                }
                try Self.insertSecureCleanupOperation(
                    in: database,
                    operationID: operationID,
                    scope: .appReset,
                    jobs: cleanupJobs,
                    requiresMaintenance: true,
                    now: now
                )

            }
        } catch {
            await restoreFastSecureDeleteAfterFailure()
            throw error
        }
        return WalletAppResetCommit(operationID: operationID)
    }

    @discardableResult
    func performPostResetMaintenance(
        operationID: UUID,
        maintenance: (@Sendable () async throws -> Void)? = nil
    ) async -> Bool {
        do {
            if let maintenance {
                try await maintenance()
            } else {
                try await pool.writeWithoutTransaction { database in
                    try database.execute(
                        sql: "PRAGMA wal_checkpoint(TRUNCATE)"
                    )
                    try database.execute(
                        sql: "PRAGMA secure_delete = FAST"
                    )
                }
                try await pool.vacuum()
            }
            try await recordResetMaintenance(
                operationID: operationID,
                state: .complete,
                errorCode: nil
            )
            pool.releaseMemoryEventually()
            return true
        } catch {
            await restoreFastSecureDeleteAfterFailure()
            let errorCode =
                WalletDatabaseResetErrorCode.failureCode(for: error)
            do {
                try await recordResetMaintenance(
                    operationID: operationID,
                    state: .failed,
                    errorCode: errorCode
                )
            } catch {
            }
            return false
        }
    }

    private func restoreFastSecureDeleteAfterFailure() async {
        do {
            try await pool.writeWithoutTransaction { database in
                try database.execute(sql: "PRAGMA secure_delete = FAST")
            }
        } catch {
        }
    }

    private static func resetResiduals(
        in database: Database
    ) throws -> [WalletDatabaseResetResidual] {
        let rows = try Row.fetchAll(
            database,
            sql: """
            SELECT 'wallets' AS tableName, COUNT(*) AS recordCount FROM wallets
            UNION ALL SELECT 'profileSecurity', COUNT(*) FROM profileSecurity
            UNION ALL SELECT 'walletAccounts', COUNT(*) FROM walletAccounts
            UNION ALL SELECT 'assets', COUNT(*) FROM assets
            UNION ALL SELECT 'accountAssets', COUNT(*) FROM accountAssets
            UNION ALL SELECT 'assetPrices', COUNT(*) FROM assetPrices
            UNION ALL SELECT 'marketSnapshots', COUNT(*) FROM marketSnapshots
            UNION ALL SELECT 'transactions', COUNT(*) FROM transactions
            UNION ALL SELECT 'transactionTransfers', COUNT(*) FROM transactionTransfers
            UNION ALL SELECT 'sendRecipientBroadcasts', COUNT(*) FROM sendRecipientBroadcasts
            UNION ALL SELECT 'sendSpendReservations', COUNT(*) FROM sendSpendReservations
            UNION ALL SELECT 'nftCollections', COUNT(*) FROM nftCollections
            UNION ALL SELECT 'nftItems', COUNT(*) FROM nftItems
            UNION ALL SELECT 'accountNFTHoldings', COUNT(*) FROM accountNFTHoldings
            UNION ALL SELECT 'contacts', COUNT(*) FROM contacts
            UNION ALL SELECT 'contactAddresses', COUNT(*) FROM contactAddresses
            UNION ALL SELECT 'connectedDApps', COUNT(*) FROM connectedDApps
            UNION ALL SELECT 'dappPermissions', COUNT(*) FROM dappPermissions
            UNION ALL SELECT 'priceAlerts', COUNT(*) FROM priceAlerts
            UNION ALL SELECT 'notifications', COUNT(*) FROM notifications
            UNION ALL SELECT 'preferences', COUNT(*) FROM preferences
            UNION ALL SELECT 'networkFeeQuotes', COUNT(*) FROM networkFeeQuotes
            UNION ALL SELECT 'currencyConverterRates', COUNT(*) FROM currencyConverterRates
            UNION ALL SELECT 'syncStates', COUNT(*) FROM syncStates
            UNION ALL SELECT 'solanaSyncState', COUNT(*) FROM solanaSyncState
            UNION ALL SELECT 'apiCache', COUNT(*) FROM apiCache
            UNION ALL SELECT 'pendingOperations', COUNT(*) FROM pendingOperations
            UNION ALL SELECT 'tags', COUNT(*) FROM tags
            UNION ALL SELECT 'transactionTags', COUNT(*) FROM transactionTags
            UNION ALL SELECT 'notificationProfiles', COUNT(*) FROM notificationProfiles
            UNION ALL SELECT 'notificationOpenAudits', COUNT(*) FROM notificationOpenAudits
            UNION ALL SELECT 'transactionNotes', COUNT(*) FROM transactionNotes
            UNION ALL SELECT 'sendFeePreferences', COUNT(*) FROM sendFeePreferences
            UNION ALL SELECT 'sendCustomFeePreferences', COUNT(*) FROM sendCustomFeePreferences
            UNION ALL SELECT 'solanaTokenEligibility', COUNT(*) FROM solanaTokenEligibility
            """
        )
        return rows.compactMap { row in
            let recordCount: Int = row["recordCount"]
            guard recordCount > 0 else { return nil }
            return WalletDatabaseResetResidual(
                tableName: row["tableName"],
                recordCount: recordCount
            )
        }
    }
}
