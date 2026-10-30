import Foundation
import XCTest
import GRDB
@testable import OathDatabase

@MainActor final class ChainHistoryTests: XCTestCase {
    private func fixture() async throws -> (OathDatabase, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("chain-history-" + UUID().uuidString)
        let db = try await OathDatabase.open(at: folder.appendingPathComponent("db.sqlite"))
        try await db.seed(networks: ["ethereum", "polygon"].enumerated().map { index, network in
            NetworkRecord(id: network, name: network, family: "evm", symbol: "ETH", decimals: 18,
                          derivationPath: "fixture", logo: "", sortOrder: index)
        }, assets: [
            .init(id: "native", networkID: "ethereum", reference: "native", name: "Ether", symbol: "ETH", decimals: 18),
            .init(id: "token", networkID: "ethereum", reference: "public-token", name: "Token", symbol: "TKN", decimals: 6),
            .init(id: "polygon-native", networkID: "polygon", reference: "native", name: "Polygon", symbol: "POL", decimals: 18)])
        try await db.importWalletIfNeeded(.init(id: "w", name: "Wallet", kind: "hd", vaultReference: "fixture", createdAt: 1), accounts: [
            .init(id: "a", walletID: "w", networkID: "ethereum", address: "public-a", derivationPath: ""),
            .init(id: "a2", walletID: "w", networkID: "ethereum", address: "public-a2", derivationPath: ""),
            .init(id: "p", walletID: "w", networkID: "polygon", address: "public-p", derivationPath: "")])
        try await db.importWalletIfNeeded(.init(id: "other", name: "Other", kind: "hd", vaultReference: "fixture2", createdAt: 1), accounts: [
            .init(id: "b", walletID: "other", networkID: "ethereum", address: "public-b", derivationPath: "")])
        try await db.pool.write { db in
            for index in 0..<230 {
                let id = String(format: "row-%03d", index), time = 100 + Double(index / 2)
                try TransactionRecord(id: id, networkID: "ethereum", hash: id, state: "confirmed", timestamp: time, updatedAt: time).insert(db)
                try ActivityRecord(id: id, walletID: "w", accountID: "a", networkID: "ethereum", transactionID: id,
                    assetID: index.isMultiple(of: 2) ? "native" : "token", direction: "incoming",
                    amountAtomic: "1000000", counterparty: "public-sender", timestamp: time).insert(db)
            }
            for (id, account, wallet, network, asset) in [
                ("other-chain", "p", "w", "polygon", "polygon-native"),
                ("other-wallet", "b", "other", "ethereum", "native"),
                ("second-account", "a2", "w", "ethereum", "native")
            ] {
                try TransactionRecord(id: id, networkID: network, hash: id, state: "confirmed", timestamp: 500, updatedAt: 500).insert(db)
                try ActivityRecord(id: id, walletID: wallet, accountID: account, networkID: network, transactionID: id,
                    assetID: asset, direction: "outgoing", amountAtomic: "1", counterparty: "public-receiver", timestamp: 500).insert(db)
            }
        }
        try await db.savePrices([
            .init(assetID: "native", currency: "USD", value: "2000", observedAt: 1, source: "fixture"),
            .init(assetID: "token", currency: "USD", value: "1", observedAt: 1, source: "fixture"),
            .init(assetID: "token", currency: "USD", value: "2", observedAt: 2, source: "fixture")])
        try await db.saveExchangeRates(.init(rates: ["USD": "1", "EUR": "0.9"], observedAt: 1, fetchedAt: 1, source: "fixture"))
        return (db, folder)
    }

    func testPreviewContainsOnlyFiveNewestAssetEntries() async throws {
        let (db, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        var observer = db.observeAssetHistory(walletID: "w", accountID: "a", assetID: "native", limit: 5).makeAsyncIterator()
        let preview = try await observer.next()
        XCTAssertEqual(preview?.map(\.id), ["row-228", "row-226", "row-224", "row-222", "row-220"])
    }

    func testAssetViewAllKeepsExactAssetAndAccountThroughSearchAndPagination() async throws {
        let (db, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await db.pool.write { db in
            // Two contracts can share a ticker and occur in the same transaction.
            try AssetRecord(id: "another-token", networkID: "ethereum", reference: "another-contract",
                name: "Other Token", symbol: "TKN", decimals: 6).insert(db)
            try ActivityRecord(id: "same-ticker", walletID: "w", accountID: "a", networkID: "ethereum",
                transactionID: "row-229", assetID: "another-token", direction: "incoming",
                amountAtomic: "1000000", counterparty: "public-sender", timestamp: 214).insert(db)
        }
        for assetID in ["native", "token"] {
            var all: [ChainHistoryItem] = [], cursor: HistoryCursor?
            while true {
                let page = try await db.chainHistory(walletID: "w", networkID: "ethereum", accountID: "a",
                    assetID: assetID, currency: "USD", before: cursor, limit: 17)
                if page.isEmpty { break }
                all += page
                let last = try XCTUnwrap(page.last).entry
                cursor = .init(timestamp: last.timestamp, id: last.id)
            }
            XCTAssertEqual(all.count, 115)
            XCTAssertEqual(Set(all.map(\.id)).count, 115)
            XCTAssertTrue(all.allSatisfy { $0.entry.assetID == assetID && $0.entry.accountID == "a" })
            let preview = try await db.assetHistory(walletID: "w", accountID: "a", assetID: assetID, limit: 6)
            XCTAssertEqual(all.prefix(6).map(\.entry), preview)
        }
        let search = try await db.chainHistory(walletID: "w", accountID: "a", assetID: "token",
            currency: "USD", limit: 200, search: "TKN")
        XCTAssertEqual(search.count, 115)
        XCTAssertTrue(search.allSatisfy { $0.entry.assetID == "token" })
        let otherAssetHash = try await db.chainHistory(walletID: "w", accountID: "a", assetID: "token",
            currency: "USD", search: "row-228")
        XCTAssertTrue(otherAssetHash.isEmpty)
        let otherWalletAccount = try await db.chainHistory(walletID: "w", accountID: "b", assetID: "native", currency: "USD")
        XCTAssertTrue(otherWalletAccount.isEmpty)
    }

    func testAssetPreviewLookaheadTracksZeroFourFiveSixAndBackToFive() async throws {
        let (db, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await db.pool.write { db in
            try db.execute(sql: "DELETE FROM activity WHERE accountID='a' AND assetID='native'")
        }
        // Hundreds of other asset/account rows must not make View All appear.
        var observer = db.observeAssetHistory(walletID: "w", accountID: "a", assetID: "native", limit: 6).makeAsyncIterator()
        let initial = try await observer.next()
        XCTAssertEqual(initial?.count, 0)
        for range in [0..<4, 4..<5, 5..<6] {
            try await db.pool.write { db in
                for index in range {
                    let id = String(format: "row-%03d", index * 2)
                    try ActivityRecord(id: id, walletID: "w", accountID: "a", networkID: "ethereum",
                        transactionID: id, assetID: "native", direction: "incoming", amountAtomic: "1",
                        counterparty: "public-sender", timestamp: Double(100 + index)).insert(db)
                }
            }
            let changed = try await observer.next()
            let entries = try XCTUnwrap(changed)
            XCTAssertEqual(entries.count, range.upperBound)
            XCTAssertEqual(entries.count > 5, range.upperBound == 6)
            XCTAssertLessThanOrEqual(entries.prefix(5).count, 5)
        }
        try await db.pool.write { db in try db.execute(sql: "DELETE FROM activity WHERE id='row-010'") }
        let removed = try await observer.next()
        XCTAssertEqual(removed?.count, 5)
    }

    func testAssetScopedObservationRetainsFilterWhenLiveHistoryChanges() async throws {
        let (db, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        var observer = db.observeChainHistory(walletID: "w", networkID: "ethereum", accountID: "a",
            assetID: "token", currency: "USD", limit: 200).makeAsyncIterator()
        let initial = try await observer.next()
        XCTAssertEqual(initial?.count, 115)
        try await db.pool.write { db in
            try TransactionRecord(id: "new", networkID: "ethereum", hash: "new", state: "pending", timestamp: 600, updatedAt: 600).insert(db)
            for assetID in ["native", "token"] {
                try ActivityRecord(id: "new-" + assetID, walletID: "w", accountID: "a", networkID: "ethereum",
                    transactionID: "new", assetID: assetID, direction: "outgoing", amountAtomic: "1",
                    counterparty: "public-receiver", timestamp: 600).insert(db)
            }
        }
        let updated = try await observer.next()
        XCTAssertEqual(updated?.count, 116)
        XCTAssertEqual(updated?.first?.id, "new-token")
        XCTAssertTrue(updated?.allSatisfy { $0.entry.assetID == "token" && $0.entry.accountID == "a" } == true)
    }

    func testChainHistoryPagesEveryAssetAndAccountWithoutCrossWalletOrNetworkLeakage() async throws {
        let (db, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        var all: [ChainHistoryItem] = [], cursor: HistoryCursor?
        while true {
            let page = try await db.chainHistory(walletID: "w", networkID: "ethereum", currency: "EUR", before: cursor, limit: 50)
            if page.isEmpty { break }
            all += page
            let last = try XCTUnwrap(page.last).entry
            cursor = .init(timestamp: last.timestamp, id: last.id)
        }
        XCTAssertEqual(all.count, 231)
        XCTAssertEqual(Set(all.map(\.id)).count, 231)
        XCTAssertEqual(all.first?.id, "second-account")
        XCTAssertEqual(all.dropFirst().first?.id, "row-229")
        XCTAssertTrue(all.allSatisfy { $0.entry.networkID == "ethereum" && ["a", "a2"].contains($0.entry.accountID) })
        XCTAssertEqual(Set(all.map { $0.entry.assetID }), ["native", "token"])
        let token = try XCTUnwrap(all.first { $0.entry.assetID == "token" })
        XCTAssertEqual(token.holding.symbol, "TKN")
        XCTAssertEqual(token.holding.decimals, 6)
        XCTAssertEqual(token.holding.price, "1.8")
        XCTAssertNil(token.holding.amountAtomic, "History metadata must not invent a current wallet balance")
        let native = try XCTUnwrap(all.first { $0.entry.assetID == "native" })
        XCTAssertEqual(native.holding.decimals, 18)
        XCTAssertEqual(native.holding.price, "1800")
        let empty = try await db.chainHistory(walletID: "missing", networkID: "ethereum", currency: "USD")
        XCTAssertTrue(empty.isEmpty)
    }

    func testExpandedObservationExceedsTwoHundredRowsAndUpdatesPrices() async throws {
        let (db, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        var observer = db.observeChainHistory(walletID: "w", networkID: "ethereum", currency: "USD", limit: 251).makeAsyncIterator()
        let initial = try await observer.next()
        XCTAssertEqual(initial?.count, 231)
        try await db.savePrices([.init(assetID: "token", currency: "USD", value: "3", observedAt: 3, source: "fixture")])
        let changed = try await observer.next()
        XCTAssertEqual(changed?.first { $0.entry.assetID == "token" }?.holding.price, "3")
        XCTAssertEqual(changed?.count, 231)
        let unknownFX = try await db.chainHistory(walletID: "w", networkID: "ethereum", currency: "JPY")
        XCTAssertTrue(unknownFX.allSatisfy { $0.holding.price == nil })
    }

    func testWalletHistoryIncludesAllChainsButOnlyThisWallet() async throws {
        let (db, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        var observer = db.observeChainHistory(walletID: "w", currency: "USD", limit: 300).makeAsyncIterator()
        let page = try await observer.next()
        let all = try XCTUnwrap(page)
        XCTAssertEqual(all.count, 232)
        XCTAssertEqual(Set(all.map { $0.entry.networkID }), ["ethereum", "polygon"])
        XCTAssertFalse(all.contains { $0.id == "other-wallet" })
    }

    func testSearchFindsOlderTransactionsAndBothTransferAddressesBeforePagination() async throws {
        let (db, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await db.pool.write { db in
            try TransferRecord(id: "transfer", transactionID: "row-003", networkID: "ethereum", assetID: "token",
                eventIndex: 0, fromAddress: "Secondary-Sender", toAddress: "Secondary-Recipient", amountAtomic: "1000000").insert(db)
        }
        for query in ["ROW-003", "secondary-sender", "secondary-recipient", "secondary-recipient TKN"] {
            let results = try await db.chainHistory(walletID: "w", currency: "USD", limit: 1, search: query)
            XCTAssertEqual(results.map(\.id), ["row-003"], query)
        }
        for query in ["%", "_", "missing000", "other-wallet"] {
            let results = try await db.chainHistory(walletID: "w", currency: "USD", search: query)
            XCTAssertTrue(results.isEmpty, query)
        }
        let recipients = try await db.chainHistory(walletID: "w", currency: "USD", search: "public-receiver")
        XCTAssertEqual(Set(recipients.map(\.id)), ["other-chain", "second-account"])
        let sent = try await db.chainHistory(walletID: "w", currency: "USD", search: "sent")
        XCTAssertEqual(Set(sent.map(\.id)), Set(recipients.map(\.id)))
        let contract = try await db.chainHistory(walletID: "w", currency: "USD", limit: 200, search: "public-token")
        XCTAssertEqual(contract.count, 115)
        XCTAssertTrue(contract.allSatisfy { $0.entry.assetID == "token" })
        let polygon = try await db.chainHistory(walletID: "w", currency: "USD", search: "polygon")
        XCTAssertEqual(polygon.map(\.id), ["other-chain"])
    }

    func testSearchMatchesExactSmallNativeAmountsAndLocalizedFiatValues() async throws {
        let (db, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        for (query, locale) in [("€1.80", "en_US"), ("١٫٨٠", "ar"), ("1,80", "fr_FR")] {
            let results = try await db.chainHistory(walletID: "w", currency: "EUR", limit: 200,
                                                    search: query, localeIdentifier: locale)
            XCTAssertEqual(results.count, 115, query)
            XCTAssertTrue(results.allSatisfy { $0.entry.assetID == "token" }, query)
        }
        let tiny = try await db.chainHistory(walletID: "w", currency: "USD", limit: 200, search: "0.000000000001")
        XCTAssertEqual(tiny.count, 115)
        XCTAssertTrue(tiny.allSatisfy { $0.entry.assetID == "native" })
        let missingFX = try await db.chainHistory(walletID: "w", currency: "JPY", search: "1.80")
        XCTAssertTrue(missingFX.isEmpty)
        let qualifiedDollars = try await db.chainHistory(walletID: "w", currency: "USD", limit: 200,
            search: "US$2.00", localeIdentifier: "ar")
        XCTAssertEqual(qualifiedDollars.count, 115)
        let unavailableCurrency = try await db.chainHistory(walletID: "w", currency: "JPY", search: "¥1")
        XCTAssertTrue(unavailableCurrency.isEmpty, "An explicitly fiat search must not match an unpriced native amount")
    }

    func testFilteredObservationReactsToPricesAndDoesNotLoseItsScope() async throws {
        let (db, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        var observer = db.observeChainHistory(walletID: "w", networkID: "ethereum", currency: "USD",
            limit: 5, search: "$3.00", localeIdentifier: "en_US").makeAsyncIterator()
        let initial = try await observer.next()
        XCTAssertEqual(initial, [])
        try await db.savePrices([.init(assetID: "token", currency: "USD", value: "3", observedAt: 4, source: "fixture")])
        let updated = try await observer.next()
        XCTAssertEqual(updated?.count, 5)
        XCTAssertTrue(updated?.allSatisfy { $0.entry.assetID == "token" && $0.entry.networkID == "ethereum" } == true)
    }
}
