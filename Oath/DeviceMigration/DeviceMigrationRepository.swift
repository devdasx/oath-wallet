import CryptoKit
import Foundation
import GRDB
import WalletCore

struct WalletDeviceMigrationAuthorization: Sendable {
    private let expiresAt: Date

    private init(expiresAt: Date) {
        self.expiresAt = expiresAt
    }

    fileprivate static func authenticated() -> Self {
        Self(expiresAt: Date().addingTimeInterval(5 * 60))
    }

    fileprivate func permitsExport() -> Bool {
        Date() <= expiresAt
    }
}

struct DeviceMigrationDestinationSecurityState:
    Equatable,
    Sendable
{
    let passcodeKeychainReference: String?
    let failedAttemptCount: Int
    let lockedUntil: Double?
    let securityUpdatedAt: Double?
    let appLockEnabled: Bool
    let biometricEnabled: Bool
    let autoLockSeconds: Int?
    let privacyShieldEnabled: Bool
}

enum DeviceMigrationTransferPolicy {
    static func removeUnsupportedWatchOnlyWallets(
        from database: Database,
        profileID: String = WalletDatabase.defaultProfileID
    ) throws {
        try database.execute(
            sql: """
            DELETE FROM wallets
            WHERE profileID = ? AND kind = 'watchOnly'
            """,
            arguments: [profileID]
        )

        let selectedWalletCount = try Int.fetchOne(
            database,
            sql: """
            SELECT COUNT(*)
            FROM wallets
            WHERE profileID = ? AND isSelected = 1
            """,
            arguments: [profileID]
        ) ?? 0
        guard selectedWalletCount == 0 else {
            return
        }

        try database.execute(
            sql: """
            UPDATE wallets
            SET isSelected = 1
            WHERE id = (
                SELECT id
                FROM wallets
                WHERE profileID = ? AND archivedAt IS NULL
                ORDER BY sortOrder, createdAt
                LIMIT 1
            )
            """,
            arguments: [profileID]
        )
    }

    static func captureDestinationSecurity(
        in database: Database,
        profileID: String = WalletDatabase.defaultProfileID
    ) throws -> DeviceMigrationDestinationSecurityState {
        guard let settings = try DBUserSettingsRecord.fetchOne(
            database,
            key: profileID
        ) else {
            throw DeviceMigrationError.invalidDatabase
        }
        let security = try DBProfileSecurityRecord.fetchOne(
            database,
            key: profileID
        )
        let hasPasscode = security != nil
        let appLockEnabled =
            hasPasscode && settings.appLockEnabled

        return DeviceMigrationDestinationSecurityState(
            passcodeKeychainReference:
                security?.passcodeKeychainReference,
            failedAttemptCount: security?.failedAttemptCount ?? 0,
            lockedUntil: security?.lockedUntil,
            securityUpdatedAt: security?.updatedAt,
            appLockEnabled: appLockEnabled,
            biometricEnabled:
                appLockEnabled && settings.biometricEnabled,
            autoLockSeconds: settings.autoLockSeconds,
            privacyShieldEnabled: settings.privacyShieldEnabled
        )
    }

    static func sanitizeExportDatabase(
        _ database: Database,
        profileID: String = WalletDatabase.defaultProfileID
    ) throws {
        // Until local discovery exists, transferring only the root cannot restore
        // known one-time output keys. Stop before changing even the snapshot.
        guard try DBBitcoinSilentPaymentOutputRecord.fetchCount(database) == 0 else {
            throw DeviceMigrationError.silentPaymentRecoveryRequired
        }
        try removeUnsupportedWatchOnlyWallets(
            from: database,
            profileID: profileID
        )
        guard var settings = try DBUserSettingsRecord.fetchOne(
            database,
            key: profileID
        ) else {
            throw DeviceMigrationError.invalidDatabase
        }

        try database.execute(
            sql: """
            UPDATE wallets
            SET secretKeyReference = NULL
            WHERE profileID = ?
            """,
            arguments: [profileID]
        )
        // Child WIF caches are installation-bound Keychain accelerators.
        // Public HD addresses remain portable and the receiving device
        // regenerates fresh cache references from the transferred root.
        try DBBitcoinHDKeyCacheRecord.deleteAll(database)
        // Known outputs are rejected above. Empty installation-bound account
        // references are not portable and do not authorize receiving.
        try DBBitcoinSilentPaymentOutputRecord.deleteAll(database)
        try DBBitcoinSilentPaymentAccountRecord.deleteAll(database)
        try DBProfileSecurityRecord.deleteAll(database)

        settings.appLockEnabled = false
        settings.biometricEnabled = false
        settings.autoLockSeconds = nil
        settings.privacyShieldEnabled = false
        try settings.update(database)

        // These rows are bound to the sending installation's APNs
        // credential and delivery outbox. Notification history remains in
        // the portable `notifications` table.
        try DBNotificationProfileRecord.deleteAll(database)
        try DBNotificationOpenAuditRecord.deleteAll(database)
    }

    static func validatePortableDatabase(
        _ database: Database,
        profileID: String = WalletDatabase.defaultProfileID
    ) throws {
        let profileIDs = try String.fetchAll(
            database,
            sql: "SELECT id FROM profiles"
        )
        guard profileID == WalletDatabase.defaultProfileID,
              profileIDs.count == 1,
              profileIDs.first == WalletDatabase.defaultProfileID else {
            throw DeviceMigrationError.invalidDatabase
        }
        guard let settings = try DBUserSettingsRecord.fetchOne(
            database,
            key: profileID
        ) else {
            throw DeviceMigrationError.invalidDatabase
        }
        let securityCount = try DBProfileSecurityRecord.fetchCount(
            database
        )
        let walletReferenceCount = try Int.fetchOne(
            database,
            sql: """
            SELECT COUNT(*)
            FROM wallets
            WHERE secretKeyReference IS NOT NULL
            """
        ) ?? 0
        let bitcoinKeyCacheReferenceCount = try
            DBBitcoinHDKeyCacheRecord.fetchCount(database)
        let silentPaymentAccountReferenceCount = try
            DBBitcoinSilentPaymentAccountRecord.fetchCount(database)
        let silentPaymentOutputReferenceCount = try
            DBBitcoinSilentPaymentOutputRecord.fetchCount(database)
        let notificationProfileCount =
            try DBNotificationProfileRecord.fetchCount(database)
        let notificationAuditCount =
            try DBNotificationOpenAuditRecord.fetchCount(database)
        let watchOnlyWalletCount = try Int.fetchOne(
            database,
            sql: """
            SELECT COUNT(*)
            FROM wallets
            WHERE kind = 'watchOnly'
            """
        ) ?? 0
        let unsupportedWatchOnlyAccountCount = try Int.fetchOne(
            database,
            sql: """
            SELECT COUNT(*)
            FROM walletAccounts AS account
            JOIN wallets AS wallet ON wallet.id = account.walletID
            WHERE account.isWatchOnly = 1
              AND wallet.kind != 'hardware'
            """
        ) ?? 0

        guard securityCount == 0,
              walletReferenceCount == 0,
              bitcoinKeyCacheReferenceCount == 0,
              silentPaymentAccountReferenceCount == 0,
              silentPaymentOutputReferenceCount == 0,
              notificationProfileCount == 0,
              notificationAuditCount == 0,
              watchOnlyWalletCount == 0,
              unsupportedWatchOnlyAccountCount == 0,
              !settings.appLockEnabled,
              !settings.biometricEnabled,
              settings.autoLockSeconds == nil,
              !settings.privacyShieldEnabled else {
            throw DeviceMigrationError.invalidDatabase
        }
    }

    static func restoreDestinationSecurity(
        _ state: DeviceMigrationDestinationSecurityState,
        in database: Database,
        profileID: String = WalletDatabase.defaultProfileID
    ) throws {
        guard var settings = try DBUserSettingsRecord.fetchOne(
            database,
            key: profileID
        ) else {
            throw DeviceMigrationError.invalidDatabase
        }

        try DBProfileSecurityRecord.deleteAll(database)
        if let reference = state.passcodeKeychainReference {
            try DBProfileSecurityRecord(
                profileID: profileID,
                passcodeKeychainReference: reference,
                failedAttemptCount: state.failedAttemptCount,
                lockedUntil: state.lockedUntil,
                updatedAt:
                    state.securityUpdatedAt
                    ?? Date().timeIntervalSince1970
            ).insert(database)
        }

        let hasPasscode =
            state.passcodeKeychainReference != nil
        settings.appLockEnabled =
            hasPasscode && state.appLockEnabled
        settings.biometricEnabled =
            settings.appLockEnabled && state.biometricEnabled
        settings.autoLockSeconds = state.autoLockSeconds
        settings.privacyShieldEnabled =
            state.privacyShieldEnabled
        try settings.update(database)
    }
}

extension WalletDatabase {
    func authorizeDeviceMigration(
        authenticationGrant: WalletAuthenticationGrant
    ) async throws -> WalletDeviceMigrationAuthorization {
        let settings = try await walletSecuritySettings()
        guard authenticationGrant.permits(settings: settings) else {
            throw DeviceMigrationError.authenticationFailed
        }
        return .authenticated()
    }

    func authorizeUnprotectedDeviceMigration() async throws
        -> WalletDeviceMigrationAuthorization {
        let protectionIsDisabled = try await pool.read { database in
            guard let settings = try DBUserSettingsRecord.fetchOne(
                database,
                key: Self.defaultProfileID
            ) else {
                throw WalletSecurityPersistenceError.missingSettings
            }
            return !settings.appLockEnabled
        }
        guard protectionIsDisabled else {
            throw DeviceMigrationError.authenticationFailed
        }
        return .authenticated()
    }

    func prepareDeviceMigrationExport(
        authorization: WalletDeviceMigrationAuthorization,
        vault: WalletSecretVault = .shared
    ) async throws -> DeviceMigrationPreparedExport {
        guard authorization.permitsExport() else {
            throw DeviceMigrationError.authorizationExpired
        }

        let pool = pool
        return try await Task.detached(priority: .userInitiated) {
            try Self.makeDeviceMigrationExport(
                pool: pool,
                vault: vault
            )
        }.value
    }

    func importDeviceMigration(
        _ package: DeviceMigrationIncomingPackage,
        vault: WalletSecretVault = .shared
    ) async throws -> DeviceMigrationImportResult {
        await PushNotificationCoordinator.shared
            .beginDeviceMigrationImport()
        beginAppReset()
        defer {
            finishAppReset()
        }

        do {
            let pool = pool
            let verified = try await Task.detached(
                priority: .userInitiated
            ) {
                try Self.verifyDeviceMigration(
                    package,
                    against: pool
                )
            }.value
            let result = try await Task.detached(
                priority: .userInitiated
            ) {
                try Self.restoreDeviceMigration(
                    verified,
                    into: pool,
                    vault: vault
                )
            }.value
            try await prepareAllBitcoinHDWallets(vault: vault)
            try await prepareAllBitcoinSilentPaymentAccounts(vault: vault)
            await PushNotificationCoordinator.shared
                .preparePersistentStateForDeviceMigrationImport(
                    database: self
                )
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .walletSecuritySettingsDidChange,
                    object: nil
                )
                PushNotificationCoordinator.shared
                    .deviceMigrationDidComplete()
            }
            return result
        } catch let error as DeviceMigrationError {
            await MainActor.run {
                PushNotificationCoordinator.shared
                    .deviceMigrationImportDidFail()
            }
            throw error
        } catch {
            await MainActor.run {
                PushNotificationCoordinator.shared
                    .deviceMigrationImportDidFail()
            }
            throw DeviceMigrationError.importFailed
        }
    }
}

extension WalletDatabase {
    struct MigrationDatabaseContents {
        let wallets: [DBWalletRecord]
        let muunRecoveryWalletIDs: Set<String>
        let bitcoinImportedWalletIDs: Set<String>
        let migrationIdentifiers: [String]
    }

    struct ExistingDestinationState {
        let walletReferences: [String]
        let security: DeviceMigrationDestinationSecurityState
        let notificationProfile: DBNotificationProfileRecord?
        let pendingNotificationOpenAudits:
            [DBNotificationOpenAuditRecord]
    }


    static func makeDeviceMigrationExport(
        pool: DatabasePool,
        vault: WalletSecretVault
    ) throws -> DeviceMigrationPreparedExport {
        let directory = try migrationTemporaryDirectory()
        let databaseURL = directory.appendingPathComponent(
            "wallet.sqlite",
            isDirectory: false
        )

        do {
            var configuration = Configuration()
            configuration.foreignKeysEnabled = true
            let snapshot = try DatabaseQueue(
                path: databaseURL.path,
                configuration: configuration
            )
            try pool.backup(to: snapshot)
            try snapshot.write { database in
                try DeviceMigrationTransferPolicy
                    .removeUnsupportedWatchOnlyWallets(from: database)
            }
            let contents = try migrationDatabaseContents(snapshot)
            guard !contents.wallets.isEmpty else {
                throw DeviceMigrationError.noWallets
            }

            let walletSecrets = try contents.wallets.compactMap {
                wallet -> DeviceMigrationWalletSecret? in
                guard let kind = DatabaseWalletKind(rawValue: wallet.kind)
                else {
                    throw DeviceMigrationError.invalidDatabase
                }
                let migrationKind: DeviceMigrationWalletSecretKind
                switch kind {
                case .created, .importedRecoveryPhrase:
                    migrationKind = .recoveryPhrase
                case .importedPrivateKey:
                    if contents.bitcoinImportedWalletIDs.contains(wallet.id) {
                        migrationKind = .bitcoinImportedWallet
                    } else {
                    migrationKind = contents.muunRecoveryWalletIDs
                        .contains(wallet.id)
                        ? .muunRecovery
                        : .privateKey
                    }
                case .watchOnly, .hardware:
                    guard wallet.secretKeyReference == nil else {
                        throw DeviceMigrationError.invalidDatabase
                    }
                    return nil
                }
                guard let reference = wallet.secretKeyReference else {
                    throw DeviceMigrationError.incompleteSecretSet
                }
                let data = try vault.data(reference: reference)
                try validateWalletSecret(data, kind: migrationKind)
                return DeviceMigrationWalletSecret(
                    walletID: wallet.id,
                    kind: migrationKind,
                    data: data
                )
            }

            try snapshot.write { database in
                try DeviceMigrationTransferPolicy
                    .sanitizeExportDatabase(database)
                try DeviceMigrationTransferPolicy
                    .validatePortableDatabase(database)
            }
            // `DatabaseQueue` may finalize SQLite bookkeeping when its
            // connection closes. Seal the byte count and digest only after
            // that work is complete so the manifest describes the exact file
            // handed to Multipeer Connectivity.
            try snapshot.close()

            let secrets = DeviceMigrationSecretsBundle(
                protocolVersion: DeviceMigrationProtocol.version,
                walletSecrets: walletSecrets
            )
            let encodedSecrets = try DeviceMigrationCryptography.encode(
                secrets
            )
            guard encodedSecrets.count
                    <= DeviceMigrationProtocol.maximumSecretByteCount else {
                throw DeviceMigrationError.invalidWalletSecret
            }

            let attributes = try FileManager.default.attributesOfItem(
                atPath: databaseURL.path
            )
            let byteCount = (attributes[.size] as? NSNumber)?
                .int64Value ?? 0
            guard byteCount > 0 else {
                throw DeviceMigrationError.invalidDatabase
            }
            guard byteCount
                    <= DeviceMigrationProtocol.maximumDatabaseByteCount else {
                throw DeviceMigrationError.databaseTooLarge
            }

            let transferID = UUID().uuidString.lowercased()
            let manifest = DeviceMigrationManifest(
                protocolVersion: DeviceMigrationProtocol.version,
                transferID: transferID,
                createdAt: Date().timeIntervalSince1970,
                sourceAppVersion:
                    Bundle.main.object(
                        forInfoDictionaryKey:
                            "CFBundleShortVersionString"
                    ) as? String ?? "0",
                sourceAppBuild:
                    Bundle.main.object(
                        forInfoDictionaryKey: "CFBundleVersion"
                    ) as? String ?? "0",
                databaseMigrationIdentifiers:
                    contents.migrationIdentifiers,
                databaseByteCount: byteCount,
                databaseSHA256: try sha256(of: databaseURL),
                walletCount: contents.wallets.count,
                walletSecretCount: walletSecrets.count
            )
            return DeviceMigrationPreparedExport(
                databaseURL: databaseURL,
                manifest: manifest,
                secrets: secrets
            )
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    static func restoreDeviceMigration(
        _ verified: VerifiedDeviceMigrationImport,
        into destinationPool: DatabasePool,
        vault: WalletSecretVault
    ) throws -> DeviceMigrationImportResult {
        let source = verified.source
        let contents = verified.contents
        let secrets = verified.secrets

        let destinationState = try destinationPool.read {
            database in
            ExistingDestinationState(
                walletReferences: try String.fetchAll(
                    database,
                    sql: """
                    SELECT secretKeyReference
                    FROM wallets
                    WHERE secretKeyReference IS NOT NULL
                    UNION
                    SELECT keychainReference
                    FROM bitcoinHDKeyCaches
                    UNION
                    SELECT keychainReference
                    FROM bitcoinSilentPaymentAccounts
                    UNION
                    SELECT keychainReference
                    FROM bitcoinSilentPaymentOutputs
                    """
                ),
                security:
                    try DeviceMigrationTransferPolicy
                    .captureDestinationSecurity(in: database),
                notificationProfile:
                    try DBNotificationProfileRecord.fetchOne(
                        database,
                        key: defaultProfileID
                    ),
                pendingNotificationOpenAudits:
                    try DBNotificationOpenAuditRecord.fetchAll(database)
            )
        }

        var createdWalletReferences: [String] = []
        var shouldDeleteCreatedReferencesOnFailure = true
        do {
            let referenceByWalletID = try Dictionary(
                uniqueKeysWithValues:
                    secrets.map { secret in
                        try validateWalletSecret(
                            secret.data,
                            kind: secret.kind
                        )
                        let reference = try vault.store(
                            secret.data,
                            kind: secret.kind.vaultKind
                        )
                        createdWalletReferences.append(reference)
                        return (secret.walletID, reference)
                    }
            )

            try source.write { database in
                for (walletID, reference) in referenceByWalletID {
                    try database.execute(
                        sql: """
                        UPDATE wallets
                        SET secretKeyReference = ?
                        WHERE id = ?
                        """,
                        arguments: [reference, walletID]
                    )
                }

                try DeviceMigrationTransferPolicy
                    .restoreDestinationSecurity(
                        destinationState.security,
                        in: database
                    )

                // A server registration belongs to this receiving
                // installation's Keychain credential. Never restore the
                // source phone's remote user binding or open-audit outbox.
                try DBNotificationProfileRecord.deleteAll(database)
                try DBNotificationOpenAuditRecord.deleteAll(database)
                if var notificationProfile =
                    destinationState.notificationProfile {
                    notificationProfile.reconciliationNeeded = true
                    notificationProfile.reconciliationGeneration += 1
                    notificationProfile.updatedAt =
                        Date().timeIntervalSince1970
                    try notificationProfile.insert(database)
                }
                for audit in
                    destinationState.pendingNotificationOpenAudits {
                    try audit.insert(database)
                }
            }
            try validateDatabase(source)

            let rollback = try DatabaseQueue()
            try destinationPool.backup(to: rollback)
            shouldDeleteCreatedReferencesOnFailure = false
            do {
                try source.backup(to: destinationPool)
                try validateRestoredReferences(
                    destinationPool,
                    walletReferences: Set(createdWalletReferences)
                )
                try validateRestoredDestinationSecurity(
                    destinationPool,
                    expected: destinationState.security
                )
                guard let selectedWallet =
                    try selectedWalletIdentity(in: destinationPool) else {
                    throw DeviceMigrationError.invalidDatabase
                }
                let settings = try applicationSettings(
                    in: destinationPool
                )

                for reference in destinationState.walletReferences
                where !createdWalletReferences.contains(reference) {
                    try? vault.deleteIfPresent(reference: reference)
                }

                return DeviceMigrationImportResult(
                    selectedWallet: selectedWallet,
                    walletCount: contents.wallets.count,
                    applicationSettings: settings
                )
            } catch {
                do {
                    try rollback.backup(to: destinationPool)
                    shouldDeleteCreatedReferencesOnFailure = true
                } catch {
                    // If rollback itself fails, retain the newly-vaulted
                    // material because the live database may already refer
                    // to it. Deleting it would turn a database failure into
                    // irreversible secret loss.
                    throw DeviceMigrationError.importFailed
                }
                throw error
            }
        } catch {
            if shouldDeleteCreatedReferencesOnFailure {
                for reference in createdWalletReferences {
                    try? vault.deleteIfPresent(reference: reference)
                }
            }
            if let migrationError = error as? DeviceMigrationError {
                throw migrationError
            }
            throw DeviceMigrationError.importFailed
        }
    }

    static func migrationDatabaseContents(
        _ reader: any DatabaseReader
    ) throws -> MigrationDatabaseContents {
        try reader.read { database in
            let wallets = try DBWalletRecord
                .filter(Column("profileID") == defaultProfileID)
                .order(Column("sortOrder"), Column("createdAt"))
                .fetchAll(database)
            return MigrationDatabaseContents(
                wallets: wallets,
                muunRecoveryWalletIDs: Set(
                    try String.fetchAll(
                        database,
                        sql: """
                        SELECT walletID
                        FROM muunRecoveryWallets
                        ORDER BY walletID
                        """
                    )
                ),
                bitcoinImportedWalletIDs: Set(try String.fetchAll(database,
                    sql: "SELECT walletID FROM walletAccounts WHERE networkID='bitcoin' AND derivationPath=?",
                    arguments: [BitcoinImportedWalletMaterial.accountMarker])),
                migrationIdentifiers: try migrationIdentifiers(database)
            )
        }
    }

    static func migrationIdentifiers(
        _ database: Database
    ) throws -> [String] {
        try String.fetchAll(
            database,
            sql: """
            SELECT identifier
            FROM grdb_migrations
            ORDER BY rowid
            """
        )
    }

    static func validatePackageFiles(
        _ package: DeviceMigrationIncomingPackage
    ) throws {
        guard package.manifest.protocolVersion
                == DeviceMigrationProtocol.version,
              package.secrets.protocolVersion
                == DeviceMigrationProtocol.version else {
            throw DeviceMigrationError.unsupportedProtocol
        }
        guard package.manifest.walletSecretCount
                == package.secrets.walletSecrets.count else {
            throw DeviceMigrationError.incompleteSecretSet
        }
        let encodedSecrets = try DeviceMigrationCryptography.encode(
            package.secrets
        )
        guard encodedSecrets.count
                <= DeviceMigrationProtocol.maximumSecretByteCount else {
            throw DeviceMigrationError.invalidWalletSecret
        }
        let attributes = try FileManager.default.attributesOfItem(
            atPath: package.databaseURL.path
        )
        let byteCount = (attributes[.size] as? NSNumber)?
            .int64Value ?? 0
        guard byteCount == package.manifest.databaseByteCount,
              byteCount > 0,
              byteCount
                <= DeviceMigrationProtocol.maximumDatabaseByteCount else {
            throw DeviceMigrationError.transferIntegrityFailed
        }
        let actualSHA256 = try sha256(of: package.databaseURL)
        guard actualSHA256 == package.manifest.databaseSHA256 else {
            throw DeviceMigrationError.transferIntegrityFailed
        }
    }

    static func validateDatabase(
        _ writer: any DatabaseWriter
    ) throws {
        try writer.read { database in
            let integrity = try String.fetchAll(
                database,
                sql: "PRAGMA quick_check"
            )
            guard integrity == ["ok"] else {
                throw DeviceMigrationError.invalidDatabase
            }
            let foreignKeyFailures = try Row.fetchAll(
                database,
                sql: "PRAGMA foreign_key_check"
            )
            guard foreignKeyFailures.isEmpty else {
                throw DeviceMigrationError.invalidDatabase
            }
            let nonMainnetCount = try Int.fetchOne(
                database,
                sql: "SELECT COUNT(*) FROM networks WHERE isMainnet <> 1"
            ) ?? 0
            guard nonMainnetCount == 0 else {
                throw DeviceMigrationError.invalidDatabase
            }
        }
    }

    static func validateRestoredReferences(
        _ pool: DatabasePool,
        walletReferences: Set<String>
    ) throws {
        try pool.read { database in
            let restoredWalletReferences = Set(
                try String.fetchAll(
                    database,
                    sql: """
                    SELECT secretKeyReference
                    FROM wallets
                    WHERE secretKeyReference IS NOT NULL
                    """
                )
            )
            guard restoredWalletReferences == walletReferences else {
                throw DeviceMigrationError.importFailed
            }
        }
    }

    static func validateRestoredDestinationSecurity(
        _ pool: DatabasePool,
        expected: DeviceMigrationDestinationSecurityState
    ) throws {
        let restored = try pool.read { database in
            try DeviceMigrationTransferPolicy
                .captureDestinationSecurity(in: database)
        }
        guard restored == expected else {
            throw DeviceMigrationError.importFailed
        }
    }

    static func selectedWalletIdentity(
        in pool: DatabasePool
    ) throws -> PersistedWalletIdentity? {
        try pool.read { database in
            guard let wallet = try DBWalletRecord
                .filter(Column("profileID") == defaultProfileID)
                .filter(Column("isSelected") == true)
                .filter(Column("archivedAt") == nil)
                .fetchOne(database),
                let account = try DBWalletAccountRecord
                    .filter(Column("walletID") == wallet.id)
                    .filter(Column("isEnabled") == true)
                    .order(
                        sql: """
                        CASE WHEN networkID = 'eth' THEN 0 ELSE 1 END,
                        createdAt
                        """
                    )
                    .fetchOne(database)
            else {
                return nil
            }
            return PersistedWalletIdentity(
                walletID: wallet.id,
                address: account.address
            )
        }
    }

    static func applicationSettings(
        in pool: DatabasePool
    ) throws -> WalletApplicationSettings {
        try pool.read { database in
            let record = try DBUserSettingsRecord.fetchOne(
                database,
                key: defaultProfileID
            )
            let preferences = Dictionary(
                uniqueKeysWithValues: try DBPreferenceRecord
                    .filter(Column("profileID") == defaultProfileID)
                    .fetchAll(database)
                    .map { ($0.key, $0) }
            )
            return applicationSettings(
                record: record,
                preferences: preferences
            )
        }
    }

    static func migrationTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "device-migration-\(UUID().uuidString.lowercased())",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [
                .protectionKey:
                    FileProtectionType.completeUntilFirstUserAuthentication
            ],
            ofItemAtPath: directory.path
        )
        return directory
    }

    static func sha256(of url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer {
            try? handle.close()
        }
        var digest = SHA256()
        while let data = try handle.read(upToCount: 1_024 * 1_024),
              !data.isEmpty {
            digest.update(data: data)
        }
        return Data(digest.finalize())
    }
}
