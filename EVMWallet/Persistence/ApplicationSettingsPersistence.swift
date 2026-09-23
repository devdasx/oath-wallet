import Foundation
import GRDB

enum WalletApplicationSettingsWriteResult: String, Equatable, Sendable {
    case persisted
    case skippedResetInProgress = "skipped_reset_in_progress"
    case skippedStaleGeneration = "skipped_stale_generation"
}

extension WalletDatabase {
    func applicationSettingsSynchronously() throws
        -> WalletApplicationSettings {
        try pool.read { database in
            let record = try DBUserSettingsRecord.fetchOne(
                database,
                key: Self.defaultProfileID
            )
            let preferences = Dictionary(
                uniqueKeysWithValues: try DBPreferenceRecord
                    .filter(Column("profileID") == Self.defaultProfileID)
                    .fetchAll(database)
                    .map { ($0.key, $0) }
            )
            return Self.applicationSettings(
                record: record,
                preferences: preferences
            )
        }
    }

    func saveApplicationSettings(
        _ settings: WalletApplicationSettings
    ) async throws {
        let generation = applicationSettingsPersistenceGeneration()
        _ = try await saveApplicationSettings(
            settings,
            expectedGeneration: generation
        )
    }

    func saveApplicationSettings(
        _ settings: WalletApplicationSettings,
        expectedGeneration: UInt64
    ) async throws -> WalletApplicationSettingsWriteResult {
        let initialGate = applicationSettingsWriteGate(
            expectedGeneration: expectedGeneration
        )
        guard initialGate == .allowed else {
            return Self.settingsWriteResult(for: initialGate)
        }

        return try await pool.write { database in
            let transactionGate = self.applicationSettingsWriteGate(
                expectedGeneration: expectedGeneration
            )
            guard transactionGate == .allowed else {
                return Self.settingsWriteResult(for: transactionGate)
            }

            let now = Date().timeIntervalSince1970
            var record = try DBUserSettingsRecord.fetchOne(
                database,
                key: Self.defaultProfileID
            ) ?? Self.defaultUserSettingsRecord(updatedAt: now)
            record.appearance = settings.appearance.rawValue
            record.languageIdentifier = settings.languageIdentifier
            record.currencyCode = settings.currencyCode
            record.currencyRatePerUSD = settings.currencyRateStorageValue
            record.balancePrivacyEnabled = settings.balancePrivacyEnabled
            record.notificationsEnabled = settings.notificationsEnabled
            record.receivedTransactionNotificationsEnabled =
                settings.receivedTransactionNotificationsEnabled
            record.sentTransactionNotificationsEnabled =
                settings.sentTransactionNotificationsEnabled
            record.adminNotificationsEnabled =
                settings.adminNotificationsEnabled
            record.updatedAt = now
            try record.save(database)

            try DBPreferenceRecord(
                profileID: Self.defaultProfileID,
                key: UniHapticEngine.preferenceKey,
                valueType: "bool",
                value: settings.hapticFeedbackEnabled ? "true" : "false",
                updatedAt: now
            ).save(database)
            try DBPreferenceRecord(
                profileID: Self.defaultProfileID,
                key: Self.assetVisibilityPreferenceKey,
                valueType: "string",
                value: settings.assetVisibilityPreferencesJSON,
                updatedAt: now
            ).save(database)
            try DBPreferenceRecord(
                profileID: Self.defaultProfileID,
                key: Self.sendAmountEntryModePreferenceKey,
                valueType: "string",
                value: settings.sendAmountEntryMode.rawValue,
                updatedAt: now
            ).save(database)
            try DBPreferenceRecord(
                profileID: Self.defaultProfileID,
                key: Self.currencyConverterHomeShortcutPreferenceKey,
                valueType: "bool",
                value: settings.currencyConverterHomeShortcutEnabled
                    ? "true"
                    : "false",
                updatedAt: now
            ).save(database)
            try DBPreferenceRecord(
                profileID: Self.defaultProfileID,
                key: Self.notificationWelcomePresentedPreferenceKey,
                valueType: "bool",
                value: settings.notificationWelcomeWasPresented
                    ? "true"
                    : "false",
                updatedAt: now
            ).save(database)
            try DBPreferenceRecord(
                profileID: Self.defaultProfileID,
                key: Self.notificationsExplicitlyDisabledPreferenceKey,
                valueType: "bool",
                value: settings.notificationsWereExplicitlyDisabled
                    ? "true"
                    : "false",
                updatedAt: now
            ).save(database)
            try DBPreferenceRecord(
                profileID: Self.defaultProfileID,
                key: Self.lastPresentedWhatsNewVersionPreferenceKey,
                valueType: "string",
                value: settings.lastPresentedWhatsNewVersion ?? "",
                updatedAt: now
            ).save(database)
            return .persisted
        }
    }

    private static func settingsWriteResult(
        for gate: WalletApplicationSettingsWriteGate
    ) -> WalletApplicationSettingsWriteResult {
        switch gate {
        case .allowed:
            .persisted
        case .resetInProgress:
            .skippedResetInProgress
        case .staleGeneration:
            .skippedStaleGeneration
        }
    }
}


extension WalletDatabase {
    static let assetVisibilityPreferenceKey =
        "wallet.assetVisibilityPreferences"
    static let sendAmountEntryModePreferenceKey =
        "send.amountEntryMode"
    static let currencyConverterHomeShortcutPreferenceKey =
        "tools.currencyConverter.homeShortcutEnabled"
    static let notificationWelcomePresentedPreferenceKey =
        "notifications.welcomeWasPresented"
    static let notificationsExplicitlyDisabledPreferenceKey =
        "notifications.explicitlyDisabled"
    static let lastPresentedWhatsNewVersionPreferenceKey =
        "app.whatsNew.lastPresentedVersion"

    static func applicationSettings(
        record: DBUserSettingsRecord?,
        preferences: [String: DBPreferenceRecord]
    ) -> WalletApplicationSettings {
        let defaults = WalletApplicationSettings.default
        let appearance = record
            .flatMap { WalletAppearancePreference(rawValue: $0.appearance) }
            ?? defaults.appearance
        let languageIdentifier = record.map(\.languageIdentifier)
            .flatMap {
                WalletAppLanguage.supportedIdentifiers.contains($0)
                    ? $0
                    : nil
            }
            ?? defaults.languageIdentifier
        let rawCurrencyCode = record?.currencyCode.uppercased()
            ?? defaults.currencyCode
        let currencyCode = rawCurrencyCode.count == 3
                && rawCurrencyCode.allSatisfy({
                    $0.isASCII && $0.isLetter
                })
            ? rawCurrencyCode
            : defaults.currencyCode
        let rawRate = record?.currencyRatePerUSD
            ?? defaults.currencyRateStorageValue
        let parsedRate = Decimal(
            string: rawRate,
            locale: Locale(identifier: "en_US_POSIX")
        )
        let currencyRateStorageValue = if currencyCode
            == WalletCurrencyPreference.defaultCode {
            WalletCurrencyPreference.defaultRateStorageValue
        } else if let parsedRate, parsedRate > 0 {
            WalletCurrencyPreference.rateStorageValue(for: parsedRate)
        } else {
            defaults.currencyRateStorageValue
        }
        let storedVisibility = preferences[
            assetVisibilityPreferenceKey
        ]?.value
        let assetVisibilityPreferencesJSON =
            storedVisibility.flatMap(validJSONObject) ?? "{}"
        let sendAmountEntryMode = preferences[
            sendAmountEntryModePreferenceKey
        ].flatMap {
            SendAmountEntryMode(rawValue: $0.value)
        } ?? defaults.sendAmountEntryMode
        let currencyConverterHomeShortcutEnabled = preferences[
            currencyConverterHomeShortcutPreferenceKey
        ].map {
            ($0.value as NSString).boolValue
        } ?? defaults.currencyConverterHomeShortcutEnabled
        let hapticFeedbackEnabled = preferences[
            UniHapticEngine.preferenceKey
        ].map {
            ($0.value as NSString).boolValue
        } ?? defaults.hapticFeedbackEnabled
        let notificationWelcomeWasPresented = preferences[
            notificationWelcomePresentedPreferenceKey
        ].map {
            ($0.value as NSString).boolValue
        } ?? defaults.notificationWelcomeWasPresented
        let notificationsEnabled = record?.notificationsEnabled
            ?? defaults.notificationsEnabled
        let notificationsWereExplicitlyDisabled = preferences[
            notificationsExplicitlyDisabledPreferenceKey
        ].map {
            ($0.value as NSString).boolValue
        } ?? (
            notificationWelcomeWasPresented && !notificationsEnabled
        )
        let lastPresentedWhatsNewVersion = AppReleaseVersion.normalized(
            preferences[lastPresentedWhatsNewVersionPreferenceKey]?.value
        )

        return WalletApplicationSettings(
            appearance: appearance,
            languageIdentifier: languageIdentifier,
            currencyCode: currencyCode,
            currencyRateStorageValue: currencyRateStorageValue,
            balancePrivacyEnabled: record?.balancePrivacyEnabled
                ?? defaults.balancePrivacyEnabled,
            assetVisibilityPreferencesJSON:
                assetVisibilityPreferencesJSON,
            sendAmountEntryMode: sendAmountEntryMode,
            currencyConverterHomeShortcutEnabled:
                currencyConverterHomeShortcutEnabled,
            hapticFeedbackEnabled: hapticFeedbackEnabled,
            notificationsEnabled: notificationsEnabled,
            receivedTransactionNotificationsEnabled:
                record?.receivedTransactionNotificationsEnabled
                    ?? defaults.receivedTransactionNotificationsEnabled,
            sentTransactionNotificationsEnabled:
                record?.sentTransactionNotificationsEnabled
                    ?? defaults.sentTransactionNotificationsEnabled,
            adminNotificationsEnabled:
                record?.adminNotificationsEnabled
                    ?? defaults.adminNotificationsEnabled,
            notificationWelcomeWasPresented:
                notificationWelcomeWasPresented,
            notificationsWereExplicitlyDisabled:
                notificationsWereExplicitlyDisabled,
            lastPresentedWhatsNewVersion:
                lastPresentedWhatsNewVersion
        )
    }

    static func defaultUserSettingsRecord(
        updatedAt: Double,
        settings: WalletApplicationSettings = .default
    ) -> DBUserSettingsRecord {
        return DBUserSettingsRecord(
            profileID: defaultProfileID,
            appearance: settings.appearance.rawValue,
            languageIdentifier: settings.languageIdentifier,
            currencyCode: settings.currencyCode,
            currencyRatePerUSD: settings.currencyRateStorageValue,
            balancePrivacyEnabled: settings.balancePrivacyEnabled,
            appLockEnabled: false,
            biometricEnabled: false,
            autoLockSeconds: 60,
            privacyShieldEnabled: false,
            notificationsEnabled: false,
            updateNotificationsEnabled: false,
            priceNotificationsEnabled: false,
            transferNotificationsEnabled: false,
            receivedTransactionNotificationsEnabled:
                settings.receivedTransactionNotificationsEnabled,
            sentTransactionNotificationsEnabled:
                settings.sentTransactionNotificationsEnabled,
            adminNotificationsEnabled:
                settings.adminNotificationsEnabled,
            analyticsEnabled: false,
            updatedAt: updatedAt
        )
    }

    private static func validJSONObject(_ value: String) -> String? {
        guard let data = value.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              object is [String: Any]
        else {
            return nil
        }
        return value
    }
}
