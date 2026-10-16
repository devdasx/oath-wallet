import Foundation
import GRDB

/// Fiat units per one USD. Decimal strings preserve the provider's precision.
/// This public market data is separate from wallets and survives wallet changes.
public struct USDExchangeRates: Sendable, Equatable {
    public let rates: [String: String]
    public let observedAt: Double
    public let fetchedAt: Double
    public let source: String

    public init(rates: [String: String], observedAt: Double, fetchedAt: Double, source: String) {
        self.rates = rates; self.observedAt = observedAt; self.fetchedAt = fetchedAt; self.source = source
    }

    public func isFresh(at date: Date) -> Bool {
        let now = date.timeIntervalSince1970
        // Retry yesterday's delayed publication hourly, otherwise once per UTC
        // day. A clock rollback must not pin the cache indefinitely.
        return fetchedAt <= now + 300 && now < max(observedAt + 90_000, fetchedAt + 3_600)
    }

    public func rate(for currency: String) -> Decimal? {
        if currency == "USD" { return 1 }
        guard let text = rates[currency] else { return nil }
        return Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))
    }
}

/// Display arithmetic only; never used to build a transaction amount.
public enum FiatConversion {
    public static func multiply(_ lhs: Decimal, _ rhs: Decimal) -> Decimal? {
        var lhs = lhs, rhs = rhs, result = Decimal()
        switch NSDecimalMultiply(&result, &lhs, &rhs, .plain) {
        case .noError, .lossOfPrecision: return result.isNaN ? nil : result
        default: return nil
        }
    }
}

extension OathDatabase {
    public func exchangeRates() async throws -> USDExchangeRates? {
        try await pool.read { try Self.exchangeRates($0) }
    }

    public func observeExchangeRates() -> AsyncThrowingStream<USDExchangeRates?, Error> {
        stream { try Self.exchangeRates($0) }
    }

    static func exchangeRates(_ db: Database) throws -> USDExchangeRates? {
        guard let metadata = try Row.fetchOne(db, sql: "SELECT * FROM exchangeRateMetadata WHERE base='USD'") else { return nil }
        let rows = try Row.fetchAll(db, sql: "SELECT currency,unitsPerUSD FROM exchangeRates")
        let rates = Dictionary(uniqueKeysWithValues: rows.map { ($0["currency"] as String, $0["unitsPerUSD"] as String) })
        return USDExchangeRates(rates: rates, observedAt: metadata["observedAt"],
                                fetchedAt: metadata["fetchedAt"], source: metadata["source"])
    }

    /// The complete table and its timestamps become visible in one commit.
    /// Invalid, older or interrupted fetches never replace the working cache.
    public func saveExchangeRates(_ snapshot: USDExchangeRates) async throws {
        guard !snapshot.rates.isEmpty, snapshot.rates.count <= 300,
              snapshot.observedAt.isFinite, snapshot.fetchedAt.isFinite,
              snapshot.observedAt > 0, snapshot.fetchedAt >= snapshot.observedAt,
              !snapshot.source.isEmpty, snapshot.source.count <= 200,
              snapshot.rates["USD"].flatMap({ Decimal(string: $0, locale: Locale(identifier: "en_US_POSIX")) }) == 1
        else { throw StoreError.invalidValue("USD exchange rates") }
        for (code, rate) in snapshot.rates {
            try Validation.currency(code); try Validation.price(rate)
            guard let value = Decimal(string: rate, locale: Locale(identifier: "en_US_POSIX")), value > 0 else {
                throw StoreError.invalidValue("exchange rate")
            }
        }
        try await pool.write { db in
            // Publication time determines the version. The device's fetch
            // clock can move backwards; it must not prevent revalidation.
            if let current = try Self.exchangeRates(db), current.observedAt > snapshot.observedAt {
                throw StoreError.staleSync
            }
            try db.execute(sql: "DELETE FROM exchangeRates")
            for (code, rate) in snapshot.rates {
                try db.execute(sql: "INSERT INTO exchangeRates(currency,unitsPerUSD) VALUES(?,?)", arguments: [code, rate])
            }
            try db.execute(sql: """
                INSERT INTO exchangeRateMetadata(base,observedAt,fetchedAt,source) VALUES('USD',?,?,?)
                ON CONFLICT(base) DO UPDATE SET observedAt=excluded.observedAt,fetchedAt=excluded.fetchedAt,source=excluded.source
                """, arguments: [snapshot.observedAt, snapshot.fetchedAt, snapshot.source])
        }
    }

    /// UI selection is a local transaction, never a network request.
    public func selectDisplayCurrency(_ code: String) async throws {
        try Validation.currency(code)
        try await pool.write { db in
            if code != "USD", try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM exchangeRates WHERE currency=?)", arguments: [code]) != true {
                throw StoreError.missingRecord
            }
            try SettingRecord(key: "currency", value: code, updatedAt: Date().timeIntervalSince1970).save(db)
        }
    }
}
