import XCTest
import GRDB
@testable import OathAnkr
@testable import OathDatabase

@MainActor final class WalletRemovalReservationTests: XCTestCase {
    func testUpgradePreservesExistingWalletAndCreatesEmptyFence() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("RemovalMigration-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:folder) }
        let url = folder.appendingPathComponent("wallet.sqlite")
        var configuration = Configuration()
        configuration.prepareDatabase { sql in sql.add(function:HistorySafety.metadataFunction) }
        let old = try DatabaseQueue(path:url.path,configuration:configuration)
        try Schema.migrator.migrate(old,upTo:"v105_bitcoin_signed_payload_digest")
        try await old.write { sql in
            try sql.execute(sql:"INSERT INTO wallets(id,name,kind,vaultReference,createdAt,backedUp) VALUES('w1','Kept name','hd','fixture',1,0)")
        }
        try old.close()
        let db = try await OathDatabase.open(at:url)
        let wallet = try await db.wallet("w1"); XCTAssertEqual(wallet?.name,"Kept name")
        let empty = try await db.pendingWalletRemovalReservations(); XCTAssertTrue(empty.isEmpty)
        let token = try await db.reserveWalletRemoval(["w1"])
        let durable = try await db.pendingWalletRemovalReservations(); XCTAssertEqual(durable,[token])
    }
    func testRealJournalAndReservationAreMutuallyExclusive() async throws {
        let (db,folder,plan,signed) = try await WalletConnectXrplJournalTests().fixture()
        defer { try? FileManager.default.removeItem(at:folder) }
        let first = try await db.reserveWalletRemoval(["w1"])
        do { _ = try await db.journalWalletConnectXrpl(id:"r1",walletID:"w1",accountID:"a1",plan:plan,signed:signed); XCTFail("Journal entered a reserved wallet") }
        catch { XCTAssertNotNil(error as? DatabaseError) }
        _ = try await db.journalWalletConnectXrpl(id:"other",walletID:"w2",accountID:"a2",plan:plan,signed:signed)
        try await db.settleWalletConnectXrpl("other",outcome:.failed)
        try await db.finishWalletRemovalReservations([first])
        _ = try await db.journalWalletConnectXrpl(id:"r1",walletID:"w1",accountID:"a1",plan:plan,signed:signed)
        do { _ = try await db.reserveWalletRemoval(["w1"]); XCTFail("Reserved wallet with pending work") }
        catch { XCTAssertEqual(error as? StoreError,.invalidTransition) }
        let reservations = try await db.pendingWalletRemovalReservations()
        XCTAssertTrue(reservations.isEmpty)
    }

    func testGroupRollbackAndTokenScopedCleanup() async throws {
        let (db,folder,_,_) = try await WalletConnectXrplJournalTests().fixture()
        defer { try? FileManager.default.removeItem(at:folder) }
        do { _ = try await db.reserveWalletRemoval(["w1","zz-missing"]); XCTFail("Missing wallet accepted") }
        catch { XCTAssertEqual(error as? StoreError,.missingRecord) }
        let empty = try await db.pendingWalletRemovalReservations(); XCTAssertTrue(empty.isEmpty)
        let old = try await db.reserveWalletRemoval(["w1"])
        let reopened = try await OathDatabase.open(at:folder.appendingPathComponent("wallet.sqlite"))
        let durable = try await reopened.pendingWalletRemovalReservations(); XCTAssertEqual(durable,[old])
        do { _ = try await reopened.reserveWalletRemoval(["w1","w2"]); XCTFail("Overlapping reservation") }
        catch { XCTAssertEqual(error as? StoreError,.invalidTransition) }
        try await reopened.finishWalletRemovalReservations([old])
        let new = try await reopened.reserveWalletRemoval(["w1","w2"])
        try await reopened.finishWalletRemovalReservations([old])
        let preserved = try await reopened.pendingWalletRemovalReservations(); XCTAssertEqual(preserved,[new])
        let reset = try await reopened.beginWalletReset()
        try await reopened.eraseWalletData(resetID:reset)
        try await reopened.finishWalletReset(resetID:reset)
        let erased = try await reopened.pendingWalletRemovalReservations(); XCTAssertTrue(erased.isEmpty)
    }

    // Schema-level backstop, not seven separate chain-signing tests.
    func testEveryJournalInsertAndPendingUpdateIsFenced() async throws {
        let tables = ["sends", "walletConnectBitcoinSubmissions", "walletConnectSolanaSubmissions",
                      "walletConnectSuiSubmissions", "walletConnectTonSubmissions",
                      "walletConnectNearSubmissions", "walletConnectStellarSubmissions", "walletConnectXrplSubmissions"]
        for table in tables {
            let (db,folder,_,_) = try await WalletConnectXrplJournalTests().fixture()
            defer { try? FileManager.default.removeItem(at:folder) }
            let token = try await db.reserveWalletRemoval(["w1"])
            let states = table == "sends" ? ["queued","signed","broadcast"] : table == "walletConnectSuiSubmissions" ? ["signed","unknown"] : ["signed","unknown","accepted"]
            for state in states {
                do { try await insert(table:table,state:state,db:db); XCTFail("Inserted \(table)/\(state)") }
                catch { XCTAssertTrue(String(describing:error).contains("Wallet removal in progress")) }
            }
            try await insert(table:table,state:"failed",db:db)
            for state in states {
                do {
                    try await db.pool.write { sql in try sql.execute(sql:"UPDATE \(table) SET state=?",arguments:[state]) }
                    XCTFail("Updated \(table)/\(state)")
                } catch { XCTAssertTrue(String(describing:error).contains("Wallet removal in progress")) }
            }
            try await db.finishWalletRemovalReservations([token])
            try await db.pool.write { sql in try sql.execute(sql:"UPDATE \(table) SET state=?",arguments:[states[0]]) }
        }
    }

    private func insert(table:String,state:String,db:OathDatabase) async throws {
        try await db.pool.write { sql in
            if table == "sends" {
                try SendRecord(id:"fixture",walletID:"w1",accountID:"a1",networkID:"xrpl",assetID:"xrpl:native",idempotencyKey:"fixture",recipient:"public-fixture",amountAtomic:"1",state:state,createdAt:1,updatedAt:1).insert(sql)
                return
            }
            let columns = try Row.fetchAll(sql,sql:"PRAGMA table_info(\(table))")
            var names = [String](), values = [DatabaseValue]()
            for column in columns {
                let name:String = column["name"], type:String = column["type"]
                names.append(name)
                if name == "walletID" { values.append("w1".databaseValue) }
                else if name == "accountID" { values.append("a1".databaseValue) }
                else if name == "state" { values.append(state.databaseValue) }
                else if type == "BLOB" { values.append(Data([0]).databaseValue) }
                else if ["INTEGER","DOUBLE","REAL"].contains(type) { values.append(1.databaseValue) }
                else { values.append(("synthetic-"+name).databaseValue) }
            }
            try sql.execute(sql:"INSERT INTO \(table)(\(names.joined(separator:","))) VALUES(\(names.map{_ in "?"}.joined(separator:",")))",arguments:StatementArguments(values))
        }
    }
}
