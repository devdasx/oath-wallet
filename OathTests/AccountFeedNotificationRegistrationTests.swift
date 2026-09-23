import Foundation
import GRDB
import Testing
@testable import Aperture

struct AccountFeedNotificationRegistrationTests {
    @Test(arguments: [
        ("xrp", "rMwNibdiFaEzsTaFCG1NnmAM3Rv3vHUy5L"),
        ("stellar", "GA5WQXYY32PG2I2EIWLGBVPHF2PHAX5UHFSYRIJGOJNGJZAK73QVLRIE"),
        ("near", "root.near"),
        ("aptos", "0x" + String(repeating: "ab", count: 32)),
        ("sui", "0x" + String(repeating: "cd", count: 32))
    ])
    func registrationUsesAccountRoleAndCanonicalAddress(
        networkID: String,
        address: String
    ) async throws {
        let database = try WalletDatabase.temporary()
        let now = Date().timeIntervalSince1970
        try await database.pool.write { db in
            try DBWalletRecord(
                id: "notification-wallet", profileID: WalletDatabase.defaultProfileID,
                name: "Fixture", kind: DatabaseWalletKind.created.rawValue,
                secretKeyReference: "opaque-fixture", isSelected: true,
                sortOrder: 0, createdAt: now, updatedAt: now,
                lastOpenedAt: now, archivedAt: nil
            ).insert(db)
            try DBWalletAccountRecord(
                id: "notification-account", walletID: "notification-wallet",
                networkID: networkID, address: address,
                normalizedAddress: address.lowercased(), label: nil,
                derivationPath: nil, accountIndex: 0, publicKey: "public-fixture",
                isWatchOnly: false, isEnabled: true, createdAt: now,
                updatedAt: now, lastSyncedAt: nil
            ).insert(db)
        }
        let snapshot = try await PushNotificationRegistrationRepository(database: database)
            .snapshot(identity: PushInstallationIdentity(
                installationID: UUID().uuidString.lowercased(),
                credential: Data(repeating: 1, count: 32),
                apnsToken: Data(repeating: 2, count: 32),
                remoteUserID: UUID().uuidString.lowercased()
            ), apnsEnvironment: "sandbox")
        let account = try #require(snapshot.wallets.flatMap(\.accounts).first {
            $0.networkID == networkID
        })
        let monitored = try #require(account.monitoredAddresses.first)
        #expect(monitored.role == "account_owner")
        #expect(monitored.address == address)
        #expect(monitored.normalizedAddress == address)
    }
}
