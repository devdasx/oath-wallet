import GRDB
import XCTest
@testable import OathDatabase

// Historical migration fixtures must insert into the table that actually
// existed at their starting schema revision, before the current record mapping.
extension AccountRecord {
    func insertIntoHistoricalAccounts(_ db: Database) throws {
        try db.execute(sql: """
            INSERT INTO accounts(id,walletID,networkID,address,derivationPath,accountIndex,syncGeneration)
            VALUES(?,?,?,?,?,?,?)
            """, arguments: [id,walletID,networkID,address,derivationPath,accountIndex,syncGeneration])
    }
}

final class LegacyAccountDirectoryTests: XCTestCase {
    func testUpgradingPopulatedDatabasePreservesJournalAndSupportsOlderWrites() throws {
        for recursion in ["OFF", "ON"] {
            let db = try DatabaseQueue()
            try Schema.migrator.migrate(db, upTo: "v1_wallet_ledger")
            try db.write { sql in
                try sql.execute(sql: """
                    PRAGMA recursive_triggers = \(recursion);
                    INSERT INTO networks(id,name,family,symbol,decimals,derivationPath,logo,sortOrder)
                      VALUES('ethereum','Ethereum','evm','ETH',18,'x','x',0),('polkadot','Polkadot','account','DOT',10,'y','y',1);
                    INSERT INTO wallets(id,name,kind,vaultReference,createdAt,backedUp) VALUES('w','fixture','hd','fixture',1,1);
                    INSERT INTO accounts(id,walletID,networkID,address,derivationPath,accountIndex)
                      VALUES('known','w','ethereum','fixture-a','x',0),('future','w','polkadot','fixture-b','y',0);
                    CREATE TABLE fixtureJournal(accountID TEXT REFERENCES accounts(id) ON DELETE CASCADE, value INTEGER NOT NULL);
                    INSERT INTO fixtureJournal VALUES('known',12),('future',83);
                    CREATE VIEW fixtureInventory AS SELECT id FROM accounts;
                    """)
                try LegacyAccountDirectory.install(sql)
                XCTAssertEqual(try String.fetchAll(sql, sql: "SELECT id FROM accounts"), ["known"])
                XCTAssertEqual(try String.fetchAll(sql, sql: "SELECT id FROM fixtureInventory ORDER BY id"), ["future", "known"])
                XCTAssertEqual(try Int.fetchAll(sql, sql: "SELECT value FROM fixtureJournal ORDER BY value"), [12,83])
                try sql.execute(sql: """
                    UPDATE accounts SET syncGeneration=3 WHERE id='known';
                    INSERT INTO accounts(id,walletID,networkID,address,derivationPath,accountIndex)
                        VALUES('added','w','ethereum','fixture-c','x',1);
                    UPDATE walletAccounts SET syncGeneration=5 WHERE id='added';
                    """)
                XCTAssertEqual(try Int.fetchOne(sql, sql: "SELECT syncGeneration FROM walletAccounts WHERE id='known'"), 3)
                XCTAssertEqual(try Int.fetchOne(sql, sql: "SELECT syncGeneration FROM accounts WHERE id='added'"), 5)
                XCTAssertThrowsError(try sql.execute(sql: """
                    INSERT OR IGNORE INTO accounts(id,walletID,networkID,address,derivationPath,accountIndex)
                      VALUES('future','w','ethereum','another','x',3)
                    """))
                try sql.execute(sql: "DELETE FROM accounts WHERE id='known'")
                XCTAssertEqual(try String.fetchAll(sql, sql: "SELECT id FROM walletAccounts ORDER BY id"), ["added", "future"])
                XCTAssertEqual(try Int.fetchAll(sql, sql: "SELECT value FROM fixtureJournal"), [83])
                try sql.execute(sql: "DELETE FROM wallets WHERE id='w'")
                for table in ["accounts","walletAccounts","fixtureJournal"] {
                    XCTAssertEqual(try Int.fetchOne(sql, sql: "SELECT count(*) FROM \(table)"), 0)
                }
                XCTAssertTrue(try Row.fetchAll(sql, sql: "PRAGMA foreign_key_check").isEmpty)
            }
        }
    }
}
