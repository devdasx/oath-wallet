import Foundation
import GRDB

extension WalletDatabase {
    func saveFXRates(_ snapshot: FXRatesSnapshot) async throws {
        try await pool.write { database in
            for currency in snapshot.currencies {
                try DBFXRateRecord(
                    baseCurrency: "USD",
                    quoteCurrency: currency.code.uppercased(),
                    rate: Self.storageString(currency.ratePerUSD),
                    englishName: currency.englishName,
                    symbol: currency.symbol,
                    effectiveDate: currency.rateDate,
                    provider: "frankfurter",
                    fetchedAt: snapshot.fetchedAt.timeIntervalSince1970
                ).save(database)
            }

            let cutoff = snapshot.fetchedAt.addingTimeInterval(
                -(366 * 24 * 60 * 60)
            ).timeIntervalSince1970
            try database.execute(
                sql: "DELETE FROM fxRates WHERE fetchedAt < ?",
                arguments: [cutoff]
            )
        }
    }

    func cachedFXRates() async throws -> FXRatesSnapshot? {
        try await pool.read { database in
            guard let fetchedAt = try Double.fetchOne(
                database,
                sql: "SELECT MAX(fetchedAt) FROM fxRates WHERE baseCurrency = 'USD'"
            ) else {
                return nil
            }

            let records = try DBFXRateRecord
                .filter(Column("baseCurrency") == "USD")
                .filter(Column("fetchedAt") == fetchedAt)
                .order(Column("quoteCurrency"))
                .fetchAll(database)
            guard !records.isEmpty else { return nil }

            return FXRatesSnapshot(
                fetchedAt: Date(timeIntervalSince1970: fetchedAt),
                currencies: records.compactMap { record in
                    guard let rate = Self.decimal(record.rate) else {
                        return nil
                    }
                    return FXCurrencyRate(
                        code: record.quoteCurrency,
                        englishName: record.englishName,
                        symbol: record.symbol,
                        ratePerUSD: rate,
                        rateDate: record.effectiveDate
                    )
                }
            )
        }
    }

}
