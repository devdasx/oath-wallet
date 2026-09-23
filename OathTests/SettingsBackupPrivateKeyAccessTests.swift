import Foundation
import GRDB
import Testing
@testable import Aperture

@MainActor
struct SettingsBackupPrivateKeyAccessTests {
    @Test
    func disabledAppLockOpensPrivateKeysWithoutAuthentication() async throws {
        let database = try WalletDatabase.temporary()
        try await database.disableAppLock()
        let settings = try await database.walletSecuritySettings()
        var loads = 0
        let access = SettingsBackupPrivateKeyAccess(
            prepare: { try await WalletSensitiveActionAuthorizer.prepare(database: database) },
            load: { grant in
                let authorization = try await database.authorizeSecretExport(
                    walletID: "backup-auth-policy-test", authenticationGrant: grant
                )
                #expect(authorization.permits(walletID: "backup-auth-policy-test"))
                #expect(!authorization.permits(walletID: "another-wallet"))
                loads += 1
                return [self.item("ethereum")]
            }
        )
        await access.request()
        #expect(loads == 1)
        #expect(access.route == .chains)
        #expect(!access.isAuthenticationPresented)
        #expect(access.authenticationContext == nil)
        #expect(access.failure == nil)
        #expect(try await database.walletSecuritySettings() == settings)
    }

    @Test
    func enablingAppLockInvalidatesEarlierUnprotectedGrant() async throws {
        let database = try WalletDatabase.temporary()
        try await database.disableAppLock()
        guard case let .authorized(grant) = try await WalletSensitiveActionAuthorizer.prepare(
            database: database
        ) else {
            Issue.record("Disabled App Lock should authorize without a challenge")
            return
        }
        try await database.pool.write { db in
            try db.execute(sql: "UPDATE userSettings SET appLockEnabled = 1")
        }
        await #expect(throws: WalletSecretExportAuthorizationError.self) {
            _ = try await database.authorizeSecretExport(
                walletID: "backup-auth-policy-test", authenticationGrant: grant
            )
        }
        guard case let .requiresPasscode(context) = try await WalletSensitiveActionAuthorizer.prepare(
            database: database
        ) else {
            Issue.record("Enabled App Lock must still protect private-key export")
            return
        }
        #expect(context.settings.requiresAuthentication)
    }

    @Test
    func successfulAuthenticationPublishesEveryProvidedChain() async throws {
        let grant = try authenticationGrant()
        let expected = [item("ethereum"), item("bitcoin"), item("stellar")]
        var loaded = false
        let access = SettingsBackupPrivateKeyAccess(
            prepare: { .authorized(grant) },
            load: { _ in loaded = true; return expected }
        )
        await access.request()
        #expect(loaded)
        #expect(access.route == .chains)
        #expect(access.items.map(\.id) == expected.map(\.id))
        access.route = nil
        access.clearExport()
        #expect(access.items.isEmpty)
    }

    @Test
    func passcodeMustCompleteAndDismissBeforeAnyKeysAreLoaded() async throws {
        var loads = 0
        let access = SettingsBackupPrivateKeyAccess(
            prepare: { .requiresPasscode(self.passcodeContext) },
            load: { _ in loads += 1; return [self.item("ethereum")] }
        )
        await access.request()
        #expect(access.isAuthenticationPresented)
        #expect(access.route == nil)
        #expect(loads == 0)
        access.completePasscode(try authenticationGrant())
        #expect(!access.isAuthenticationPresented)
        #expect(loads == 0)
        await access.authenticationDidDismiss()
        #expect(loads == 1)
        #expect(access.route == .chains)
    }

    @Test
    func dismissingPasscodeWithoutAGrantNeverLoadsKeys() async {
        var loads = 0
        let access = SettingsBackupPrivateKeyAccess(
            prepare: { .requiresPasscode(self.passcodeContext) },
            load: { _ in loads += 1; return [self.item("ethereum")] }
        )
        await access.request()
        await access.authenticationDidDismiss()
        #expect(loads == 0)
        #expect(access.route == nil)
        #expect(access.items.isEmpty)
        #expect(access.authenticationContext == nil)
    }

    @Test
    func cancelledAuthenticationNeverReadsSecretMaterial() async {
        var loads = 0
        let access = SettingsBackupPrivateKeyAccess(
            prepare: { .cancelled },
            load: { _ in loads += 1; return [self.item("ethereum")] }
        )
        await access.request()
        #expect(loads == 0)
        #expect(access.route == nil)
        #expect(!access.isBusy)
    }

    @Test
    func failedExportDoesNotNavigateOrRetainItems() async throws {
        let grant = try authenticationGrant()
        let access = SettingsBackupPrivateKeyAccess(
            prepare: { .authorized(grant) },
            load: { _ in throw WalletManagementError.secretUnavailable }
        )
        await access.request()
        #expect(access.failure != nil)
        #expect(access.route == nil)
        #expect(access.items.isEmpty)
        #expect(!access.isBusy)
    }

    @Test
    func biometricOverlayDefersNavigationUntilSceneIsActive() async throws {
        let grant = try authenticationGrant()
        let access = SettingsBackupPrivateKeyAccess(
            prepare: { .authorized(grant) },
            load: { _ in [self.item("ethereum")] }
        )
        access.sceneBecameInactive()
        await access.request()
        #expect(access.route == nil)
        #expect(access.items.isEmpty)
        access.sceneBecameActive()
        #expect(access.route == .chains)
        #expect(access.items.count == 1)
    }

    @Test
    func backgroundInvalidatesPendingPasscodeAndBiometricResults() async throws {
        let grant = try authenticationGrant()
        let access = SettingsBackupPrivateKeyAccess(
            prepare: { .authorized(grant) },
            load: { _ in [self.item("ethereum")] }
        )
        access.sceneBecameInactive()
        await access.request()
        access.cancelPendingRequest()
        access.sceneBecameActive()
        #expect(access.route == nil)
        #expect(access.items.isEmpty)

        let passcodeAccess = SettingsBackupPrivateKeyAccess(
            prepare: { .requiresPasscode(self.passcodeContext) },
            load: { _ in Issue.record("A stale passcode must not load keys"); return [] }
        )
        await passcodeAccess.request()
        passcodeAccess.cancelPendingRequest()
        passcodeAccess.completePasscode(grant)
        await passcodeAccess.authenticationDidDismiss()
        #expect(passcodeAccess.route == nil)
    }

    @Test
    func lateExportResultAfterCancellationIsDiscarded() async throws {
        let grant = try authenticationGrant()
        var continuation: CheckedContinuation<[WalletPrivateKeyExportItem], Never>?
        let access = SettingsBackupPrivateKeyAccess(
            prepare: { .authorized(grant) },
            load: { _ in await withCheckedContinuation { continuation = $0 } }
        )
        let task = Task { await access.request() }
        while continuation == nil { await Task.yield() }
        access.cancelPendingRequest()
        continuation?.resume(returning: [item("ethereum")])
        await task.value
        #expect(access.route == nil)
        #expect(access.items.isEmpty)
    }

    private var passcodeContext: WalletAuthenticationPasscodeContext {
        WalletAuthenticationPasscodeContext(settings: .secureDefault, initialErrorKey: nil)
    }

    private func authenticationGrant() throws -> WalletAuthenticationGrant {
        let result = WalletAuthenticationAction.resolveBiometricResult(
            .success(()), settings: .secureDefault
        )
        guard case let .authorized(grant) = result else {
            throw WalletManagementError.secretUnavailable
        }
        return grant
    }

    private func item(_ id: String) -> WalletPrivateKeyExportItem {
        WalletPrivateKeyExportItem(
            id: id,
            titleKey: "network.ethereum.name",
            logoSource: .nativeCoin(blockchain: .ethereum),
            backupNetwork: .evm,
            detail: .verbatim(id),
            privateKey: String(repeating: "0", count: 64)
        )
    }
}

extension SettingsBackupPrivateKeyAccessTests {
    @Test
    func privateKeyFallbackIsRetainedUntilItsSourceSceneIsActive() async {
        let access = SettingsBackupPrivateKeyAccess(
            prepare: { .requiresPasscode(.init(settings: .secureDefault, initialErrorKey: nil)) },
            load: { _ in Issue.record("Keys must not load before authentication."); return [] }
        )
        access.sceneBecameInactive()
        await access.request()
        #expect(!access.isAuthenticationPresented)
        #expect(access.authenticationContext != nil)
        #expect(access.route == nil)
        access.sceneBecameActive()
        #expect(access.isAuthenticationPresented)
        await access.authenticationDidDismiss()
        #expect(access.route == nil)
        #expect(access.authenticationContext == nil)
    }
}
