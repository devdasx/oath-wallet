import XCTest
import GRDB
@testable import OathDatabase

final class RetiredDeliveryMigrationTests: XCTestCase {
    private func queue() throws -> DatabaseQueue {
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            db.add(function: HistorySearch.function)
            db.add(function: HistoryFilter.amountFunction)
            db.add(function: HistorySafety.metadataFunction)
        }
        return try DatabaseQueue(configuration: configuration)
    }

    private func assertRetired(_ db: Database) throws {
        XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM sqlite_master WHERE lower(name) LIKE '%notification%'"), 0)
        XCTAssertFalse(try db.columns(in: "walletConnectSolanaSubmissions").contains { $0.name == "notificationRegistered" })
        XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM settings WHERE key GLOB 'notifications.*'"), 0)
        XCTAssertTrue(try db.tableExists("sends"))
        XCTAssertTrue(try db.tableExists("transactions"))
        XCTAssertTrue(try db.tableExists("walletConnectSolanaSubmissions"))
    }

    func testFreshWalletHasNoDeliveryObjects() throws {
        let queue = try queue()
        try Schema.migrator.migrate(queue)
        try queue.read { try assertRetired($0) }
    }

    func testUpgradeFromBeforePushDoesNotCreateDeliveryObjects() throws {
        let queue = try queue()
        try Schema.migrator.migrate(queue, upTo: "v60_walletconnect_solana")
        try Schema.migrator.migrate(queue)
        try queue.read { try assertRetired($0) }
    }

    func testUpgradeRemovesOldDeliveryStateAndPreservesWalletAndSendJournals() throws {
        let queue = try queue()
        try Schema.migrator.migrate(queue, upTo: "v63_notification_external_submissions")
        try queue.write { db in
            // Reproduce the retired schema exactly; production no longer creates it.
            try db.execute(sql: """
                CREATE TABLE notificationRegistrationOutbox (
                    sendID TEXT PRIMARY KEY NOT NULL REFERENCES sends(id) ON DELETE CASCADE,
                    transactionID TEXT NOT NULL REFERENCES transactions(id) ON DELETE CASCADE,
                    createdAt DOUBLE NOT NULL, delivered INTEGER NOT NULL DEFAULT 0 CHECK(delivered IN (0,1))
                );
                CREATE INDEX notification_registration_pending ON notificationRegistrationOutbox(createdAt) WHERE delivered=0;
                CREATE TRIGGER notification_send_insert AFTER INSERT ON sends
                WHEN NEW.transactionID IS NOT NULL AND NEW.state IN ('broadcast','confirmed','failed')
                BEGIN
                    INSERT OR IGNORE INTO notificationRegistrationOutbox(sendID,transactionID,createdAt) VALUES(NEW.id,NEW.transactionID,NEW.updatedAt);
                END;
                CREATE TRIGGER notification_send_update AFTER UPDATE OF state,transactionID ON sends
                WHEN NEW.transactionID IS NOT NULL AND NEW.state IN ('broadcast','confirmed','failed')
                BEGIN
                    INSERT OR IGNORE INTO notificationRegistrationOutbox(sendID,transactionID,createdAt) VALUES(NEW.id,NEW.transactionID,NEW.updatedAt);
                END;
                ALTER TABLE walletConnectSolanaSubmissions ADD COLUMN notificationRegistered INTEGER NOT NULL DEFAULT 0 CHECK(notificationRegistered IN (0,1));
                CREATE INDEX wc_solana_notification_pending ON walletConnectSolanaSubmissions(notificationRegistered,createdAt);
                INSERT INTO settings(key,value,updatedAt) VALUES
                    ('notifications.enabled','true',1),('notifications.previews','true',1),
                    ('notifications.received','true',1),('balancesHidden','true',1);
                """)
            try NetworkRecord(id: "solana", name: "Solana", family: "solana", symbol: "SOL", decimals: 9, derivationPath: "fixture", logo: "", sortOrder: 0).insert(db)
            try AssetRecord(id: "solana:native", networkID: "solana", reference: "native", name: "Solana", symbol: "SOL", decimals: 9).insert(db)
            // This fixture predates parentWalletID/confirmedName; do not encode
            // today's WalletRecord into the deliberately older schema.
            try db.execute(sql: "INSERT INTO wallets(id,name,kind,vaultReference,createdAt,backedUp) VALUES('wallet','Fixture','watchOnly','none',1,0)")
            try AccountRecord(id: "account", walletID: "wallet", networkID: "solana", address: "public-owner", derivationPath: "fixture").insert(db)
            try db.execute(sql: """
                INSERT INTO transactions(id,networkID,hash,state,timestamp,updatedAt) VALUES('tx','solana','public-hash','pending',1,1);
                INSERT INTO sends(id,walletID,accountID,networkID,assetID,senderAddress,idempotencyKey,recipient,amountAtomic,state,signedPayload,transactionID,createdAt,updatedAt)
                VALUES('send','wallet','account','solana','solana:native','public-owner','fixture','recipient','1','broadcast',X'010203','tx',1,1);
                INSERT INTO walletConnectSolanaSubmissions(id,walletID,accountID,chain,owner,fingerprint,signature,unsigned,signed,minimumSlot,createdAt,state)
                VALUES('wc','wallet','account','solana:mainnet','public-owner','fixture-fingerprint','public-signature',X'010203',X'040506',0,1,'accepted');
                """)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM notificationRegistrationOutbox"), 1)
        }
        try Schema.migrator.migrate(queue)
        try Schema.migrator.migrate(queue) // Reopening must not erase or duplicate wallet data.
        try queue.write { db in
            try assertRetired(db)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM wallets"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM accounts"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM transactions"), 1)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT value FROM settings WHERE key='balancesHidden'"), "true")
            XCTAssertEqual(try Data.fetchOne(db, sql: "SELECT signedPayload FROM sends WHERE id='send'"), Data([1,2,3]))
            XCTAssertEqual(try Data.fetchOne(db, sql: "SELECT signed FROM walletConnectSolanaSubmissions WHERE id='wc'"), Data([4,5,6]))
            // Send settlement must still work after the old triggers are gone.
            try db.execute(sql: "UPDATE sends SET state='confirmed' WHERE id='send'")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT state FROM sends WHERE id='send'"), "confirmed")
            XCTAssertTrue(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
        }
    }
}
