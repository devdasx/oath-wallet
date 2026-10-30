import XCTest
import GRDB
@testable import OathDatabase

@MainActor final class WalletTreeTests: XCTestCase {
    private func wallet(_ id: String, parent: String? = nil, passphrase: Bool = false) -> WalletRecord {
        .init(id: id, name: id, kind: passphrase || parent != nil ? "passphrase" : "hd",
              vaultReference: id, createdAt: 1, parentWalletID: parent)
    }

    func testTreeGroupsOutOfOrderChildrenAndPreservesIndependentRows() {
        let tree = WalletTree([wallet("c", parent: "a"), wallet("b"), wallet("a"), wallet("d", parent: "c")])
        XCTAssertEqual(tree.roots.map(\.id), ["b", "a"])
        XCTAssertEqual(tree.roots.last?.children.map(\.id), ["c"])
        XCTAssertEqual(tree.flattened.map(\.id), ["b", "a", "c", "d"])
    }

    func testAbsentParentAndCyclesNeverHideWallets() {
        let tree = WalletTree([wallet("c", parent: "absent"), wallet("a", parent: "b"),
                               wallet("b", parent: "a"), wallet("self", parent: "self"), wallet("d", parent: "a")])
        XCTAssertEqual(Set(tree.roots.map(\.id)), ["a", "b", "c", "self"])
        XCTAssertEqual(Set(tree.flattened.map(\.id)), ["a", "b", "c", "self", "d"])
        XCTAssertEqual(tree.flattened.count, 5)
    }

    func testMoveParentCarriesSubtreeAndChildMovesOnlyAmongSiblings() {
        let tree = WalletTree([wallet("a"), wallet("b"), wallet("c", parent: "a"),
                               wallet("d", parent: "a"), wallet("e", parent: "c")])
        XCTAssertEqual(tree.moving([0], to: 2, parentID: nil), ["b", "a", "c", "e", "d"])
        XCTAssertEqual(tree.moving([0], to: 2, parentID: "a"), ["a", "d", "c", "e", "b"])
        XCTAssertEqual(tree.moving([99], to: 0, parentID: "a"), tree.flattened.map(\.id))
    }

    func testVisibleRowsCarryDepthAndContinuousBranchesWithoutHidingChildren() {
        let tree = WalletTree([wallet("a"), wallet("b"), wallet("c", parent: "a"),
                               wallet("d", parent: "a"), wallet("e", parent: "c")])
        XCTAssertEqual(tree.rows.map(\.id), ["a", "c", "e", "d", "b"])
        XCTAssertEqual(tree.rows.map(\.depth), [0, 1, 2, 1, 0])
        XCTAssertEqual(tree.rows.map(\.parentID), [nil, "a", "c", "a", nil])
        XCTAssertEqual(tree.rows.map(\.continuingAncestorDepths), [[], [], [0], [], []])
        XCTAssertEqual(tree.rows.map(\.hasChildren), [true, true, false, false, false])
        XCTAssertEqual(tree.rows.map(\.hasFollowingSibling), [true, true, false, false, false])
    }

    func testVisibleRowMovePreservesFamiliesAndNeverReparents() {
        let tree = WalletTree([wallet("a"), wallet("b"), wallet("c", parent: "a"),
                               wallet("d", parent: "a"), wallet("e", parent: "c")])
        XCTAssertEqual(tree.movingRows([0], to: 5), ["b", "a", "c", "e", "d"])
        XCTAssertEqual(tree.movingRows([1], to: 4), ["a", "d", "c", "e", "b"])
        XCTAssertEqual(tree.movingRows([3], to: 0), ["a", "d", "c", "e", "b"])
        // A child dropped outside its family stays in that family.
        XCTAssertEqual(tree.movingRows([2], to: 5), tree.flattened.map(\.id))
        // A multirow operation across levels cannot split parent and child.
        XCTAssertEqual(tree.movingRows([0, 1], to: 5), tree.flattened.map(\.id))
        XCTAssertEqual(tree.movingRows([99], to: 0), tree.flattened.map(\.id))
    }

    func testNativeSectionOrderMovesWholeFamilyAndKeepsOriginalParents() {
        let tree = WalletTree([wallet("a"), wallet("c", parent: "a"), wallet("e", parent: "c"),
                               wallet("d", parent: "a"), wallet("b"), wallet("f", parent: "b")])
        let moved = tree.reordering(["b", "f", "a", "c", "e", "d"])
        XCTAssertEqual(moved.flattened.map(\.id), ["b", "f", "a", "c", "e", "d"])
        // UIKit may propose dropping a child outside its original group. Move
        // it amongst its siblings only; never adopt the proposed parent.
        let childMoved = tree.reordering(["d", "b", "f", "a", "c", "e"])
        XCTAssertEqual(childMoved.flattened.map(\.id), ["b", "f", "a", "d", "c", "e"])
        XCTAssertEqual(childMoved.rows.first { $0.id == "d" }?.parentID, "a")
        XCTAssertEqual(childMoved.rows.first { $0.id == "e" }?.parentID, "c")
    }

    func testNativeCollapsedOrStaleSnapshotCannotLoseWallets() {
        let tree = WalletTree([wallet("a"), wallet("c", parent: "a"), wallet("b")])
        for invalid in [["b", "a"], ["b", "a", "a"], ["b", "a", "unknown"], []] {
            XCTAssertEqual(tree.reordering(invalid).flattened.map(\.id), ["a", "c", "b"])
        }
    }

    func testFamilyOrderPersistsWithIndependentChildRecords() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try await OathDatabase.open(at: folder.appendingPathComponent("wallet.sqlite"))
        for record in [wallet("a"), wallet("c", parent: "a"), wallet("d", parent: "a"), wallet("b")] {
            try await db.importWalletIfNeeded(record, accounts: [])
        }
        let tree = WalletTree(try await db.wallets())
        let order = tree.reordering(["b", "a", "d", "c"]).flattened.map(\.id)
        try await db.reorderWallets(order)
        let saved = try await db.wallets()
        XCTAssertEqual(saved.map(\.id), ["b", "a", "d", "c"])
        XCTAssertEqual(saved.first { $0.id == "c" }?.parentWalletID, "a")
        XCTAssertEqual(saved.first { $0.id == "d" }?.parentWalletID, "a")
        try await db.reconcileWalletLifecycle([.init(id: "d", deletedAt: 10)])
        let remaining = try await db.wallets()
        XCTAssertEqual(remaining.map(\.id), ["b", "a", "c"])
    }

    func testMissingOrCyclicParentsHaveRootDepthInVisibleRows() {
        let tree = WalletTree([wallet("orphan", parent: "absent"),
                               wallet("a", parent: "b"), wallet("b", parent: "a"), wallet("c", parent: "a")])
        XCTAssertEqual(tree.rows.map(\.id), ["orphan", "a", "c", "b"])
        XCTAssertEqual(tree.rows.map(\.depth), [0, 0, 1, 0])
        XCTAssertEqual(tree.rows.map(\.parentID), [nil, nil, "a", nil])
    }

    func testParentDeletionDoesNotDeleteChildAndRestoreRegroupsIt() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try await OathDatabase.open(at: folder.appendingPathComponent("wallet.sqlite"))
        try await db.importWalletIfNeeded(wallet("a"), accounts: [])
        try await db.importWalletIfNeeded(wallet("c", parent: "a"), accounts: [])
        try await db.reconcileWalletFamilies([.init(id: "c", parentID: "a", index: 1, vaultReference: "c")])
        try await db.reconcileWalletLifecycle([.init(id: "a", deletedAt: 10)])
        let hiddenParent = try await db.wallets()
        XCTAssertEqual(WalletTree(hiddenParent).roots.map(\.id), ["c"])
        try await db.reconcileWalletLifecycle([.init(id: "a", deletedAt: nil)])
        let restored = try await db.wallets()
        XCTAssertEqual(WalletTree(restored).roots.first?.children.map(\.id), ["c"])
        try await db.deleteWalletMetadata("a")
        let remaining = try await db.wallets()
        XCTAssertEqual(remaining.map(\.id), ["c"])
        XCTAssertEqual(remaining.first?.parentWalletID, "a")
    }

    func testProjectionRestoresOrdinalWithoutChangingCustomLabelOrOrder() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try await OathDatabase.open(at: folder.appendingPathComponent("wallet.sqlite"))
        try await db.importWalletIfNeeded(wallet("c", passphrase: true), accounts: [])
        try await db.reconcileWalletFamilies([.init(id: "c", parentID: "a", index: 17, vaultReference: "c")])
        let row = try await db.wallet("c")
        XCTAssertEqual(row?.nameIndex, 17); XCTAssertEqual(row?.name, "c")
        XCTAssertEqual(row?.sortOrder, 0); XCTAssertEqual(row?.nameGroup, "passphrase")
        try await db.importWalletIfNeeded(wallet("next", passphrase: true), accounts: [])
        let next = try await db.wallet("next")
        XCTAssertEqual(next?.nameIndex, 18)
    }

    func testV68UpgradeNumbersPassphraseWalletsWithoutRenamingOtherWallets() throws {
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            db.add(function: HistorySearch.function)
            db.add(function: HistoryFilter.amountFunction)
            db.add(function: HistorySafety.metadataFunction)
        }
        let db = try DatabaseQueue(configuration: configuration)
        try Schema.migrator.migrate(db, upTo: "v68_stablecoin_restriction_checks")
        try db.write { sql in
            try sql.execute(sql: """
                INSERT INTO wallets(id,name,kind,vaultReference,createdAt,backedUp,nameIndex,nameGroup)
                VALUES('root','Original','hd','root',1,0,8,'main'),
                      ('first','','passphrase','first',2,0,9,'main'),
                      ('second','Travel','passphrase','second',3,0,10,'main');
                """)
        }
        try Schema.migrator.migrate(db)
        let rows = try db.read { try WalletRecord.fetchAll($0, sql: "SELECT * FROM wallets ORDER BY createdAt") }
        XCTAssertEqual(rows.map(\.nameIndex), [8, 1, 2])
        XCTAssertEqual(rows.map(\.name), ["Original", "", "Travel"])
        XCTAssertEqual(rows.map(\.nameGroup), ["main", "passphrase", "passphrase"])
        XCTAssertTrue(rows.allSatisfy { $0.parentWalletID == nil })
    }

    func testLegacyMnemonicWalletCanReceiveAuthenticatedPassphraseProjection() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try await OathDatabase.open(at: folder.appendingPathComponent("wallet.sqlite"))
        try await db.importWalletIfNeeded(wallet("legacy"), accounts: [])
        try await db.reconcileWalletFamilies([.init(id: "legacy", parentID: nil, index: 1, vaultReference: "legacy")])
        let row = try await db.wallet("legacy")
        XCTAssertEqual(row?.kind, "passphrase"); XCTAssertEqual(row?.name, "legacy")
    }

    func testConflictingProjectionCannotRelabelAnotherWalletOrBlockValidSiblings() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try await OathDatabase.open(at: folder.appendingPathComponent("wallet.sqlite"))
        try await db.importWalletIfNeeded(wallet("conflict"), accounts: [])
        try await db.importWalletIfNeeded(wallet("valid", passphrase: true), accounts: [])
        try await db.reconcileWalletFamilies([
            .init(id: "conflict", parentID: "a", index: 2, vaultReference: "different-vault"),
            .init(id: "valid", parentID: "a", index: 3, vaultReference: "valid")
        ])
        let conflict = try await db.wallet("conflict"), valid = try await db.wallet("valid")
        XCTAssertEqual(conflict?.kind, "hd"); XCTAssertNil(conflict?.parentWalletID)
        XCTAssertEqual(valid?.nameIndex, 3); XCTAssertEqual(valid?.parentWalletID, "a")
    }
}
