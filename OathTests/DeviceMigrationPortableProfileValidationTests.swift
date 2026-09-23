import Foundation
import GRDB
import Testing
@testable import Aperture

@Suite(.serialized)
struct DeviceMigrationPortableProfileValidationTests {
    @Test
    func secondProfileHardwareWalletCannotBypassManifestCoverage()
        async throws
    {
        let source = try WalletDatabase.temporary()
        let destination = try WalletDatabase.temporary()
        try await insertHardwareWallet(
            profileID: WalletDatabase.defaultProfileID,
            walletID: "portable-default-hardware",
            address: "0x1111111111111111111111111111111111111111",
            into: source.pool
        )

        let authorization =
            try await source.authorizeUnprotectedDeviceMigration()
        let prepared = try await source.prepareDeviceMigrationExport(
            authorization: authorization,
            vault: .shared
        )
        defer {
            try? FileManager.default.removeItem(
                at: prepared.databaseURL.deletingLastPathComponent()
            )
        }
        let forged = try packageAddingSecondProfileHardwareWallet(
            to: prepared
        )

        #expect(prepared.manifest.walletCount == 1)
        #expect(prepared.secrets.walletSecrets.isEmpty)
        #expect(forged.databaseWalletCount == 2)
        #expect(forged.package.manifest.walletCount == 1)

        do {
            _ = try await destination.importDeviceMigration(
                forged.package,
                vault: .shared
            )
            Issue.record(
                "Expected the extra-profile migration to be rejected."
            )
        } catch let error as DeviceMigrationError {
            #expect(error == .invalidDatabase)
        } catch {
            Issue.record(
                "Unexpected migration error type: \(type(of: error))"
            )
        }

        let state = try await destination.pool.read { database in
            DestinationState(
                profileIDs: try String.fetchAll(
                    database,
                    sql: "SELECT id FROM profiles ORDER BY id"
                ),
                walletCount: try DBWalletRecord.fetchCount(database),
                accountCount: try DBWalletAccountRecord.fetchCount(database)
            )
        }
        #expect(state.profileIDs == [WalletDatabase.defaultProfileID])
        #expect(state.walletCount == 0)
        #expect(state.accountCount == 0)
    }
}

private extension DeviceMigrationPortableProfileValidationTests {
    struct ForgedPackage {
        let package: DeviceMigrationIncomingPackage
        let databaseWalletCount: Int
    }

    struct DestinationState {
        let profileIDs: [String]
        let walletCount: Int
        let accountCount: Int
    }

    static let secondProfileID = "portable-secondary-profile"

    func packageAddingSecondProfileHardwareWallet(
        to prepared: DeviceMigrationPreparedExport
    ) throws -> ForgedPackage {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let snapshot = try DatabaseQueue(
            path: prepared.databaseURL.path,
            configuration: configuration
        )
        let databaseWalletCount = try snapshot.write { database in
            let now = Date().timeIntervalSince1970
            try DBProfileRecord(
                id: Self.secondProfileID,
                displayName: "Secondary",
                createdAt: now,
                updatedAt: now,
                lastActiveAt: now
            ).insert(database)
            try insertHardwareWallet(
                profileID: Self.secondProfileID,
                walletID: "portable-secondary-hardware",
                address:
                    "0x2222222222222222222222222222222222222222",
                in: database
            )
            return try DBWalletRecord.fetchCount(database)
        }
        try snapshot.close()

        let attributes = try FileManager.default.attributesOfItem(
            atPath: prepared.databaseURL.path
        )
        let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? 0
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
        return ForgedPackage(
            package: DeviceMigrationIncomingPackage(
                databaseURL: prepared.databaseURL,
                manifest: manifest,
                secrets: prepared.secrets
            ),
            databaseWalletCount: databaseWalletCount
        )
    }

    func insertHardwareWallet(
        profileID: String,
        walletID: String,
        address: String,
        into pool: DatabasePool
    ) async throws {
        try await pool.write { database in
            try insertHardwareWallet(
                profileID: profileID,
                walletID: walletID,
                address: address,
                in: database
            )
        }
    }

    func insertHardwareWallet(
        profileID: String,
        walletID: String,
        address: String,
        in database: Database
    ) throws {
        let now = Date().timeIntervalSince1970
        try DBWalletRecord(
            id: walletID,
            profileID: profileID,
            name: "Hardware",
            kind: DatabaseWalletKind.hardware.rawValue,
            secretKeyReference: nil,
            isSelected: true,
            sortOrder: 0,
            createdAt: now,
            updatedAt: now,
            lastOpenedAt: now,
            archivedAt: nil
        ).insert(database)
        try DBWalletAccountRecord(
            id: "\(walletID):eth:0",
            walletID: walletID,
            networkID: "eth",
            address: address,
            normalizedAddress: address.lowercased(),
            label: nil,
            derivationPath: nil,
            accountIndex: 0,
            publicKey: nil,
            isWatchOnly: true,
            isEnabled: true,
            createdAt: now,
            updatedAt: now,
            lastSyncedAt: nil
        ).insert(database)
    }
}
