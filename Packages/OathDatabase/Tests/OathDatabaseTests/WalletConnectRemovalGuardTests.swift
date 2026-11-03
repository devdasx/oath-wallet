import XCTest
import GRDB
@testable import OathAnkr
@testable import OathDatabase

@MainActor final class WalletConnectRemovalGuardTests: XCTestCase {
    let tables = ["walletConnectBitcoinSubmissions", "walletConnectSolanaSubmissions",
                  "walletConnectSuiSubmissions", "walletConnectTonSubmissions",
                  "walletConnectNearSubmissions", "walletConnectStellarSubmissions",
                  "walletConnectXrplSubmissions"]

    func testSignedXrplRemovalAndPurgeAreBlocked() async throws {
        for state in ["signed", "unknown", "accepted"] {
            let (db,folder,plan,signed)=try await WalletConnectXrplJournalTests().fixture()
            defer { try? FileManager.default.removeItem(at:folder) }
            _=try await db.journalWalletConnectXrpl(id:"pending",walletID:"w1",accountID:"a1",plan:plan,signed:signed)
            if state != "signed" { try await db.settleWalletConnectXrpl("pending",outcome:state == "unknown" ? .unknown:.accepted) }
            let reopened=try await OathDatabase.open(at:folder.appendingPathComponent("wallet.sqlite"))
            let pending=try await reopened.pendingWalletConnectXrplSubmissions()
            XCTAssertEqual(pending.count,1);XCTAssertEqual(try pending[0].decoded().1,signed)
            do { try await reopened.validateWalletRemoval(["w1"]);XCTFail("Removal accepted pending XRP \(state)") }
            catch { XCTAssertEqual(error as? StoreError,.invalidTransition) }
            do { try await reopened.deleteWalletMetadata("w1");XCTFail("Purge accepted pending XRP \(state)") }
            catch { XCTAssertEqual(error as? StoreError,.invalidTransition) }
        }
    }

    // This matrix tests removal SQL against real migrated table schemas. Only
    // the XRP case above constructs and verifies signed transaction payloads.
    private func insertSyntheticRow(_ table:String,state:String,db:OathDatabase) async throws {
        try await db.pool.write { sql in
            let columns=try Row.fetchAll(sql,sql:"PRAGMA table_info(\(table))")
            var names=[String](), values=[DatabaseValue]()
            for column in columns {
                let name:String=column["name"], type:String=column["type"]
                names.append(name)
                if name=="walletID" { values.append("w1".databaseValue) }
                else if name=="accountID" { values.append("a1".databaseValue) }
                else if name=="state" { values.append(state.databaseValue) }
                else if type=="BLOB" { values.append(Data([0]).databaseValue) }
                else if ["INTEGER","DOUBLE","REAL"].contains(type) { values.append(1.databaseValue) }
                else { values.append(("synthetic-"+name).databaseValue) }
            }
            try sql.execute(sql:"INSERT INTO \(table)(\(names.joined(separator:","))) VALUES(\(names.map{_ in "?"}.joined(separator:",")))",arguments:StatementArguments(values))
        }
    }
    func testEveryJournalPendingStateBlocksOnlyItsWallet() async throws {
        for table in tables {
            for state in (table=="walletConnectSuiSubmissions" ? ["signed","unknown"]:["signed","unknown","accepted"]) {
                let (db,folder,_,_)=try await WalletConnectXrplJournalTests().fixture()
                defer { try? FileManager.default.removeItem(at:folder) }
                try await insertSyntheticRow(table,state:state,db:db)
                try await db.validateWalletRemoval(["w2"])
                try await db.deleteWalletMetadata("w2")
                do { try await db.validateWalletRemoval(["w1"]);XCTFail("Removal accepted \(table)/\(state)") }
                catch { XCTAssertEqual(error as? StoreError,.invalidTransition) }
                do { try await db.deleteWalletMetadata("w1");XCTFail("Purge accepted \(table)/\(state)") }
                catch { XCTAssertEqual(error as? StoreError,.invalidTransition) }
            }
        }
    }
    func testTerminalJournalStatesPermitRemoval() async throws {
        for table in tables {
            for state in ["confirmed","failed","expired"] {
                let (db,folder,_,_)=try await WalletConnectXrplJournalTests().fixture()
                defer { try? FileManager.default.removeItem(at:folder) }
                try await insertSyntheticRow(table,state:state,db:db)
                try await db.validateWalletRemoval(["w1"])
                try await db.deleteWalletMetadata("w1")
                let count=try await db.pool.read { try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM \(table)") }
                XCTAssertEqual(count,0)
            }
        }
    }
    func testPreviouslyRemovedJournalsKeepRetentionCleanupReachable() async throws {
        for table in tables {
            let (db,folder,_,_)=try await WalletConnectXrplJournalTests().fixture()
            defer { try? FileManager.default.removeItem(at:folder) }
            try await insertSyntheticRow(table,state:"unknown",db:db)
            // Older versions permitted this removal. Unlock eventually purges
            // expired deleted-wallet metadata without another user preflight.
            try await db.reconcileWalletLifecycle([.init(id:"w1",deletedAt:1)])
            do { try await db.deleteWalletMetadata("w1") }
            catch { XCTFail("Legacy retention cleanup blocked for \(table): \(error)") }
        }
    }
    func testResetStillErasesPendingJournalAndRejectsLateWrites() async throws {
        let (db,folder,plan,signed)=try await WalletConnectXrplJournalTests().fixture()
        defer { try? FileManager.default.removeItem(at:folder) }
        _=try await db.journalWalletConnectXrpl(id:"pending",walletID:"w1",accountID:"a1",plan:plan,signed:signed)
        let reset=try await db.beginWalletReset()
        let hidden=try await db.pendingWalletConnectXrplSubmissions();XCTAssertTrue(hidden.isEmpty)
        do { try await db.settleWalletConnectXrpl("pending",outcome:.accepted);XCTFail("Late update during reset") } catch { XCTAssertNotNil(error as? DatabaseError) }
        try await db.eraseWalletData(resetID:reset)
        try await db.finishWalletReset(resetID:reset)
        let absent=try await db.walletConnectXrplSubmission("pending");XCTAssertNil(absent)
        do { _=try await db.journalWalletConnectXrpl(id:"late",walletID:"w1",accountID:"a1",plan:plan,signed:signed);XCTFail("Recreated erased wallet work") }
        catch { XCTAssertEqual(error as? XrplSendError,.wrongOwner) }
    }
}
