import Foundation
import Observation

struct WalletAppResetPreservedPreferences: Equatable, Sendable {
    let appearance: WalletAppearancePreference
    let languageIdentifier: String
    let currencyCode: String
    let currencyRateStorageValue: String
    let hapticFeedbackEnabled: Bool
    let lastPresentedWhatsNewVersion: String?
}

struct WalletApplicationSettings: Equatable, Sendable {
    var appearance: WalletAppearancePreference
    var languageIdentifier: String
    var currencyCode: String
    var currencyRateStorageValue: String
    var balancePrivacyEnabled: Bool
    var assetVisibilityPreferencesJSON: String
    var sendAmountEntryMode: SendAmountEntryMode
    var currencyConverterHomeShortcutEnabled: Bool
    var hapticFeedbackEnabled: Bool
    var notificationsEnabled: Bool
    var receivedTransactionNotificationsEnabled: Bool
    var sentTransactionNotificationsEnabled: Bool
    var adminNotificationsEnabled: Bool
    var notificationWelcomeWasPresented: Bool
    var notificationsWereExplicitlyDisabled: Bool
    var lastPresentedWhatsNewVersion: String?

    static let `default` = WalletApplicationSettings(
        appearance: .system,
        languageIdentifier: WalletAppLanguage.defaultIdentifier,
        currencyCode: WalletCurrencyPreference.defaultCode,
        currencyRateStorageValue:
            WalletCurrencyPreference.defaultRateStorageValue,
        balancePrivacyEnabled: false,
        assetVisibilityPreferencesJSON: "{}",
        sendAmountEntryMode: .asset,
        currencyConverterHomeShortcutEnabled: false,
        hapticFeedbackEnabled: true,
        notificationsEnabled: false,
        receivedTransactionNotificationsEnabled: true,
        sentTransactionNotificationsEnabled: false,
        adminNotificationsEnabled: true,
        notificationWelcomeWasPresented: false,
        notificationsWereExplicitlyDisabled: false,
        lastPresentedWhatsNewVersion: nil
    )

    var appResetPreservedPreferences:
        WalletAppResetPreservedPreferences {
        WalletAppResetPreservedPreferences(
            appearance: appearance,
            languageIdentifier: languageIdentifier,
            currencyCode: currencyCode,
            currencyRateStorageValue: currencyRateStorageValue,
            hapticFeedbackEnabled: hapticFeedbackEnabled,
            lastPresentedWhatsNewVersion:
                lastPresentedWhatsNewVersion
        )
    }

    static func resetDefaults(
        preserving preferences: WalletAppResetPreservedPreferences
    ) -> WalletApplicationSettings {
        var settings = WalletApplicationSettings.default
        settings.appearance = preferences.appearance
        settings.languageIdentifier = preferences.languageIdentifier
        settings.currencyCode = preferences.currencyCode
        settings.currencyRateStorageValue =
            preferences.currencyRateStorageValue
        settings.hapticFeedbackEnabled =
            preferences.hapticFeedbackEnabled
        settings.lastPresentedWhatsNewVersion =
            preferences.lastPresentedWhatsNewVersion
        return settings
    }
}

enum WalletFirstRunSettings {
    static var current: WalletApplicationSettings {
        resolve(
            locale: .autoupdatingCurrent,
            preferredLanguages: Locale.preferredLanguages
        )
    }

    static func resolve(
        locale: Locale,
        preferredLanguages: [String]
    ) -> WalletApplicationSettings {
        var settings = WalletApplicationSettings.default
        settings.appearance = .system
        settings.languageIdentifier = preferredLanguageIdentifier(
            locale: locale,
            preferredLanguages: preferredLanguages
        )
        settings.currencyCode = regionalCurrencyCode(locale: locale)

        // The configured app root immediately refreshes the selected
        // currency's real rate. USD remains exactly one by definition.
        settings.currencyRateStorageValue =
            WalletCurrencyPreference.defaultRateStorageValue
        return settings
    }

    private static func preferredLanguageIdentifier(
        locale: Locale,
        preferredLanguages: [String]
    ) -> String {
        let preferences = preferredLanguages + [locale.identifier]
        return Bundle.preferredLocalizations(
            from: WalletAppLanguage.supportedIdentifiers,
            forPreferences: preferences
        ).first ?? WalletAppLanguage.defaultIdentifier
    }

    static func regionalCurrencyCode(locale: Locale) -> String {
        guard let identifier = locale.currency?.identifier.uppercased(),
              identifier != "XXX",
              identifier.count == 3,
              identifier.allSatisfy({
                  $0.isASCII && $0.isLetter
              })
        else {
            return WalletCurrencyPreference.defaultCode
        }
        return identifier
    }
}

/// The single in-memory source of application preferences used by SwiftUI.
///
/// Mutations update the interface immediately, update the small runtime
/// formatting context, and are then serialized into `WalletDatabase`.
@MainActor
@Observable
final class WalletSettingsStore {
    private(set) var appearance: WalletAppearancePreference
    private(set) var languageIdentifier: String
    private(set) var currencyCode: String
    private(set) var currencyRateStorageValue: String
    private(set) var balancePrivacyEnabled: Bool
    private(set) var assetVisibilityPreferencesJSON: String
    private(set) var sendAmountEntryMode: SendAmountEntryMode
    private(set) var currencyConverterHomeShortcutEnabled: Bool
    private(set) var hapticFeedbackEnabled: Bool
    private(set) var notificationsEnabled: Bool
    private(set) var receivedTransactionNotificationsEnabled: Bool
    private(set) var sentTransactionNotificationsEnabled: Bool
    private(set) var adminNotificationsEnabled: Bool
    private(set) var notificationWelcomeWasPresented: Bool
    private(set) var notificationsWereExplicitlyDisabled: Bool
    private(set) var lastPresentedWhatsNewVersion: String?

    @ObservationIgnored
    private let database: WalletDatabase
    @ObservationIgnored
    private var persistenceTask:
        Task<WalletSettingsPersistenceResult, Never>?
    @ObservationIgnored
    private var resetDrainTask:
        Task<WalletSettingsPersistenceResult, Never>?
    @ObservationIgnored
    private var persistenceGeneration: UInt64 = 0
    @ObservationIgnored
    private var persistenceSequence: UInt64 = 0
    @ObservationIgnored
    private var isPreparingForAppReset = false
    @ObservationIgnored
    private var preparedResetPreferences:
        WalletAppResetPreservedPreferences?

    init(
        database: WalletDatabase,
        initialSettings: WalletApplicationSettings? = nil
    ) {
        let settings = initialSettings
            ?? (try? database.applicationSettingsSynchronously())
            ?? .default
        self.database = database
        appearance = settings.appearance
        languageIdentifier = settings.languageIdentifier
        currencyCode = settings.currencyCode
        currencyRateStorageValue = settings.currencyRateStorageValue
        balancePrivacyEnabled = settings.balancePrivacyEnabled
        assetVisibilityPreferencesJSON =
            settings.assetVisibilityPreferencesJSON
        sendAmountEntryMode = settings.sendAmountEntryMode
        currencyConverterHomeShortcutEnabled =
            settings.currencyConverterHomeShortcutEnabled
        hapticFeedbackEnabled = settings.hapticFeedbackEnabled
        notificationsEnabled = settings.notificationsEnabled
        receivedTransactionNotificationsEnabled =
            settings.receivedTransactionNotificationsEnabled
        sentTransactionNotificationsEnabled =
            settings.sentTransactionNotificationsEnabled
        adminNotificationsEnabled = settings.adminNotificationsEnabled
        notificationWelcomeWasPresented =
            settings.notificationWelcomeWasPresented
        notificationsWereExplicitlyDisabled =
            settings.notificationsWereExplicitlyDisabled
        lastPresentedWhatsNewVersion =
            settings.lastPresentedWhatsNewVersion
        applyRuntimeSettings(settings)
    }

    func setAppearance(_ appearance: WalletAppearancePreference) {
        guard self.appearance != appearance else { return }
        self.appearance = appearance
        persistCurrentSettings()
    }

    func setLanguageIdentifier(_ identifier: String) {
        guard WalletAppLanguage.supportedIdentifiers.contains(identifier),
              languageIdentifier != identifier
        else {
            return
        }
        languageIdentifier = identifier
        WalletRuntimePreferences.shared.setLanguageIdentifier(identifier)
        persistCurrentSettings()
    }

    func selectCurrency(code: String, ratePerUSD: Decimal) {
        let normalizedCode = Self.normalizedCurrencyCode(code)
        let normalizedRate = normalizedCode
            == WalletCurrencyPreference.defaultCode
            ? Decimal(1)
            : max(ratePerUSD, Decimal(string: "0.000000000001") ?? 1)
        let rateStorageValue = WalletCurrencyPreference.rateStorageValue(
            for: normalizedRate
        )
        guard currencyCode != normalizedCode
                || currencyRateStorageValue != rateStorageValue
        else {
            return
        }
        currencyCode = normalizedCode
        currencyRateStorageValue = rateStorageValue
        updateRuntimeCurrency()
        persistCurrentSettings()
    }

    func updateSelectedCurrencyRate(_ ratePerUSD: Decimal) {
        let normalizedRate = currencyCode
            == WalletCurrencyPreference.defaultCode
            ? Decimal(1)
            : max(ratePerUSD, Decimal(string: "0.000000000001") ?? 1)
        let rateStorageValue = WalletCurrencyPreference.rateStorageValue(
            for: normalizedRate
        )
        guard currencyRateStorageValue != rateStorageValue else { return }
        currencyRateStorageValue = rateStorageValue
        updateRuntimeCurrency()
        persistCurrentSettings()
    }

    func setBalancePrivacyEnabled(_ isEnabled: Bool) {
        guard balancePrivacyEnabled != isEnabled else { return }
        balancePrivacyEnabled = isEnabled
        persistCurrentSettings()
    }

    func toggleBalancePrivacy() {
        setBalancePrivacyEnabled(!balancePrivacyEnabled)
    }

    func setAssetVisibilityPreferencesJSON(_ json: String) {
        guard Self.isValidJSONObject(json),
              assetVisibilityPreferencesJSON != json
        else {
            return
        }
        assetVisibilityPreferencesJSON = json
        persistCurrentSettings()
    }

    func setSendAmountEntryMode(_ mode: SendAmountEntryMode) {
        guard sendAmountEntryMode != mode else { return }
        sendAmountEntryMode = mode
        persistCurrentSettings()
    }

    func setCurrencyConverterHomeShortcutEnabled(_ isEnabled: Bool) {
        guard currencyConverterHomeShortcutEnabled != isEnabled else {
            return
        }
        currencyConverterHomeShortcutEnabled = isEnabled
        persistCurrentSettings()
    }

    func setHapticFeedbackEnabled(_ isEnabled: Bool) {
        guard hapticFeedbackEnabled != isEnabled else { return }
        UniHapticEngine.shared.setEnabled(isEnabled)
        hapticFeedbackEnabled = isEnabled
        persistCurrentSettings()
    }

    func setNotificationsEnabled(_ isEnabled: Bool) {
        let explicitlyDisabled = !isEnabled
        guard notificationsEnabled != isEnabled
                || notificationsWereExplicitlyDisabled != explicitlyDisabled
        else {
            return
        }
        notificationsEnabled = isEnabled
        notificationsWereExplicitlyDisabled = explicitlyDisabled
        persistCurrentSettings()
    }

    func recordNotificationEnableIntent() {
        guard notificationsWereExplicitlyDisabled else { return }
        notificationsWereExplicitlyDisabled = false
        persistCurrentSettings()
    }

    func synchronizeNotificationsEnabledWithSystem(_ isEnabled: Bool) {
        guard notificationsEnabled != isEnabled else { return }
        notificationsEnabled = isEnabled
        persistCurrentSettings()
    }

    func setReceivedTransactionNotificationsEnabled(_ isEnabled: Bool) {
        guard receivedTransactionNotificationsEnabled != isEnabled else {
            return
        }
        receivedTransactionNotificationsEnabled = isEnabled
        persistCurrentSettings()
    }

    func setSentTransactionNotificationsEnabled(_ isEnabled: Bool) {
        guard sentTransactionNotificationsEnabled != isEnabled else {
            return
        }
        sentTransactionNotificationsEnabled = isEnabled
        persistCurrentSettings()
    }

    func setAdminNotificationsEnabled(_ isEnabled: Bool) {
        guard adminNotificationsEnabled != isEnabled else { return }
        adminNotificationsEnabled = isEnabled
        persistCurrentSettings()
    }

    func markNotificationWelcomePresented() {
        guard !notificationWelcomeWasPresented else { return }
        notificationWelcomeWasPresented = true
        persistCurrentSettings()
    }

    func markWhatsNewPresented(version: String) {
        guard let version = AppReleaseVersion.normalized(version),
              lastPresentedWhatsNewVersion != version else {
            return
        }
        lastPresentedWhatsNewVersion = version
        persistCurrentSettings()
    }

    /// Waits for every preference mutation already issued by the UI.
    @discardableResult
    func flush() async -> Bool {
        guard let persistenceTask else { return true }
        return await persistenceTask.value.isDurable
    }

    /// Captures the explicitly retained preferences, then invalidates and
    /// drains the complete serialized write chain before the reset transaction
    /// is allowed to begin.
    @discardableResult
    func prepareForAppReset() async -> WalletAppResetPreservedPreferences {
        if isPreparingForAppReset {
            _ = await resetDrainTask?.value
            return preparedResetPreferences
                ?? currentSettings.appResetPreservedPreferences
        }

        let preservedPreferences =
            currentSettings.appResetPreservedPreferences
        preparedResetPreferences = preservedPreferences
        isPreparingForAppReset = true
        persistenceGeneration &+= 1
        let pendingTask = persistenceTask
        persistenceTask = nil
        resetDrainTask = pendingTask
        pendingTask?.cancel()

        _ = await pendingTask?.value
        resetDrainTask = nil
        return preservedPreferences
    }

    /// Restores the runtime mirror from durable state if reset failed. No
    /// pre-reset snapshot is ever written back as part of recovery.
    @discardableResult
    func recoverAfterFailedAppReset() -> Bool {
        persistenceGeneration &+= 1
        persistenceTask?.cancel()
        resetDrainTask?.cancel()
        persistenceTask = nil
        resetDrainTask = nil

        do {
            let durableSettings =
                try database.applicationSettingsSynchronously()
            apply(durableSettings)
            isPreparingForAppReset = false
            preparedResetPreferences = nil
            return true
        } catch {
            return false
        }
    }

    /// Called only after the database reset transaction has installed defaults.
    func resetToDatabaseDefaults() {
        resetToDatabaseDefaults(preserving: nil)
    }

    /// Applies the same reset values installed by the atomic GRDB transaction,
    /// retaining only the preferences explicitly allowed across an app reset.
    func resetToDatabaseDefaults(
        preserving preferences: WalletAppResetPreservedPreferences
    ) {
        resetToDatabaseDefaults(preserving: Optional(preferences))
    }

    private func resetToDatabaseDefaults(
        preserving preferences: WalletAppResetPreservedPreferences?
    ) {
        persistenceGeneration &+= 1
        persistenceTask?.cancel()
        resetDrainTask?.cancel()
        persistenceTask = nil
        resetDrainTask = nil
        isPreparingForAppReset = false
        preparedResetPreferences = nil
        let resetSettings = preferences.map {
            WalletApplicationSettings.resetDefaults(preserving: $0)
        } ?? .default
        apply(resetSettings)
    }

    /// Replaces the runtime mirror after an atomic device migration restore.
    /// The supplied value has already been validated and committed to GRDB.
    func applyDeviceMigrationSettings(
        _ settings: WalletApplicationSettings
    ) {
        persistenceGeneration &+= 1
        persistenceTask?.cancel()
        resetDrainTask?.cancel()
        persistenceTask = nil
        resetDrainTask = nil
        isPreparingForAppReset = false
        apply(settings)
    }

    private var currentSettings: WalletApplicationSettings {
        WalletApplicationSettings(
            appearance: appearance,
            languageIdentifier: languageIdentifier,
            currencyCode: currencyCode,
            currencyRateStorageValue: currencyRateStorageValue,
            balancePrivacyEnabled: balancePrivacyEnabled,
            assetVisibilityPreferencesJSON: assetVisibilityPreferencesJSON,
            sendAmountEntryMode: sendAmountEntryMode,
            currencyConverterHomeShortcutEnabled:
                currencyConverterHomeShortcutEnabled,
            hapticFeedbackEnabled: hapticFeedbackEnabled,
            notificationsEnabled: notificationsEnabled,
            receivedTransactionNotificationsEnabled:
                receivedTransactionNotificationsEnabled,
            sentTransactionNotificationsEnabled:
                sentTransactionNotificationsEnabled,
            adminNotificationsEnabled: adminNotificationsEnabled,
            notificationWelcomeWasPresented:
                notificationWelcomeWasPresented,
            notificationsWereExplicitlyDisabled:
                notificationsWereExplicitlyDisabled,
            lastPresentedWhatsNewVersion:
                lastPresentedWhatsNewVersion
        )
    }

    private func persistCurrentSettings() {
        guard !isPreparingForAppReset else {
            return
        }

        let settings = currentSettings
        let precedingTask = persistenceTask
        persistenceSequence &+= 1
        let storeGeneration = persistenceGeneration
        let databaseGeneration =
            database.applicationSettingsPersistenceGeneration()

        persistenceTask = Task { [database] in
            _ = await precedingTask?.value

            guard !Task.isCancelled else {
                return .superseded
            }
            guard persistenceGeneration == storeGeneration else {
                return .superseded
            }

            do {
                let writeResult =
                    try await database.saveApplicationSettings(
                        settings,
                        expectedGeneration: databaseGeneration
                    )
                let result = WalletSettingsPersistenceResult(writeResult)
                return result
            } catch {
                let failureCode =
                    WalletSettingsPersistenceErrorCode.failureCode(
                        for: error
                    )
                return .failed(failureCode)
            }
        }
    }

    private func apply(_ settings: WalletApplicationSettings) {
        appearance = settings.appearance
        languageIdentifier = settings.languageIdentifier
        currencyCode = settings.currencyCode
        currencyRateStorageValue = settings.currencyRateStorageValue
        balancePrivacyEnabled = settings.balancePrivacyEnabled
        assetVisibilityPreferencesJSON =
            settings.assetVisibilityPreferencesJSON
        sendAmountEntryMode = settings.sendAmountEntryMode
        currencyConverterHomeShortcutEnabled =
            settings.currencyConverterHomeShortcutEnabled
        hapticFeedbackEnabled = settings.hapticFeedbackEnabled
        notificationsEnabled = settings.notificationsEnabled
        receivedTransactionNotificationsEnabled =
            settings.receivedTransactionNotificationsEnabled
        sentTransactionNotificationsEnabled =
            settings.sentTransactionNotificationsEnabled
        adminNotificationsEnabled = settings.adminNotificationsEnabled
        notificationWelcomeWasPresented =
            settings.notificationWelcomeWasPresented
        notificationsWereExplicitlyDisabled =
            settings.notificationsWereExplicitlyDisabled
        lastPresentedWhatsNewVersion =
            settings.lastPresentedWhatsNewVersion
        applyRuntimeSettings(settings)
    }

    private func applyRuntimeSettings(
        _ settings: WalletApplicationSettings
    ) {
        WalletRuntimePreferences.shared.apply(settings)
        UniHapticEngine.shared.configure(
            isEnabled: settings.hapticFeedbackEnabled
        )
    }

    private func updateRuntimeCurrency() {
        WalletRuntimePreferences.shared.setCurrency(
            code: currencyCode,
            rateStorageValue: currencyRateStorageValue
        )
    }

    private static func normalizedCurrencyCode(_ code: String) -> String {
        let normalized = code.uppercased()
        guard normalized.count == 3,
              normalized.allSatisfy({ $0.isASCII && $0.isLetter })
        else {
            return WalletCurrencyPreference.defaultCode
        }
        return normalized
    }

    private static func isValidJSONObject(_ value: String) -> Bool {
        guard let data = value.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data)
        else {
            return false
        }
        return object is [String: Any]
    }
}

private enum WalletSettingsPersistenceResult: Equatable, Sendable {
    case persisted
    case superseded
    case resetInProgress
    case staleDatabaseGeneration
    case failed(String)

    init(_ result: WalletApplicationSettingsWriteResult) {
        switch result {
        case .persisted:
            self = .persisted
        case .skippedResetInProgress:
            self = .resetInProgress
        case .skippedStaleGeneration:
            self = .staleDatabaseGeneration
        }
    }

    var isDurable: Bool {
        switch self {
        case .persisted, .superseded:
            true
        case .resetInProgress, .staleDatabaseGeneration, .failed:
            false
        }
    }

    var diagnosticCode: String {
        switch self {
        case .persisted:
            "persisted"
        case .superseded:
            "superseded"
        case .resetInProgress:
            "reset_in_progress"
        case .staleDatabaseGeneration:
            "stale_database_generation"
        case let .failed(code):
            "failed_\(code)"
        }
    }
}

private enum WalletSettingsPersistenceErrorCode {
    static func failureCode(for error: Error) -> String {
        let nsError = error as NSError
        let domain = nsError.domain
            .replacingOccurrences(of: " ", with: "_")
            .lowercased()
        return "\(domain)_\(nsError.code)"
    }
}

/// Synchronous formatting and localization helpers sometimes run outside a
/// SwiftUI view. They read this lock-protected mirror; durable ownership stays
/// with `WalletDatabase` and mutations stay with `WalletSettingsStore`.
final class WalletRuntimePreferences: @unchecked Sendable {
    static let shared = WalletRuntimePreferences()

    private struct Values {
        var languageIdentifier = WalletAppLanguage.defaultIdentifier
        var currencyCode = WalletCurrencyPreference.defaultCode
        var currencyRateStorageValue =
            WalletCurrencyPreference.defaultRateStorageValue
    }

    private let lock = NSLock()
    private var values = Values()

    private init() {}

    var languageIdentifier: String {
        lock.withLock { values.languageIdentifier }
    }

    var currencyCode: String {
        lock.withLock { values.currencyCode }
    }

    var currencyRateStorageValue: String {
        lock.withLock { values.currencyRateStorageValue }
    }

    func apply(_ settings: WalletApplicationSettings) {
        lock.withLock {
            values.languageIdentifier = settings.languageIdentifier
            values.currencyCode = settings.currencyCode
            values.currencyRateStorageValue =
                settings.currencyRateStorageValue
        }
    }

    func setLanguageIdentifier(_ identifier: String) {
        lock.withLock {
            values.languageIdentifier = identifier
        }
    }

    func setCurrency(code: String, rateStorageValue: String) {
        lock.withLock {
            values.currencyCode = code
            values.currencyRateStorageValue = rateStorageValue
        }
    }
}
