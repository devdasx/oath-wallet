import Foundation
import Testing
@testable import Aperture

@MainActor
@Suite(.serialized)
struct ICloudBackupReplacementTests {
    @Test
    func firstBackupIsVerifiedAndRestorable() async throws {
        let fixture = try ICloudReplacementFixture()
        defer { fixture.cleanUp() }
        let receipt = try await fixture.create()
        let saved = try await fixture.store.fetch(walletID: fixture.wallet.id)
        #expect(receipt.serverChangeTag == saved.contentDigest.hexString)
        let restored = try await fixture.service.restore(walletID: fixture.wallet.id)
        #expect(try WalletRecoveryCredential.decode(restored.secret) == fixture.credential)
        #expect(try fixture.files().count == 1)
    }

    @Test
    func repeatAndReopenedRequestsRequireConsentBeforeSecretsOrPasskeys() async throws {
        let fixture = try ICloudReplacementFixture()
        defer { fixture.cleanUp() }
        try await fixture.create()
        let original = try await fixture.store.fetch(walletID: fixture.wallet.id)
        let root = fixture.root
        let reopened = fixture.service(using: WalletICloudDriveBackupStore(containerURLProvider: { root }))
        for service in [fixture.service, reopened] {
            var requestedMaterial = false
            await #expect(throws: WalletCloudBackupReplacementRequired.self) {
                _ = try await service.backup(
                    wallet: fixture.wallet, privateKeyMetadata: nil, writePolicy: .createOnly
                ) { _ in
                    requestedMaterial = true
                    return .recoveryPhrase(fixture.credential)
                }
            }
            #expect(!requestedMaterial)
        }
        #expect(fixture.authorizer.registrations == 1)
        #expect(fixture.authorizer.assertions == 0)
        #expect(try await fixture.store.fetch(walletID: fixture.wallet.id) == original)
    }

    @Test
    func confirmedReplacementRemovesOldRevisionOnlyAfterVerification() async throws {
        let fixture = try ICloudReplacementFixture()
        defer { fixture.cleanUp() }
        try await fixture.create()
        let original = try await fixture.store.fetch(walletID: fixture.wallet.id)
        let originalFile = try #require(fixture.files().first)
        let key = try fixture.privateKeyConfiguration()
        try await key.createBackup(using: fixture.service)
        let unrelated = try await fixture.store.fetch(walletID: key.cloudWalletID)
        try await fixture.create(policy: .replaceExisting)
        let replacement = try await fixture.store.fetch(walletID: fixture.wallet.id)
        #expect(replacement.contentDigest != original.contentDigest)
        #expect(replacement.passkeyCredentialID == original.passkeyCredentialID)
        #expect(!FileManager.default.fileExists(atPath: originalFile.path))
        #expect(try fixture.files().count == 2)
        #expect(try await fixture.store.fetch(walletID: key.cloudWalletID) == unrelated)
        let restored = try await fixture.service.restore(walletID: fixture.wallet.id)
        #expect(try WalletRecoveryCredential.decode(restored.secret) == fixture.credential)
    }

    @Test
    func cancelledReplacementPreservesTheCurrentBackup() async throws {
        let fixture = try ICloudReplacementFixture()
        defer { fixture.cleanUp() }
        try await fixture.create()
        let original = try await fixture.store.fetch(walletID: fixture.wallet.id)
        fixture.authorizer.cancel = true
        await #expect(throws: WalletCloudBackupError.passkeyCanceled) {
            try await fixture.create(policy: .replaceExisting)
        }
        #expect(try await fixture.store.fetch(walletID: fixture.wallet.id) == original)
        fixture.authorizer.cancel = false
        let restored = try await fixture.service.restore(walletID: fixture.wallet.id)
        #expect(try WalletRecoveryCredential.decode(restored.secret) == fixture.credential)
    }

    @Test(arguments: [false, true])
    func failedWriteOrReadbackPreservesTheCurrentBackup(corruptWrite: Bool) async throws {
        let fixture = try ICloudReplacementFixture()
        defer { fixture.cleanUp() }
        try await fixture.create()
        let original = try await fixture.store.fetch(walletID: fixture.wallet.id)
        let root = fixture.root
        let failingStore = WalletICloudDriveBackupStore(containerURLProvider: { root }) { _, url in
            if corruptWrite { try Data("invalid-test-document".utf8).write(to: url) }
            else { throw WalletCloudBackupError.storageFailed }
        }
        await #expect(throws: (any Error).self) {
            try await fixture.create(using: fixture.service(using: failingStore), policy: .replaceExisting)
        }
        #expect(try await fixture.store.fetch(walletID: fixture.wallet.id) == original)
        #expect(try fixture.files().count == 1)
        let restored = try await fixture.service.restore(walletID: fixture.wallet.id)
        #expect(try WalletRecoveryCredential.decode(restored.secret) == fixture.credential)
    }

    @Test
    func storeCheckPreventsAConcurrentCreateFromOverwritingAnExistingBackup() async throws {
        let fixture = try ICloudReplacementFixture()
        defer { fixture.cleanUp() }
        try await fixture.create()
        let original = try await fixture.store.fetch(walletID: fixture.wallet.id)
        await #expect(throws: WalletCloudBackupReplacementRequired.self) {
            _ = try await fixture.store.save(original, writePolicy: .createOnly)
        }
        #expect(try await fixture.store.fetch(walletID: fixture.wallet.id) == original)
        #expect(try fixture.files().count == 1)
    }

    @Test
    func backupAppearingDuringAuthorizationStillRequiresReplacementConsent() async throws {
        let fixture = try ICloudReplacementFixture()
        defer { fixture.cleanUp() }
        try await fixture.create()
        let competingBackup = try await fixture.store.fetch(walletID: fixture.wallet.id)
        _ = try await fixture.store.remove(walletID: fixture.wallet.id)
        await #expect(throws: WalletCloudBackupReplacementRequired.self) {
            _ = try await fixture.service.backup(
                wallet: fixture.wallet, privateKeyMetadata: nil, writePolicy: .createOnly
            ) { _ in
                // Another device's backup arrives after the initial existence check.
                _ = try await fixture.store.save(competingBackup)
                return .recoveryPhrase(fixture.credential)
            }
        }
        #expect(try await fixture.store.fetch(walletID: fixture.wallet.id) == competingBackup)
        let restored = try await fixture.service.restore(walletID: fixture.wallet.id)
        #expect(try WalletRecoveryCredential.decode(restored.secret) == fixture.credential)
    }

    @Test
    func privateKeyReplacementIsSeparateFromTheRecoveryPhrase() async throws {
        let fixture = try ICloudReplacementFixture()
        defer { fixture.cleanUp() }
        try await fixture.create()
        let phrase = try await fixture.store.fetch(walletID: fixture.wallet.id)
        let key = try fixture.privateKeyConfiguration()
        try await key.createBackup(using: fixture.service)
        let original = try await fixture.store.fetch(walletID: key.cloudWalletID)
        await #expect(throws: WalletCloudBackupReplacementRequired.self) {
            _ = try await key.createBackup(using: fixture.service)
        }
        #expect(try await fixture.store.fetch(walletID: key.cloudWalletID) == original)
        try await key.createBackup(using: fixture.service, writePolicy: .replaceExisting)
        #expect(try await fixture.store.fetch(walletID: key.cloudWalletID).contentDigest != original.contentDigest)
        #expect(try await fixture.store.fetch(walletID: fixture.wallet.id) == phrase)
        let restored = try await fixture.service.restore(walletID: key.cloudWalletID)
        #expect(String(data: restored.secret, encoding: .utf8) == String(repeating: "0", count: 63) + "1")
    }

    @Test
    func unavailableCloudAndCorruptExistingDocumentsNeverPermitCreation() async throws {
        let fixture = try ICloudReplacementFixture()
        defer { fixture.cleanUp() }
        let unavailable = fixture.service(using: WalletICloudDriveBackupStore(containerURLProvider: { nil }))
        await #expect(throws: WalletCloudBackupError.iCloudUnavailable) {
            try await fixture.create(using: unavailable)
        }
        #expect(fixture.authorizer.registrations == 0)
        try await fixture.create()
        let file = try #require(fixture.files().first)
        let corrupt = Data("corrupt-test-document".utf8)
        try corrupt.write(to: file)
        await #expect(throws: (any Error).self) { try await fixture.create() }
        #expect(fixture.authorizer.registrations == 1)
        #expect(fixture.authorizer.assertions == 0)
        #expect(try Data(contentsOf: file) == corrupt)
    }

    @Test
    func existingCloudBackupRepairsPersistentStatusAndRestoredIdentity() async throws {
        let fixture = try ICloudReplacementFixture()
        defer { fixture.cleanUp() }
        let receipt = try await fixture.create()
        let localID = UUID().uuidString
        let database = try await fixture.database(localID: localID, cloudID: fixture.wallet.id)
        let before = try await database.managedWallet(walletID: localID)
        #expect(before.iCloudBackupUpdatedAt == nil)
        let found = try await WalletICloudPasskeyBackupCreation.existingBackup(
            database: database, wallet: before, service: fixture.service
        )
        #expect(found?.iCloudBackupWalletID == fixture.wallet.id)
        let reopened = try await database.managedWallet(walletID: localID)
        #expect(reopened.iCloudBackupUpdatedAt == receipt.serverModifiedAt)
        #expect(reopened.iCloudBackupWalletID == fixture.wallet.id)
        try await fixture.service.removeBackup(walletID: fixture.wallet.id)
        #expect(try await WalletICloudPasskeyBackupCreation.existingBackup(
            database: database, wallet: reopened, service: fixture.service
        ) == nil)
        #expect(try await database.managedWallet(walletID: localID).iCloudBackupUpdatedAt == nil)
    }
}
