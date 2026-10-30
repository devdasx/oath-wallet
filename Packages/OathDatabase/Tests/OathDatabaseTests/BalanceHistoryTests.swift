import XCTest
import GRDB
@testable import OathDatabase

@MainActor final class BalanceHistoryTests: XCTestCase {
    private func fixture() async throws -> (OathDatabase, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BalanceHistory-" + UUID().uuidString)
            .appendingPathComponent("wallet.sqlite")
        let db = try await OathDatabase.open(at: url)
        try await db.seed(networks: [.init(id: "bitcoin", name: "Bitcoin", family: "utxo", symbol: "BTC", decimals: 8,
                                          derivationPath: "test", logo: "btc", sortOrder: 0)],
                          assets: [.init(id: "btc", networkID: "bitcoin", reference: "native", name: "Bitcoin", symbol: "BTC", decimals: 8)])
        for id in ["w1", "w2"] {
            try await db.importWalletIfNeeded(.init(id: id, name: "Test", kind: "hd", vaultReference: "fixture-" + id, createdAt: 1),
                accounts: [.init(id: "account-" + id, walletID: id, networkID: "bitcoin", address: "public-fixture", derivationPath: "test")])
        }
        return (db, url)
    }
    private let interval = DateInterval(start: Date(timeIntervalSince1970: 1_000), duration: 1_000)
    private func append(_ db: OathDatabase, _ value: String, time: Double = 1_100, complete: Bool = true,
                        wallet: String = "w1", currency: String = "USD", reason: BalanceSnapshotReason = .refresh) async throws {
        try await db.appendBalanceSnapshot(walletID: wallet, currency: currency, total: Decimal(string: value)!,
            complete: complete, reason: reason, date: Date(timeIntervalSince1970: time))
    }
    private func day(_ db: OathDatabase) async throws -> BalanceDaySummary {
        try await db.balanceDay(walletID: "w1", currency: "USD", interval: interval)
    }

    func testEveryEventAppendsEvenWhenValueIsUnchangedAndSurvivesReopen() async throws {
        let (db, url) = try await fixture()
        for reason in [BalanceSnapshotReason.homeVisit, .refresh, .appOpen, .refresh] {
            try await append(db, "100.123456789", reason: reason)
        }
        let reopened = try await OathDatabase.open(at: url)
        let entries = try await reopened.balanceHistory(walletID: "w1", currency: "USD")
        XCTAssertEqual(entries.count, 4)
        XCTAssertEqual(Set(entries.map(\.eventID)).count, 4)
        XCTAssertEqual(entries.map(\.reason), [.refresh, .appOpen, .refresh, .homeVisit])
        XCTAssertTrue(entries.allSatisfy { $0.total == Decimal(string: "100.123456789") })
        let result = try await day(reopened)
        XCTAssertEqual(result.change?.amount, 0)
        XCTAssertEqual(result.change?.percentage, 0)
    }

    func testGainLossAndUnchangedUseFirstTodayNotPreviousUpdate() async throws {
        let (db, _) = try await fixture()
        try await append(db, "99.2")
        try await append(db, "101.68", time: 1_200)
        var result = try await day(db)
        XCTAssertEqual(result.change?.amount, Decimal(string: "2.48"))
        XCTAssertEqual(result.change?.percentage, Decimal(string: "2.5"))
        try await append(db, "89.28", time: 1_300)
        result = try await day(db)
        XCTAssertEqual(result.change?.amount, Decimal(string: "-9.92"))
        XCTAssertEqual(result.change?.percentage, -10)
        try await append(db, "99.2", time: 1_400)
        result = try await day(db)
        XCTAssertEqual(result.change?.amount, 0)
        XCTAssertEqual(result.change?.percentage, 0)
    }

    func testWalletCurrencyAndDayIsolation() async throws {
        let (db, _) = try await fixture()
        try await append(db, "500", time: 999)
        try await append(db, "100", time: 1_000)
        try await append(db, "110", time: 1_999)
        try await append(db, "900", time: 2_000)
        try await append(db, "10000", wallet: "w2")
        try await append(db, "222", currency: "EUR")
        let result = try await day(db)
        XCTAssertEqual(result.opening?.total, 100)
        XCTAssertEqual(result.latest?.total, 110)
        XCTAssertEqual(result.change?.amount, 10)
        let next = try await db.balanceDay(walletID: "w1", currency: "USD", interval: .init(start: interval.end, duration: 1_000))
        XCTAssertEqual(next.opening?.total, 900)
        XCTAssertEqual(next.change?.amount, 0)
        let empty = try await db.balanceDay(walletID: "w1", currency: "USD", interval: .init(start: interval.end.addingTimeInterval(1_000), duration: 1_000))
        XCTAssertEqual(empty.change?.amount, 0, "Carry the last known balance through an idle day")
    }

    func testIncompleteSnapshotsRemainSavedButNeverBecomeFalseGain() async throws {
        let (db, _) = try await fixture()
        try await append(db, "0", complete: false)
        var result = try await day(db)
        XCTAssertNil(result.change)
        try await append(db, "100", time: 1_200)
        result = try await day(db)
        XCTAssertEqual(result.opening?.total, 100)
        XCTAssertEqual(result.change?.amount, 0)
        try await append(db, "45", time: 1_300, complete: false)
        result = try await day(db)
        XCTAssertNil(result.change)
        try await append(db, "105", time: 1_400)
        result = try await day(db)
        XCTAssertEqual(result.change?.amount, 5)
        let history = try await db.balanceHistory(walletID: "w1", currency: "USD")
        XCTAssertEqual(history.count, 4)
    }

    func testZeroStartingBalanceHasNoInvalidPercentage() async throws {
        let (db, _) = try await fixture()
        try await append(db, "0")
        try await append(db, "25", time: 1_200)
        let result = try await day(db)
        XCTAssertEqual(result.change?.amount, 25)
        XCTAssertNil(result.change?.percentage)
        XCTAssertNil(BalanceDayChange(opening: .nan, current: 1))
        XCTAssertNil(BalanceDayChange(opening: -1, current: 1))
    }

    func testDecimalPrecisionAndStableTimestampOrdering() async throws {
        let (db, _) = try await fixture()
        try await append(db, "12345678901234567890.123456789")
        try await append(db, "12345678901234567890.123456790")
        let result = try await day(db)
        XCTAssertEqual(result.change?.amount, Decimal(string: "0.000000001"))
        XCTAssertLessThan(try XCTUnwrap(result.opening?.id), try XCTUnwrap(result.latest?.id))
    }

    func testIdempotentRetryAndConflictingPayloadRollback() async throws {
        let (db, _) = try await fixture(), event = UUID()
        let first = try await db.appendBalanceSnapshot(walletID: "w1", currency: "USD", total: 10, complete: true, reason: .refresh, eventID: event)
        let retry = try await db.appendBalanceSnapshot(walletID: "w1", currency: "USD", total: 10, complete: true, reason: .refresh, eventID: event)
        XCTAssertEqual(first, retry)
        do {
            try await db.appendBalanceSnapshot(walletID: "w2", currency: "USD", total: 20, complete: true, reason: .refresh, eventID: event)
            XCTFail("Conflicting identity accepted")
        } catch { XCTAssertEqual(error as? StoreError, .conflictingIdentity) }
        let entries = try await db.balanceHistory(walletID: "w1", currency: "USD")
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.total, 10)
    }

    func testCurrentSnapshotReadsCommittedBalancesPricesAndSelectedCurrency() async throws {
        let (db, _) = try await fixture()
        let now = Date().timeIntervalSince1970
        try await db.savePrices([.init(assetID: "btc", currency: "USD", value: "100", observedAt: now, source: "fixture")])
        try await db.saveBalances([.init(accountID: "account-w1", assetID: "btc", networkID: "bitcoin", amountAtomic: "200000000", observedAt: now, source: "fixture")])
        try await db.saveExchangeRates(.init(rates: ["USD": "1", "EUR": "0.9"], observedAt: now, fetchedAt: now, source: "fixture"))
        try await db.setSetting("currency", value: "EUR")
        let current = try await db.recordCurrentBalance(walletID: "w1", currency: "USD", reason: .homeVisit)
        XCTAssertEqual(current?.currency, "EUR")
        XCTAssertEqual(current?.total, 180)
        XCTAssertEqual(current?.valuationComplete, true)
        try await db.setSetting("currency", value: "USD")
        let next = try await db.recordCurrentBalance(walletID: "w1", currency: "EUR", reason: .refresh)
        XCTAssertEqual(next?.currency, "USD")
        XCTAssertEqual(next?.total, 200)
        let euros = try await db.balanceHistory(walletID: "w1", currency: "EUR")
        XCTAssertEqual(euros.count, 1, "Currency changes must not overwrite history")
    }

    func testLiveObservationPublishesCommittedHistory() async throws {
        let (db, _) = try await fixture()
        let changed = expectation(description: "Observed new daily balance")
        let task = Task {
            for try await value in db.observeBalanceDay(walletID: "w1", currency: "USD", interval: interval) {
                if value.change?.amount == 8 { changed.fulfill(); return }
            }
        }
        try await append(db, "100")
        try await append(db, "108", time: 1_200)
        await fulfillment(of: [changed], timeout: 5)
        task.cancel()
        try await task.value
    }

    func testRemovalAndResetPreventLateWritesAndEraseHistory() async throws {
        let (db, _) = try await fixture()
        try await append(db, "100")
        try await append(db, "200", wallet: "w2")
        try await db.reconcileWalletLifecycle([.init(id: "w1", deletedAt: 100)])
        let blocked = try await db.recordCurrentBalance(walletID: "w1", currency: "USD", reason: .refresh)
        XCTAssertNil(blocked)
        let hidden = try await day(db)
        XCTAssertNil(hidden.change)
        try await db.reconcileWalletLifecycle([.init(id: "w1", deletedAt: nil)])
        let restored = try await db.balanceHistory(walletID: "w1", currency: "USD")
        XCTAssertEqual(restored.count, 1)
        try await db.deleteWalletMetadata("w1")
        let count = try await db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM balanceSnapshots") }
        XCTAssertEqual(count, 1)
        let reset = try await db.beginWalletReset()
        let late = try await db.recordCurrentBalance(walletID: "w2", currency: "USD", reason: .appOpen)
        XCTAssertNil(late)
        try await db.eraseWalletData(resetID: reset)
        try await db.finishWalletReset(resetID: reset)
        let remaining = try await db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM balanceSnapshots") }
        XCTAssertEqual(remaining, 0)
    }

    func testMigrationPreservesExistingWalletAndIndexesBothQueries() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("BalanceUpgrade-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("wallet.sqlite"), old = try DatabaseQueue(path: url.path)
        try Schema.migrator.migrate(old, upTo: "v48_evm_send")
        try await old.write { sql in
            try sql.execute(sql: "INSERT INTO wallets(id,name,kind,vaultReference,createdAt,backedUp) VALUES('old','Old','hd','fixture',1,0)")
        }
        try old.close()
        let db = try await OathDatabase.open(at: url)
        try await db.appendBalanceSnapshot(walletID: "old", currency: "USD", total: 100, complete: true, reason: .appOpen)
        let wallets = try await db.wallets()
        XCTAssertEqual(wallets.map(\.id), ["old"])
        let plans = try await db.pool.read { sql in
            try ["AND comparisonReady=1 ORDER BY recordedAt,id", "ORDER BY recordedAt DESC,id DESC"].map { suffix in
                try Row.fetchAll(sql, sql: "EXPLAIN QUERY PLAN SELECT * FROM balanceSnapshots WHERE walletID='old' AND currency='USD' AND recordedAt>=0 AND recordedAt<9999999999 \(suffix) LIMIT 1")
                    .map { $0["detail"] as String }.joined(separator: " ")
            }
        }
        XCTAssertTrue(plans[0].contains("balance_snapshots_comparison_day"), plans[0])
        XCTAssertTrue(plans[1].contains("balance_snapshots_day"), plans[1])
        XCTAssertTrue(plans.allSatisfy { !$0.contains("TEMP B-TREE") })
    }

    func testLocalCalendarBoundariesAndDaylightSaving() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Hebron"))
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-14T21:30:00Z"))
        let day = BalanceDaySummary.interval(containing: date, calendar: calendar)
        XCTAssertEqual(calendar.component(.day, from: day.start), 15)
        XCTAssertEqual(calendar.component(.hour, from: day.start), 0)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let spring = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-03-08T12:00:00Z"))
        let fall = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-01T12:00:00Z"))
        XCTAssertEqual(BalanceDaySummary.interval(containing: spring, calendar: calendar).duration, 23 * 3600)
        XCTAssertEqual(BalanceDaySummary.interval(containing: fall, calendar: calendar).duration, 25 * 3600)
    }

    func testInvalidValuesAndBoundedReads() async throws {
        let (db, _) = try await fixture()
        for amount in [Decimal.nan, -1] {
            do {
                try await db.appendBalanceSnapshot(walletID: "w1", currency: "USD", total: amount, complete: true, reason: .refresh)
                XCTFail("Invalid amount accepted")
            } catch { }
        }
        for currency in ["usd", "US", "US$"] {
            do { try await append(db, "1", currency: currency); XCTFail("Invalid currency accepted") } catch { }
        }
        for value in [0, 501] {
            do { _ = try await db.balanceHistory(walletID: "w1", currency: "USD", limit: value); XCTFail("Unbounded read accepted") } catch { }
        }
        try await append(db, "1"); try await append(db, "2")
        let limited = try await db.balanceHistory(walletID: "w1", currency: "USD", limit: 1)
        XCTAssertEqual(limited.map(\.total), [2])
    }

    func testDisplayedTotalWithMissingChainAndPriceUsesSettledBaselineAndSurvivesReopen() async throws {
        let (db, url) = try await fixture()
        try await db.setSetting("currency", value: "USD")
        try await db.seed(networks: [
            .init(id: "ethereum", name: "Ethereum", family: "evm", symbol: "ETH", decimals: 18, derivationPath: "test", logo: "eth", sortOrder: 1),
            .init(id: "near", name: "Near", family: "account", symbol: "NEAR", decimals: 24, derivationPath: "test", logo: "near", sortOrder: 2)
        ], assets: [
            .init(id: "eth", networkID: "ethereum", reference: "native", name: "Ethereum", symbol: "ETH", decimals: 18),
            .init(id: "unpriced", networkID: "ethereum", reference: "0x1111111111111111111111111111111111111111", name: "Unpriced", symbol: "TEST", decimals: 18),
            .init(id: "near", networkID: "near", reference: "native", name: "Near", symbol: "NEAR", decimals: 24)
        ])
        try await db.pool.write { sql in
            for network in ["ethereum", "near"] {
                try AccountRecord(id: network, walletID: "w1", networkID: network, address: "fixture", derivationPath: "test").insert(sql)
            }
        }
        let today = BalanceDaySummary.interval(containing: Date())
        func currentDay(_ database: OathDatabase) async throws -> BalanceDaySummary {
            try await database.balanceDay(walletID: "w1", currency: "USD", interval: today)
        }
        let loading = try await db.recordCurrentBalance(walletID: "w1", currency: "USD", reason: .appOpen)
        XCTAssertEqual(loading?.comparisonReady, false)
        let time = Date().timeIntervalSince1970
        try await db.savePrices([
            .init(assetID: "btc", currency: "USD", value: "100", observedAt: time, source: "fixture"),
            .init(assetID: "eth", currency: "USD", value: "5", observedAt: time, source: "fixture")
        ])
        try await db.saveBalances([
            .init(accountID: "account-w1", assetID: "btc", networkID: "bitcoin", amountAtomic: "40000000", observedAt: time, source: "fixture"),
            .init(accountID: "ethereum", assetID: "eth", networkID: "ethereum", amountAtomic: "0", observedAt: time, source: "fixture"),
            .init(accountID: "ethereum", assetID: "unpriced", networkID: "ethereum", amountAtomic: "1000000000000000000", observedAt: time, source: "fixture")
        ])
        let partial = try await db.recordCurrentBalance(walletID: "w1", currency: "USD", reason: .balanceUpdate)
        XCTAssertEqual(partial?.total, 40); XCTAssertEqual(partial?.comparisonReady, false)
        let initial = try await currentDay(db)
        XCTAssertNil(initial.change, "Initial loading must not become a false daily gain")
        try await db.saveBalances([.init(accountID: "account-w1", assetID: "btc", networkID: "bitcoin", amountAtomic: "100000000", observedAt: time + 1, source: "fixture")])
        let baseline = try await db.recordCurrentBalance(walletID: "w1", currency: "USD", reason: .balanceUpdate, settled: true)
        XCTAssertEqual(baseline?.total, 100); XCTAssertEqual(baseline?.valuationComplete, false)
        XCTAssertEqual(baseline?.comparisonReady, true)
        let assets = try XCTUnwrap(baseline?.assets())
        XCTAssertEqual(assets.count, 4)
        XCTAssertEqual(assets.first { $0.assetID == "btc" }?.fiatValue, "100")
        XCTAssertEqual(assets.first { $0.assetID == "unpriced" }?.amountAtomic, "1000000000000000000")
        XCTAssertNil(assets.first { $0.assetID == "unpriced" }?.usdPrice)
        XCTAssertNil(assets.first { $0.assetID == "near" }?.amountAtomic)

        // A received coin adds $5. Other chains/tokens still have unknown values.
        try await db.saveBalances([.init(accountID: "ethereum", assetID: "eth", networkID: "ethereum", amountAtomic: "1000000000000000000", observedAt: time + 2, source: "fixture")])
        let displayed = try await db.snapshot(walletID: "w1", currency: "USD")
        let beforeWrite = try await currentDay(db)
        XCTAssertEqual(beforeWrite.change(current: displayed.totalFiat)?.amount, 5)
        XCTAssertEqual(beforeWrite.change(current: displayed.totalFiat)?.percentage, 5)
        try await db.recordCurrentBalance(walletID: "w1", currency: "USD", reason: .balanceUpdate)
        let received = try await currentDay(db)
        XCTAssertEqual(received.change?.amount, 5); XCTAssertEqual(received.change?.percentage, 5)

        let reopened = try await OathDatabase.open(at: url)
        try await reopened.recordCurrentBalance(walletID: "w1", currency: "USD", reason: .appOpen)
        try await reopened.savePrices([.init(assetID: "eth", currency: "USD", value: "3", observedAt: time + 3, source: "fixture")])
        try await reopened.recordCurrentBalance(walletID: "w1", currency: "USD", reason: .refresh)
        let repriced = try await currentDay(reopened)
        XCTAssertEqual(repriced.opening?.total, 100)
        XCTAssertEqual(repriced.latest?.total, 103)
        XCTAssertEqual(repriced.change?.amount, 3); XCTAssertEqual(repriced.change?.percentage, 3)
        XCTAssertNil(repriced.opening?.holdingsJSON, "Daily observation must not load asset payloads")
        let history = try await reopened.balanceHistory(walletID: "w1", currency: "USD")
        XCTAssertEqual(history.count, 6)
        XCTAssertEqual(try history.first?.assets()?.first { $0.assetID == "eth" }?.usdPrice, "3")
        XCTAssertEqual(try history.first { $0.id == baseline?.id }?.assets(), assets, "Saved snapshots must not change when prices change")
    }

    func testPartialBaselineCurrencyChangesAndZeroTotalsStayComparable() async throws {
        let (db, _) = try await fixture()
        let time = Date().timeIntervalSince1970
        try await db.saveBalances([.init(accountID: "account-w1", assetID: "btc", networkID: "bitcoin", amountAtomic: "100000000", observedAt: time, source: "fixture")])
        try await db.savePrices([.init(assetID: "btc", currency: "USD", value: "100", observedAt: time, source: "fixture")])
        try await db.setSetting("currency", value: "USD")
        try await db.recordCurrentBalance(walletID: "w1", currency: "USD", reason: .balanceUpdate, settled: true)
        try await db.saveExchangeRates(.init(rates: ["USD": "1", "EUR": "0.9"], observedAt: time, fetchedAt: time, source: "fixture"))
        try await db.setSetting("currency", value: "EUR")
        let euro = try await db.recordCurrentBalance(walletID: "w1", currency: "USD", reason: .homeVisit)
        XCTAssertEqual(euro?.currency, "EUR"); XCTAssertEqual(euro?.total, 90); XCTAssertEqual(euro?.comparisonReady, true)
        try await db.saveBalances([.init(accountID: "account-w1", assetID: "btc", networkID: "bitcoin", amountAtomic: "0", observedAt: time + 1, source: "fixture")])
        try await db.recordCurrentBalance(walletID: "w1", currency: "EUR", reason: .balanceUpdate)
        let zero = try await db.balanceDay(walletID: "w1", currency: "EUR", interval: BalanceDaySummary.interval(containing: Date()))
        XCTAssertEqual(zero.change?.amount, -90); XCTAssertEqual(zero.change?.percentage, -100)
        XCTAssertEqual(BalanceDayChange(opening: 0, current: 0)?.percentage, 0)
        XCTAssertNil(BalanceDayChange(opening: 0, current: 10)?.percentage)
    }

    func testOneCalendarYearRetentionKeepsEveryEventAndUsesIndex() async throws {
        let (db, url) = try await fixture()
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2025-02-28T12:00:00Z"))
        let cutoff = try XCTUnwrap(ISO8601DateFormatter().date(from: "2024-02-28T12:00:00Z"))
        try await append(db, "10", time: cutoff.timeIntervalSince1970 - 1)
        try await append(db, "20", time: cutoff.timeIntervalSince1970)
        try await append(db, "30", time: cutoff.timeIntervalSince1970 + 1, wallet: "w2")
        for _ in 0..<550 { try await append(db, "40", time: now.timeIntervalSince1970) }
        let rows = try await db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM balanceSnapshots") }
        XCTAssertEqual(rows, 552, "Retain full events, not only a capped or daily list")
        let oldest = try await db.pool.read { try Double.fetchOne($0, sql: "SELECT MIN(recordedAt) FROM balanceSnapshots") }
        XCTAssertEqual(oldest, cutoff.timeIntervalSince1970)
        let reopened = try await OathDatabase.open(at: url)
        try await reopened.pruneBalanceHistory(now: now.addingTimeInterval(2))
        let remaining = try await reopened.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM balanceSnapshots") }
        XCTAssertEqual(remaining, 550)
        let plan = try await db.pool.read { try Row.fetchAll($0, sql: "EXPLAIN QUERY PLAN DELETE FROM balanceSnapshots WHERE recordedAt<1").map { $0["detail"] as String }.joined(separator: " ") }
        XCTAssertTrue(plan.contains("balance_snapshots_retention"), plan)
    }

    func testSelectablePeriodsUseOnlyRetainedSnapshots() async throws {
        let (db, url) = try await fixture()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-24T01:00:00Z"))
        let old = try XCTUnwrap(ISO8601DateFormatter().date(from: "2020-01-01T01:00:00Z"))
        try await append(db, "10", time: old.timeIntervalSince1970)
        // Incomplete discovery must not become All's baseline.
        try await append(db, "0", time: old.timeIntervalSince1970 - 1, complete: false)
        let periods: [BalanceHistoryPeriod] = [.year, .sixMonths, .month, .week, .today]
        for (index, period) in periods.enumerated() {
            let time = period.interval(containing: now, calendar: calendar).start.addingTimeInterval(3600)
            try await append(db, String(20 + index * 10), time: time.timeIntervalSince1970)
        }
        try await append(db, "999", time: now.timeIntervalSince1970, wallet: "w2")
        try await append(db, "777", time: now.timeIntervalSince1970, currency: "EUR")
        let reopened = try await OathDatabase.open(at: url)
        for (period, opening) in zip(BalanceHistoryPeriod.allCases, [50, 40, 30, 20, 20, 20]) {
            let summary = try await reopened.balanceDay(walletID: "w1", currency: "USD",
                interval: period.interval(containing: now, calendar: calendar))
            XCTAssertEqual(summary.opening?.total, Decimal(opening), period.rawValue)
            XCTAssertEqual(summary.latest?.total, 60, period.rawValue)
            XCTAssertEqual(summary.change?.amount, Decimal(60 - opening), period.rawValue)
        }
        let absent = try await reopened.balanceDay(walletID: "w1", currency: "GBP",
            interval: BalanceHistoryPeriod.all.interval(containing: now, calendar: calendar))
        XCTAssertNil(absent.change(current: 65), "Do not borrow another currency's opening")
    }

    func testWeekAndLongerPeriodsUseThreeDaysOfAvailableSnapshots() async throws {
        let (db, _) = try await fixture()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-24T12:00:00Z"))
        let first = now.addingTimeInterval(-3 * 86400)
        try await append(db, "100", time: first.timeIntervalSince1970)
        try await append(db, "110", time: now.addingTimeInterval(-86400).timeIntervalSince1970)
        try await append(db, "125", time: now.timeIntervalSince1970)
        for period in [BalanceHistoryPeriod.week, .month, .sixMonths, .year, .all] {
            let summary = try await db.balanceDay(walletID: "w1", currency: "USD",
                interval: period.interval(containing: now, calendar: calendar))
            XCTAssertEqual(summary.opening?.recordedAt, first.timeIntervalSince1970, period.rawValue)
            XCTAssertEqual(summary.latest?.recordedAt, now.timeIntervalSince1970, period.rawValue)
            XCTAssertEqual(summary.change?.amount, 25, period.rawValue)
            XCTAssertEqual(summary.change?.percentage, 25, period.rawValue)
        }
        let today = try await db.balanceDay(walletID: "w1", currency: "USD",
            interval: BalanceHistoryPeriod.today.interval(containing: now, calendar: calendar))
        XCTAssertEqual(today.change?.amount, 15, "Include the first transfer after the day boundary")
    }

    func testPeriodCalendarArithmeticAndEmptyHistory() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2024-03-31T16:00:00Z"))
        let today = calendar.startOfDay(for: now)
        XCTAssertEqual(BalanceHistoryPeriod.today.interval(containing: now, calendar: calendar),
            BalanceDaySummary.interval(containing: now, calendar: calendar))
        let month = BalanceHistoryPeriod.month.interval(containing: now, calendar: calendar)
        XCTAssertEqual(calendar.component(.day, from: month.start), 29, "Clamp to leap February")
        XCTAssertEqual(month.start, calendar.date(byAdding: .month, value: -1, to: today))
        XCTAssertEqual(BalanceHistoryPeriod.sixMonths.interval(containing: now, calendar: calendar).start,
            calendar.date(byAdding: .month, value: -6, to: today))
        XCTAssertEqual(BalanceHistoryPeriod.year.interval(containing: now, calendar: calendar).start,
            calendar.date(byAdding: .year, value: -1, to: today))
        XCTAssertEqual(BalanceHistoryPeriod.week.interval(containing: now, calendar: calendar).start,
            calendar.date(byAdding: .day, value: -7, to: today))
        let (db, _) = try await fixture()
        for period in BalanceHistoryPeriod.allCases {
            let summary = try await db.balanceDay(walletID: "w1", currency: "USD",
                interval: period.interval(containing: now, calendar: calendar))
            XCTAssertNil(summary.change(current: 100), "No fabricated return for an unrecorded period")
        }
    }

    func testZeroLabelUsesCurrencyAndPercentageDisplayPrecision() throws {
        let locale = Locale(identifier: "en_US")
        let zero = try XCTUnwrap(BalanceDayChange(opening: 100, current: 100))
        XCTAssertTrue(zero.isZeroAtDisplayPrecision(currency: "USD", locale: locale))
        let tiny = try XCTUnwrap(BalanceDayChange(opening: 100, current: Decimal(string: "100.001")!))
        XCTAssertTrue(tiny.isZeroAtDisplayPrecision(currency: "USD", locale: locale))
        XCTAssertFalse(tiny.isZeroAtDisplayPrecision(currency: "KWD", locale: locale))
        let negative = try XCTUnwrap(BalanceDayChange(opening: 100, current: Decimal(string: "99.999")!))
        XCTAssertTrue(negative.isZeroAtDisplayPrecision(currency: "USD", locale: locale))
        let nonzeroPercent = try XCTUnwrap(BalanceDayChange(opening: Decimal(string: "0.001")!, current: Decimal(string: "0.002")!))
        XCTAssertFalse(nonzeroPercent.isZeroAtDisplayPrecision(currency: "USD", locale: locale))
        let gain = try XCTUnwrap(BalanceDayChange(opening: 100, current: 101))
        XCTAssertFalse(gain.isZeroAtDisplayPrecision(currency: "USD", locale: locale))
    }

    func testUpgradeKeepsLegacySnapshotsWithoutInventingAssetDetails() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("BalanceLegacy-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("wallet.sqlite"), old = try DatabaseQueue(path: url.path)
        try Schema.migrator.migrate(old, upTo: "v53_thorchain_sending")
        try await old.write { sql in
            try sql.execute(sql: "INSERT INTO wallets(id,name,kind,vaultReference,createdAt,backedUp) VALUES('w1','Test','hd','fixture',1,0)")
            for complete in [false, true] {
                try sql.execute(sql: "INSERT INTO balanceSnapshots(eventID,walletID,currency,amount,valuationComplete,recordedAt,reason) VALUES(?,'w1','USD','100',?,1100,'refresh')", arguments: [UUID().uuidString, complete])
            }
        }
        try old.close()
        let db = try await OathDatabase.open(at: url)
        let history = try await db.balanceHistory(walletID: "w1", currency: "USD")
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(history.map(\.comparisonReady), [true, false])
        XCTAssertNil(try history[0].assets())
        let summary = try await day(db)
        XCTAssertEqual(summary.change?.amount, 0)
    }

    func testUpgradeDuringPendingResetDoesNotTripTheSnapshotWriteFence() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("BalanceResetUpgrade-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("wallet.sqlite"), old = try DatabaseQueue(path: url.path)
        try Schema.migrator.migrate(old, upTo: "v53_thorchain_sending")
        try await old.write { sql in
            try sql.execute(sql: "INSERT INTO wallets(id,name,kind,vaultReference,createdAt,backedUp) VALUES('w1','Test','hd','fixture',1,0)")
            try sql.execute(sql: "INSERT INTO balanceSnapshots(eventID,walletID,currency,amount,valuationComplete,recordedAt,reason) VALUES(?,'w1','USD','100',1,1100,'refresh')", arguments: [UUID().uuidString])
            try sql.execute(sql: "INSERT INTO metadata(key,value) VALUES('walletReset','fixture')")
        }
        try old.close()
        let db = try await OathDatabase.open(at: url)
        let history = try await db.balanceHistory(walletID: "w1", currency: "USD")
        XCTAssertTrue(history.isEmpty)
        let ignored = try await db.recordCurrentBalance(walletID: "w1", currency: "USD", reason: .appOpen)
        XCTAssertNil(ignored)
    }
    func testSettledEmptyWalletReceiveAndSendUpdateEveryRangeBeforeHistoryWrite() async throws {
        let (db, _) = try await fixture()
        let time = Date().timeIntervalSince1970
        // The second chain has not answered. A measured empty account is still
        // valid evidence once initial refresh has settled.
        try await db.pool.write { sql in
            try AccountRecord(id: "unknown", walletID: "w1", networkID: "bitcoin", address: "unknown-fixture", derivationPath: "test").insert(sql)
        }
        try await db.saveBalances([.init(accountID: "account-w1", assetID: "btc", networkID: "bitcoin", amountAtomic: "0", observedAt: time, source: "fixture")])
        let baseline = try await db.recordCurrentBalance(walletID: "w1", currency: "USD", reason: .balanceUpdate, settled: true)
        XCTAssertEqual(baseline?.comparisonReady, true)
        XCTAssertEqual(baseline?.total, 0)
        XCTAssertEqual(baseline?.valuationComplete, false)
        try await db.savePrices([.init(assetID: "btc", currency: "USD", value: "100", observedAt: time, source: "fixture")])
        for (index, amount) in ["100000000", "60000000", "0"].enumerated() {
            try await db.saveBalances([.init(accountID: "account-w1", assetID: "btc", networkID: "bitcoin", amountAtomic: amount, observedAt: time + Double(index + 1), source: "fixture")])
            let portfolio = try await db.snapshot(walletID: "w1", currency: "USD")
            for period in BalanceHistoryPeriod.allCases {
                let summary = try await db.balanceDay(walletID: "w1", currency: "USD", interval: period.interval(containing: Date()))
                let change = summary.change(current: portfolio.totalFiat, currency: portfolio.currency, exchangeRate: portfolio.displayExchangeRate)
                XCTAssertEqual(change?.amount, [100, 60, 0][index], period.rawValue)
                XCTAssertEqual(summary.opening?.id, baseline?.id, period.rawValue)
            }
        }
    }

    func testEveryRangeConvertsItsOriginalBaselineConcurrentlyWithoutNewSnapshots() async throws {
        let (db, url) = try await fixture()
        let now = Date(), time = now.timeIntervalSince1970
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        try await db.saveExchangeRates(.init(rates: ["USD": "1", "CAD": "1.4", "EUR": "0.9"], observedAt: time, fetchedAt: time, source: "fixture"))
        for (index, period) in [BalanceHistoryPeriod.year, .sixMonths, .month, .week, .today].enumerated() {
            // A snapshot exactly at the boundary is usable even after a switch.
            try await append(db, String(10 + index * 10), time: period.interval(containing: now, calendar: calendar).start.timeIntervalSince1970)
        }
        try await append(db, "100", time: time)
        let before = try await db.balanceHistory(walletID: "w1", currency: "USD")
        let reopened = try await OathDatabase.open(at: url)
        for currency in ["CAD", "EUR", "USD", "CAD"] {
            try await reopened.selectDisplayCurrency(currency)
            let rate: Decimal = currency == "CAD" ? Decimal(string: "1.4")! : currency == "EUR" ? Decimal(string: "0.9")! : 1
            let values = try await withThrowingTaskGroup(of: BalanceDaySummary.self) { group in
                for period in BalanceHistoryPeriod.allCases {
                    let interval = period.interval(containing: now, calendar: calendar)
                    group.addTask { try await reopened.balanceDay(walletID: "w1", currency: currency, interval: interval) }
                }
                var values: [BalanceDaySummary] = []
                for try await value in group { values.append(value) }
                return values
            }
            for summary in values {
                let openingUSD = try XCTUnwrap(summary.opening?.usdAmount.flatMap { Decimal(string: $0) })
                XCTAssertEqual(summary.change?.amount, (100 - openingUSD) * rate)
                XCTAssertEqual(summary.change?.percentage, (100 - openingUSD) / openingUSD * 100)
                // A view can convert its previous summary synchronously before
                // the replacement database observer emits the new currency.
                let previous = try await reopened.balanceDay(walletID: "w1", currency: "USD", interval: summary.interval)
                XCTAssertEqual(previous.change(current: 100 * rate, currency: currency, exchangeRate: rate), summary.change)
                let sent = previous.change(current: openingUSD * rate / 2, currency: currency, exchangeRate: rate)
                XCTAssertEqual(sent?.amount, -openingUSD * rate / 2)
                XCTAssertEqual(sent?.percentage, -50)
                XCTAssertNil(summary.opening?.holdingsJSON)
            }
        }
        let after = try await reopened.balanceHistory(walletID: "w1", currency: "USD")
        XCTAssertEqual(before, after, "Currency selection must not rewrite the original events")
    }

    func testCurrencySwitchDoesNotTurnRateUpdatesIntoTransfers() async throws {
        let (db, _) = try await fixture()
        let time = Date().timeIntervalSince1970
        try await db.saveExchangeRates(.init(rates: ["USD": "1", "CAD": "1.4"], observedAt: time, fetchedAt: time, source: "fixture"))
        try await append(db, "140", time: time, currency: "CAD")
        try await append(db, "154", time: time + 1, currency: "CAD")
        try await db.saveExchangeRates(.init(rates: ["USD": "1", "CAD": "1.5"], observedAt: time + 2, fetchedAt: time + 2, source: "fixture"))
        let result = try await db.balanceDay(walletID: "w1", currency: "CAD", interval: BalanceHistoryPeriod.all.interval(containing: Date()))
        XCTAssertEqual(result.opening?.total, 150)
        XCTAssertEqual(result.latest?.total, 165)
        XCTAssertEqual(result.change?.amount, 15)
        XCTAssertEqual(result.change?.percentage, 10)
    }

    func testUpgradeUsesSavedExchangeRateAndBackfillsWhenRatesArriveLater() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("BalanceCurrencyUpgrade-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("wallet.sqlite")
        var configuration = Configuration()
        configuration.prepareDatabase { sql in sql.add(function: HistorySafety.metadataFunction) }
        let old = try DatabaseQueue(path: url.path, configuration: configuration)
        try Schema.migrator.migrate(old, upTo: "v77_preserve_evm_history_receipts")
        try await old.write { sql in
            try sql.execute(sql: "INSERT INTO wallets(id,name,kind,vaultReference,createdAt,backedUp) VALUES('w1','Test','hd','fixture',1,0)")
            let asset = BalanceSnapshotAsset(.catalogPreview(account: .init(id: "a", walletID: "w1", networkID: "bitcoin", address: "fixture", derivationPath: "test"), address: "fixture", assetID: "btc", reference: "native", name: "Bitcoin", symbol: "BTC", logo: nil))
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(asset)) as? [String: Any])
            object["exchangeRate"] = "1.4"
            let data = try JSONSerialization.data(withJSONObject: [object])
            try sql.execute(sql: "INSERT INTO balanceSnapshots(eventID,walletID,currency,amount,valuationComplete,comparisonReady,holdingsJSON,recordedAt,reason) VALUES(?,'w1','CAD','140',1,1,?,1100,'refresh')", arguments: [UUID().uuidString, data])
            try sql.execute(sql: "INSERT INTO balanceSnapshots(eventID,walletID,currency,amount,valuationComplete,comparisonReady,recordedAt,reason) VALUES(?,'w1','EUR','99',1,1,1200,'refresh')", arguments: [UUID().uuidString])
        }
        try old.close()
        let db = try await OathDatabase.open(at: url)
        var summary = try await day(db)
        XCTAssertEqual(summary.opening?.total, 100)
        let time = Date().timeIntervalSince1970
        try await db.saveExchangeRates(.init(rates: ["USD": "1", "CAD": "1.5", "EUR": "0.9"], observedAt: time, fetchedAt: time, source: "fixture"))
        summary = try await day(db)
        XCTAssertEqual(summary.opening?.total, 100, "Historical saved rate wins over the new table")
        XCTAssertEqual(summary.latest?.total, 110)
        XCTAssertEqual(summary.change?.amount, 10)
    }

}
