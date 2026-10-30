#!/usr/bin/env python3
"""Host checks for the production settings model with an in-memory database/UI adapter.

No simulator, device, real preferences, wallet data or network is accessed.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / 'OathAtmosphere/Shared/OathAppSettings.swift').read_text()
source = source.replace('import SwiftUI', 'import Foundation').replace('import OathDiagnostics\n', '').replace('import OathDatabase\n', '')
fixture = r'''
import Foundation

enum FixtureError: Error { case rejected }
actor SettingsDatabase {
    var values: [String: String] = [:]
    var continuations: [UUID: AsyncThrowingStream<[String: String], Error>.Continuation] = [:]
    var reject = false
    var writes = 0
    func settings() -> [String: String] { values }
    func setSetting(_ key: String, value: String) throws {
        if reject { reject = false; throw FixtureError.rejected }
        values[key] = value; writes += 1
        for continuation in continuations.values { continuation.yield(values) }
    }
    func selectDisplayCurrency(_ code: String) throws { try setSetting("currency", value: code) }
    nonisolated func observeSettings() -> AsyncThrowingStream<[String: String], Error> {
        let id = UUID()
        return AsyncThrowingStream { continuation in
            Task { await self.addObserver(id, continuation) }
            continuation.onTermination = { _ in Task { await self.removeObserver(id) } }
        }
    }
    func addObserver(_ id: UUID, _ continuation: AsyncThrowingStream<[String: String], Error>.Continuation) {
        continuations[id] = continuation
        continuation.yield(values)
    }
    func removeObserver(_ id: UUID) { continuations[id] = nil }
    func rejectNextWrite() { reject = true }
    func clear() { values = [:] }
}
actor OathDataEnvironment {
    static let shared = OathDataEnvironment()
    let store = SettingsDatabase()
    func database() -> SettingsDatabase { store }
}
enum OathDiagnostics {
    @TaskLocal static var operationID: UUID?
    @MainActor static var errors = 0
    @MainActor static func record(_ error: Error, component: String = "", operation: String = "") { errors += 1 }
    static func isExpectedCancellation(_ error: Error) -> Bool { error is CancellationError }
}
@MainActor final class UIApplication {
    static let shared = UIApplication()
    enum State { case active }
    let applicationState = State.active
    let supportsAlternateIcons = false
    var alternateIconName: String?
    func setAlternateIconName(_ value: String?) async throws { alternateIconName = value }
}
enum OathAppIcon: String {
    case signalBlue
    static var current: Self? { nil }
    var alternateName: String? { nil }
}
@MainActor final class OathHaptics {
    static let shared = OathHaptics()
    enum Event { case error, success, selection }
    var isEnabled = true
    func setEnabled(_ enabled: Bool) { isEnabled = enabled }
    func play(_ event: Event) {}
}
enum OathLanguagePreference: String {
    case system
    func resolve(preferredLanguages: [String]) -> OathLanguage { OathLanguage() }
}
struct OathLanguage {}
@MainActor final class OathCommittedLanguage {
    static let shared = OathCommittedLanguage()
    func update(_ preference: OathLanguagePreference) {}
}
enum AppAppearance: String {
    case system, light, dark
    static let settingKey = "appearance"
    init(settings: [String: String]) { self = .system }
}
@main enum Checks {
    @MainActor static func wait(_ condition: () async -> Bool) async throws {
        for _ in 0..<1_000 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        preconditionFailure("Settings did not settle")
    }
    @MainActor static func main() async throws {
        let db = await OathDataEnvironment.shared.database()
        let settings = OathAppSettings()
        precondition(!settings.hideRecentlyDeletedInSwitcher, "Default must show Recently Deleted before loading")
        await settings.loadInitial()
        precondition(settings.loaded && !settings.hideRecentlyDeletedInSwitcher, "Missing preference defaults to visible")
        let observation = Task { await settings.observe() }
        defer { observation.cancel() }
        settings.selectHideRecentlyDeletedInSwitcher(true)
        try await wait { settings.hideRecentlyDeletedInSwitcher }
        let savedEnabled = await db.settings()
        precondition(savedEnabled["security.hideRecentlyDeletedInSwitcher"] == "true")
        let relaunched = OathAppSettings()
        await relaunched.loadInitial()
        precondition(relaunched.hideRecentlyDeletedInSwitcher, "Saved choice survives a fresh model")

        settings.selectHideRecentlyDeletedInSwitcher(false)
        try await wait { !settings.hideRecentlyDeletedInSwitcher }
        let savedDisabled = await db.settings()
        precondition(savedDisabled["security.hideRecentlyDeletedInSwitcher"] == "false")
        let writes = await db.writes
        settings.selectHideRecentlyDeletedInSwitcher(true)
        settings.selectHideRecentlyDeletedInSwitcher(false)
        try await wait { await db.writes == writes + 2 && !settings.hideRecentlyDeletedInSwitcher }

        await db.rejectNextWrite()
        settings.selectHideRecentlyDeletedInSwitcher(true)
        try await wait { settings.showsError }
        precondition(!settings.hideRecentlyDeletedInSwitcher, "Failed save must not hide the section")
        precondition(OathDiagnostics.errors == 1, "Failed preference write uses shared diagnostics")
        let savedAfterFailure = await db.settings()
        precondition(savedAfterFailure["security.hideRecentlyDeletedInSwitcher"] == "false")
        settings.showsError = false
        settings.selectHideRecentlyDeletedInSwitcher(true)
        try await wait { settings.hideRecentlyDeletedInSwitcher }

        try await db.setSetting("security.hideRecentlyDeletedInSwitcher", value: "invalid")
        try await wait { !settings.hideRecentlyDeletedInSwitcher }
        await db.clear()
        let reset = OathAppSettings()
        await reset.loadInitial()
        precondition(!reset.hideRecentlyDeletedInSwitcher, "Cleared settings restore the visible default")
        print("Passed switcher preference default, observation, persistence, tap ordering, failed save, retry and reset checks (production settings, mocked database/UI).")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='oath-switcher-settings-') as directory:
    work = Path(directory)
    (work / 'Settings.swift').write_text(source)
    (work / 'Checks.swift').write_text(fixture)
    executable = work / 'checks'
    subprocess.run(['swiftc', '-swift-version', '6', '-parse-as-library',
                    str(ROOT / 'OathAtmosphere/Localization/OathStringKey.swift'),
                    str(ROOT / 'OathAtmosphere/Security/OathSecurityPolicy.swift'),
                    str(work / 'Settings.swift'), str(work / 'Checks.swift'), '-o', str(executable)], check=True)
    subprocess.run([str(executable)], check=True, timeout=30)

switcher = (ROOT / 'OathAtmosphere/Home/OathWalletSwitcherSheet.swift').read_text()
management = (ROOT / 'OathAtmosphere/Home/OathWalletManagementPages.swift').read_text()
navigation = (ROOT / 'OathAtmosphere/Home/OathWalletSheets.swift').read_text()
security = (ROOT / 'OathAtmosphere/Security/OathSecurityPage.swift').read_text()
assert 'rows.deletedCount > 0 && !settings.hideRecentlyDeletedInSwitcher' in switcher
assert 'OathRecentlyDeletedWalletsRow(count: rows.deletedCount)' in switcher
assert 'OathRecentlyDeletedWalletsRow(count: rows.deletedCount)' in management
assert 'hideRecentlyDeletedInSwitcher' not in management, 'Settings must always expose retained wallets'
assert 'switcherRoot({ path.append(.wallet($0)) }, { path.append(.recentlyDeleted) })' in navigation
assert 'OathRecentlyDeletedWalletsPage(session: session, removal: walletRemoval)' in navigation
assert 'value: settings.hideRecentlyDeletedInSwitcher' in security
assert 'onChange: settings.selectHideRecentlyDeletedInSwitcher' in security
print('Passed shared Recently Deleted entry, Settings access and switcher navigation wiring checks (source inspection).')
