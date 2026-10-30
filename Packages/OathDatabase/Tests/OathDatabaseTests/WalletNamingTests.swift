import XCTest
import GRDB
@testable import OathDatabase

@MainActor final class WalletNamingTests: XCTestCase {
    private func fixture() async throws -> (OathDatabase, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wallet-naming-" + UUID().uuidString).appendingPathComponent("db.sqlite")
        let db = try await OathDatabase.open(at: url)
        try await db.seed(networks: ["ethereum", "solana"].map {
            .init(id: $0, name: $0, family: "fixture", symbol: "COIN", decimals: 9, derivationPath: "", logo: "", sortOrder: 0)
        }, assets: [])
        return (db, url)
    }

    private func add(_ db: OathDatabase, _ id: String, kind: String = "hd", group: String? = nil, network: String = "ethereum") async throws {
        try await db.importWalletIfNeeded(.init(id: id, name: "", kind: kind, vaultReference: id, createdAt: 1, nameGroup: group),
            accounts: [.init(id: id + ":account", walletID: id, networkID: network, address: "public-fixture", derivationPath: "")])
    }

    func testSeparateSequencesSurviveReorderingDeletionReopenAndRetry() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        for index in 0..<3 {
            try await add(db, "main\(index)")
            try await add(db, "imported\(index)", kind: "imported")
            try await add(db, "restored\(index)", kind: "imported", group: "restored")
            try await add(db, "ethereum\(index)", kind: "privateKey")
            try await add(db, "solana\(index)", kind: "privateKey", network: "solana")
        }
        try await add(db, "main0") // Idempotent enrollment never consumes a name.
        let wallets = try await db.wallets()
        for prefix in ["main", "imported", "restored", "ethereum", "solana"] {
            XCTAssertEqual(wallets.filter { $0.id.hasPrefix(prefix) }.map(\.nameIndex), [0, 1, 2])
        }
        XCTAssertEqual(wallets.first { $0.id == "ethereum0" }?.nameGroup, "network:ethereum")
        try await db.reorderWallets(wallets.reversed().map(\.id))
        try await db.reconcileWalletLifecycle([.init(id: "main2", deletedAt: 100)])
        let reopened = try await OathDatabase.open(at: url)
        try await add(reopened, "main3")
        let next = try await reopened.wallet("main3")
        XCTAssertEqual(next?.nameIndex, 3)
        try await reopened.reconcileWalletLifecycle([.init(id: "main2", deletedAt: nil)])
        let restored = try await reopened.wallet("main2")
        XCTAssertEqual(restored?.nameIndex, 2)
    }

    func testCustomizationKeepsAutomaticNamesLocalizableAndCustomLabelsExact() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await add(db, "main")
        try await db.customizeWallet("main", name: "Main Wallet", colorHex: "126BB5", keepDefaultName: true)
        let automatic = try await db.wallet("main")
        XCTAssertEqual(automatic?.name, "")
        XCTAssertEqual(automatic?.confirmedName, "Main Wallet")
        XCTAssertEqual(automatic?.nameIndex, 0)
        XCTAssertEqual(automatic?.colorHex, "126BB5")
        try await db.customizeWallet("main", name: "ادخار", colorHex: nil)
        do { try await db.customizeWallet("main", name: "Main Wallet", colorHex: nil, keepDefaultName: true); XCTFail("A custom name was cleared") }
        catch { XCTAssertEqual(error as? StoreError, .invalidTransition) }
        let custom = try await db.wallet("main")
        XCTAssertEqual(custom?.name, "ادخار")
        XCTAssertEqual(custom?.confirmedName, "ادخار")
        try await add(db, "next")
        let next = try await db.wallet("next")
        XCTAssertEqual(next?.nameIndex, 1)
    }

    func testConfirmedNameSurvivesReopenRenameAndUnicodeLimits() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await add(db, "main")
        let chosen = "المحفظة الرئيسية"
        try await db.customizeWallet("main", name: chosen, colorHex: nil, keepDefaultName: true)
        let reopened = try await OathDatabase.open(at: url)
        let snapshot = try await reopened.snapshot(walletID: "main", currency: "USD")
        XCTAssertEqual(snapshot.wallet.confirmedName, chosen)
        XCTAssertEqual(snapshot.wallet.name, "")
        let emojiName = String(repeating: "👨‍👩‍👧‍👦", count: 100)
        try await reopened.renameWallet("main", name: emojiName)
        let renamed = try await reopened.wallet("main")
        XCTAssertEqual(renamed?.name, emojiName)
        XCTAssertEqual(renamed?.confirmedName, emojiName)
        for invalid in [String(repeating: "a", count: 101), "a" + String(repeating: "\u{301}", count: 3000)] {
            do { try await reopened.customizeWallet("main", name: invalid, colorHex: nil); XCTFail("Invalid name accepted") }
            catch { XCTAssertEqual(error as? StoreError, .invalidValue("wallet name")) }
        }
    }

    func testUpgradePreservesCustomNamesAndGroupsOldAutomaticNames() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("name-upgrade-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("db.sqlite"), old = try DatabaseQueue(path: url.path)
        try Schema.migrator.migrate(old, upTo: "v55_wallet_portfolio_filters")
        try await old.write { db in
            for (index, kind) in ["hd", "imported", "hd", "imported"].enumerated() {
                try db.execute(sql: "INSERT INTO wallets(id,name,kind,vaultReference,createdAt,nameIndex,sortOrder,backedUp) VALUES(?,?,?,?,?,?,?,0)",
                    arguments: ["w\(index)", index == 2 ? "Personal" : "", kind, "fixture\(index)", index, index, 3-index])
            }
        }
        try old.close()
        let db = try await OathDatabase.open(at: url)
        let rows = try await db.wallets().sorted { $0.id < $1.id }
        XCTAssertEqual(rows.map(\.nameGroup), ["main", "imported", "main", "imported"])
        XCTAssertEqual(rows.map(\.nameIndex), [0, 0, 1, 1])
        XCTAssertEqual(rows[2].name, "Personal")
        XCTAssertNil(rows[2].confirmedName, "Upgrade must preserve existing labels without guessing past language")
        XCTAssertEqual(rows.map(\.sortOrder), [3, 2, 1, 0])
    }

    func testUpgradeDoesNotBlockAnInterruptedWalletReset() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("name-reset-upgrade-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("db.sqlite"), old = try DatabaseQueue(path: url.path)
        try Schema.migrator.migrate(old, upTo: "v55_wallet_portfolio_filters")
        try await old.write { db in
            try db.execute(sql: "INSERT INTO wallets(id,name,kind,vaultReference,createdAt,backedUp) VALUES('w','Personal','hd','fixture',1,0)")
            try db.execute(sql: "INSERT INTO metadata(key,value) VALUES('walletReset','pending')")
        }
        try old.close()
        let upgraded = try await OathDatabase.open(at: url)
        let reset = try await upgraded.pool.read { try String.fetchOne($0, sql: "SELECT value FROM metadata WHERE key='walletReset'") }
        XCTAssertEqual(reset, "pending")
    }
}
