import Foundation
import GRDB

public enum BalanceSnapshotReason: String, Codable, Sendable {
    case homeVisit, appOpen, refresh, balanceUpdate
}

/// Local-only valuation evidence. Unknown quantities/prices stay unknown rather
/// than being stored as zero; no keys, credentials or wallet names are included.
public struct BalanceSnapshotAsset: Codable, Equatable, Sendable {
    public let accountID: String
    public let assetID: String
    public let networkID: String
    public let reference: String
    public let symbol: String
    public let decimals: Int
    public let amountAtomic: String?
    public let usdPrice: String?
    public let exchangeRate: String?
    public let fiatValue: String?
    public let balanceObservedAt: Double?
    public let priceObservedAt: Double?

    init(_ holding: Holding) {
        accountID = holding.accountID; assetID = holding.assetID
        networkID = holding.networkID; reference = holding.reference
        symbol = holding.symbol; decimals = holding.decimals
        amountAtomic = holding.amountAtomic; usdPrice = holding.usdPrice
        exchangeRate = holding.exchangeRate
        fiatValue = holding.fiatDisplayValue.map { NSDecimalNumber(decimal: $0).stringValue }
        balanceObservedAt = holding.balanceObservedAt; priceObservedAt = holding.priceObservedAt
    }
}

/// Exact display valuation at an event, never a transaction/signing amount.
public struct BalanceSnapshotRecord: Decodable, FetchableRecord, Equatable, Sendable, Identifiable {
    public let id: Int64
    public let eventID: String
    public let walletID: String
    public let currency: String
    public let amount: String
    public let valuationComplete: Bool
    public let comparisonReady: Bool
    public let holdingsJSON: Data?
    public let recordedAt: Double
    public let reason: BalanceSnapshotReason

    public var total: Decimal? { Decimal(string: amount, locale: Locale(identifier: "en_US_POSIX")) }

    /// Older entries contain only the total and intentionally return nil.
    public func assets() throws -> [BalanceSnapshotAsset]? {
        try holdingsJSON.map { try JSONDecoder().decode([BalanceSnapshotAsset].self, from: $0) }
    }
}

public struct BalanceDayChange: Equatable, Sendable {
    public let amount: Decimal
    /// Percentage points, e.g. 2.5 means 2.5%. Undefined for a zero opening balance.
    public let percentage: Decimal?

    public init?(opening: Decimal, current: Decimal) {
        guard !opening.isNaN, !current.isNaN, opening >= 0, current >= 0 else { return nil }
        var current = current, opening = opening, difference = Decimal()
        let subtraction = NSDecimalSubtract(&difference, &current, &opening, .plain)
        guard subtraction == .noError || subtraction == .lossOfPrecision, !difference.isNaN else { return nil }
        amount = difference
        if opening == 0 { percentage = current == 0 ? 0 : nil; return }
        var ratio = Decimal()
        let division = NSDecimalDivide(&ratio, &difference, &opening, .plain)
        percentage = division == .noError || division == .lossOfPrecision ? FiatConversion.multiply(ratio, 100) : nil
    }
}

public struct BalanceDaySummary: Equatable, Sendable {
    public let walletID: String
    public let currency: String
    public let interval: DateInterval
    public let opening: BalanceSnapshotRecord?
    public let latest: BalanceSnapshotRecord?

    public var change: BalanceDayChange? {
        // Initial discovery is excluded. Thereafter compare the same displayed
        // total as Home even if another token has no market price.
        guard let opening, let latest, opening.comparisonReady, latest.comparisonReady,
              let first = opening.total, let last = latest.total else { return nil }
        return BalanceDayChange(opening: first, current: last)
    }

    /// The label updates with Home immediately, while persistence is coalesced.
    public func change(current: Decimal) -> BalanceDayChange? {
        guard let opening, opening.comparisonReady, let first = opening.total else { return nil }
        return BalanceDayChange(opening: first, current: current)
    }

    /// Calendar boundaries account for the device's timezone and 23/25-hour days.
    public static func interval(containing date: Date, calendar: Calendar = .autoupdatingCurrent) -> DateInterval {
        calendar.dateInterval(of: .day, for: date) ?? DateInterval(start: date, duration: 0)
    }
}

extension OathDatabase {
    /// Read the actual committed balance and append it in the same transaction.
    /// Provider progress cannot race an old UI snapshot into the end of the list.
    @discardableResult
    public func recordCurrentBalance(walletID: String, currency: String, reason: BalanceSnapshotReason,
                                     eventID: UUID = UUID(), settled: Bool = false) async throws -> BalanceSnapshotRecord? {
        try Validation.currency(currency)
        return try await pool.write { db in
            guard try Self.canRecordBalance(db, walletID: walletID) else { return nil }
            if let previous = try BalanceSnapshotRecord.fetchOne(db, sql: "SELECT * FROM balanceSnapshots WHERE eventID=?",
                                                                 arguments: [eventID.uuidString]) {
                guard previous.walletID == walletID, previous.reason == reason else { throw StoreError.conflictingIdentity }
                return previous
            }
            let snapshot = try Self.snapshot(db, walletID: walletID, currency: currency)
            // Establish the first baseline after the initial refresh settles,
            // including partial provider failures. Future visits/refreshes keep
            // this durable readiness; unrelated missing prices cannot disable it.
            let hadBaseline = try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM balanceSnapshots WHERE walletID=? AND comparisonReady=1)
                """, arguments: [walletID]) == true
            let hasValue = snapshot.valuationComplete || snapshot.totalFiat > 0
            let ready = hadBaseline || (settled && hasValue)
            let assets = snapshot.holdings.map(BalanceSnapshotAsset.init)
            return try Self.appendBalance(db, walletID: walletID, currency: snapshot.currency,
                total: snapshot.totalFiat, complete: snapshot.valuationComplete, ready: ready,
                holdings: try JSONEncoder().encode(assets), reason: reason,
                eventID: eventID, date: Date())
        }
    }

    /// Append-only history. Identical amounts from different events are retained.
    /// Supplying the same event ID makes a retry idempotent without altering a row.
    @discardableResult
    public func appendBalanceSnapshot(walletID: String, currency: String, total: Decimal, complete: Bool,
                                      reason: BalanceSnapshotReason, eventID: UUID = UUID(),
                                      date: Date = Date(), comparisonReady: Bool? = nil) async throws -> BalanceSnapshotRecord? {
        try await pool.write { db in
            guard try Self.canRecordBalance(db, walletID: walletID) else { return nil }
            return try Self.appendBalance(db, walletID: walletID, currency: currency, total: total,
                complete: complete, ready: comparisonReady ?? complete, holdings: nil,
                reason: reason, eventID: eventID, date: date)
        }
    }

    private static func canRecordBalance(_ db: Database, walletID: String) throws -> Bool {
        // Expected teardown races are not failures and must not recreate erased data.
        try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM wallets WHERE id=? AND deletedAt IS NULL)
                AND NOT EXISTS(SELECT 1 FROM metadata WHERE key='walletReset')
            """, arguments: [walletID]) == true
    }

    private static func appendBalance(_ db: Database, walletID: String, currency: String, total: Decimal,
                                      complete: Bool, ready: Bool, holdings: Data?, reason: BalanceSnapshotReason, eventID: UUID,
                                      date: Date) throws -> BalanceSnapshotRecord {
        try Validation.currency(currency)
        guard !total.isNaN, total >= 0, date.timeIntervalSince1970.isFinite, date.timeIntervalSince1970 >= 0 else {
            throw StoreError.invalidValue("balance snapshot")
        }
        try pruneBalanceHistory(db, now: date)
        let amount = NSDecimalNumber(decimal: total).stringValue
        try db.execute(sql: """
            INSERT INTO balanceSnapshots(eventID,walletID,currency,amount,valuationComplete,comparisonReady,holdingsJSON,recordedAt,reason)
            VALUES(?,?,?,?,?,?,?,?,?) ON CONFLICT(eventID) DO NOTHING
            """, arguments: [eventID.uuidString, walletID, currency, amount, complete, ready, holdings, date.timeIntervalSince1970, reason.rawValue])
        guard let record = try BalanceSnapshotRecord.fetchOne(db, sql: "SELECT * FROM balanceSnapshots WHERE eventID=?",
                                                              arguments: [eventID.uuidString]) else { throw StoreError.missingRecord }
        guard record.walletID == walletID, record.currency == currency, record.amount == amount,
              record.valuationComplete == complete, record.comparisonReady == ready,
              record.holdingsJSON == holdings, record.reason == reason else { throw StoreError.conflictingIdentity }
        return record
    }

    /// Rolling calendar year, including leap years. The timestamp index avoids
    /// scanning retained rows; deletion runs on GRDB's writer, never the UI actor.
    public func pruneBalanceHistory(now: Date = Date()) async throws {
        try await pool.write { try Self.pruneBalanceHistory($0, now: now) }
    }

    private static func pruneBalanceHistory(_ db: Database, now: Date) throws {
        guard now.timeIntervalSince1970.isFinite else { throw StoreError.invalidValue("balance retention date") }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let cutoff = calendar.date(byAdding: .year, value: -1, to: now) else { throw StoreError.invalidValue("balance retention date") }
        try db.execute(sql: "DELETE FROM balanceSnapshots WHERE recordedAt<?", arguments: [cutoff.timeIntervalSince1970])
    }

    /// Bounded reads; the full history stays on disk, not in Home's view state.
    public func balanceHistory(walletID: String, currency: String, limit: Int = 100) async throws -> [BalanceSnapshotRecord] {
        try Validation.currency(currency)
        guard (1...500).contains(limit) else { throw StoreError.invalidValue("balance history limit") }
        return try await pool.read { db in
            guard try Self.canRecordBalance(db, walletID: walletID) else { return [] }
            return try BalanceSnapshotRecord.fetchAll(db, sql: """
                SELECT * FROM balanceSnapshots WHERE walletID=? AND currency=? ORDER BY recordedAt DESC,id DESC LIMIT ?
                """, arguments: [walletID, currency, limit])
        }
    }

    public func balanceDay(walletID: String, currency: String, interval: DateInterval) async throws -> BalanceDaySummary {
        try await pool.read { try Self.balanceDay($0, walletID: walletID, currency: currency, interval: interval) }
    }

    public func observeBalanceDay(walletID: String, currency: String, interval: DateInterval) -> AsyncThrowingStream<BalanceDaySummary, Error> {
        stream { try Self.balanceDay($0, walletID: walletID, currency: currency, interval: interval) }
    }

    private static func balanceDay(_ db: Database, walletID: String, currency: String,
                                   interval: DateInterval) throws -> BalanceDaySummary {
        try Validation.currency(currency)
        guard interval.start.timeIntervalSince1970.isFinite, interval.end.timeIntervalSince1970.isFinite,
              interval.duration > 0 else { throw StoreError.invalidValue("balance day") }
        var opening: BalanceSnapshotRecord?, latest: BalanceSnapshotRecord?
        if try canRecordBalance(db, walletID: walletID) {
            let arguments: StatementArguments = [walletID, currency, interval.start.timeIntervalSince1970, interval.end.timeIntervalSince1970]
            // Daily observations need only two small headers, not a year of
            // holdings payloads. Full details remain available through history.
            let columns = "id,eventID,walletID,currency,amount,valuationComplete,comparisonReady,recordedAt,reason"
            opening = try BalanceSnapshotRecord.fetchOne(db, sql: """
                SELECT \(columns) FROM balanceSnapshots WHERE walletID=? AND currency=? AND recordedAt>=? AND recordedAt<?
                AND comparisonReady=1 ORDER BY recordedAt,id LIMIT 1
                """, arguments: arguments)
            latest = try BalanceSnapshotRecord.fetchOne(db, sql: """
                SELECT \(columns) FROM balanceSnapshots WHERE walletID=? AND currency=? AND recordedAt>=? AND recordedAt<?
                ORDER BY recordedAt DESC,id DESC LIMIT 1
                """, arguments: arguments)
        }
        return BalanceDaySummary(walletID: walletID, currency: currency, interval: interval, opening: opening, latest: latest)
    }
}
