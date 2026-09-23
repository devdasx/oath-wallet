import Foundation
import GRDB
import UIKit

struct PushNotificationRegistrationRepository: Sendable {
    let database: WalletDatabase

    func prepareInstallationIdentity(
        installationID: String,
        remoteUserID: String,
        forceRemoteUserRotation: Bool = false
    ) async throws {
        _ = try await notificationProfile(
            installationID: installationID,
            remoteUserID: remoteUserID,
            forceRemoteUserRotation: forceRemoteUserRotation
        )
    }

    func compatibleRemoteUserID(
        installationID: String,
        allowsUnboundProfile: Bool
    ) async -> String? {
        try? await database.pool.read { database in
            guard let profile =
                try DBNotificationProfileRecord.fetchOne(
                    database,
                    key: WalletDatabase.defaultProfileID
                ),
                UUID(uuidString: profile.remoteUserID) != nil,
                profile.installationID == installationID
                    || (
                        allowsUnboundProfile
                            && profile.installationID == nil
                    )
            else {
                return nil
            }
            return profile.remoteUserID
        }
    }

    @MainActor
    func snapshot(
        identity: PushInstallationIdentity,
        apnsEnvironment: String,
        forceRemoteUserRotation: Bool = false
    ) async throws -> PushInstallationSnapshotRequest {
        guard let apnsToken = identity.apnsToken,
              (16...128).contains(apnsToken.count) else {
            throw PushNotificationRegistrationRepositoryError
                .missingAPNSToken
        }
        guard let remoteUserID = identity.remoteUserID,
              UUID(uuidString: remoteUserID) != nil else {
            throw PushNotificationRegistrationRepositoryError
                .missingRemoteUserID
        }

        let profile = try await notificationProfile(
            installationID: identity.installationID,
            remoteUserID: remoteUserID,
            forceRemoteUserRotation: forceRemoteUserRotation
        )
        let snapshot = try await database.pool.read { database in
            let settings = try DBUserSettingsRecord.fetchOne(
                database,
                key: WalletDatabase.defaultProfileID
            )
            let rows = try Row.fetchAll(
                database,
                sql: """
                SELECT
                    wallet.id AS walletID,
                    wallet.name AS walletName,
                    wallet.kind AS walletKind,
                    wallet.isSelected AS walletIsSelected,
                    wallet.notificationsEnabledWhenInactive
                        AS notificationsEnabledWhenInactive,
                    account.id AS accountID,
                    account.address AS address,
                    network.id AS networkID,
                    network.chainID AS chainID
                FROM wallets AS wallet
                JOIN walletAccounts AS account
                  ON account.walletID = wallet.id
                JOIN networks AS network
                  ON network.id = account.networkID
                WHERE wallet.profileID = ?
                  AND wallet.archivedAt IS NULL
                  AND account.isEnabled = 1
                  AND network.isMainnet = 1
                  AND network.isEnabled = 1
                ORDER BY
                    wallet.sortOrder,
                    wallet.createdAt,
                    network.sortOrder,
                    account.createdAt
                """,
                arguments: [WalletDatabase.defaultProfileID]
            )
            let solanaMonitorRows = try Row.fetchAll(
                database,
                sql: """
                SELECT
                    state.accountID,
                    state.address
                FROM solanaSyncState AS state
                JOIN walletAccounts AS account
                  ON account.id = state.accountID
                JOIN wallets AS wallet
                  ON wallet.id = account.walletID
                WHERE wallet.profileID = ?
                  AND wallet.archivedAt IS NULL
                  AND account.isEnabled = 1
                ORDER BY state.accountID, state.address
                """,
                arguments: [WalletDatabase.defaultProfileID]
            )
            let bitcoinImportedMonitorRows = try Row.fetchAll(
                database,
                sql: """
                SELECT
                    account.id AS accountID,
                    imported.publicAddress AS publicAddress
                FROM bitcoinImportedAddresses AS imported
                JOIN wallets AS wallet
                  ON wallet.id = imported.walletID
                JOIN walletAccounts AS account
                  ON account.walletID = wallet.id
                 AND account.derivationPath = ?
                JOIN networks AS network
                  ON network.id = account.networkID
                WHERE wallet.profileID = ?
                  AND wallet.archivedAt IS NULL
                  AND account.isEnabled = 1
                  AND network.isMainnet = 1
                  AND network.isEnabled = 1
                ORDER BY
                    account.id,
                    imported.sourceIndex,
                    imported.branch,
                    imported.addressIndex
                """,
                arguments: [
                    BitcoinImportedWalletMaterial.accountMarker,
                    WalletDatabase.defaultProfileID
                ]
            )
            return (
                preferences: Self.preferences(from: settings),
                currency: Self.currencySettings(from: settings),
                wallets: Self.wallets(
                    from: rows,
                    solanaMonitorRows: solanaMonitorRows,
                    bitcoinImportedMonitorRows:
                        bitcoinImportedMonitorRows
                )
            )
        }

        let appVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "0"

        return PushInstallationSnapshotRequest(
            remoteUserID: profile.remoteUserID,
            installationID: identity.installationID,
            apnsToken: apnsToken.hexadecimalString,
            environment: apnsEnvironment,
            locale: Self.serviceLocale,
            currencyCode: snapshot.currency.code,
            currencyRatePerUSDBase10: snapshot.currency.rate,
            appVersion: appVersion,
            osVersion: UIDevice.current.systemVersion,
            deviceModel: UIDevice.current.model,
            preferences: snapshot.preferences,
            wallets: snapshot.wallets
        )
    }

    func markRegistrationAttempt() async throws -> Int64 {
        let profile = try await notificationProfile()
        return try await database.pool.write { database in
            var updated = profile
            let now = Date().timeIntervalSince1970
            updated.reconciliationNeeded = true
            updated.reconciliationGeneration += 1
            updated.lastRegistrationAttemptAt = now
            updated.updatedAt = now
            try updated.update(database)
            return updated.reconciliationGeneration
        }
    }

    func markRegistrationSucceeded(
        snapshotDigest: String,
        installationID: String,
        reconciliationGeneration: Int64
    ) async throws -> Bool {
        try await database.pool.write { database in
            let now = Date().timeIntervalSince1970
            try database.execute(
                sql: """
                UPDATE notificationProfiles
                SET reconciliationNeeded = 0,
                    lastSnapshotDigest = ?,
                    lastRegistrationSuccessAt = ?,
                    lastRegistrationErrorCode = NULL,
                    updatedAt = ?
                WHERE profileID = ?
                  AND installationID = ?
                  AND reconciliationGeneration = ?
                """,
                arguments: [
                    snapshotDigest,
                    now,
                    now,
                    WalletDatabase.defaultProfileID,
                    installationID,
                    reconciliationGeneration
                ]
            )
            return database.changesCount == 1
        }
    }

    func markRegistrationFailed(
        errorCode: String,
        installationID: String?,
        reconciliationGeneration: Int64?
    ) async throws {
        guard let installationID,
              let reconciliationGeneration else {
            return
        }
        try await database.pool.write { database in
            let now = Date().timeIntervalSince1970
            try database.execute(
                sql: """
                UPDATE notificationProfiles
                SET reconciliationNeeded = 1,
                    lastRegistrationErrorCode = ?,
                    updatedAt = ?
                WHERE profileID = ?
                  AND installationID = ?
                  AND reconciliationGeneration = ?
                """,
                arguments: [
                    Self.sanitized(errorCode),
                    now,
                    WalletDatabase.defaultProfileID,
                    installationID,
                    reconciliationGeneration
                ]
            )
        }
    }

    func markReconciliationNeeded() async throws {
        let profile = try await notificationProfile()
        try await database.pool.write { database in
            var updated = profile
            updated.reconciliationNeeded = true
            updated.reconciliationGeneration += 1
            updated.updatedAt = Date().timeIntervalSince1970
            try updated.update(database)
        }
    }

    func isReconciliationNeeded() async -> Bool {
        (try? await database.pool.read { database in
            try DBNotificationProfileRecord.fetchOne(
                database,
                key: WalletDatabase.defaultProfileID
            )?.reconciliationNeeded
        }) ?? true
    }

    func hasSuccessfulRegistration(
        installationID: String
    ) async -> Bool {
        (try? await database.pool.read { database in
            guard let profile =
                try DBNotificationProfileRecord.fetchOne(
                database,
                key: WalletDatabase.defaultProfileID
                ) else {
                return false
            }
            return profile.installationID == installationID
                && profile.lastRegistrationSuccessAt != nil
        }) ?? false
    }

    private func notificationProfile(
        installationID: String? = nil,
        remoteUserID: String? = nil,
        forceRemoteUserRotation: Bool = false
    ) async throws
        -> DBNotificationProfileRecord {
        try await database.pool.write { database in
            if var existing = try DBNotificationProfileRecord.fetchOne(
                database,
                key: WalletDatabase.defaultProfileID
            ) {
                guard let installationID else {
                    return existing
                }
                guard let remoteUserID,
                      UUID(uuidString: remoteUserID) != nil else {
                    throw PushNotificationRegistrationRepositoryError
                        .missingRemoteUserID
                }

                let isDifferentInstallation =
                    existing.installationID != nil
                    && existing.installationID != installationID
                let isUnboundMigration =
                    forceRemoteUserRotation
                    && existing.installationID != installationID
                let isDifferentRemoteUser =
                    existing.remoteUserID != remoteUserID

                if isDifferentInstallation || isUnboundMigration
                    || isDifferentRemoteUser {
                    let now = Date().timeIntervalSince1970
                    existing.remoteUserID = remoteUserID
                    existing.installationID = installationID
                    existing.reconciliationNeeded = true
                    existing.reconciliationGeneration += 1
                    existing.lastSnapshotDigest = nil
                    existing.lastRegistrationAttemptAt = nil
                    existing.lastRegistrationSuccessAt = nil
                    existing.lastRegistrationErrorCode = nil
                    existing.historyBackfillCursor = nil
                    existing.updatedAt = now
                    try existing.update(database)
                    try DBNotificationOpenAuditRecord.deleteAll(database)
                } else if existing.installationID == nil {
                    existing.installationID = installationID
                    existing.reconciliationNeeded = true
                    existing.reconciliationGeneration += 1
                    existing.updatedAt = Date().timeIntervalSince1970
                    try existing.update(database)
                }
                return existing
            }

            let now = Date().timeIntervalSince1970
            guard let remoteUserID,
                  UUID(uuidString: remoteUserID) != nil else {
                throw PushNotificationRegistrationRepositoryError
                    .missingRemoteUserID
            }
            let record = DBNotificationProfileRecord(
                profileID: WalletDatabase.defaultProfileID,
                remoteUserID: remoteUserID,
                installationID: installationID,
                reconciliationNeeded: true,
                reconciliationGeneration: 0,
                lastSnapshotDigest: nil,
                lastRegistrationAttemptAt: nil,
                lastRegistrationSuccessAt: nil,
                lastRegistrationErrorCode: nil,
                updatedAt: now
            )
            try record.insert(database)
            return record
        }
    }

    private static func preferences(
        from settings: DBUserSettingsRecord?
    ) -> PushNotificationPreferences {
        PushNotificationPreferences(
            master: settings?.notificationsEnabled ?? false,
            received:
                settings?.receivedTransactionNotificationsEnabled ?? true,
            sent:
                settings?.sentTransactionNotificationsEnabled ?? false,
            admin: settings?.adminNotificationsEnabled ?? true
        )
    }

    private static func wallets(
        from rows: [Row],
        solanaMonitorRows: [Row],
        bitcoinImportedMonitorRows: [Row]
    )
        -> [PushRegisteredWallet] {
        struct MutableWallet {
            let id: String
            let name: String
            let kind: String
            let notificationMonitoringEnabled: Bool
            var accounts: [PushRegisteredAccount]
        }

        var orderedIDs: [String] = []
        var values: [String: MutableWallet] = [:]
        let solanaMonitors = Dictionary(
            grouping: solanaMonitorRows,
            by: { row -> String in row["accountID"] }
        ).mapValues { rows in
            rows.map { row -> String in row["address"] }
        }
        let bitcoinImportedMonitors = Dictionary(
            grouping: bitcoinImportedMonitorRows,
            by: { row -> String in row["accountID"] }
        ).mapValues { rows in
            rows.compactMap { row -> String? in
                let data: Data = row["publicAddress"]
                return try? JSONDecoder()
                    .decode(BitcoinHDDerivedAddress.self, from: data)
                    .address
            }
        }

        for row in rows {
            let walletID: String = row["walletID"]
            let networkID: String = row["networkID"]
            let address: String = row["address"]
            let accountID: String = row["accountID"]
            let chainID: Int64 = row["chainID"]
            let walletIsSelected: Bool = row["walletIsSelected"]
            let notificationsEnabledWhenInactive: Bool =
                row["notificationsEnabledWhenInactive"]
            if values[walletID] == nil {
                orderedIDs.append(walletID)
                values[walletID] = MutableWallet(
                    id: walletID,
                    name: row["walletName"],
                    kind: row["walletKind"],
                    notificationMonitoringEnabled:
                        walletIsSelected
                            || notificationsEnabledWhenInactive,
                    accounts: []
                )
            }
            values[walletID]?.accounts.append(
                PushRegisteredAccount(
                    accountID: accountID,
                    networkID: networkID,
                    chainID: String(chainID),
                    monitoredAddresses: monitoredAddresses(
                        ownerAddress: address,
                        accountID: accountID,
                        networkID: networkID,
                        solanaMonitors: solanaMonitors,
                        bitcoinImportedMonitors:
                            bitcoinImportedMonitors
                    )
                )
            )
        }

        return orderedIDs.compactMap { id in
            guard let wallet = values[id] else { return nil }
            return PushRegisteredWallet(
                walletID: wallet.id,
                name: wallet.name,
                kind: wallet.kind,
                notificationMonitoringEnabled:
                    wallet.notificationMonitoringEnabled,
                accounts: wallet.accounts
            )
        }
    }

    private static func monitoredAddresses(
        ownerAddress: String,
        accountID: String,
        networkID: String,
        solanaMonitors: [String: [String]],
        bitcoinImportedMonitors: [String: [String]]
    ) -> [PushMonitoredAddress] {
        let ownerRole: String
        switch networkID {
        case "xrp", "stellar", "aptos", "sui", "near":
            ownerRole = "account_owner"
        case "solana":
            ownerRole = "solana_owner"
        case "tron":
            ownerRole = "tron_owner"
        case TONConstants.networkID:
            ownerRole = "ton_owner"
        case "bitcoin", "bitcoin_cash", "litecoin", "dogecoin":
            ownerRole = "utxo_owner"
        default:
            ownerRole = "evm_owner"
        }

        var result = [
            PushMonitoredAddress(
                address: ownerAddress,
                normalizedAddress: normalizedAddress(
                    ownerAddress,
                    networkID: networkID
                ),
                role: ownerRole
            )
        ]
        let bitcoinFamilyNetworks: Set<String> = [
            "bitcoin", "bitcoin_cash", "litecoin", "dogecoin"
        ]
        if bitcoinFamilyNetworks.contains(networkID) {
            let importedAddresses = Set(
                bitcoinImportedMonitors[accountID, default: []]
            )
            for address in importedAddresses.sorted()
            where address != ownerAddress {
                result.append(
                    PushMonitoredAddress(
                        address: address,
                        normalizedAddress: normalizedAddress(
                            address,
                            networkID: networkID
                        ),
                        role: "utxo_owner"
                    )
                )
            }
            return result
        }

        guard networkID == "solana" else { return result }

        let tokenAddresses = Set(
            solanaMonitors[accountID, default: []]
        )
        for address in tokenAddresses.sorted()
        where address != ownerAddress {
            result.append(
                PushMonitoredAddress(
                    address: address,
                    normalizedAddress: address,
                    role: "solana_token_account"
                )
            )
        }
        return result
    }

    private static func normalizedAddress(
        _ address: String,
        networkID: String
    ) -> String {
        let trimmed = address.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let caseSensitiveNetworks: Set<String> = [
            "bitcoin",
            "bitcoin_cash",
            "litecoin",
            "dogecoin",
            "solana",
            "xrp",
            "stellar",
            "tron",
            TONConstants.networkID
        ]
        return caseSensitiveNetworks.contains(networkID)
            ? trimmed
            : trimmed.lowercased()
    }

    private static var serviceLocale: String {
        let candidate = WalletRuntimePreferences.shared
            .languageIdentifier
        guard (2...35).contains(candidate.utf8.count) else {
            return "en"
        }
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "_-")
        )
        return candidate.unicodeScalars.allSatisfy(allowed.contains)
            ? candidate
            : "en"
    }

    private static func currencySettings(
        from settings: DBUserSettingsRecord?
    ) -> (code: String, rate: String) {
        let rawCode = settings?.currencyCode.uppercased()
            ?? WalletCurrencyPreference.defaultCode
        guard
            rawCode.count == 3,
            rawCode.allSatisfy({ $0.isASCII && $0.isLetter })
        else {
            return (
                WalletCurrencyPreference.defaultCode,
                WalletCurrencyPreference.defaultRateStorageValue
            )
        }
        guard rawCode != WalletCurrencyPreference.defaultCode else {
            return (
                WalletCurrencyPreference.defaultCode,
                WalletCurrencyPreference.defaultRateStorageValue
            )
        }
        let rawRate = settings?.currencyRatePerUSD ?? ""
        guard
            let rate = Decimal(
                string: rawRate,
                locale: Locale(identifier: "en_US_POSIX")
            ),
            rate > 0
        else {
            return (
                WalletCurrencyPreference.defaultCode,
                WalletCurrencyPreference.defaultRateStorageValue
            )
        }
        return (
            rawCode,
            WalletCurrencyPreference.rateStorageValue(for: rate)
        )
    }

    private static func sanitized(_ value: String) -> String {
        String(
            value.unicodeScalars
                .filter {
                    CharacterSet.alphanumerics.contains($0)
                        || $0 == "_" || $0 == "-" || $0 == "."
                }
                .prefix(160)
                .map(Character.init)
        )
    }
}

enum PushNotificationRegistrationRepositoryError: Error {
    case missingAPNSToken
    case missingRemoteUserID
}

private extension Data {
    var hexadecimalString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
