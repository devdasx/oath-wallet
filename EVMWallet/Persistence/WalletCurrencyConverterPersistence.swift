import Foundation
import GRDB

struct CurrencyConverterMarketPrice: Equatable, Sendable {
    let unitID: String
    let priceUSD: Decimal
    let provider: String
    let observedAt: Date
    let expiresAt: Date?
}

private struct DBCurrencyConverterRateRecord:
    Codable,
    FetchableRecord,
    PersistableRecord,
    Sendable
{
    static let databaseTableName = "currencyConverterRates"

    let unitID: String
    let priceUSD: String
    let provider: String
    let observedAt: Double
    let expiresAt: Double?
}

extension WalletDatabase {
    static let currencyConverterSourcePreferenceKey =
        "tools.currencyConverter.source"
    static let currencyConverterTargetPreferenceKey =
        "tools.currencyConverter.target"
    static let currencyConverterUnitIDsPreferenceKey =
        "tools.currencyConverter.units"

    static let currencyConverterLastUsedPreferenceKey =
        "tools.currencyConverter.lastUsedUnit"

    static func registerCurrencyConverterMigration(
        on migrator: inout DatabaseMigrator
    ) {
        migrator.registerMigration(
            "v57_currency_converter_rates"
        ) { database in
            try database.execute(
                sql: """
                CREATE TABLE currencyConverterRates (
                    unitID TEXT NOT NULL
                        CHECK (length(unitID) > 0),
                    priceUSD TEXT NOT NULL
                        CHECK (length(priceUSD) > 0),
                    provider TEXT NOT NULL
                        CHECK (length(provider) > 0),
                    observedAt REAL NOT NULL,
                    expiresAt REAL,
                    PRIMARY KEY(unitID, provider, observedAt)
                ) WITHOUT ROWID;

                CREATE INDEX currencyConverterRates_latest
                    ON currencyConverterRates(
                        unitID,
                        observedAt DESC
                    );
                """
            )
        }
    }

    func currencyConverterSelection() async throws
        -> CurrencyConverterSelection? {
        try await pool.read { database in
            let preferences = try DBPreferenceRecord
                .filter(Column("profileID") == Self.defaultProfileID)
                .filter([
                    Self.currencyConverterSourcePreferenceKey,
                    Self.currencyConverterTargetPreferenceKey,
                    Self.currencyConverterUnitIDsPreferenceKey,
                    Self.currencyConverterLastUsedPreferenceKey
                ].contains(Column("key")))
                .fetchAll(database)
            let values = Dictionary(
                uniqueKeysWithValues: preferences.map {
                    ($0.key, $0.value)
                }
            )
            if let savedUnitIDs = values[
                Self.currencyConverterUnitIDsPreferenceKey
            ] {
                let selection = CurrencyConverterSelection(
                    unitIDs: savedUnitIDs
                        .split(separator: "\n")
                        .map(String.init),
                    lastUsedUnitID: values[Self.currencyConverterLastUsedPreferenceKey]
                )
                if selection.unitIDs.count >= 2 {
                    return selection
                }
            }

            guard let sourceID = values[
                Self.currencyConverterSourcePreferenceKey
            ], let targetID = values[
                Self.currencyConverterTargetPreferenceKey
            ], !sourceID.isEmpty, !targetID.isEmpty,
               sourceID != targetID else {
                return nil
            }
            return CurrencyConverterSelection(
                sourceID: sourceID,
                targetID: targetID
            )
        }
    }

    func saveCurrencyConverterSelection(
        _ selection: CurrencyConverterSelection
    ) async throws {
        guard selection.unitIDs.count >= 2 else {
            return
        }
        let generation = applicationSettingsPersistenceGeneration()
        guard applicationSettingsWriteGate(
            expectedGeneration: generation
        ) == .allowed else {
            return
        }

        try await pool.write { database in
            guard self.applicationSettingsWriteGate(
                expectedGeneration: generation
            ) == .allowed else {
                return
            }
            let now = Date().timeIntervalSince1970
            try DBPreferenceRecord(
                profileID: Self.defaultProfileID,
                key: Self.currencyConverterSourcePreferenceKey,
                valueType: "string",
                value: selection.sourceID,
                updatedAt: now
            ).save(database)
            try DBPreferenceRecord(
                profileID: Self.defaultProfileID,
                key: Self.currencyConverterTargetPreferenceKey,
                valueType: "string",
                value: selection.targetID,
                updatedAt: now
            ).save(database)
            try DBPreferenceRecord(
                profileID: Self.defaultProfileID,
                key: Self.currencyConverterUnitIDsPreferenceKey,
                valueType: "string",
                value: selection.unitIDs.joined(separator: "\n"),
                updatedAt: now
            ).save(database)
            try DBPreferenceRecord(
                profileID: Self.defaultProfileID,
                key: Self.currencyConverterLastUsedPreferenceKey,
                valueType: "string",
                value: selection.lastUsedUnitID,
                updatedAt: now
            ).save(database)
        }
    }

    func saveCurrencyConverterMarketPrices(
        _ prices: [CurrencyConverterMarketPrice]
    ) async throws {
        let validPrices = prices.filter {
            !$0.unitID.isEmpty && $0.priceUSD > 0
                && !$0.provider.isEmpty
        }
        guard !validPrices.isEmpty else { return }

        let generation = applicationSettingsPersistenceGeneration()
        guard applicationSettingsWriteGate(
            expectedGeneration: generation
        ) == .allowed else {
            return
        }
        try await pool.write { database in
            guard self.applicationSettingsWriteGate(
                expectedGeneration: generation
            ) == .allowed else {
                return
            }
            for price in validPrices {
                try DBCurrencyConverterRateRecord(
                    unitID: price.unitID,
                    priceUSD: Self.storageString(price.priceUSD),
                    provider: price.provider,
                    observedAt: price.observedAt.timeIntervalSince1970,
                    expiresAt: price.expiresAt?
                        .timeIntervalSince1970
                ).save(database)
            }

            let cutoff = Date().addingTimeInterval(
                -(30 * 24 * 60 * 60)
            ).timeIntervalSince1970
            try database.execute(
                sql: """
                DELETE FROM currencyConverterRates
                WHERE observedAt < ?
                """,
                arguments: [cutoff]
            )
        }
    }

    func cachedCurrencyConverterMarketPrices(
        maximumAge: TimeInterval? = nil
    ) async throws -> [String: CurrencyConverterMarketPrice] {
        try await pool.read { database in
            let records = try DBCurrencyConverterRateRecord
                .order(Column("observedAt").desc)
                .fetchAll(database)
            let cutoff = maximumAge.map {
                Date().addingTimeInterval(-$0).timeIntervalSince1970
            }
            var resolved: [String: CurrencyConverterMarketPrice] = [:]
            for record in records where resolved[record.unitID] == nil {
                guard cutoff.map({ record.observedAt >= $0 }) ?? true,
                      let price = Decimal(
                          string: record.priceUSD,
                          locale: Locale(identifier: "en_US_POSIX")
                      ), price > 0 else {
                    continue
                }
                resolved[record.unitID] = CurrencyConverterMarketPrice(
                    unitID: record.unitID,
                    priceUSD: price,
                    provider: record.provider,
                    observedAt: Date(
                        timeIntervalSince1970: record.observedAt
                    ),
                    expiresAt: record.expiresAt.map {
                        Date(timeIntervalSince1970: $0)
                    }
                )
            }
            return resolved
        }
    }

    func currencyConverterPositiveBalanceAssets(
        walletID: String
    ) async throws -> [WalletAsset] {
        try await pool.read { database in
            let accounts = try DBWalletAccountRecord
                .filter(Column("walletID") == walletID)
                .filter(Column("isEnabled") == true)
                .fetchAll(database)
            guard !accounts.isEmpty else { return [] }

            let accountByID = Dictionary(
                uniqueKeysWithValues: accounts.map { ($0.id, $0) }
            )
            let holdings = WalletHomeHoldingProjection.unifiedHoldings(
                try DBAccountAssetRecord
                    .filter(
                        Array(accountByID.keys).contains(
                            Column("accountID")
                        )
                    )
                    .filter(Column("isEnabled") == true)
                    .fetchAll(database),
                accountByID: accountByID
            ).filter {
                guard let exactBalance = ExactDecimalText
                    .canonicalUnsigned($0.balance) else {
                    return false
                }
                return ExactDecimalText.isNonzeroUnsigned(exactBalance)
            }

            let assetIDs = Array(Set(holdings.map(\.assetID)))
            guard !assetIDs.isEmpty else { return [] }
            let assets = try DBAssetRecord
                .filter(assetIDs.contains(Column("id")))
                .fetchAll(database)
            let assetByID = Dictionary(
                uniqueKeysWithValues: assets.map { ($0.id, $0) }
            )
            let networkByID = Dictionary(
                uniqueKeysWithValues: try DBNetworkRecord
                    .filter(
                        Array(Set(assets.map(\.networkID)))
                            .contains(Column("id"))
                    )
                    .fetchAll(database)
                    .map { ($0.id, $0) }
            )

            return holdings.compactMap { holding in
                guard let asset = assetByID[holding.assetID],
                      Self.isDisplayEligibleAsset(asset),
                      let account = accountByID[holding.accountID],
                      let networkRecord = networkByID[asset.networkID],
                      let network = WalletBlockchain(
                          rawValue: networkRecord.trustWalletBlockchain
                      ),
                      let balanceText = ExactDecimalText
                          .canonicalUnsigned(holding.balance),
                      let balance = Self.decimal(balanceText),
                      balance > 0 else {
                    return nil
                }
                return WalletAsset(
                    id: asset.id,
                    name: asset.name,
                    symbol: asset.symbol,
                    logoSource: Self.logoSource(
                        asset: asset,
                        fallbackNetwork: network
                    ),
                    network: network,
                    balance: balance,
                    fiatValue: Self.decimal(
                        holding.fiatUSDValue ?? "0"
                    ) ?? 0,
                    balanceText: balanceText,
                    balanceAtomic: holding.balanceAtomic,
                    decimals: asset.decimals,
                    receiveAddress: account.address,
                    isPinned: holding.isPinned,
                    isVerified: asset.isVerified,
                    isSpam: asset.isSpam
                )
            }
            .sorted {
                if $0.fiatValue == $1.fiatValue {
                    return $0.name.localizedStandardCompare($1.name)
                        == .orderedAscending
                }
                return $0.fiatValue > $1.fiatValue
            }
        }
    }
}
