import Foundation
import GRDB

extension WalletDatabase {
    static func latestValidUSDPriceRecord(
        assetID: String,
        maximumAge: TimeInterval? = nil,
        database: Database
    ) throws -> DBAssetPriceRecord? {
        guard let asset = try DBAssetRecord.fetchOne(
            database,
            key: assetID
        ) else { return nil }
        var request = DBAssetPriceRecord
            .filter(Column("assetID") == assetID)
            .filter(Column("quoteCurrency") == "USD")
        if let maximumAge {
            request = request.filter(
                Column("observedAt") >= Date().timeIntervalSince1970
                    - maximumAge
            )
        }
        return try request.order(Column("observedAt").desc)
            .fetchAll(database)
            .first { record in
                guard let price = decimal(record.price), price > 0 else {
                    return false
                }
                return AssetPriceClient.cachedPriceIsReusable(record, for: asset)
            }
    }

    static func cachedFiatUSDValue(
        amountText: String,
        assetID: String,
        fallback: String?,
        database: Database
    ) throws -> String? {
        let asset = try DBAssetRecord.fetchOne(database, key: assetID)
        let safeFallback = asset?.assetType == DatabaseAssetType.native.rawValue ? fallback : nil
        guard
            let record = try latestValidUSDPriceRecord(
                assetID: assetID,
                database: database
            ),
            let price = decimal(record.price)
        else { return safeFallback }
        return transactionUSDValueText(
            amountText: amountText,
            unitPrice: price
        ) ?? safeFallback
    }

}
