import XCTest
@testable import OathDatabase

@MainActor final class MultisigNoticeTests: XCTestCase {
    private func fixture() async throws -> (OathDatabase, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MultisigNoticeTests-" + UUID().uuidString)
            .appendingPathComponent("wallet.sqlite")
        let db = try await OathDatabase.open(at: url)
        try await db.seed(networks: [.init(id: "tron", name: "TRON", family: "tron", symbol: "TRX",
                                         decimals: 6, derivationPath: "fixture", logo: "tron", sortOrder: 0)], assets: [])
        for id in ["imported", "restored"] {
            try await addWallet(id, db: db)
        }
        return (db, url)
    }

    private func addWallet(_ id: String, db: OathDatabase) async throws {
        try await db.importWalletIfNeeded(
            .init(id: id, name: "Fixture", kind: "imported", vaultReference: "fixture-" + id, createdAt: 1),
            accounts: [.init(id: id + "-account", walletID: id, networkID: "tron",
                             address: "same-public-fixture", derivationPath: "fixture")])
    }

    func testAcknowledgementPersistsAcrossReopenAndWalletSwitches() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let before = try await db.hasAcknowledgedMultisigNotice(walletID: "imported")
        XCTAssertFalse(before)
        try await db.acknowledgeMultisigNotice(walletID: "imported")
        try await db.acknowledgeMultisigNotice(walletID: "imported") // Repeated taps remain one preference.
        try await db.setSetting("activeWalletID", value: "restored")
        let reopened = try await OathDatabase.open(at: url)
        let acknowledged = try await reopened.hasAcknowledgedMultisigNotice(walletID: "imported")
        let otherWallet = try await reopened.hasAcknowledgedMultisigNotice(walletID: "restored")
        XCTAssertTrue(acknowledged)
        XCTAssertFalse(otherWallet, "The same public address in another wallet must have its own notice")
        try await reopened.setSetting("activeWalletID", value: "imported")
        let afterSwitch = try await reopened.hasAcknowledgedMultisigNotice(walletID: "imported")
        XCTAssertTrue(afterSwitch)
    }

    func testMetadataUpdatesKeepAcknowledgementButNewImportsDoNotInheritIt() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await db.acknowledgeMultisigNotice(walletID: "imported")
        try await db.customizeWallet("imported", name: "Renamed", colorHex: nil)
        try await addWallet("imported", db: db) // Import reconciliation must not reset the preference.
        let updated = try await db.hasAcknowledgedMultisigNotice(walletID: "imported")
        XCTAssertTrue(updated)
        try await db.deleteWalletMetadata("imported")
        let settings = try await db.settings()
        XCTAssertNil(settings[OathDatabase.multisigNoticeKey("imported")])
        try await addWallet("new-import", db: db)
        let fresh = try await db.hasAcknowledgedMultisigNotice(walletID: "new-import")
        XCTAssertFalse(fresh)
        try await addWallet("imported", db: db) // A backup can restore the original UUID after permanent removal.
        let restored = try await db.hasAcknowledgedMultisigNotice(walletID: "imported")
        XCTAssertFalse(restored)
    }

    func testMissingOrDeletedWalletCannotCreateOrphanAcknowledgement() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await db.reconcileWalletLifecycle([.init(id: "imported", deletedAt: 100)])
        for id in ["missing", "imported"] {
            do {
                try await db.acknowledgeMultisigNotice(walletID: id)
                XCTFail("Acknowledged unavailable wallet")
            } catch StoreError.missingRecord { }
        }
        let settings = try await db.settings()
        XCTAssertFalse(settings.keys.contains { $0.hasPrefix("multisigNoticeAcknowledged.") })
    }

    func testLegacyCardPreferencesDoNotChangeSheetAcknowledgement() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await db.setSetting(OathDatabase.multisigNoticeKey("imported"), value: "true")
        try await db.setSetting(OathDatabase.multisigWarningKey("imported"), value: "true")
        try await db.setSetting(OathDatabase.multisigWarningKey("restored"), value: "true")
        let reopened = try await OathDatabase.open(at: url)
        let acknowledged = try await reopened.multisigNoticeState(walletID: "imported")
        let unacknowledged = try await reopened.multisigNoticeState(walletID: "restored")
        XCTAssertTrue(acknowledged.acknowledged)
        XCTAssertFalse(unacknowledged.acknowledged)
    }

    func testPermanentRemovalClearsLegacyCardPreferenceForFreshRestore() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await db.acknowledgeMultisigNotice(walletID: "imported")
        try await db.setSetting(OathDatabase.multisigWarningKey("imported"), value: "true")
        try await db.deleteWalletMetadata("imported")
        let settings = try await db.settings()
        XCTAssertNil(settings[OathDatabase.multisigNoticeKey("imported")])
        XCTAssertNil(settings[OathDatabase.multisigWarningKey("imported")])
        try await addWallet("imported", db: db)
        let restored = try await db.multisigNoticeState(walletID: "imported")
        XCTAssertFalse(restored.acknowledged)
    }
}
