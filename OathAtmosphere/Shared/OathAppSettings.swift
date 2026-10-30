import OathDiagnostics
import SwiftUI
import Observation
import OathDatabase

/// One committed SQL settings stream drives the entire scene, including the
/// locked state. Changing a preference never recreates navigation or sheets.
@MainActor @Observable final class OathAppSettings {
    private(set) var preference: OathLanguagePreference = .system
    private(set) var appearance: AppAppearance = .system
    private(set) var currency = Locale.autoupdatingCurrent.currency?.identifier ?? "USD"
    private(set) var appIcon = OathAppIcon.current
    private(set) var changingAppIcon = false
    private(set) var appSwitcherPrivacy = false
    private(set) var hideRecentlyDeletedInSwitcher = false
    private(set) var lockDelay = OathLockDelay.immediately
    private(set) var hapticFeedbackEnabled = OathHaptics.shared.isEnabled
    private(set) var loaded = false
    private(set) var failed = false
    var showsError = false
    @ObservationIgnored private var pendingWrite: Task<Void, Never>?
    @ObservationIgnored private var observing = false
    @ObservationIgnored private var attemptedRetiredIconReset = false
    private var systemLanguages = Locale.preferredLanguages
    var language: OathLanguage { preference.resolve(preferredLanguages: systemLanguages) }

    /// A one-shot, background SQL read before the scene's first frame. The
    /// ongoing observer starts after mounting and uses the same apply path.
    func loadInitial() async {
        guard !loaded else { return }
        do {
            let database = try await OathDataEnvironment.shared.database()
            apply(try await database.settings())
        } catch { OathDiagnostics.record(error); if !Task.isCancelled { failed = true } }
    }

    func observe() async {
        guard !observing else { return }
        observing = true
        failed = false
        defer { observing = false }
        do {
            let database = try await OathDataEnvironment.shared.database()
            for try await values in database.observeSettings() {
                apply(values)
            }
        } catch is CancellationError { }
        catch { OathDiagnostics.record(error); if !Task.isCancelled { failed = true; showsError = loaded } }
    }

    func select(_ value: OathLanguagePreference) { save("language", value: value.rawValue) }
    func selectAppearance(_ value: AppAppearance) { save(AppAppearance.settingKey, value: value.rawValue) }
    func selectCurrency(_ code: String) async throws {
        let database = try await OathDataEnvironment.shared.database()
        try await database.selectDisplayCurrency(code)
        currency = code
        OathHaptics.shared.play(.selection)
    }
    func selectAppIcon(_ choice: OathAppIcon, feedback: Bool = true) async throws {
        guard !changingAppIcon, UIApplication.shared.supportsAlternateIcons else { return }
        // Compare the actual platform name: a retired alternate must still be
        // reset even though it is no longer represented by our selection enum.
        guard choice.alternateName != UIApplication.shared.alternateIconName else {
            appIcon = .current
            return
        }
        changingAppIcon = true
        defer { changingAppIcon = false }
        // iOS owns icon installation and its system confirmation. Never update
        // our checkmark or database before it reports success.
        try await UIApplication.shared.setAlternateIconName(choice.alternateName)
        appIcon = .current
        // The OS owns the installed icon. A preference-write failure must not
        // claim the successfully installed icon failed or roll its checkmark back.
        if let appIcon { save("appIcon", value: appIcon.rawValue) }
        if feedback { OathHaptics.shared.play(.success) }
    }

    func refreshAppIcon() async {
        guard !changingAppIcon else { return }
        let previous = appIcon
        appIcon = .current
        if let appIcon {
            if previous != appIcon { save("appIcon", value: appIcon.rawValue) }
            return
        }
        // Updates remove the former icon assets. Only ask iOS to return a
        // retired selection to the new primary while the app is in foreground.
        guard UIApplication.shared.applicationState == .active,
              UIApplication.shared.supportsAlternateIcons, !attemptedRetiredIconReset else { return }
        // Avoid repeating a system prompt if an automatic reset fails. The
        // user can still choose any design explicitly in App Icon settings.
        attemptedRetiredIconReset = true
        await OathDiagnostics.$operationID.withValue(UUID()) {
            do { try await selectAppIcon(.signalBlue, feedback: false) }
            catch {
                OathDiagnostics.record(error, component: "app_icon", operation: "reset_retired_icon")
                if !OathDiagnostics.isExpectedCancellation(error) { showsError = true }
            }
        }
    }
    func selectLockDelay(_ value: OathLockDelay) { save(OathLockDelay.settingKey, value: String(value.rawValue)) }
    func selectHapticFeedback(_ enabled: Bool) {
        OathHaptics.shared.setEnabled(enabled)
        hapticFeedbackEnabled = enabled
    }
    func selectAppSwitcherPrivacy(_ enabled: Bool) { save("security.appSwitcherPrivacy", value: enabled ? "true" : "false") }
    func selectHideRecentlyDeletedInSwitcher(_ enabled: Bool) {
        save("security.hideRecentlyDeletedInSwitcher", value: enabled ? "true" : "false")
    }
    func refreshSystemLanguage() { systemLanguages = Locale.preferredLanguages }

    private func apply(_ values: [String: String]) {
        preference = values["language"].flatMap(OathLanguagePreference.init(rawValue:)) ?? .system
        appearance = AppAppearance(settings: values)
        currency = values["currency"] ?? Locale.autoupdatingCurrent.currency?.identifier ?? "USD"
        // The OS also persists this choice. Reconcile SQL after reinstall or an
        // interrupted write without triggering an icon-change prompt at launch.
        appIcon = .current
        if let appIcon, values["appIcon"] != appIcon.rawValue { save("appIcon", value: appIcon.rawValue) }
        appSwitcherPrivacy = values["security.appSwitcherPrivacy"] == "true"
        hideRecentlyDeletedInSwitcher = values["security.hideRecentlyDeletedInSwitcher"] == "true"
        lockDelay = OathLockDelay(settings: values)
        OathCommittedLanguage.shared.update(preference)
        loaded = true; failed = false
    }

    private func save(_ key: String, value: String) {
        // Preserve tap order while all disk work stays on GRDB's writer queue.
        let previous = pendingWrite
        pendingWrite = Task {
            await previous?.value
            do {
                let database = try await OathDataEnvironment.shared.database()
                try await database.setSetting(key, value: value)
            } catch { OathDiagnostics.record(error); showsError = true; OathHaptics.shared.play(.error) }
        }
    }
}

extension AppAppearance {
    var title: OathStringKey {
        switch self {
        case .system: .appearanceSystem
        case .light: .appearanceLight
        case .dark: .appearanceDark
        }
    }
}
