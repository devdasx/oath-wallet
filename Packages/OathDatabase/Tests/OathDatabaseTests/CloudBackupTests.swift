import XCTest
import GRDB
@testable import OathDatabase

@MainActor final class CloudBackupTests: XCTestCase {
    func testAllWalletObservationTracksIndependentUploadStatesAndDisable() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var updates = db.observeCloudBackups().makeAsyncIterator()
        let initial = try await updates.next()
        XCTAssertEqual(initial, [])
        let first = CloudBackupRecord(walletID: "first", backupID: UUID(), accountID: "fixture", encryptedDocument: Data([1]))
        let second = CloudBackupRecord(walletID: "second", backupID: UUID(), accountID: "fixture", encryptedDocument: Data([2]))
        try await db.queueCloudBackup(first)
        let queued = try await updates.next()
        XCTAssertEqual(queued?.map(\.walletID), ["first"])
        XCTAssertEqual(queued?.first?.state, "queued")
        try await db.queueCloudBackup(second)
        let both = try await updates.next()
        XCTAssertEqual(both?.map(\.walletID), ["first", "second"])
        try await db.updateCloudBackup(backupID: first.backupID, state: "uploaded")
        let partial = try await updates.next()
        XCTAssertEqual(partial?.map(\.state), ["uploaded", "queued"])
        try await db.updateCloudBackup(backupID: second.backupID, state: "failed", failureCode: "quota")
        let failed = try await updates.next()
        XCTAssertEqual(failed?.map(\.state), ["uploaded", "failed"])
        let reopened = try await OathDatabase.open(at: url)
        let durable = try await reopened.cloudBackup(walletID: "second")
        XCTAssertEqual(durable?.encryptedDocument, second.encryptedDocument, "Retry retains only the encrypted document")
        try await db.disableCloudBackup(walletID: "first")
        let disabled = try await updates.next()
        XCTAssertEqual(disabled?.map(\.walletID), ["second"])
    }

    func testBackupOfferSurvivesReopenAndIsConsumedOnlyForItsWallet() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let created = WalletRecord(id: "created", name: "", kind: "hd", vaultReference: "created", createdAt: 1,
                                   pendingBackupOffer: .cloudOrManual)
        let imported = WalletRecord(id: "imported", name: "", kind: "imported", vaultReference: "imported", createdAt: 2,
                                    pendingBackupOffer: .cloudOnly)
        for wallet in [created, imported] { try await db.importWalletIfNeeded(wallet, accounts: []) }
        let reopened = try await OathDatabase.open(at: url)
        let createdOffer = try await reopened.wallet(created.id)?.pendingBackupOffer
        XCTAssertEqual(createdOffer, .cloudOrManual)
        try await reopened.updatePendingBackupOffer(walletID: created.id, to: .cloudOnly)
        let matchedImport = try await reopened.wallet(created.id)?.pendingBackupOffer
        XCTAssertEqual(matchedImport, .cloudOnly)
        // Independent database connections represent two presenters racing on Home.
        async let first = db.claimBackupOffer(walletID: created.id)
        async let second = reopened.claimBackupOffer(walletID: created.id)
        let winners = try await [first, second].compactMap { $0 }
        XCTAssertEqual(winners, [.cloudOnly])
        try await reopened.updatePendingBackupOffer(walletID: created.id, to: .cloudOnly)
        try await reopened.importWalletIfNeeded(created, accounts: [])
        let consumed = try await reopened.wallet(created.id)?.pendingBackupOffer
        let other = try await reopened.wallet(imported.id)?.pendingBackupOffer
        XCTAssertNil(consumed)
        XCTAssertEqual(other, .cloudOnly)
        let relaunched = try await OathDatabase.open(at: url)
        let repeatOffer = try await relaunched.claimBackupOffer(walletID: created.id)
        XCTAssertNil(repeatOffer)
        try await reopened.queueCloudBackup(.init(walletID: imported.id, backupID: UUID(), accountID: "fixture",
                                                  encryptedDocument: Data([1])))
        let queued = try await db.wallet(imported.id)?.pendingBackupOffer
        XCTAssertEqual(queued, .cloudOnly, "Queueing an upload does not consume the one-time prompt")
        let importedOffer = try await relaunched.claimBackupOffer(walletID: imported.id)
        XCTAssertEqual(importedOffer, .cloudOnly)
    }

    func testFailedClaimCanRetryAndCompletedCloudOnlyBackupCannotBeClaimed() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await db.pool.write {
            try $0.execute(sql: "UPDATE wallets SET pendingBackupOffer = 'cloudOnly'")
            try $0.execute(sql: """
                CREATE TRIGGER reject_offer BEFORE UPDATE OF pendingBackupOffer ON wallets
                BEGIN SELECT RAISE(ABORT, 'test write failure'); END
                """)
        }
        do {
            _ = try await db.claimBackupOffer(walletID: "first")
            XCTFail("A failed write must not authorize presentation")
        } catch is DatabaseError {}
        try await db.pool.write { try $0.execute(sql: "DROP TRIGGER reject_offer") }
        let retried = try await db.claimBackupOffer(walletID: "first")
        XCTAssertEqual(retried, .cloudOnly)

        let job = CloudBackupRecord(walletID: "second", backupID: UUID(), accountID: "fixture", encryptedDocument: Data([1]))
        try await db.queueCloudBackup(job)
        try await db.updateCloudBackup(backupID: job.backupID, state: "uploaded")
        let alreadyBackedUp = try await db.claimBackupOffer(walletID: "second")
        XCTAssertNil(alreadyBackedUp)
    }

    func testExistingWalletOffersAreReviewedOnceAcrossUpgradeAndReopen() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await db.pool.write {
            try $0.execute(sql: "ALTER TABLE wallets DROP COLUMN needsBackupOfferReview")
            try $0.execute(sql: "ALTER TABLE wallets DROP COLUMN pendingBackupOffer")
            try $0.execute(sql: "DELETE FROM grdb_migrations WHERE identifier IN ('v103_wallet_backup_offer','v104_existing_wallet_backup_offers')")
        }
        let migrated = try await OathDatabase.open(at: url)
        let wallets = try await migrated.wallets()
        XCTAssertEqual(wallets.count, 2)
        XCTAssertTrue(wallets.allSatisfy { $0.needsBackupOfferReview == true })
        try await migrated.finishBackupOfferReview(walletID: "first", previouslyUntrackedOffer: .cloudOrManual)
        try await migrated.finishBackupOfferReview(walletID: "second", previouslyUntrackedOffer: .cloudOnly)
        let first = try await migrated.wallet("first")
        let second = try await migrated.wallet("second")
        XCTAssertEqual(first?.pendingBackupOffer, .cloudOrManual)
        XCTAssertEqual(second?.pendingBackupOffer, .cloudOnly)
        try await migrated.updatePendingBackupOffer(walletID: "first", to: nil)
        let reopened = try await OathDatabase.open(at: url)
        try await reopened.finishBackupOfferReview(walletID: "first", previouslyUntrackedOffer: .cloudOrManual)
        let consumed = try await reopened.wallet("first")
        XCTAssertNil(consumed?.pendingBackupOffer)
        XCTAssertNil(consumed?.needsBackupOfferReview)
    }

    func testPriorDismissalAndCloudRestoreStaySuppressedDuringBackfill() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await db.pool.write { try $0.execute(sql: "UPDATE wallets SET needsBackupOfferReview = 1") }
        // A cleared v103 offer carries an existing tracking marker in the vault.
        try await db.finishBackupOfferReview(walletID: "first", previouslyUntrackedOffer: nil)
        // Restoring a matching older wallet can precede its authenticated classification.
        try await db.updatePendingBackupOffer(walletID: "second", to: nil)
        try await db.finishBackupOfferReview(walletID: "second", previouslyUntrackedOffer: .cloudOrManual)
        let wallets = try await db.wallets()
        XCTAssertTrue(wallets.allSatisfy { $0.pendingBackupOffer == nil && $0.needsBackupOfferReview == nil })
    }

    func testVisibleOptionsFollowOnlyThisWalletsConfirmedCloudBackup() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var status = db.observeBackupOfferStatus(walletID: "first").makeAsyncIterator()
        let initial = try await status.next()
        XCTAssertEqual(initial, .unconfirmed)
        XCTAssertEqual(initial?.visibleOffer(for: .cloudOnly), .cloudOnly)
        XCTAssertEqual(initial?.visibleOffer(for: .cloudOrManual), .cloudOrManual)
        let job = CloudBackupRecord(walletID: "first", backupID: UUID(), accountID: "fixture", encryptedDocument: Data([1]))
        try await db.queueCloudBackup(job)
        let queued = try await status.next()
        XCTAssertEqual(queued, .uploading)
        try await db.updateCloudBackup(backupID: job.backupID, state: "failed", failureCode: "quota")
        let failed = try await status.next()
        XCTAssertEqual(failed, .unconfirmed)
        let retry = CloudBackupRecord(walletID: "first", backupID: UUID(), accountID: "fixture", encryptedDocument: Data([2]))
        try await db.queueCloudBackup(retry)
        _ = try await status.next()
        try await db.updateCloudBackup(backupID: retry.backupID, state: "uploaded")
        let uploaded = try await status.next()
        XCTAssertEqual(uploaded, .uploaded)
        XCTAssertEqual(uploaded?.visibleOffer(for: .cloudOrManual), .manualOnly)
        XCTAssertNil(uploaded?.visibleOffer(for: .cloudOnly))
        XCTAssertNil(uploaded?.visibleOffer(for: nil))
        var other = db.observeBackupOfferStatus(walletID: "second").makeAsyncIterator()
        let otherStatus = try await other.next()
        XCTAssertEqual(otherStatus, .unconfirmed)
        try await db.reconcileRemovedCloudBackups(confirmedMissingBackupID: retry.backupID)
        let missing = try await status.next()
        XCTAssertEqual(missing, .unconfirmed)
    }

    func testTurningOffUploadsPreservesAConfirmedCloudCopyForTheOffer() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let job = CloudBackupRecord(walletID: "first", backupID: UUID(), accountID: "fixture", encryptedDocument: Data([1]))
        try await db.queueCloudBackup(job)
        try await db.updateCloudBackup(backupID: job.backupID, state: "uploaded")
        try await db.disableCloudBackup(walletID: "first")
        let reopened = try await OathDatabase.open(at: url)
        var updates = reopened.observeBackupOfferStatus(walletID: "first").makeAsyncIterator()
        let status = try await updates.next()
        XCTAssertEqual(status, .uploaded)
        XCTAssertEqual(status?.visibleOffer(for: .cloudOrManual), .manualOnly)
        XCTAssertNil(status?.visibleOffer(for: .cloudOnly))
    }

    private func fixture() async throws -> (OathDatabase, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CloudBackupDB-" + UUID().uuidString).appendingPathComponent("wallet.sqlite")
        let db = try await OathDatabase.open(at: url)
        for id in ["first", "second"] {
            try await db.importWalletIfNeeded(.init(id: id, name: id, kind: "hd", vaultReference: id, createdAt: 1), accounts: [])
        }
        return (db, url)
    }
    func testMigrationPreservesExistingWallets() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await db.pool.write {
            try $0.execute(sql: "DROP TABLE cloudBackups; DELETE FROM grdb_migrations WHERE identifier='v2_encrypted_icloud_backups'")
        }
        let migrated = try await OathDatabase.open(at: url)
        let wallets = try await migrated.wallets()
        XCTAssertEqual(wallets.count, 2)
        let check = try await migrated.pool.read { try String.fetchOne($0, sql: "PRAGMA integrity_check") }
        XCTAssertEqual(check, "ok")
        let index = try await migrated.pool.read { try String.fetchOne($0, sql: "SELECT name FROM sqlite_master WHERE name='cloud_backups_pending'") }
        XCTAssertNotNil(index)
    }
    func testOutboxSurvivesReopenAndOnlyConfirmedUploadMarksCorrectWallet() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let job = CloudBackupRecord(walletID: "second", backupID: UUID(), accountID: "synthetic-account", encryptedDocument: Data([1,2,3]))
        try await db.queueCloudBackup(job)
        try await db.updateCloudBackup(backupID: job.backupID, state: "uploading", percent: 95)
        let reopened = try await OathDatabase.open(at: url)
        let pending = try await reopened.cloudBackup(walletID: "second")
        XCTAssertEqual(pending?.encryptedDocument, job.encryptedDocument)
        let before = try await reopened.wallet("second")
        XCTAssertFalse(before!.backedUp)
        try await reopened.updateCloudBackup(backupID: job.backupID, state: "uploaded")
        let saved = try await db.cloudBackup(walletID: "second")
        XCTAssertEqual(saved?.state, "uploaded"); XCTAssertNotNil(saved?.uploadedAt)
        XCTAssertNil(saved?.encryptedDocument)
        let wallets = try await db.wallets()
        XCTAssertTrue(wallets.first { $0.id == "second" }!.backedUp)
        XCTAssertFalse(wallets.first { $0.id == "first" }!.backedUp)
    }
    func testStaleCallbacksDisableAndForeignKeys() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let first = CloudBackupRecord(walletID: "first", backupID: UUID(), accountID: "a", encryptedDocument: Data([1]))
        let second = CloudBackupRecord(walletID: "first", backupID: UUID(), accountID: "b", encryptedDocument: Data([2]))
        try await db.queueCloudBackup(first); try await db.queueCloudBackup(second)
        try await db.updateCloudBackup(backupID: first.backupID, state: "uploaded")
        var saved = try await db.cloudBackup(walletID: "first")
        XCTAssertEqual(saved?.backupID, second.backupID); XCTAssertEqual(saved?.state, "queued")
        try await db.disableCloudBackup(walletID: "first")
        try await db.updateCloudBackup(backupID: second.backupID, state: "uploaded")
        saved = try await db.cloudBackup(walletID: "first")
        XCTAssertEqual(saved?.enabled, false); XCTAssertNil(saved?.encryptedDocument)
        let missing = CloudBackupRecord(walletID: "unknown", backupID: UUID(), accountID: "a", encryptedDocument: Data([1]))
        do { try await db.queueCloudBackup(missing); XCTFail("Orphan backup was accepted") } catch { }
        try await db.deleteWalletMetadata("first")
        saved = try await db.cloudBackup(walletID: "first")
        XCTAssertNil(saved)
    }
    func testRemovedRemoteFileQuietlyTurnsOffOnceAndSurvivesReopen() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let job = CloudBackupRecord(walletID: "first", backupID: UUID(), accountID: "a", encryptedDocument: Data([1]))
        try await db.queueCloudBackup(job)
        try await db.updateCloudBackup(backupID: job.backupID, state: "uploaded")
        var updates = db.observeCloudBackup(walletID: "first").makeAsyncIterator()
        let initial = try await updates.next() ?? nil
        XCTAssertEqual(initial?.enabled, true)
        try await db.reconcileRemovedCloudBackups(confirmedMissingBackupID: job.backupID)
        let removed = try await updates.next() ?? nil
        XCTAssertEqual(removed?.enabled, false, "The observed switch turns off")
        XCTAssertEqual(removed?.state, "failed", "The absent file is no longer confirmed")
        XCTAssertNil(removed?.failureCode, "No warning or error-haptic trigger is published")
        XCTAssertNil(removed?.encryptedDocument, "A removed backup cannot be reuploaded automatically")
        XCTAssertNil(removed?.percent)
        XCTAssertNotNil(removed?.uploadedAt, "Keep the date of the historical upload")

        try await db.reconcileRemovedCloudBackups(confirmedMissingBackupID: job.backupID)
        try await db.updateCloudBackup(backupID: job.backupID, state: "uploaded")
        let reopened = try await OathDatabase.open(at: url)
        let persisted = try await reopened.cloudBackup(walletID: "first")
        XCTAssertEqual(persisted, removed, "Repeated checks and late callbacks cannot turn the switch back on")
        let resumable = try await reopened.cloudBackups()
        XCTAssertTrue(resumable.isEmpty)
    }

    func testPreviouslySavedMissingWarningIsClearedWithoutHidingOtherFailures() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let missing = CloudBackupRecord(walletID: "first", backupID: UUID(), accountID: "a", encryptedDocument: Data([1]))
        let quota = CloudBackupRecord(walletID: "second", backupID: UUID(), accountID: "a", encryptedDocument: Data([2]))
        try await db.queueCloudBackup(missing)
        try await db.updateCloudBackup(backupID: missing.backupID, state: "uploaded")
        // Reproduce the durable state written by the previous app version.
        try await db.invalidateCloudBackup(backupID: missing.backupID, failureCode: "missing")
        try await db.queueCloudBackup(quota)
        try await db.updateCloudBackup(backupID: quota.backupID, state: "failed", failureCode: "quota")
        let beforeQuota = try await db.cloudBackup(walletID: "second")

        try await db.reconcileRemovedCloudBackups()
        let repaired = try await db.cloudBackup(walletID: "first")
        XCTAssertEqual(repaired?.enabled, false)
        XCTAssertNil(repaired?.failureCode)
        try await db.reconcileRemovedCloudBackups()
        let repeated = try await db.cloudBackup(walletID: "first")
        XCTAssertEqual(repeated, repaired)
        let afterQuota = try await db.cloudBackup(walletID: "second")
        XCTAssertEqual(afterQuota, beforeQuota, "Real upload failures remain visible and retryable")
    }

    func testRemovedBackupCanBeReplacedAndUploadedForSameWallet() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let old = CloudBackupRecord(walletID: "first", backupID: UUID(), accountID: "a", encryptedDocument: Data([1]))
        try await db.queueCloudBackup(old)
        try await db.updateCloudBackup(backupID: old.backupID, state: "uploaded")
        try await db.reconcileRemovedCloudBackups(confirmedMissingBackupID: old.backupID)
        let reopened = try await OathDatabase.open(at: url)
        var updates = reopened.observeCloudBackup(walletID: "first").makeAsyncIterator()
        let removed = try await updates.next() ?? nil
        XCTAssertEqual(removed?.enabled, false)

        let replacement = CloudBackupRecord(walletID: "first", backupID: UUID(), accountID: "a", encryptedDocument: Data([2]))
        try await reopened.queueCloudBackup(replacement)
        let queued = try await updates.next() ?? nil
        XCTAssertEqual(queued, replacement, "A new backup re-enables the same wallet with fresh ciphertext and identity")
        try await reopened.updateCloudBackup(backupID: replacement.backupID, state: "uploading", percent: 50)
        let uploading = try await updates.next() ?? nil
        XCTAssertEqual(uploading?.enabled, true)
        XCTAssertEqual(uploading?.state, "uploading")
        try await reopened.updateCloudBackup(backupID: replacement.backupID, state: "uploaded")
        let uploaded = try await updates.next() ?? nil
        XCTAssertEqual(uploaded?.enabled, true)
        XCTAssertEqual(uploaded?.state, "uploaded")
        XCTAssertNil(uploaded?.failureCode)
        XCTAssertNil(uploaded?.encryptedDocument)

        // Old metadata and compatibility cleanup must not retire the new file.
        try await reopened.reconcileRemovedCloudBackups(confirmedMissingBackupID: old.backupID)
        try await reopened.invalidateCloudBackup(backupID: old.backupID, failureCode: "missing")
        try await reopened.reconcileRemovedCloudBackups()
        let persisted = try await db.cloudBackup(walletID: "first")
        XCTAssertEqual(persisted, uploaded)
    }

    func testRemovalObservationCannotDisableReplacementOrUnfinishedUpload() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let old = CloudBackupRecord(walletID: "first", backupID: UUID(), accountID: "a", encryptedDocument: Data([1]))
        let replacement = CloudBackupRecord(walletID: "first", backupID: UUID(), accountID: "a", encryptedDocument: Data([2]))
        try await db.queueCloudBackup(old)
        try await db.updateCloudBackup(backupID: old.backupID, state: "uploaded")
        try await db.queueCloudBackup(replacement)
        try await db.reconcileRemovedCloudBackups(confirmedMissingBackupID: old.backupID)
        try await db.reconcileRemovedCloudBackups(confirmedMissingBackupID: replacement.backupID)
        let queued = try await db.cloudBackup(walletID: "first")
        XCTAssertEqual(queued, replacement)
        try await db.updateCloudBackup(backupID: replacement.backupID, state: "uploading", percent: 50)
        let uploading = try await db.cloudBackup(walletID: "first")
        try await db.reconcileRemovedCloudBackups(confirmedMissingBackupID: replacement.backupID)
        let unchanged = try await db.cloudBackup(walletID: "first")
        XCTAssertEqual(unchanged, uploading, "Absence from metadata does not cancel an unfinished upload")
    }
}
