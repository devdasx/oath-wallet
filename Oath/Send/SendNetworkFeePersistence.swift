import Foundation
import GRDB

private struct DBSendFeePreference: Codable, FetchableRecord,
    PersistableRecord, Sendable {
    static let databaseTableName = "sendFeePreferences"

    let profileID: String
    var preset: String
    var updatedAt: Double
}

private struct DBSendCustomFeePreference: Codable, FetchableRecord,
    PersistableRecord, Sendable {
    static let databaseTableName = "sendCustomFeePreferences"

    let profileID: String
    let networkID: String
    var model: String
    var primaryValue: String
    var secondaryValue: String?
    var totalBudgetAtomic: String?
    var updatedAt: Double
}

struct SendCachedNativeFeeBalance: Sendable {
    let atomic: String?
    let balance: String
}

extension WalletDatabase {
    func cachedNativeFeeBalance(
        networkID: String,
        sourceAddress: String
    ) async throws -> SendCachedNativeFeeBalance? {
        try await pool.read { database in
            guard let row = try Row.fetchOne(
                database,
                sql: """
                    SELECT nativeHolding.balanceAtomic AS atomic,
                           COALESCE(nativeHolding.balance, '0') AS balance
                    FROM walletAccounts AS account
                    JOIN assets AS nativeAsset
                      ON nativeAsset.networkID = account.networkID
                     AND nativeAsset.assetType = 'native'
                     AND nativeAsset.normalizedContractAddress = ''
                    LEFT JOIN accountAssets AS nativeHolding
                      ON nativeHolding.accountID = account.id
                     AND nativeHolding.assetID = nativeAsset.id
                    WHERE account.networkID = ?
                      AND account.address = ?
                      AND account.isEnabled = 1
                    ORDER BY nativeHolding.updatedAt DESC
                    LIMIT 1
                    """,
                arguments: [networkID, sourceAddress]
            ) else { return nil }
            let atomic: String? = row["atomic"]
            let balance: String = row["balance"]
            return SendCachedNativeFeeBalance(
                atomic: atomic,
                balance: balance
            )
        }
    }
}

actor SendNetworkFeePreferenceRepository {
    private let database: WalletDatabase

    init(database: WalletDatabase) {
        self.database = database
    }

    func policy(for networkID: String) async throws
        -> SendNetworkFeePolicy {
        let result = try await database.pool.read { database in
            let preference = try DBSendFeePreference.fetchOne(
                database,
                key: WalletDatabase.defaultProfileID
            )
            let custom = try DBSendCustomFeePreference.fetchOne(
                database,
                key: [
                    "profileID": WalletDatabase.defaultProfileID,
                    "networkID": networkID
                ]
            )
            return (preference, custom)
        }
        let preset = result.0.flatMap {
            SendNetworkFeePreset(rawValue: $0.preset)
        } ?? .fastest
        guard preset == .custom,
              let record = result.1,
              let model = SendNetworkFeeCustomModel(
                rawValue: record.model
              )
        else {
            let policy = SendNetworkFeePolicy.preset(preset)
            return policy
        }
        let value = SendNetworkFeeCustomValue(
            model: model,
            primaryValue: record.primaryValue,
            secondaryValue: record.secondaryValue,
            totalBudgetAtomic: record.totalBudgetAtomic
        )
        let policy = value.isValid(for: networkID)
            ? SendNetworkFeePolicy.custom(value)
            : .fastest
        return policy
    }

    func savePreset(_ preset: SendNetworkFeePreset) async throws {
        let normalized = preset == .custom ? .fastest : preset
        guard !database.isPerformingAppReset() else { return }
        try await database.pool.write { database in
            try DBSendFeePreference(
                profileID: WalletDatabase.defaultProfileID,
                preset: normalized.rawValue,
                updatedAt: Date().timeIntervalSince1970
            ).save(database)
        }
    }

    func saveCustom(
        _ value: SendNetworkFeeCustomValue,
        for networkID: String
    ) async throws {
        guard value.isValid(for: networkID) else {
            throw SendNetworkFeeInputError.invalid
        }
        guard !database.isPerformingAppReset() else { return }
        try await database.pool.write { database in
            let now = Date().timeIntervalSince1970
            try DBSendCustomFeePreference(
                profileID: WalletDatabase.defaultProfileID,
                networkID: networkID,
                model: value.model.rawValue,
                primaryValue: value.primaryValue,
                secondaryValue: value.secondaryValue,
                totalBudgetAtomic: value.totalBudgetAtomic,
                updatedAt: now
            ).save(database)
            try DBSendFeePreference(
                profileID: WalletDatabase.defaultProfileID,
                preset: SendNetworkFeePreset.custom.rawValue,
                updatedAt: now
            ).save(database)
        }
    }
}
