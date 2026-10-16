import Foundation
import XCTest
import GRDB
@testable import OathDatabase

@MainActor final class HistoryFilterTests: XCTestCase {
    private func fixture() async throws -> (OathDatabase, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("history-filters-" + UUID().uuidString)
        let store = try await OathDatabase.open(at: folder.appendingPathComponent("db.sqlite"))
        try await store.seed(networks: ["ethereum", "polygon"].enumerated().map {
            NetworkRecord(id: $1, name: $1, family: "evm", symbol: "ETH", decimals: 18,
                derivationPath: "", logo: "", sortOrder: $0)
        }, assets: [
            .init(id: "eth", networkID: "ethereum", reference: "native", name: "Ether", symbol: "ETH", decimals: 18),
            .init(id: "token", networkID: "ethereum", reference: "public-token", name: "Token", symbol: "TKN", decimals: 6),
            .init(id: "pol", networkID: "polygon", reference: "native", name: "Polygon", symbol: "POL", decimals: 18)
        ])
        try await store.importWalletIfNeeded(.init(id: "w", name: "Wallet", kind: "hd", vaultReference: "fixture", createdAt: 1), accounts: [
            .init(id: "e", walletID: "w", networkID: "ethereum", address: "public-owner", derivationPath: ""),
            .init(id: "p", walletID: "w", networkID: "polygon", address: "public-owner-p", derivationPath: "")])
        try await store.importWalletIfNeeded(.init(id: "other", name: "Other", kind: "hd", vaultReference: "fixture-other", createdAt: 1), accounts: [
            .init(id: "other-e", walletID: "other", networkID: "ethereum", address: "public-other", derivationPath: "")])
        try await store.pool.write { db in
            let fixtures: [(String, String, String, String, String, Double)] = [
                ("n1", "eth", "incoming", "confirmed", "1000000000000000000", 100),
                ("n2", "eth", "outgoing", "pending", "2000000000000000000", 200),
                ("n3", "token", "outgoing", "failed", "3000000", 300),
                ("n4", "token", "self", "replaced", "4000000", 400),
                ("n5", "token", "outgoing", "pending", "5000000", 500),
                ("n6", "pol", "incoming", "confirmed", "6000000000000000000", 600),
                ("n7", "token", "incoming", "reorged", "7000000", 700),
                ("n8", "token", "outgoing", "pending", "100000000", 0)
            ]
            for (id, asset, direction, state, amount, time) in fixtures {
                let network = asset == "pol" ? "polygon" : "ethereum"
                let account = asset == "pol" ? "p" : "e"
                try TransactionRecord(id: id, networkID: network, hash: id, state: state, timestamp: time, updatedAt: time).insert(db)
                try ActivityRecord(id: id, walletID: "w", accountID: account, networkID: network,
                    transactionID: id, assetID: asset, direction: direction, amountAtomic: amount,
                    counterparty: "public-peer", timestamp: time).insert(db)
            }
            try db.execute(sql: """
                INSERT INTO transactionEvidence(accountID,transactionID,conflictKeys,returnsToWallet,outcome,outcomeAt)
                VALUES ('e','n5',X'5B5D',1,'canceled',750)
                """)
            try ActivityRecord(id: "other-wallet", walletID: "other", accountID: "other-e", networkID: "ethereum",
                transactionID: "n1", assetID: "eth", direction: "incoming", amountAtomic: "1",
                counterparty: "public-peer", timestamp: 900).insert(db)
        }
        return (store, folder)
    }

    func testCombinedFiltersIntersectAndUseVerifiedOutcomes() async throws {
        let (db, folder) = try await fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        var filter = HistoryFilter()
        filter.networkIDs = ["ethereum"]; filter.assetIDs = ["token"]
        filter.directions = [.outgoing]; filter.statuses = [.failed, .canceled]
        filter.startDate = Date(timeIntervalSince1970: 250); filter.endDate = Date(timeIntervalSince1970: 800)
        filter.minimumAmount = "2.5"; filter.maximumAmount = "5"
        let result = try await db.chainHistory(walletID: "w", currency: "USD", search: "TKN public-peer", filter: filter)
        XCTAssertEqual(result.map(\.id), ["n5", "n3"])
        let differentAsset = try await db.chainHistory(walletID: "w", assetID: "eth", currency: "USD", filter: filter)
        XCTAssertTrue(differentAsset.isEmpty, "Filters must never broaden a scoped asset screen")
        let differentWallet = try await db.chainHistory(walletID: "other", currency: "USD", filter: filter)
        XCTAssertTrue(differentWallet.isEmpty)
    }

    func testEveryStatusAndDirectionSelection() async throws {
        let (db, folder) = try await fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let expected: [HistoryFilter.Status: Set<String>] = [.confirmed: ["n1", "n6"], .pending: ["n2", "n8"],
            .failed: ["n3"], .replaced: ["n4"], .canceled: ["n5"], .reorged: ["n7"]]
        for status in HistoryFilter.Status.allCases {
            var filter = HistoryFilter(); filter.statuses = [status]
            let rows = try await db.chainHistory(walletID: "w", currency: "USD", filter: filter)
            XCTAssertEqual(Set(rows.map(\.id)), expected[status], status.rawValue)
        }
        for direction in HistoryFilter.Direction.allCases {
            var filter = HistoryFilter(); filter.directions = [direction]
            let rows = try await db.chainHistory(walletID: "w", currency: "USD", filter: filter)
            XCTAssertFalse(rows.isEmpty)
            XCTAssertTrue(rows.allSatisfy { $0.entry.direction == direction.rawValue })
        }
        var both = HistoryFilter(); both.directions = [.incoming, .outgoing]
        let rows = try await db.chainHistory(walletID: "w", currency: "USD", filter: both)
        XCTAssertEqual(rows.count, 7)
    }

    func testDatesUseInclusiveStartExclusiveEndAndExcludeUnknownTime() async throws {
        let (db, folder) = try await fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        var filter = HistoryFilter()
        filter.startDate = Date(timeIntervalSince1970: 700); filter.endDate = Date(timeIntervalSince1970: 750)
        let first = try await db.chainHistory(walletID: "w", currency: "USD", filter: filter)
        XCTAssertEqual(first.map(\.id), ["n7"])
        filter.startDate = Date(timeIntervalSince1970: 750); filter.endDate = Date(timeIntervalSince1970: 751)
        let canceled = try await db.chainHistory(walletID: "w", currency: "USD", filter: filter)
        XCTAssertEqual(canceled.map(\.id), ["n5"])
        filter.startDate = nil; filter.endDate = Date(timeIntervalSince1970: 200)
        let before = try await db.chainHistory(walletID: "w", currency: "USD", filter: filter)
        XCTAssertEqual(before.map(\.id), ["n1"])
    }

    func testAmountBoundsAreExactInclusiveAndIndependentOfPrices() async throws {
        let (db, folder) = try await fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        try await db.pool.write { db in
            try db.execute(sql: "UPDATE activity SET amountAtomic='1000000000000000001' WHERE id='n1'")
        }
        var filter = HistoryFilter()
        filter.minimumAmount = "1.000000000000000001"; filter.maximumAmount = filter.minimumAmount
        let exact = try await db.chainHistory(walletID: "w", currency: "JPY", filter: filter)
        XCTAssertEqual(exact.map(\.id), ["n1"])
        filter.maximumAmount = "1"; filter.minimumAmount = nil
        let less = try await db.chainHistory(walletID: "w", currency: "USD", filter: filter)
        XCTAssertTrue(less.isEmpty)
        let large = String(repeating: "9", count: 190)
        XCTAssertEqual(HistoryFilter.compareAmounts(large, "1" + String(repeating: "0", count: 190)), .orderedAscending)
        XCTAssertEqual(HistoryFilter.compareAmounts("0." + String(repeating: "0", count: 191) + "1", "0"), .orderedDescending)
    }

    func testFiltersApplyBeforePagingAndRemainActiveOnEveryPage() async throws {
        let (db, folder) = try await fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        var filter = HistoryFilter(); filter.networkIDs = ["ethereum"]; filter.directions = [.outgoing]
        var ids: [String] = [], cursor: HistoryCursor?
        while true {
            let page = try await db.chainHistory(walletID: "w", currency: "USD", before: cursor,
                                                 limit: 1, search: "public-peer", filter: filter)
            guard let last = page.last else { break }
            ids += page.map(\.id)
            cursor = .init(timestamp: last.entry.timestamp, id: last.id)
        }
        XCTAssertEqual(ids, ["n5", "n3", "n2", "n8"])
        let first = try await db.chainHistory(walletID: "w", currency: "USD", limit: 1, search: "n2", filter: filter)
        XCTAssertEqual(first.map(\.id), ["n2"])
    }

    func testObservationMovesTransactionsOutOfPendingWhenTheyConfirm() async throws {
        let (db, folder) = try await fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        var filter = HistoryFilter(); filter.statuses = [.pending]
        var observer = db.observeChainHistory(walletID: "w", currency: "USD", filter: filter).makeAsyncIterator()
        let first = try await observer.next()
        XCTAssertEqual(first?.map(\.id), ["n2", "n8"])
        try await db.pool.write { db in try db.execute(sql: "UPDATE transactions SET state='confirmed' WHERE id='n2'") }
        let next = try await observer.next()
        XCTAssertEqual(next?.map(\.id), ["n8"])
    }

    func testOptionsIncludeUnheldAssetsAndRespectWalletAndAssetScope() async throws {
        let (db, folder) = try await fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let all = try await db.historyFilterAssets(walletID: "w")
        XCTAssertEqual(Set(all.map(\.id)), ["eth", "pol", "token"])
        let token = try await db.historyFilterAssets(walletID: "w", networkID: "ethereum", accountID: "e", assetID: "token")
        XCTAssertEqual(token.map(\.id), ["token"])
        let other = try await db.historyFilterAssets(walletID: "other")
        XCTAssertEqual(other.map(\.id), ["eth"])
    }

    func testLocalizedAmountValidationRejectsPartialAndReversedRanges() async throws {
        XCTAssertEqual(HistoryFilter.canonicalAmount("٠٠١٢٫٣٤٠", locale: Locale(identifier: "ar")), "12.34")
        XCTAssertEqual(HistoryFilter.canonicalAmount("12,340", locale: Locale(identifier: "fr_FR")), "12.34")
        XCTAssertEqual(HistoryFilter.canonicalAmount(".000000000000000001"), "0.000000000000000001")
        for text in ["", ".", "-1", "12oops", "1e3", "NaN", "1.2.3", "1,000"] {
            XCTAssertNil(HistoryFilter.canonicalAmount(text), text)
        }
        var filter = HistoryFilter(); filter.minimumAmount = "3"; filter.maximumAmount = "2"
        XCTAssertFalse(filter.isValid)
        let (db, folder) = try await fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        do {
            _ = try await db.chainHistory(walletID: "w", currency: "USD", filter: filter)
            XCTFail("An invalid filter must not silently show unfiltered results")
        } catch { XCTAssertEqual(error as? StoreError, .invalidValue("history filter")) }
        filter = .init(); filter.startDate = Date(timeIntervalSince1970: 2); filter.endDate = Date(timeIntervalSince1970: 1)
        XCTAssertFalse(filter.isValid)
    }
}
