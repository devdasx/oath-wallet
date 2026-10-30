import Foundation
import XCTest
import GRDB
@testable import OathDatabase
@testable import OathAnkr

extension ThorchainTests {
    private func metadataCatalog(time: Double, decimals: Int, name: String) -> ThorchainCatalog {
        var catalog = ThorchainCatalog()
        catalog.observedAt = Date(timeIntervalSince1970: time)
        catalog.tokens["x/metadata-fixture"] = .init(reference: "x/metadata-fixture", name: name, symbol: name, decimals: decimals)
        catalog.prices["x/metadata-fixture"] = "2"
        return catalog
    }

    private func storeCatalog(_ catalog: ThorchainCatalog, db: OathDatabase, ticket: ThorchainSyncTicket) async throws {
        try await db.commitThorchainCatalog(catalog, ticket: ticket)
        // Reproduce an existing installation whose public cache is already newer.
        try await db.saveMarketCache(.init(key: "thorchain.catalog", source: "THORChain",
            payload: JSONEncoder().encode(catalog), fetchedAt: catalog.observedAt.timeIntervalSince1970))
    }

    func testDelayedCatalogCannotRollBackSharedTokenMetadata() async throws {
        let (db, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try await db.beginThorchainSync(accountID: "a1")
        let second = try await db.beginThorchainSync(accountID: "a2")
        let newer = metadataCatalog(time: 200, decimals: 6, name: "Current")
        try await storeCatalog(newer, db: db, ticket: first)
        try await db.commitThorchainCatalog(metadataCatalog(time: 100, decimals: 8, name: "Old"), ticket: second)

        let asset = try await db.asset(networkID: "thorchain", reference: "x/metadata-fixture")
        XCTAssertEqual(asset?.decimals, 6)
        XCTAssertEqual(asset?.name, "Current")
        XCTAssertEqual(asset?.symbol, "Current")
        let cache = try await db.marketCache(key: "thorchain.catalog")
        XCTAssertEqual(cache?.fetchedAt, 200)
    }

    func testDelayedInventoryUsesLatestMetadataWithoutLosingFreshBalance() async throws {
        let (db, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try await db.beginThorchainSync(accountID: "a1")
        let second = try await db.beginThorchainSync(accountID: "a2")
        try await storeCatalog(metadataCatalog(time: 200, decimals: 6, name: "Current"), db: db, ticket: first)
        try await db.commitThorchainInventory(.init(owner: owner,
            holdings: [.init(reference: "native", amount: "1"), .init(reference: "x/metadata-fixture", amount: "1000000")],
            observedAt: Date(timeIntervalSince1970: 300), height: 123), ticket: second,
            catalog: metadataCatalog(time: 100, decimals: 8, name: "Old"))

        let snapshot = try await db.snapshot(walletID: "w2", currency: "USD")
        let token = snapshot.holdings.first { $0.reference == "x/metadata-fixture" }
        XCTAssertEqual(token?.amountAtomic, "1000000")
        XCTAssertEqual(token?.decimals, 6)
        let asset = try await db.asset(networkID: "thorchain", reference: "x/metadata-fixture")
        XCTAssertEqual(asset?.name, "Current")
    }

    func testDelayedHistoryKeepsCurrentPrecisionAndRemainsVisible() async throws {
        let (db, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try await db.beginThorchainSync(accountID: "a1")
        let second = try await db.beginThorchainSync(accountID: "a2")
        try await storeCatalog(metadataCatalog(time: 200, decimals: 6, name: "Current"), db: db, ticket: first)
        let cursor = try await db.thorchainCursor(ticket: second, stream: "transfer.recipient", lane: "backfill", height: 200)
        let event = ThorchainEvent(id: "metadata-fixture", hash: String(repeating: "D", count: 64),
            reference: "x/metadata-fixture", amount: "1000000", direction: "incoming", counterparty: other,
            state: "confirmed", height: 100, timestamp: 1, fee: nil)
        try await db.commitThorchainHistory(.init(owner: owner, events: [event], next: nil, rawCount: 1),
            cursor: cursor, ticket: second, catalog: metadataCatalog(time: 100, decimals: 8, name: "Old"))

        let reopened = try await OathDatabase.open(at: folder.appendingPathComponent("wallet.sqlite"))
        let asset = try await reopened.asset(networkID: "thorchain", reference: "x/metadata-fixture")
        XCTAssertEqual(asset?.decimals, 6)
        let history = try await reopened.history(walletID: "w2")
        XCTAssertEqual(history.count, 1, "A late page must not hide the transfer by mismatching the trusted decimals")
        XCTAssertEqual(history.first?.amountAtomic, "1000000")
    }

    func testCatalogMetadataAndCacheCommitTogetherAndRollbackTogether() async throws {
        let (db, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ticket = try await db.beginThorchainSync(accountID: "a1")
        try await db.commitThorchainCatalog(metadataCatalog(time: 100, decimals: 8, name: "First"), ticket: ticket)
        let before = try await db.marketCache(key: "thorchain.catalog")
        XCTAssertEqual(before?.fetchedAt, 100, "Metadata cannot be published without its ordering watermark")
        try await db.pool.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_fixture_price BEFORE INSERT ON prices
                WHEN NEW.observedAt=200 BEGIN SELECT RAISE(ABORT,'fixture storage failure'); END
                """)
        }
        do {
            try await db.commitThorchainCatalog(metadataCatalog(time: 200, decimals: 6, name: "Second"), ticket: ticket)
            XCTFail("Injected storage failure was swallowed")
        } catch { XCTAssertTrue(error is DatabaseError) }
        let reopened = try await OathDatabase.open(at: folder.appendingPathComponent("wallet.sqlite"))
        let after = try await reopened.marketCache(key: "thorchain.catalog")
        XCTAssertEqual(after, before)
        let asset = try await reopened.asset(networkID: "thorchain", reference: "x/metadata-fixture")
        XCTAssertEqual(asset?.decimals, 8)
        XCTAssertEqual(asset?.name, "First")
    }

    func testConcurrentCatalogsKeepMetadataAndCacheFromSameNewestObservation() async throws {
        let (db, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let tickets = [try await db.beginThorchainSync(accountID: "a1"), try await db.beginThorchainSync(accountID: "a2")]
        let catalogs = (1...20).map { metadataCatalog(time: Double($0), decimals: $0 % 2 == 0 ? 6 : 8, name: "Version\($0)") }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (index, catalog) in catalogs.reversed().enumerated() {
                let ticket = tickets[index % 2]
                group.addTask { try await db.commitThorchainCatalog(catalog, ticket: ticket) }
            }
            try await group.waitForAll()
        }
        let reopened = try await OathDatabase.open(at: folder.appendingPathComponent("wallet.sqlite"))
        let cache = try await reopened.marketCache(key: "thorchain.catalog")
        let saved = try JSONDecoder().decode(ThorchainCatalog.self, from: XCTUnwrap(cache?.payload))
        let asset = try await reopened.asset(networkID: "thorchain", reference: "x/metadata-fixture")
        XCTAssertEqual(cache?.fetchedAt, 20)
        XCTAssertEqual(asset?.name, "Version20")
        XCTAssertEqual(asset?.decimals, 6)
        XCTAssertEqual(saved.tokens["x/metadata-fixture"]?.name, asset?.name)
        XCTAssertEqual(saved.tokens["x/metadata-fixture"]?.decimals, asset?.decimals)
    }

    func testInvalidCacheDoesNotBlockValidCatalogAndInvalidInputCannotReplaceIt() async throws {
        let (db, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ticket = try await db.beginThorchainSync(accountID: "a1")
        // Optional public cache corruption must not prevent recovery from a live read.
        try await db.saveMarketCache(.init(key: "thorchain.catalog", source: "THORChain",
            payload: Data("invalid fixture".utf8), fetchedAt: 500))
        try await db.commitThorchainCatalog(metadataCatalog(time: 200, decimals: 6, name: "Current"), ticket: ticket)
        let before = try await db.marketCache(key: "thorchain.catalog")
        XCTAssertEqual(before?.fetchedAt, 200)
        var bad = metadataCatalog(time: 300, decimals: 6, name: "Bad")
        bad.tokens["x/metadata-fixture"] = .init(reference: "x/different", name: "Bad", symbol: "BAD", decimals: 6)
        do { try await db.commitThorchainCatalog(bad, ticket: ticket); XCTFail("Mismatched identity accepted") }
        catch { XCTAssertEqual(error as? StoreError, .conflictingIdentity) }
        let after = try await db.marketCache(key: "thorchain.catalog")
        XCTAssertEqual(after, before)
        let asset = try await db.asset(networkID: "thorchain", reference: "x/metadata-fixture")
        XCTAssertEqual(asset?.name, "Current")
    }

    func testSupersededAccountCannotPublishNewCatalog() async throws {
        let (db, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ticket = try await db.beginThorchainSync(accountID: "a1")
        try await db.commitThorchainCatalog(metadataCatalog(time: 100, decimals: 8, name: "First"), ticket: ticket)
        let before = try await db.marketCache(key: "thorchain.catalog")
        _ = try await db.beginThorchainSync(accountID: "a1")
        do {
            try await db.commitThorchainCatalog(metadataCatalog(time: 200, decimals: 6, name: "Second"), ticket: ticket)
            XCTFail("Superseded account bypassed the generation guard")
        } catch { XCTAssertEqual(error as? StoreError, .staleSync) }
        let after = try await db.marketCache(key: "thorchain.catalog")
        XCTAssertEqual(after, before)
        let asset = try await db.asset(networkID: "thorchain", reference: "x/metadata-fixture")
        XCTAssertEqual(asset?.name, "First")
    }
}
