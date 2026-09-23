import Foundation
import GRDB
import Testing
@testable import Aperture

@Suite(.serialized)
struct DeviceMigrationRestoreAtomicityTests {
    @Test
    @MainActor
    func postPreflightRestoreFailurePreservesNotificationState()
        async throws {
        let source = try WalletDatabase.temporary()
        let destination = try WalletDatabase.temporary()
        let vault = WalletSecretVault.shared
        let phrase = WalletCredentialTestFixtures.recoveryPhrase()
        let identity = try await source.persistImportedWallet(
            draft: try WalletCoreService.importRecoveryPhrase(phrase),
            security: .reuseExistingProfile,
            vault: vault
        )
        let sourceReference = try await source.pool.read { database in
            try #require(
                try DBWalletRecord.fetchOne(
                    database,
                    key: identity.walletID
                )?.secretKeyReference
            )
        }
        defer {
            try? vault.deleteIfPresent(reference: sourceReference)
        }

        try await seedDestinationNotificationState(destination)
        let before = try await destinationState(destination)
        let pushIdentityBefore =
            try PushInstallationVault.shared.currentIdentity()

        let preflightPrepared = try await preparedExport(
            from: source,
            vault: vault
        )
        defer {
            try? FileManager.default.removeItem(
                at: preflightPrepared.databaseURL
                    .deletingLastPathComponent()
            )
        }
        let preflightPackage = try packageWithoutSelectedWallet(
            preflightPrepared
        )
        do {
            let verified = try WalletDatabase.verifyDeviceMigration(
                preflightPackage,
                against: destination.pool
            )
            #expect(verified.contents.wallets.count == 1)
        }

        let importPrepared = try await preparedExport(
            from: source,
            vault: vault
        )
        defer {
            try? FileManager.default.removeItem(
                at: importPrepared.databaseURL.deletingLastPathComponent()
            )
        }
        let importPackage = try packageWithoutSelectedWallet(
            importPrepared
        )

        do {
            _ = try await destination.importDeviceMigration(
                importPackage,
                vault: vault
            )
            Issue.record(
                "Expected post-preflight restore validation to fail."
            )
        } catch let error as DeviceMigrationError {
            #expect(error == .invalidDatabase)
        } catch {
            Issue.record(
                "Unexpected migration error type: \(type(of: error))"
            )
        }

        #expect(try await destinationState(destination) == before)
        #expect(
            try PushInstallationVault.shared.currentIdentity()
                == pushIdentityBefore
        )
    }
}

private extension DeviceMigrationRestoreAtomicityTests {
    struct DestinationState: Equatable {
        let notificationProfile: NotificationProfileState?
        let openAudits: [OpenAuditState]
        let walletCount: Int
        let accountCount: Int
    }

    struct NotificationProfileState: Equatable {
        let profileID: String
        let remoteUserID: String
        let installationID: String?
        let reconciliationNeeded: Bool
        let reconciliationGeneration: Int64
        let lastSnapshotDigest: String?
        let lastRegistrationAttemptAt: Double?
        let lastRegistrationSuccessAt: Double?
        let lastRegistrationErrorCode: String?
        let historyBackfillCursor: String?
        let updatedAt: Double

        init(_ record: DBNotificationProfileRecord) {
            profileID = record.profileID
            remoteUserID = record.remoteUserID
            installationID = record.installationID
            reconciliationNeeded = record.reconciliationNeeded
            reconciliationGeneration = record.reconciliationGeneration
            lastSnapshotDigest = record.lastSnapshotDigest
            lastRegistrationAttemptAt =
                record.lastRegistrationAttemptAt
            lastRegistrationSuccessAt =
                record.lastRegistrationSuccessAt
            lastRegistrationErrorCode =
                record.lastRegistrationErrorCode
            historyBackfillCursor = record.historyBackfillCursor
            updatedAt = record.updatedAt
        }
    }

    struct OpenAuditState: Equatable {
        let notificationID: String
        let createdAt: Double
        let attemptCount: Int
        let lastAttemptAt: Double?
        let nextAttemptAt: Double
        let lastErrorCode: String?

        init(_ record: DBNotificationOpenAuditRecord) {
            notificationID = record.notificationID
            createdAt = record.createdAt
            attemptCount = record.attemptCount
            lastAttemptAt = record.lastAttemptAt
            nextAttemptAt = record.nextAttemptAt
            lastErrorCode = record.lastErrorCode
        }
    }

    func seedDestinationNotificationState(
        _ walletDatabase: WalletDatabase
    ) async throws {
        let now = Date().timeIntervalSince1970
        try await walletDatabase.pool.write { database in
            try DBNotificationProfileRecord(
                profileID: WalletDatabase.defaultProfileID,
                remoteUserID:
                    "b19f39f1-b78b-4946-9191-9fc865e77984",
                installationID: nil,
                reconciliationNeeded: false,
                reconciliationGeneration: 23,
                lastSnapshotDigest: String(repeating: "s", count: 43),
                lastRegistrationAttemptAt: now - 30,
                lastRegistrationSuccessAt: now - 20,
                lastRegistrationErrorCode: "preserved_restore_error",
                historyBackfillCursor: "preserved_restore_cursor",
                updatedAt: now - 10
            ).insert(database)
            try DBNotificationOpenAuditRecord(
                notificationID: "preserved-restore-audit-a",
                createdAt: now - 40,
                attemptCount: 2,
                lastAttemptAt: now - 30,
                nextAttemptAt: now + 30,
                lastErrorCode: "preserved_audit_error_a"
            ).insert(database)
            try DBNotificationOpenAuditRecord(
                notificationID: "preserved-restore-audit-b",
                createdAt: now - 20,
                attemptCount: 4,
                lastAttemptAt: now - 10,
                nextAttemptAt: now + 90,
                lastErrorCode: "preserved_audit_error_b"
            ).insert(database)
        }
    }

    func destinationState(
        _ walletDatabase: WalletDatabase
    ) async throws -> DestinationState {
        try await walletDatabase.pool.read { database in
            let profile = try DBNotificationProfileRecord.fetchOne(
                database,
                key: WalletDatabase.defaultProfileID
            )
            let audits = try DBNotificationOpenAuditRecord
                .order(Column("notificationID"))
                .fetchAll(database)
            return DestinationState(
                notificationProfile:
                    profile.map(NotificationProfileState.init),
                openAudits: audits.map(OpenAuditState.init),
                walletCount: try DBWalletRecord.fetchCount(database),
                accountCount:
                    try DBWalletAccountRecord.fetchCount(database)
            )
        }
    }

    func preparedExport(
        from source: WalletDatabase,
        vault: WalletSecretVault
    ) async throws -> DeviceMigrationPreparedExport {
        let authorization =
            try await source.authorizeUnprotectedDeviceMigration()
        return try await source.prepareDeviceMigrationExport(
            authorization: authorization,
            vault: vault
        )
    }

    func packageWithoutSelectedWallet(
        _ prepared: DeviceMigrationPreparedExport
    ) throws -> DeviceMigrationIncomingPackage {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let snapshot = try DatabaseQueue(
            path: prepared.databaseURL.path,
            configuration: configuration
        )
        try snapshot.write { database in
            try database.execute(
                sql: "UPDATE wallets SET isSelected = 0"
            )
        }
        try snapshot.close()

        let attributes = try FileManager.default.attributesOfItem(
            atPath: prepared.databaseURL.path
        )
        let byteCount =
            (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let original = prepared.manifest
        let manifest = DeviceMigrationManifest(
            protocolVersion: original.protocolVersion,
            transferID: original.transferID,
            createdAt: original.createdAt,
            sourceAppVersion: original.sourceAppVersion,
            sourceAppBuild: original.sourceAppBuild,
            databaseMigrationIdentifiers:
                original.databaseMigrationIdentifiers,
            databaseByteCount: byteCount,
            databaseSHA256: try WalletDatabase.sha256(
                of: prepared.databaseURL
            ),
            walletCount: original.walletCount,
            walletSecretCount: original.walletSecretCount
        )
        return DeviceMigrationIncomingPackage(
            databaseURL: prepared.databaseURL,
            manifest: manifest,
            secrets: prepared.secrets
        )
    }
}
