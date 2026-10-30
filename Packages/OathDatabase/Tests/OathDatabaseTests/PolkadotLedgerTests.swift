import Foundation
import XCTest
import GRDB
@testable import OathDatabase
@testable import OathAnkr

@MainActor final class PolkadotLedgerTests: XCTestCase {
    let owner = "13vg3Mrxm3GL9eXxLsGgLYRueiwFCiMbkdHBL4ZN5aob5D4N"
    var token: PolkadotToken { .init(reference: "assets:1984", name: "Tether", symbol: "USDt", decimals: 6, pallet: "Assets", key: Data([192, 7, 0, 0])) }
    func setup() async throws -> (OathDatabase, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Polkadot-" + UUID().uuidString)
        let db = try await OathDatabase.open(at: folder.appendingPathComponent("wallet.sqlite"))
        try await db.seed(networks: [.init(id: "polkadot", name: "Polkadot", family: "account", symbol: "DOT", decimals: 10, derivationPath: "m/44'/354'/0'/0'/0'", logo: "network-polkadot", sortOrder: 0)], assets: [.init(id: "polkadot:native", networkID: "polkadot", reference: "native", name: "Polkadot", symbol: "DOT", decimals: 10)])
        for n in 1...2 { try await db.importWalletIfNeeded(.init(id: "w\(n)", name: "Fixture", kind: "hd", vaultReference: "test\(n)", createdAt: 1), accounts: [.init(id: "a\(n)", walletID: "w\(n)", networkID: "polkadot", address: owner, derivationPath: "m/44'/354'/0'/0'/0'")]) }
        return (db, folder)
    }
    func inventory(_ height: Int64 = 100, token: Bool = true) -> PolkadotInventory {
        .init(owner: owner, blockHash: "0x" + String(repeating: "ab", count: 32), height: height,
            holdings: [.init(token: .native, amount: "12345678901234567890")] + (token ? [.init(token: self.token, amount: "9007199254740993")] : []), observedAt: Date(timeIntervalSince1970: Double(height)))
    }
    func testExactBalancesIsolationOfflineAndSpentTokens() async throws {
        let (db, folder) = try await setup(); defer { try? FileManager.default.removeItem(at: folder) }
        let ticket = try await db.beginPolkadotSync(accountID: "a1")
        try await db.commitPolkadotInventory(inventory(), ticket: ticket)
        let snapshot = try await db.snapshot(walletID: "w1", currency: "USD")
        XCTAssertEqual(snapshot.holdings.first { $0.reference == "assets:1984" }?.amountAtomic, "9007199254740993")
        let other = try await db.snapshot(walletID: "w2", currency: "USD"); XCTAssertNil(other.holdings.first?.amountAtomic)
        let reopened = try await OathDatabase.open(at: folder.appendingPathComponent("wallet.sqlite"))
        let cached = try await reopened.snapshot(walletID: "w1", currency: "USD"); XCTAssertEqual(snapshot.holdings, cached.holdings)
        try await db.commitPolkadotInventory(inventory(200, token: false), ticket: ticket)
        let spent = try await db.balance(accountID: "a1", assetID: "polkadot:assets:1984"); XCTAssertEqual(spent?.amountAtomic, "0")
    }
    func testStaleAndWrongOwnerNeverOverwrite() async throws {
        let (db, folder) = try await setup(); defer { try? FileManager.default.removeItem(at: folder) }
        let old = try await db.beginPolkadotSync(accountID: "a1")
        try await db.commitPolkadotInventory(inventory(), ticket: old)
        let new = try await db.beginPolkadotSync(accountID: "a1")
        do { try await db.commitPolkadotInventory(inventory(200), ticket: old); XCTFail() } catch { XCTAssertEqual(error as? StoreError, .staleSync) }
        do { try await db.commitPolkadotInventory(inventory(99), ticket: new); XCTFail() } catch { XCTAssertEqual(error as? StoreError, .staleSync) }
        let bad = PolkadotInventory(owner: "different", blockHash: inventory().blockHash, height: 300, holdings: inventory().holdings)
        do { try await db.commitPolkadotInventory(bad, ticket: new); XCTFail() } catch { XCTAssertEqual(error as? StoreError, .conflictingIdentity) }
        let saved = try await db.balance(accountID: "a1", assetID: "polkadot:assets:1984"); XCTAssertEqual(saved?.amountAtomic, "9007199254740993")
    }
    func testHistoryReplayExtrinsicMergeAndDurableWindows() async throws {
        let (db, folder) = try await setup(); defer { try? FileManager.default.removeItem(at: folder) }
        let ticket = try await db.beginPolkadotSync(accountID: "a1")
        let cursor = try await db.polkadotHistoryCursor(ticket, stream: "assets", latestHeight: 100)
        XCTAssertEqual(cursor.page, 0); XCTAssertEqual(cursor.lowerHeight, 0)
        let peer = try PolkadotIdentity.address(publicKey: Data(repeating: 7, count: 32))
        let event = PolkadotEvent(id: "event:99-3", transaction: "99-2", reference: token.reference, amount: "50000000", from: peer, to: owner, height: 99, timestamp: 1_000, successful: true, token: token)
        let page = PolkadotHistoryPage(events: [event], next: 1, oldestHeight: 99)
        try await db.commitPolkadotHistory(page, ticket: ticket, stream: "assets", currentPage: 0, advance: true)
        try await db.commitPolkadotHistory(page, ticket: ticket, stream: "assets", currentPage: 0, advance: false)
        let resumed = try await db.polkadotHistoryCursor(ticket, stream: "assets", latestHeight: 200)
        XCTAssertEqual(resumed.page, 1); XCTAssertEqual(resumed.upperHeight, 100)
        try await db.commitPolkadotHistory(.init(events: [], next: nil), ticket: ticket, stream: "assets", currentPage: 1, advance: true)
        let next = try await db.polkadotHistoryCursor(ticket, stream: "assets", latestHeight: 200)
        XCTAssertEqual(next.page, 0); XCTAssertEqual(next.lowerHeight, 98); XCTAssertEqual(next.upperHeight, 200)
        let extrinsic = PolkadotEvent(id: "extrinsic:99-2", transaction: "99-2", reference: "native", amount: "0", from: owner, to: owner, height: 99, timestamp: 1_000, successful: true, token: .native)
        try await db.commitPolkadotHistory(.init(events: [extrinsic], next: nil), ticket: ticket, stream: "extrinsics", currentPage: 0, advance: false)
        let history = try await db.chainHistory(walletID: "w1", currency: "USD")
        XCTAssertEqual(history.count, 1); XCTAssertEqual(history.first?.entry.amountAtomic, "50000000")
        XCTAssertEqual(history.first?.entry.state, "confirmed")
        let elsewhere = try await db.chainHistory(walletID: "w2", currency: "USD"); XCTAssertTrue(elsewhere.isEmpty)
    }
    func testEmptyLaggingIndexerDoesNotSkipDelayedHistory() async throws {
        let (db, folder) = try await setup(); defer { try? FileManager.default.removeItem(at: folder) }
        let ticket = try await db.beginPolkadotSync(accountID: "a1")
        _ = try await db.polkadotHistoryCursor(ticket, stream: "native", latestHeight: 100)
        try await db.commitPolkadotHistory(.init(events: [], next: nil), ticket: ticket, stream: "native", currentPage: 0, advance: true)
        let delayed = try await db.polkadotHistoryCursor(ticket, stream: "native", latestHeight: 110)
        XCTAssertEqual(delayed.page, 0)
        XCTAssertEqual(delayed.lowerHeight, 0, "An empty indexer response must not mark the finalized node height as indexed")
        XCTAssertEqual(delayed.upperHeight, 110)
    }
    func testFailedExtrinsicAndPriceIdentity() async throws {
        let (db, folder) = try await setup(); defer { try? FileManager.default.removeItem(at: folder) }
        let ticket = try await db.beginPolkadotSync(accountID: "a1")
        try await db.commitPolkadotInventory(inventory(), ticket: ticket)
        let event = PolkadotEvent(id: "extrinsic:99-2", transaction: "99-2", reference: "native", amount: "0", from: owner, to: owner, height: 99, timestamp: 1_000, successful: false, token: .native)
        try await db.commitPolkadotHistory(.init(events: [event], next: nil), ticket: ticket, stream: "extrinsics", currentPage: 0, advance: false)
        let history = try await db.chainHistory(walletID: "w1", currency: "USD"); XCTAssertEqual(history.first?.entry.state, "failed")
        try await db.commitPolkadotPrices([.init(reference: "assets:1984", usd: "0.99", source: "fixture", observedAt: Date(timeIntervalSince1970: 1_000))], ticket: ticket)
        let snapshot = try await db.snapshot(walletID: "w1", currency: "USD")
        XCTAssertEqual(snapshot.holdings.first { $0.reference == "assets:1984" }?.price, "0.99")
    }
}
