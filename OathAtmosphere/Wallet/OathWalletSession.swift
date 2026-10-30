import OathDiagnostics
import Foundation
import Observation
import OathDatabase
import OathAnkr
import OathMarketData
import OathBitcoin
#if canImport(UIKit)
import UIKit
#endif

@MainActor @Observable
final class OathWalletSession {
    enum State { case loading, upgrading, onboarding, locked, home(OathWalletProfile), unavailable }
    enum LegacyPhase { case passcode, migrating, biometrics, failed }
    private(set) var legacyPhase: LegacyPhase = .migrating
    @ObservationIgnored private var legacySource: LegacyWalletSnapshot?
    @ObservationIgnored private let legacySourceURL: URL
    @ObservationIgnored private let legacySecrets: any OathLegacySecretReading
    var isUpgrading: Bool { if case .upgrading = state { true } else { false } }
    enum LockReason { case automatic, manual }
    var state: State = .loading
    var busy = false
    private(set) var animatesUnlock = true
    var notice: OathStringKey?
    // Display-only metadata survives a lock so SwiftUI does not destroy the
    // current navigation/sheet hierarchy. Secrets still live only in the vault.
    private(set) var displayedProfile: OathWalletProfile?
    private(set) var portfolio: WalletSnapshot? {
        didSet {
            let hidden = portfolio?.settings["balancesHidden"] == "true"
            if balancesHidden != hidden { balancesHidden = hidden }
        }
    }
    let homePortfolio = OathHomePortfolioModel()
    // Cache the durable per-wallet UI preference. It contains no credentials
    // and does not change signing rules or wallet protection.
    private(set) var multisigNoticeStates: [UUID: MultisigNoticeState] = [:]
    private(set) var stablecoinSecurityStates: [UUID: StablecoinSecurityState] = [:]
    private(set) var homeHistory: OathHomeHistorySnapshot?
    // Display evidence belongs to the wallet session, not a visible Home pill.
    // Keep it through modal presentation, scene inactivity and authentication.
    private(set) var balanceDaySummary: BalanceDaySummary?
    private struct BalanceDayScope: Equatable {
        let walletID: String
        let currency: String
        let interval: DateInterval
    }
    @ObservationIgnored private var balanceDayScope: BalanceDayScope?
    @ObservationIgnored private var balanceDayObservation: Task<Void, Never>?
    private(set) var wallets: [WalletRecord] = [] {
        didSet {
            // A deleted wallet may later be restored from a backup with the
            // same UUID. Reload its durable preference rather than a stale cache.
            let activeIDs = Set(wallets.compactMap { UUID(uuidString: $0.id) })
            multisigNoticeStates = multisigNoticeStates.filter { activeIDs.contains($0.key) }
            stablecoinSecurityStates = stablecoinSecurityStates.filter { activeIDs.contains($0.key) }
        }
    }
    private(set) var recentlyDeletedWallets: [WalletRecord] = []
    @ObservationIgnored private var deletionTimer: Task<Void, Never>?
    private(set) var changingWallet = false
    private(set) var resetting = false
    private(set) var bitcoinRefreshing = false
    private(set) var bitcoinRefreshFailed = false
    private(set) var bitcoinRevision = 0
    @ObservationIgnored private var bitcoinWork: Task<Void, Never>?
    @ObservationIgnored private var solanaWork: Task<Void, Never>?
    @ObservationIgnored private var ankrWork: Task<Void, Never>?
    @ObservationIgnored private var assetFilterWork: Task<Void, Never>?
    @ObservationIgnored private var addedTokenPriceWork: Task<Void, Never>?
    @ObservationIgnored let tokenSelection = OathTokenSelectionModel()
    private(set) var ankrRefreshFailed = false
    private(set) var ankrRevision = 0
    private(set) var resetFailed = false
    var isLocked: Bool { if case .locked = state { true } else { false } }
    var isUnlocked: Bool { if case .home = state { true } else { false } }
    var allowsAutomaticBiometricUnlock: Bool { isLocked && lockReason == .automatic }
    // Session-owned intent survives lock-screen recreation and scene activation.
    // A manual lock requires an explicit PIN entry or biometric-button tap.
    private var lockReason: LockReason = .automatic
    var allowsBackgroundWalletWork: Bool { !resetting && (isUnlocked || isLocked) }
    private var completingInitialSetup = false
    private(set) var welcomesWithRetainedWallets = false
    var presentsOnboarding: Bool {
        if case .onboarding = state { return true }
        return completingInitialSetup || welcomesWithRetainedWallets
    }
    var pendingCustomizationID: String? {
        guard let id = displayedProfile?.id.uuidString,
              wallets.contains(where: { $0.id == id && $0.needsCustomization }) else { return nil }
        return id
    }
    // A separate observable scalar prevents every balance/sync checkpoint
    // from invalidating every screen that only reads the visibility setting.
    private(set) var balancesHidden = false
    private(set) var biometricRepairNeeded = false
    private(set) var security = OathWalletSecurityState()
    @ObservationIgnored private var lockPolicy = OathAutoLockPolicy()
    @ObservationIgnored private var backgroundLock: Task<Void, Never>?
    @ObservationIgnored private var vaultLockWork: Task<Void, Never>?
    let vault: OathWalletVault
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var unlockWork: Task<OathWalletProfile, Error>?
    @ObservationIgnored private var databaseObservation: Task<Void, Never>?
    @ObservationIgnored private var balanceSnapshotWork: Task<Void, Never>?
    @ObservationIgnored private var observationCurrency: String?
    @ObservationIgnored private var walletsObservation: Task<Void, Never>?
    @ObservationIgnored private var walletWork: Task<OathWalletProfile, Error>?
    @ObservationIgnored private let protectedDataAvailable: @MainActor () -> Bool
    @ObservationIgnored private var waitingForProtectedStartup = false

    init(vault: OathWalletVault? = nil, legacySourceURL: URL = OathLegacyUpgrade.sourceURL,
         legacySecrets: any OathLegacySecretReading = OathLegacyKeychain(),
         protectedDataAvailable: (@MainActor () -> Bool)? = nil) {
        self.legacySourceURL = legacySourceURL
        self.legacySecrets = legacySecrets
        self.protectedDataAvailable = protectedDataAvailable ?? {
            #if canImport(UIKit)
            UIApplication.shared.isProtectedDataAvailable
            #else
            true
            #endif
        }
        if let vault { self.vault = vault; return }
        #if DEBUG && targetEnvironment(simulator)
        // Test isolation, not an authentication bypass. Every test still uses
        // the real Keychain, encryption, passcode flow, and unlock checks.
        if let scope = UserDefaults.standard.string(forKey: "oath.walletTestScope"), UUID(uuidString: scope) != nil {
            let service = "org.oathwallet.tests." + scope
            let installation = OathInstallationSecurity.live(namespace: service)
            self.vault = OathWalletVault(storage: OathInstallationVaultStorage(
                raw: OathVaultKeychain(service: service + ".wallet-vault"), installation: installation),
                biometricStore: OathBiometricCredentialStore(service: service + ".wallet-biometry-v1",
                                                              installation: installation))
            return
        }
        #endif
        self.vault = OathWalletVault()
    }

    func resumeProtectedStartup() async {
        guard waitingForProtectedStartup, protectedDataAvailable() else { return }
        await load()
    }

    func load() async {
        guard case .loading = state else { return }
        // A background/cold scene may connect before iOS releases protected
        // files. Return promptly so scene restoration never waits for unlock.
        // In particular, no absent key/credential can be inferred in this state.
        guard protectedDataAvailable() else { waitingForProtectedStartup = true; return }
        waitingForProtectedStartup = false
        await OathDiagnostics.$operationID.withValue(UUID()) {
            await loadProtectedWallet()
        }
    }

    private func loadProtectedWallet() async {
        let token = generation
        var stage = "reset_journal"
        do {
            // Explicit recovery and authenticated empty-vault cleanup outrank
            // old-source reads. Ordinary pre-release reset intent does not.
            let recoveryReset = try await vault.hasPendingLegacyRecoveryReset()
            let emptyWalletReset = try await vault.hasPendingEmptyWalletReset()
            if recoveryReset || emptyWalletReset {
                guard token == generation else { return }
                resetting = true
                Task { await continueReset() }
                return
            }
            stage = "legacy_read"
            if let source = try await LegacyWalletSource.read(at: legacySourceURL),
               try await vault.needsLegacyMigration(source) {
                guard token == generation else { return }
                legacySource = source
                legacyPhase = source.security.appLockEnabled ? .passcode : .migrating
                state = .upgrading
                if !source.security.appLockEnabled { Task { await self.upgradeLegacy(digits: nil) } }
                return
            }
            // Present recovery progress immediately after an interrupted reset;
            // never keep UIKit's launch surface waiting for file cleanup.
            stage = "reset_journal"
            if try await vault.hasPendingReset() {
                guard token == generation else { return }
                resetting = true
                Task { await continueReset() }
                return
            }
            stage = "vault_read"
            let exists = try await vault.exists()
            stage = "security_read"
            let security = exists ? try await vault.securityState() : .init()
            guard token == generation, case .loading = state else { return }
            self.security = security
            if exists, !security.passcodeEnabled {
                stage = "unlock"
                try await openHome(try await vault.unlockWithoutPasscode(), token: token)
                return
            }
            // SQL metadata can populate the real Home behind the blur without
            // opening the vault. Legacy/missing metadata must not block unlock.
            stage = "locked_display"
            let snapshot = exists ? await OathDiagnostics.attemptOptional("lockedDisplaySnapshot", body: { try await vault.lockedDisplaySnapshot() }) : nil
            let records = exists ? (await OathDiagnostics.attempt("displayWallets", body: { try await vault.displayWallets() })) : nil
            guard token == generation, case .loading = state else { return }
            if let snapshot, let profile = OathDiagnostics.attempt("decode_locked_profile", body: { try OathWalletProfile.stored(snapshot) }) {
                try await prepareHomeDisplay(snapshot, database: vault.database(), token: token)
                guard token == generation else { return }
                displayedProfile = profile
                portfolio = snapshot
                // Public names only, to keep the selected name consistent in
                // Home's cold-launch backdrop. The vault still owns membership.
                wallets = records ?? [snapshot.wallet]
            }
            guard token == generation, case .loading = state else { return }
            state = exists ? .locked : .onboarding
        } catch is CancellationError {
            // An interrupted scene connection can retry local readiness; it is
            // not a failed vault or a reason to manufacture an unavailable UI.
        } catch {
            guard token == generation, case .loading = state else { return }
            // The device can lock between the availability check and an I/O
            // completion. Only known protected-access failures may wait. An
            // unlocked permission failure or missing entitlement still reports.
            if !protectedDataAvailable(), Self.isProtectedStartupAccessFailure(error) {
                waitingForProtectedStartup = true
                return
            }
            OathDiagnostics.record(error, operation: "load", context: ["stage": stage])
            state = .unavailable
        }
    }

    private static func isProtectedStartupAccessFailure(_ error: any Error) -> Bool {
        if case OathPasscodeSaveError.deviceLocked = error { return true }
        if case OathInstallationSecurityError.keychain(-25308) = error { return true }
        let value = error as NSError
        return value.domain == NSCocoaErrorDomain &&
            [CocoaError.fileReadNoPermission.rawValue, CocoaError.fileWriteNoPermission.rawValue].contains(value.code)
    }

    func upgradeLegacy(digits: [UInt8]?) async {
        guard isUpgrading, !busy, let source = legacySource else { return }
        busy = true; notice = nil
        let token = generation
        await vaultLockWork?.value
        guard token == generation else { return }
        legacyPhase = .migrating
        let sourceURL = legacySourceURL
        let secrets = legacySecrets
        let work = Task { [vault] in
            try await OathDiagnostics.$operationID.withValue(UUID()) {
                try await vault.migrateLegacy(source, digits: digits, secrets: secrets, sourceURL: sourceURL)
            }
        }
        unlockWork = work
        defer { if token == generation { busy = false; unlockWork = nil } }
        do {
            let profile = try await work.value
            guard token == generation else { return }
            try await openHome(profile, token: token)
        } catch is CancellationError {
            // Background cancellation retains the original stores and retries after authentication.
        } catch {
            guard token == generation else { return }
            switch error as? OathWalletError {
            case .wrongPasscode: legacyPhase = .passcode; notice = .unlockIncorrect
            case .throttled: legacyPhase = .passcode; notice = .unlockWait
            default:
                // Never attach legacy rows, references or decrypted material to diagnostics.
                OathDiagnostics.record(DiagnosticFailure("legacy_upgrade_failed"), component: "legacy_upgrade", operation: "migrate",
                                       context: ["stage": "authenticated_commit"])
                legacyPhase = .failed
                notice = (error as? LegacyUpgradeError) == .unsupportedWallet ? .legacyUpgradeUnsupported : .legacyUpgradeFailure
            }
        }
    }

    func retryLegacyUpgrade() {
        guard isUpgrading, !busy, !resetting else { return }
        // Re-read public metadata so a repaired/restored source is not compared
        // forever against the snapshot from the first failed attempt.
        notice = nil; legacySource = nil
        state = .loading
        Task { await load() }
    }

    func finishLegacyProtection(enableBiometrics: Bool) async {
        guard isUpgrading, legacyPhase == .biometrics, !busy else { return }
        busy = true; notice = nil
        let token = generation
        defer { if token == generation { busy = false } }
        do {
            if enableBiometrics {
                let result = try await vault.enableBiometrics(strings: .current)
                guard token == generation else { return }
                guard case .enabled = result else { return } // Cancellation keeps the explicit transition on screen.
            }
            try await vault.finishLegacyBiometricTransition()
            try await openHome(try await vault.unlockedProfile(), token: token)
        } catch is CancellationError { }
        catch {
            OathDiagnostics.record(DiagnosticFailure("legacy_protection_transition"), component: "legacy_upgrade", operation: "protection")
            if token == generation { notice = .legacyUpgradeFailure }
        }
    }

    func finishedSetup(requiresCustomization: Bool = true) async {
        // Keep the original NavigationStack alive after the atomic vault save.
        // It pushes Customize after Face ID instead of being replaced by Home.
        completingInitialSetup = requiresCustomization
        let token = generation
        do { try await openHome(try await vault.unlockedProfile(), token: token) }
        catch { OathDiagnostics.record(error); if token == generation { state = .locked } }
    }

    func finishInitialCustomization() {
        guard isUnlocked, !wallets.isEmpty, pendingCustomizationID == nil else { return }
        completingInitialSetup = false
        welcomesWithRetainedWallets = false
    }

    func refreshSecurity() async throws {
        let token = generation
        let updated = try await vault.securityState()
        guard token == generation else { throw CancellationError() }
        security = updated
        if !updated.biometricsEnabled { biometricRepairNeeded = false }
        if !updated.passcodeEnabled {
            backgroundLock?.cancel(); lockPolicy.reset()
            if isLocked {
                await vaultLockWork?.value
                guard token == generation else { throw CancellationError() }
                try await openHome(try await vault.unlockWithoutPasscode(), token: token)
            }
        }
    }

    func enteredBackground(delay: OathLockDelay, now: ContinuousClock.Instant = .now) {
        if isUpgrading {
            if resetting || legacyPhase == .failed { return }
            if legacySource == nil { requestLock(reason: .automatic); return }
            generation = UUID(); unlockWork?.cancel(); unlockWork = nil
            busy = false; notice = nil
            legacyPhase = legacySource?.security.appLockEnabled == true ? .passcode : .migrating
            let previous = vaultLockWork
            vaultLockWork = Task { [vault] in await previous?.value; await vault.lock() }
            return
        }
        guard security.passcodeEnabled, isUnlocked else { return }
        lockPolicy.leave(delay: delay, now: now)
        if lockPolicy.requiresLock(now: now) { requestLock(reason: .automatic); return }
        backgroundLock?.cancel()
        guard let deadline = lockPolicy.deadline else { return }
        backgroundLock = Task { [weak self] in
            do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
            guard let self, self.lockPolicy.requiresLock(now: .now) else { return }
            self.requestLock(reason: .automatic)
        }
    }

    /// Called synchronously before foreground content becomes interactive.
    /// iOS may suspend the timer, so elapsed time is checked again on return.
    func enteringForeground(now: ContinuousClock.Instant = .now) {
        if isUpgrading, !busy, legacyPhase == .migrating {
            Task { await upgradeLegacy(digits: nil) }
        }
        backgroundLock?.cancel(); backgroundLock = nil
        if security.passcodeEnabled, lockPolicy.requiresLock(now: now) { requestLock(reason: .automatic) }
        lockPolicy.reset()
        Task { await purgeExpiredWallets() }
        Task {
            if isUnlocked, !resetting, !changingWallet {
                await recordBalanceSnapshot(.appOpen)
                await refreshBalanceDay()
                await OathPostSendBalanceRefresh.shared.resume(vault: vault)
            }
        }
    }

    func lock(reason: LockReason = .manual) async {
        guard security.passcodeEnabled else { return }
        requestLock(reason: reason)
        await vaultLockWork?.value
    }

    private func requestLock(reason: LockReason) {
        guard !resetting else { return }
        // Repeated lifecycle locks must not undo an existing manual-lock choice.
        if !isLocked || reason == .manual { lockReason = reason }
        backgroundLock?.cancel(); backgroundLock = nil
        lockPolicy.reset()
        generation = UUID()
        homePortfolio.cancel()
        stopBalanceDayObservation()
        bitcoinWork?.cancel(); bitcoinWork = nil
        ankrWork?.cancel(); ankrWork = nil
        assetFilterWork?.cancel(); assetFilterWork = nil
        addedTokenPriceWork?.cancel(); addedTokenPriceWork = nil
        tokenSelection.cancel()
        solanaWork?.cancel(); solanaWork = nil
        bitcoinRefreshing = false
        databaseObservation?.cancel()
        databaseObservation = nil
        balanceSnapshotWork?.cancel(); balanceSnapshotWork = nil
        walletsObservation?.cancel()
        walletsObservation = nil
        deletionTimer?.cancel(); deletionTimer = nil
        walletWork?.cancel()
        walletWork = nil
        changingWallet = false
        observationCurrency = nil
        // Freeze the last committed display values underneath the native blur.
        // No observation or refresh may publish new values until authenticated.
        unlockWork?.cancel()
        unlockWork = nil
        busy = false
        notice = nil
        state = .locked
        let previous = vaultLockWork
        vaultLockWork = Task { [vault] in
            await previous?.value
            await OathPostSendBalanceRefresh.shared.pause()
            await OathBitcoinSync.shared.cancel()
            await OathAnkrSync.shared.cancel()
            await vault.lock()
        }
    }

    func unlock(_ digits: [UInt8]) async {
        guard !busy, case .locked = state else { return }
        animatesUnlock = true
        busy = true; notice = nil
        let token = UUID()
        generation = token
        await vaultLockWork?.value
        guard token == generation else { return }
        let vault = vault
        let work = Task {
            try await OathDiagnostics.$operationID.withValue(token) {
                try await vault.unlock(digits: digits)
            }
        }
        unlockWork = work
        defer { if token == generation { busy = false; unlockWork = nil } }
        do {
            let profile = try await work.value
            guard token == generation else { return }
            // Only a verified wallet passcode may replace a missing/stale key.
            // A fresh system match is still required to enable biometrics.
            if biometricRepairNeeded {
                let result = await OathDeviceBiometrics(
                    credentialStore: vault.biometricStore,
                    credentialProvider: { try await vault.biometricCredential() }
                ).enableIfAvailable()
                guard token == generation else { return }
                if case .enabled = result { biometricRepairNeeded = false }
            }
            try await openHome(profile, token: token)
        } catch is CancellationError {
            // Locking/backgrounding cancels an attempt without an error dialog.
        } catch {
            guard token == generation else { return }
            switch error as? OathWalletError {
            // Rejection and lockout are authentication results. The vault still
            // reports original crypto/storage failures before mapping errors;
            // a second generic wrongPasscode event adds no failure evidence.
            case .throttled: notice = .unlockWait
            case .wrongPasscode: notice = .unlockIncorrect
            default:
                OathDiagnostics.$operationID.withValue(token) { OathDiagnostics.record(error) }
                notice = .walletUnavailable
            }
        }
    }

    func unlockWithBiometrics(automatically: Bool = false) async {
        guard !busy, security.biometricsEnabled, !biometricRepairNeeded, case .locked = state else { return }
        // Enforce intent here as well as in the view: a queued automatic request
        // must not start authentication after the user explicitly locks the app.
        guard !automatically || allowsAutomaticBiometricUnlock else { return }
        busy = true; notice = nil
        let token = UUID()
        generation = token
        await vaultLockWork?.value
        guard token == generation else { return }
        let vault = vault
        let reason = OathLocalizer.current.text(.unlockReason)
        let work = Task { try await vault.unlockWithBiometrics(reason: reason) }
        unlockWork = work
        defer { if token == generation { busy = false; unlockWork = nil } }
        do {
            let profile = try await work.value
            guard token == generation else { return }
            // Face ID already supplies the success animation. Remove our lock
            // as soon as the authenticated Home state is ready, without stacking
            // a second input-blocking dissolve after the system prompt.
            animatesUnlock = false
            try await openHome(profile, token: token)
        } catch is CancellationError {
            // Never resurrect an attempt after the app has been locked.
        } catch {
            // A declined/locked biometric prompt uses the app PIN fallback;
            // it is expected authentication control flow, not an app failure.
            if (error as? OathBiometricCredentialError)?.isExpectedAuthenticationOutcome != true {
                OathDiagnostics.record(error)
            }
            guard token == generation else { return }
            switch error as? OathBiometricCredentialError {
            case .missing where automatically:
                // A passcode-only wallet has no enrolled credential. Opening
                // its screen must not show an error or opt it into biometrics.
                break
            case .missing, .invalid:
                biometricRepairNeeded = true
            case .cancelled, .unavailable, .keychain: break
            default: notice = .walletUnavailable
            }
        }
    }

    func backedUp() async throws {
        let updated = try await vault.markBackedUp()
        guard case .home(let current) = state, current.id == updated.id else { return }
        publishHome(updated)
    }

    func refresh() async throws {
        guard case .home(let current) = state else { return }
        let token = generation
        do {
            // Independent ledgers update concurrently. A provider failure does
            // not cancel successful work on another family of networks.
            // Capture the refresh event immediately alongside provider work,
            // so a long refresh does not postpone the durable history entry.
            async let balanceEvent: Void = recordBalanceSnapshot(.refresh)
            async let bitcoin: Result<Void, Error> = refreshBitcoinResult()
            async let ankr: Result<Void, Error> = refreshAnkrResult()
            let results = await (bitcoin, ankr)
            await balanceEvent
            guard token == generation, case .home(let active) = state, active.id == current.id else { return }
            // Also save the committed result when a provider failed and left
            // partial values. History failure must never fail a refresh.
            await recordBalanceSnapshot(.balanceUpdate, settled: true)
            try results.0.get(); try results.1.get()
            // Refresh reads committed SQL state. Network providers must commit
            // through the repository; they never mutate screen balances.
            let updated = try await vault.reloadProfile()
            guard token == generation, case .home(let active) = state,
                  active.id == current.id else { return }
            // An unchanged refresh must not rebuild the home hierarchy while
            // UIKit is animating the refresh control back out of the scroll view.
            if updated != active { publishHome(updated) }
            let db = try await vault.database()
            let currency = Locale.autoupdatingCurrent.currency?.identifier ?? "USD"
            let snapshot = try await db.snapshot(walletID: updated.id.uuidString, currency: currency)
            guard token == generation, case .home(let active) = state, active.id == updated.id else { return }
            if portfolio != snapshot { portfolio = snapshot }
            if observationCurrency != currency {
                observePortfolio(database: db, walletID: updated.id, token: token, currency: currency)
            }
        } catch { OathDiagnostics.record(error);
            guard token == generation, case .home = state else { return }
            throw error
        }
    }

    /// Local history only: values and wallet identifiers never enter telemetry.
    /// SQLite performs the snapshot read and append off the main actor.
    func recordBalanceSnapshot(_ reason: BalanceSnapshotReason, settled: Bool = false,
                               openingHome: Bool = false) async {
        guard case .home(let profile) = state, !resetting, !changingWallet || openingHome else { return }
        let token = generation
        await OathDiagnostics.$operationID.withValue(UUID()) {
            do {
                let database = try await vault.database()
                try Task.checkCancellation()
                guard token == generation, case .home(let active) = state, active.id == profile.id else { return }
                try await database.recordCurrentBalance(walletID: profile.id.uuidString,
                    currency: Locale.autoupdatingCurrent.currency?.identifier ?? "USD", reason: reason, settled: settled)
            } catch is CancellationError { } // Expected lock/navigation cancellation.
            catch { OathDiagnostics.record(error, component: "balance_history", operation: "append_snapshot") }
        }
    }

    private func scheduleBalanceSnapshot(token: UUID) {
        balanceSnapshotWork?.cancel()
        balanceSnapshotWork = Task { [weak self] in
            // Coalesce rapid provider/price commits, never their visible balance
            // updates. Session ownership also captures changes off the Home tab.
            do { try await Task.sleep(for: .milliseconds(450)) }
            catch { return } // Expected replacement, lock or wallet switch.
            guard let self, token == self.generation, self.isUnlocked else { return }
            await self.recordBalanceSnapshot(.balanceUpdate)
        }
    }

    func balanceChange(on interval: DateInterval) -> BalanceDayChange? {
        guard let portfolio, let summary = balanceDaySummary,
              summary.walletID == portfolio.wallet.id,
              summary.interval == interval else { return nil }
        if let change = summary.change(current: portfolio.totalFiat, currency: portfolio.currency, exchangeRate: portfolio.displayExchangeRate) { return change }
        // An empty first-discovery history has no measured change yet. An
        // interrupted read is different: it retains its last valid summary.
        guard summary.opening == nil else { return nil }
        return BalanceDayChange(opening: portfolio.totalFiat, current: portfolio.totalFiat)
    }

    /// Additional period observations are scoped to the current unlocked wallet.
    /// The caller owns cancellation and reports read failures at its UI boundary.
    func observeBalancePeriod(_ period: BalanceHistoryPeriod, at date: Date) async throws -> AsyncThrowingStream<BalanceDaySummary, Error> {
        guard isUnlocked, !resetting, !changingWallet, let portfolio else { throw CancellationError() }
        let token = generation
        let database = try await vault.database()
        try Task.checkCancellation()
        guard token == generation, isUnlocked, self.portfolio?.wallet.id == portfolio.wallet.id,
              self.portfolio?.currency == portfolio.currency else { throw CancellationError() }
        return database.observeBalanceDay(walletID: portfolio.wallet.id, currency: portfolio.currency,
            interval: period.interval(containing: date))
    }

    /// Resume/re-scope only when needed. Navigation never clears display data.
    func refreshBalanceDay() async {
        guard isUnlocked, !resetting, !changingWallet, let portfolio else { return }
        let token = generation
        await OathDiagnostics.$operationID.withValue(UUID()) {
            do {
                let database = try await vault.database()
                guard token == generation, isUnlocked, self.portfolio?.wallet.id == portfolio.wallet.id,
                      self.portfolio?.currency == portfolio.currency else { return }
                observeBalanceDay(database: database, walletID: portfolio.wallet.id,
                    currency: portfolio.currency, interval: BalanceDaySummary.interval(containing: Date()), token: token)
            } catch is CancellationError { } // Expected scene or wallet teardown.
            catch { OathDiagnostics.record(error, component: "balance_history", operation: "resume_day") }
        }
    }

    private func stopBalanceDayObservation() {
        balanceDayObservation?.cancel(); balanceDayObservation = nil
        balanceDayScope = nil
    }

    private func observeBalanceDay(database: OathDatabase, walletID: String, currency: String,
                                   interval: DateInterval, token: UUID) {
        let scope = BalanceDayScope(walletID: walletID, currency: currency, interval: interval)
        guard balanceDayScope != scope || balanceDayObservation == nil else { return }
        stopBalanceDayObservation()
        balanceDayScope = scope
        balanceDayObservation = Task { [weak self] in
            await OathDiagnostics.$operationID.withValue(UUID()) {
                do {
                    for try await summary in database.observeBalanceDay(walletID: walletID, currency: currency, interval: interval) {
                        guard !Task.isCancelled, let self, token == self.generation, self.isUnlocked,
                              self.balanceDayScope == scope, self.portfolio?.wallet.id == walletID,
                              self.portfolio?.currency == currency else { return }
                        self.balanceDaySummary = summary
                    }
                } catch is CancellationError { } // Expected lock, wallet change or day rollover.
                catch { OathDiagnostics.record(error, component: "balance_history", operation: "observe_day") }
                if let self, token == self.generation, self.balanceDayScope == scope, !Task.isCancelled {
                    self.balanceDayObservation = nil
                }
            }
        }
    }

    func refreshBitcoin() async throws {
        guard case .home(let current) = state else { return }
        let token = generation
        let ids = current.addresses.filter { UTXONetwork(rawValue: $0.chain.id) != nil }.compactMap(\.accountID)
        guard !ids.isEmpty else { return }
        bitcoinRefreshing = true
        defer { if token == generation { bitcoinRefreshing = false } }
        do {
            async let quote: Void = refreshBitcoinPrice()
            try await withThrowingTaskGroup(of: Void.self) { group in
                for id in ids { group.addTask { [vault] in try await OathBitcoinSync.shared.refresh(accountID: id, vault: vault) } }
                try await group.waitForAll()
            }
            await quote
            guard token == generation else { return }
            bitcoinRefreshFailed = false; bitcoinRevision += 1
        } catch { OathDiagnostics.record(error);
            guard token == generation, !Task.isCancelled else { return }
            bitcoinRefreshFailed = true; bitcoinRevision += 1
            throw error
        }
    }

    private func refreshBitcoinResult() async -> Result<Void, Error> {
        do { try await refreshBitcoin(); return .success(()) } catch { OathDiagnostics.record(error); return .failure(error) }
    }
    private func refreshAnkrResult() async -> Result<Void, Error> {
        do { try await refreshAnkr(); return .success(()) } catch { OathDiagnostics.record(error); return .failure(error) }
    }
    func refreshAnkr() async throws {
        guard case .home(let current) = state,
              current.addresses.contains(where: { AnkrSynchronizer.supports(networkID: $0.chain.id) || $0.chain == .solana || $0.chain == .tron || $0.chain == .ton || $0.chain == .aptos || $0.chain == .sui || $0.chain == .thorchain || $0.chain == .near || $0.chain == .xrpl || $0.chain == .stellar || $0.chain == .polkadot || $0.chain == .robinhood || $0.chain == .arc || $0.chain == .hyperevm || $0.chain == .monad || $0.chain == .unichain || $0.chain == .celo || $0.chain == .chiliz || $0.chain == .filecoin || $0.chain == .sei || $0.chain == .zerog || $0.chain == .iotex }) else { return }
        let token = generation
        do {
            async let solana: Result<Void, Error> = refreshSolanaResult()
            async let evm: Result<Void, Error> = refreshEVMResult(walletID: current.id.uuidString)
            async let tron: Result<Void, Error> = refreshTronResult()
            async let ton: Result<Void, Error> = refreshTonResult()
            async let aptos: Result<Void, Error> = refreshAptosResult()
            async let sui: Result<Void, Error> = refreshSuiResult()
            async let thorchain: Result<Void, Error> = refreshThorchainResult()
            async let near: Result<Void, Error> = refreshNearResult()
            async let xrpl: Result<Void, Error> = refreshXrplResult()
            async let polkadot: Result<Void, Error> = refreshPolkadotResult()
            async let stellar: Result<Void, Error> = refreshStellarResult()
            async let robinhood: Result<Void, Error> = refreshRobinhoodResult()
            async let monad: Result<Void, Error> = refreshIndexedEVMResult(.monad)
            async let chiliz: Result<Void, Error> = refreshIndexedEVMResult(.chiliz)
            async let filecoin: Result<Void, Error> = refreshIndexedEVMResult(.filecoin)
            async let iotex: Result<Void, Error> = refreshIndexedEVMResult(.iotex)
            async let zerog: Result<Void, Error> = refreshIndexedEVMResult(.zerog)
            async let sei: Result<Void, Error> = refreshIndexedEVMResult(.sei)
            async let celo: Result<Void, Error> = refreshIndexedEVMResult(.celo)
            async let unichain: Result<Void, Error> = refreshIndexedEVMResult(.unichain)
            async let hyperevm: Result<Void, Error> = refreshHyperEVMResult()
            async let arc: Result<Void, Error> = refreshArcResult()
            let results = await (solana, evm, tron, ton, aptos, sui, near, xrpl, stellar, robinhood, arc, hyperevm, monad, unichain, thorchain, celo, chiliz, polkadot, filecoin, sei, zerog, iotex)
            guard token == generation, !Task.isCancelled else { throw CancellationError() }
            // All chains have finished before propagating an original failure.
            // Successful chains keep their committed state even when another fails.
            for result in [results.0, results.1, results.2, results.3, results.4, results.5, results.6, results.7, results.8, results.9, results.10, results.11, results.12, results.13, results.14, results.15, results.16, results.17, results.18, results.19, results.20, results.21] { try result.get() }
            ankrRefreshFailed = false; ankrRevision += 1
        } catch { OathDiagnostics.record(error);
            guard token == generation, !Task.isCancelled else { return }
            ankrRefreshFailed = true; ankrRevision += 1
            throw error
        }
    }

    private func refreshEVMResult(walletID: String) async -> Result<Void, Error> {
        do { try await OathAnkrSync.shared.refresh(walletID: walletID); return .success(()) } catch { OathDiagnostics.record(error); return .failure(error) }
    }
    private func refreshSolanaResult() async -> Result<Void, Error> {
        do { try await refreshSolana(); return .success(()) } catch { OathDiagnostics.record(error); return .failure(error) }
    }
    private func refreshTronResult() async -> Result<Void, Error> {
        do { try await refreshTron(); return .success(()) } catch { OathDiagnostics.record(error); return .failure(error) }
    }
    func refreshTron() async throws {
        guard case .home(let current) = state, isUnlocked else { return }
        let token = generation
        let ids = current.addresses.filter { $0.chain == .tron }.compactMap(\.accountID)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for id in ids { group.addTask { try await OathAnkrSync.shared.refreshTron(accountID: id) } }
            try await group.waitForAll()
        }
        guard token == generation, isUnlocked, !Task.isCancelled else { throw CancellationError() }
    }
    private func refreshTonResult() async -> Result<Void, Error> {
        do { try await refreshTon(); return .success(()) } catch { OathDiagnostics.record(error); return .failure(error) }
    }
    func refreshTon() async throws {
        guard case .home(let current) = state, isUnlocked else { return }
        let token = generation
        let ids = current.addresses.filter { $0.chain == .ton }.compactMap(\.accountID)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for id in ids { group.addTask { try await OathAnkrSync.shared.refreshTon(accountID: id) } }
            try await group.waitForAll()
        }
        guard token == generation, isUnlocked, !Task.isCancelled else { throw CancellationError() }
    }
    private func refreshAptosResult() async -> Result<Void, Error> {
        do { try await refreshAptos(); return .success(()) } catch { OathDiagnostics.record(error); return .failure(error) }
    }
    func refreshAptos() async throws {
        guard case .home(let current) = state, isUnlocked else { return }
        let token = generation
        let ids = current.addresses.filter { $0.chain == .aptos }.compactMap(\.accountID)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for id in ids { group.addTask { try await OathAnkrSync.shared.refreshAptos(accountID: id) } }
            try await group.waitForAll()
        }
        guard token == generation, isUnlocked, !Task.isCancelled else { throw CancellationError() }
    }
    private func refreshSuiResult() async -> Result<Void, Error> {
        do { try await refreshSui(); return .success(()) } catch { OathDiagnostics.record(error); return .failure(error) }
    }
    func refreshSui() async throws {
        guard case .home(let current) = state, isUnlocked else { return }
        let token = generation
        let ids = current.addresses.filter { $0.chain == .sui }.compactMap(\.accountID)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for id in ids { group.addTask { try await OathAnkrSync.shared.refreshSui(accountID: id) } }
            try await group.waitForAll()
        }
        guard token == generation, isUnlocked, !Task.isCancelled else { throw CancellationError() }
    }
    private func refreshThorchainResult() async -> Result<Void, Error> {
        do { try await refreshThorchain(); return .success(()) } catch { OathDiagnostics.record(error); return .failure(error) }
    }
    func refreshThorchain() async throws {
        guard case .home(let current) = state, isUnlocked else { return }
        let token = generation
        let ids = current.addresses.filter { $0.chain == .thorchain }.compactMap(\.accountID)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for id in ids { group.addTask { try await OathAnkrSync.shared.refreshThorchain(accountID: id) } }
            try await group.waitForAll()
        }
        guard token == generation, isUnlocked, !Task.isCancelled else { throw CancellationError() }
    }
    private func refreshNearResult() async -> Result<Void, Error> {
        do { try await refreshNear(); return .success(()) } catch { OathDiagnostics.record(error); return .failure(error) }
    }
    func refreshNear() async throws {
        guard case .home(let current) = state, isUnlocked else { return }
        let token = generation
        let ids = current.addresses.filter { $0.chain == .near }.compactMap(\.accountID)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for id in ids { group.addTask { try await OathAnkrSync.shared.refreshNear(accountID: id) } }
            try await group.waitForAll()
        }
        guard token == generation, isUnlocked, !Task.isCancelled else { throw CancellationError() }
    }
    private func refreshXrplResult() async -> Result<Void, Error> {
        do { try await refreshXrpl(); return .success(()) } catch { OathDiagnostics.record(error); return .failure(error) }
    }
    func refreshXrpl() async throws {
        guard case .home(let current) = state, isUnlocked else { return }
        let token = generation
        let ids = current.addresses.filter { $0.chain == .xrpl }.compactMap(\.accountID)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for id in ids { group.addTask { try await OathAnkrSync.shared.refreshXrpl(accountID: id) } }
            try await group.waitForAll()
        }
        guard token == generation, isUnlocked, !Task.isCancelled else { throw CancellationError() }
    }
    private func refreshPolkadotResult() async -> Result<Void, Error> {
        do { try await refreshPolkadot(); return .success(()) } catch { OathDiagnostics.record(error); return .failure(error) }
    }
    func refreshPolkadot() async throws {
        guard case .home(let current) = state, isUnlocked else { return }
        let token = generation
        let ids = current.addresses.filter { $0.chain == .polkadot }.compactMap(\.accountID)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for id in ids { group.addTask { try await OathAnkrSync.shared.refreshPolkadot(accountID: id) } }
            try await group.waitForAll()
        }
        guard token == generation, isUnlocked, !Task.isCancelled else { throw CancellationError() }
    }
    private func refreshStellarResult() async -> Result<Void, Error> {
        do { try await refreshStellar(); return .success(()) } catch { OathDiagnostics.record(error); return .failure(error) }
    }
    func refreshStellar() async throws {
        guard case .home(let current) = state, isUnlocked else { return }
        let token = generation
        let ids = current.addresses.filter { $0.chain == .stellar }.compactMap(\.accountID)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for id in ids { group.addTask { try await OathAnkrSync.shared.refreshStellar(accountID: id) } }
            try await group.waitForAll()
        }
        guard token == generation, isUnlocked, !Task.isCancelled else { throw CancellationError() }
    }
    private func refreshIndexedEVMResult(_ chain: IndexedEVMChain) async -> Result<Void, Error> {
        do { try await refreshIndexedEVM(chain); return .success(()) }
        catch { OathDiagnostics.record(error, context: ["chain": chain.rawValue]); return .failure(error) }
    }
    func refreshIndexedEVM(_ chain: IndexedEVMChain) async throws {
        guard case .home(let current) = state, isUnlocked else { return }
        let token = generation
        let ids = current.addresses.filter { $0.chain.id == chain.rawValue }.compactMap(\.accountID)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for id in ids { group.addTask { try await OathAnkrSync.shared.refreshIndexedEVM(accountID: id, chain: chain) } }
            try await group.waitForAll()
        }
        guard token == generation, isUnlocked, !Task.isCancelled else { throw CancellationError() }
    }
    private func refreshHyperEVMResult() async -> Result<Void, Error> {
        do { try await refreshHyperEVM(); return .success(()) } catch { OathDiagnostics.record(error); return .failure(error) }
    }
    func refreshHyperEVM() async throws {
        guard case .home(let current) = state, isUnlocked else { return }
        let token = generation
        let ids = current.addresses.filter { $0.chain == .hyperevm }.compactMap(\.accountID)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for id in ids { group.addTask { try await OathAnkrSync.shared.refreshHyperEVM(accountID: id) } }
            try await group.waitForAll()
        }
        guard token == generation, isUnlocked, !Task.isCancelled else { throw CancellationError() }
    }
    private func refreshRobinhoodResult() async -> Result<Void, Error> {
        do { try await refreshRobinhood(); return .success(()) } catch { OathDiagnostics.record(error); return .failure(error) }
    }
    func refreshRobinhood() async throws {
        guard case .home(let current) = state, isUnlocked else { return }
        let token = generation
        let ids = current.addresses.filter { $0.chain == .robinhood }.compactMap(\.accountID)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for id in ids { group.addTask { try await OathAnkrSync.shared.refreshRobinhood(accountID: id) } }
            try await group.waitForAll()
        }
        guard token == generation, isUnlocked, !Task.isCancelled else { throw CancellationError() }
    }
    private func refreshArcResult() async -> Result<Void, Error> {
        do { try await refreshArc(); return .success(()) } catch { OathDiagnostics.record(error); return .failure(error) }
    }
    func refreshArc() async throws {
        guard case .home(let current) = state, isUnlocked else { return }
        let token = generation
        let ids = current.addresses.filter { $0.chain == .arc }.compactMap(\.accountID)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for id in ids { group.addTask { try await OathAnkrSync.shared.refreshArc(accountID: id) } }
            try await group.waitForAll()
        }
        guard token == generation, isUnlocked, !Task.isCancelled else { throw CancellationError() }
    }
    func solanaReceivePathChanged() {
        solanaWork?.cancel()
        solanaWork = Task { [weak self] in await OathDiagnostics.attempt("refresh_solana") { try await self?.refreshSolana() } }
    }
    func refreshSolana() async throws {
        guard case .home(let current) = state else { return }
        let token = generation
        let ids = current.addresses.filter { $0.chain == .solana }.compactMap(\.accountID)
        // Register both public derivations before the synchronizer resolves
        // the active address, including legacy Trust-default wallets.
        for id in ids {
            _ = try await vault.solanaReceiveState(accountID: id)
            guard token == generation, isUnlocked, !Task.isCancelled else { throw CancellationError() }
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for id in ids { group.addTask { try await OathAnkrSync.shared.refreshSolana(accountID: id) } }
            try await group.waitForAll()
        }
    }

    private func refreshBitcoinPrice() async {
        let networks = Set(displayedProfile?.addresses.filter { UTXONetwork(rawValue: $0.chain.id) != nil }.map { $0.chain.id } ?? [])
        await withTaskGroup(of: Void.self) { group in
            for network in networks {
                group.addTask {
                    do {
                        let service = try await OathMarketEnvironment.shared.service()
                        _ = try await service.quote(for: MarketAsset(id: network + ":native", networkID: network, reference: "native", decimals: 8))
                    } catch { OathDiagnostics.record(error); /* Keep the cached USD quote on pricing failures. */ }
                }
            }
        }
    }

    func toggleBalancesHidden() async throws {
        guard case .home = state else { throw OathWalletError.locked }
        let database = try await vault.database()
        try await database.toggleBalanceVisibility()
    }

    func loadMultisigNoticeState(walletID: UUID) async throws -> MultisigNoticeState {
        if let cached = multisigNoticeStates[walletID] { return cached }
        let token = generation
        let database = try await vault.database()
        let state = try await database.multisigNoticeState(walletID: walletID.uuidString)
        try Task.checkCancellation()
        guard token == generation, !resetting else { throw CancellationError() }
        if wallets.contains(where: { $0.id == walletID.uuidString }) {
            // A concurrent acknowledgement wins over this older read.
            if let cached = multisigNoticeStates[walletID] { return cached }
            multisigNoticeStates[walletID] = state
        }
        return state
    }

    func checkStablecoinRestrictions(walletID: UUID, accounts: [StablecoinRestrictionAccount]) async {
        let token = generation
        await OathDiagnostics.$operationID.withValue(UUID()) {
            do {
                let database = try await vault.database()
                guard token == generation, !resetting else { return }
                // Even provider-file decoding stays off the UI actor.
                let checker = await Task.detached(priority: .utility) {
                    OathDiagnostics.$operationID.withValue(UUID()) {
                        OathTokenRPCConfiguration.bundled().makeStablecoinRestrictionCheck()
                    }
                }.value
                guard token == generation, !resetting else { return }
                // A utility task owns the scan after launch. Cancellation of a
                // SwiftUI .task cannot lose a finding or trigger a second probe.
                await StablecoinSecurityScan.shared.run(database: database, walletID: walletID.uuidString, accounts: accounts, checker: checker)
                let saved = try await database.stablecoinSecurityState(walletID: walletID.uuidString)
                guard token == generation, !resetting, wallets.contains(where: { $0.id == walletID.uuidString }) else { return }
                // Do not overwrite a concurrent Got it with an older read.
                if stablecoinSecurityStates[walletID]?.acknowledged != true { stablecoinSecurityStates[walletID] = saved }
            } catch is CancellationError { /* Lock/reset teardown is expected. */ }
            catch {
                if (error as? StoreError) != .missingRecord {
                    OathDiagnostics.record(error, component: "stablecoin_security", operation: "load_wallet_findings")
                }
            }
        }
    }

    func acknowledgeStablecoinSecurity(walletID: UUID) async throws {
        guard isUnlocked, !changingWallet, !resetting, displayedProfile?.id == walletID else { throw CancellationError() }
        let token = generation
        let database = try await vault.database()
        guard token == generation, isUnlocked, !changingWallet, !resetting, displayedProfile?.id == walletID else { throw CancellationError() }
        try await database.acknowledgeStablecoinSecurity(walletID: walletID.uuidString)
        let saved = try await database.stablecoinSecurityState(walletID: walletID.uuidString)
        if token == generation, !resetting { stablecoinSecurityStates[walletID] = saved }
    }

    func acknowledgeMultisigNotice(walletID: UUID) async throws {
        guard isUnlocked, !changingWallet, !resetting, displayedProfile?.id == walletID else {
            throw CancellationError()
        }
        let token = generation
        let database = try await vault.database()
        guard token == generation, isUnlocked, !changingWallet, !resetting, displayedProfile?.id == walletID else {
            throw CancellationError()
        }
        let saved = try await database.acknowledgeMultisigNotice(walletID: walletID.uuidString)
        if token == generation, !resetting, wallets.contains(where: { $0.id == walletID.uuidString }) {
            multisigNoticeStates[walletID] = saved
        }
    }

    func saveAssetFilters(_ selection: PortfolioFilter, walletID: String) async throws {
        guard isUnlocked, !changingWallet, !resetting, displayedProfile?.id.uuidString == walletID else {
            throw OathWalletError.locked
        }
        let token = generation
        let database = try await vault.database()
        try Task.checkCancellation()
        guard token == generation, isUnlocked else { throw CancellationError() }
        let previous = try await database.portfolioFilter(walletID: walletID)
        try await database.savePortfolioFilter(selection, walletID: walletID)
        let snapshot = try await database.snapshot(walletID: walletID, currency: portfolio?.currency ?? "USD")
        guard token == generation, isUnlocked else { throw CancellationError() }
        portfolio = snapshot
        if previous.hidesUnverifiedTokens && !selection.hidesUnverifiedTokens {
            assetFilterWork?.cancel()
            assetFilterWork = Task {
                await OathDiagnostics.attempt("refresh_unfiltered_balances") {
                    try await OathAnkrSync.shared.refreshBalances(walletID: walletID)
                }
            }
        }
    }

    /// Visibility never removes balances, history or signing accounts. A settings
    /// page may edit another wallet without publishing it over the active one.
    func setAssetHidden(_ hidden: Bool, assetID: String, walletID: String) async throws {
        guard isUnlocked, !changingWallet, !resetting else { throw CancellationError() }
        let request = generation
        let database = try await vault.database()
        try Task.checkCancellation()
        guard request == generation, isUnlocked, !resetting else { throw CancellationError() }
        try await database.setAssetHidden(hidden, assetID: assetID, walletID: walletID)
        guard portfolio?.wallet.id == walletID else { return }
        let snapshot = try await database.snapshot(walletID: walletID, currency: portfolio?.currency ?? "USD")
        guard request == generation, isUnlocked, portfolio?.wallet.id == walletID else { throw CancellationError() }
        portfolio = snapshot
    }

    @discardableResult
    func addToken(_ token: OathTokenDefinition, walletID: String) async throws -> WalletSnapshot {
        guard isUnlocked, !changingWallet, !resetting, displayedProfile?.id.uuidString == walletID else {
            throw OathWalletError.locked
        }
        let request = generation
        guard try TokenDiscoveryNetworks.canonical(token.reference, network: token.network.id) ==
            (token.isNativeRepresentation ? "native" : token.reference) else { throw OathTokenLookupError.invalidAddress }
        // A catalog contains identity/name data, not necessarily decimals. Never
        // guess a scale: resolve only the selected contract, off the UI actor.
        let owner = portfolio?.accounts.first { $0.networkID == token.network.id }?.address
        let token = try await OathDiagnostics.$chain.withValue(token.network.id) {
            try await OathDiagnostics.$operationID.withValue(UUID()) {
                try await OathTokenService.shared.resolveForAdding(token, owner: owner)
            }
        }
        guard let decimals = token.decimals else { throw OathTokenLookupError.metadataUnavailable }
        try Task.checkCancellation()
        guard request == generation, isUnlocked, !changingWallet, !resetting,
              displayedProfile?.id.uuidString == walletID else { throw CancellationError() }
        let database = try await vault.database()
        try Task.checkCancellation()
        guard request == generation, isUnlocked else { throw OathWalletError.locked }
        if !token.isNativeRepresentation {
            try await database.trackAsset(AssetRecord(id: token.id, networkID: token.network.id,
                reference: token.reference, name: token.name, symbol: token.symbol, decimals: decimals,
                logo: token.logoURL?.absoluteString), walletID: walletID)
        }
        let snapshot = try await database.snapshot(walletID: walletID, currency: portfolio?.currency ?? "USD")
        guard request == generation, isUnlocked else { throw OathWalletError.locked }
        portfolio = snapshot
        // Adding a token publishes immediately. Resolve its public price without
        // waiting for a balance refresh or requiring the user to open details.
        // The shared service coalesces detail/other callers and publishes to the
        // same price table observed by Home. No wallet identity enters a request.
        let asset = MarketAsset(id: token.isNativeRepresentation ? token.network.id + ":native" : token.id,
            networkID: token.network.id, reference: token.isNativeRepresentation ? "native" : token.reference,
            decimals: token.isNativeRepresentation ? token.network.chain.nativeDecimals : decimals)
        addedTokenPriceWork?.cancel()
        addedTokenPriceWork = Task {
            await OathDiagnostics.$chain.withValue(asset.networkID) {
                await OathDiagnostics.$operationID.withValue(UUID()) {
                    do {
                        let service = try await OathMarketEnvironment.shared.service()
                        _ = try await service.quote(for: asset)
                    } catch {
                        // A valid token need not have a public trading market.
                        if error as? MarketDataError != .notListed {
                            OathDiagnostics.record(error, component: "market_price", operation: "added_token_quote")
                        }
                    }
                }
            }
        }
        return snapshot
    }

    func walletName(_ wallet: WalletRecord?, strings: OathLocalizer) -> String {
        OathWalletNaming.displayName(wallet, strings: strings)
    }

    func selectWallet(_ id: UUID) async throws {
        guard isUnlocked else { throw OathWalletError.locked }
        guard displayedProfile?.id != id else { return }
        try await changeWallet { try await $0.selectWallet(id) }
        OathHaptics.shared.play(.selection)
    }

    func reorderWallets(_ ids: [String]) async throws {
        guard isUnlocked, !changingWallet, Set(ids) == Set(wallets.map(\.id)) else { throw OathWalletError.locked }
        let token = generation
        let database = try await vault.database()
        guard token == generation, isUnlocked else { throw CancellationError() }
        try await database.reorderWallets(ids)
        guard token == generation, isUnlocked else { throw CancellationError() }
        let positions = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, $0.offset) })
        wallets.sort { positions[$0.id, default: 0] < positions[$1.id, default: 0] }
        OathHaptics.shared.play(.selection)
    }

    func removeWallets(_ action: OathWalletRemovalAction, authorization: UUID) async throws {
        if action.resetsApp {
            try await performReset { [vault] in
                try await vault.beginReset(removing: action, authorization: authorization)
            }
            return
        }
        _ = try await changeWallet { try await $0.removeWallets(action, authorization: authorization) }
        OathHaptics.shared.play(.success)
    }

    func recoverDeletedWallets(_ ids: Set<String>) async throws {
        _ = try await changeWallet { try await $0.recoverDeletedWallets(ids) }
        OathHaptics.shared.play(.success)
    }

    private func scheduleDeletionCleanup() {
        deletionTimer?.cancel()
        guard let oldest = recentlyDeletedWallets.compactMap(\.deletedAt).min() else { return }
        let delay = max(1, oldest + OathVaultContents.retention - Date.now.timeIntervalSince1970)
        deletionTimer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            self?.deletionTimer = nil
            await self?.purgeExpiredWallets()
        }
    }

    func purgeExpiredWallets() async {
        guard isUnlocked, !changingWallet,
              recentlyDeletedWallets.contains(where: {
                  $0.deletedAt.map { Date.now.timeIntervalSince1970 - $0 >= OathVaultContents.retention } == true
              }) else { return }
        do { _ = try await changeWallet { try await $0.maintainDeletedWallets() } }
        catch { OathDiagnostics.record(error); if isUnlocked { notice = .walletChangeFailed } }
    }

    func renameWallet(_ id: String, name: String) async throws {
        guard isUnlocked else { throw OathWalletError.locked }
        guard !changingWallet else { throw OathWalletError.unavailable }
        guard wallets.contains(where: { $0.id == id }) else { throw StoreError.missingRecord }
        let token = generation
        let database = try await vault.database()
        try Task.checkCancellation()
        guard token == generation, isUnlocked else { throw CancellationError() }
        // GRDB commits on its writer queue. Existing observations refresh the
        // list and selected portfolio; a rename never switches wallets or keys.
        try await database.renameWallet(id, name: name)
        guard token == generation, isUnlocked else { throw CancellationError() }
        OathHaptics.shared.play(.success)
    }

    func restoreWallet(_ restoration: OathRestoredWallet) async throws {
        _ = try await changeWallet { try await $0.restoreWallet(restoration) }
        OathHaptics.shared.play(.success)
    }

    @discardableResult
    func addWallet(requestID: UUID, importing phrase: OathValidatedMnemonic? = nil,
                   privateKey: OathImportedPrivateKey? = nil, multisig: OathMultisigMaterial? = nil) async throws -> String {
        let profile = try await changeWallet { try await $0.addWallet(requestID: requestID, importing: phrase, privateKey: privateKey, multisig: multisig) }
        OathHaptics.shared.play(.success)
        return profile.id.uuidString
    }

    func customizeWallet(_ id: String, name: String, colorHex: String?, keepDefaultName: Bool = false) async throws {
        guard isUnlocked else { throw OathWalletError.locked }
        guard !changingWallet else { throw OathWalletError.unavailable }
        guard wallets.contains(where: { $0.id == id }) else { throw StoreError.missingRecord }
        let token = generation
        let database = try await vault.database()
        try Task.checkCancellation()
        guard token == generation, isUnlocked else { throw CancellationError() }
        try await database.customizeWallet(id, name: name, colorHex: colorHex, keepDefaultName: keepDefaultName)
        // Completion follows the committed snapshot, not an observation that
        // may arrive on the following run loop. Home opens in the chosen color.
        let records = try await vault.wallets()
        var snapshot: WalletSnapshot?
        if let selected = displayedProfile?.id.uuidString {
            snapshot = try await database.snapshot(walletID: selected, currency: portfolio?.currency ?? "USD")
        }
        guard token == generation, isUnlocked else { throw CancellationError() }
        wallets = records
        if let snapshot { portfolio = snapshot }
        OathHaptics.shared.play(.success)
    }

    @discardableResult
    func addPassphraseWallet(sourceID: String, passphrase: String, requestID: UUID) async throws -> String {
        let profile = try await changeWallet {
            try await $0.addPassphraseWallet(sourceID: sourceID, passphrase: passphrase, requestID: requestID)
        }
        OathHaptics.shared.play(.success)
        return profile.id.uuidString
    }

    func addSeedPasswordWallet(sourceID: String, password: String, requestID: UUID) async throws -> String {
        let profile = try await changeWallet { vault in
            do { return try await vault.addSeedPasswordWallet(sourceID: sourceID, password: password, requestID: requestID) }
            catch is CancellationError { throw CancellationError() }
            catch let error as OathWalletError {
                // diagnostics: seed-password-propagation; changeWallet reports failures and excludes duplicates.
                throw error
            }
            catch {
                // Cryptographic library errors can contain key expressions; expose only a stable failure code.
                OathDiagnostics.record(DiagnosticFailure("electrum_password_derivation_failed"), component: "wallet", operation: "derive_seed_password", context: ["chain": "bitcoin"])
                throw OathWalletError.unavailable
            }
        }
        OathHaptics.shared.play(.success)
        return profile.id.uuidString
    }

    @discardableResult
    private func changeWallet(_ operation: @escaping @Sendable (OathWalletVault) async throws -> OathWalletProfile) async throws -> OathWalletProfile {
        guard isUnlocked else { throw OathWalletError.locked }
        guard !changingWallet else { throw OathWalletError.unavailable }
        let token = UUID()
        generation = token
        homePortfolio.cancel()
        stopBalanceDayObservation()
        changingWallet = true
        ankrWork?.cancel(); ankrWork = nil
        assetFilterWork?.cancel(); assetFilterWork = nil
        addedTokenPriceWork?.cancel(); addedTokenPriceWork = nil
        tokenSelection.cancel()
        solanaWork?.cancel(); solanaWork = nil
        bitcoinWork?.cancel(); bitcoinWork = nil
        deletionTimer?.cancel(); deletionTimer = nil
        databaseObservation?.cancel()
        balanceSnapshotWork?.cancel(); balanceSnapshotWork = nil
        walletsObservation?.cancel()
        let vault = vault
        let work = Task {
            await OathPostSendBalanceRefresh.shared.pause()
            await OathAnkrSync.shared.cancel()
            await OathBitcoinSync.shared.cancel()
            try Task.checkCancellation()
            return try await operation(vault)
        }
        walletWork = work
        defer {
            if token == generation {
                changingWallet = false; walletWork = nil
            }
        }
        do {
            let profile = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
            guard token == generation else { throw CancellationError() }
            try await openHome(profile, token: token)
            return profile
        } catch {
            // A duplicate wallet is an expected form result; cancellation is navigation control flow.
            if case OathWalletError.duplicatePassphraseWallet = error { }
            else if !(error is CancellationError) { OathDiagnostics.record(error) }
            guard token == generation else { throw CancellationError() }
            // If SQL/presentation failed after a vault commit, reconcile the
            // actual selection. Never display one wallet with another's keys.
            do {
                // Finishing a cancelled editor still needs a fresh snapshot.
                // Do not carry its cancellation into this bounded recovery read
                // or a normal Back action would unnecessarily lock the app.
                try await Task { @MainActor in
                    guard token == self.generation, self.isUnlocked else { throw CancellationError() }
                    try await self.openHome(try await vault.maintainDeletedWallets(), token: token)
                }.value
            }
            catch { OathDiagnostics.record(error); if token == generation { await lock(reason: .automatic) } }
            throw error
        }
    }

    private func openHome(_ profile: OathWalletProfile, token: UUID) async throws {
        guard token == generation else { throw CancellationError() }
        // Unlock/migration has already reconciled the encrypted membership. A
        // credential-anchor profile is not a wallet and must never open Home.
        let emptyWalletReset = try await OathDiagnostics.$operationID.withValue(UUID()) {
            try await vault.beginEmptyWalletResetIfNeeded()
        }
        if emptyWalletReset {
            await continueReset()
            return
        }
        if try await vault.legacyBiometricTransitionRequired() {
            guard token == generation else { throw CancellationError() }
            security = try await vault.securityState()
            legacyPhase = .biometrics
            state = .upgrading
            return
        }
        let security = try await vault.securityState()
        let database = try await vault.database()
        let currency = Locale.autoupdatingCurrent.currency?.identifier ?? "USD"
        let records = try await vault.wallets(includingDeleted: true)
        let active = records.filter { $0.deletedAt == nil }
        let snapshot = active.contains(where: { $0.id == profile.id.uuidString })
            ? try await database.snapshot(walletID: profile.id.uuidString, currency: currency) : nil
        if let snapshot { try await prepareHomeDisplay(snapshot, database: database, token: token) }
        guard token == generation else { throw CancellationError() }
        self.security = security
        portfolio = snapshot
        wallets = active
        recentlyDeletedWallets = records.filter { $0.deletedAt != nil }
        if let snapshot {
            publishHome(try OathWalletProfile.stored(snapshot))
            observePortfolio(database: database, walletID: profile.id, token: token, currency: currency)
            observeBalanceDay(database: database, walletID: snapshot.wallet.id, currency: snapshot.currency,
                interval: BalanceDaySummary.interval(containing: Date()), token: token)
        } else {
            homePortfolio.reset(); homeHistory = nil
            stopBalanceDayObservation(); balanceDaySummary = nil
            displayedProfile = nil
            lockReason = .automatic
            state = .home(profile)
        }
        observeWallets(database: database, ids: Set(records.map(\.id)), token: token)
        scheduleDeletionCleanup()
        await recordBalanceSnapshot(.appOpen, openingHome: true)
        await OathPostSendBalanceRefresh.shared.resume(vault: vault)
        guard token == generation, isUnlocked else { throw CancellationError() }
        bitcoinWork?.cancel()
        bitcoinRefreshFailed = false
        bitcoinWork = Task { [weak self] in await OathDiagnostics.attempt("refresh_bitcoin") { try await self?.refreshBitcoin() } }
        let initialBitcoinWork = bitcoinWork
        ankrWork?.cancel()
        ankrRefreshFailed = false
        ankrWork = Task { [weak self] in
            await OathDiagnostics.attempt("refresh_ankr") { try await self?.refreshAnkr() }
            await initialBitcoinWork?.value
            guard let self, token == self.generation, self.isUnlocked, !Task.isCancelled else { return }
            // A missing quote or failed provider must not prevent comparison of
            // the usable total after the first discovery cycle has finished.
            await self.recordBalanceSnapshot(.balanceUpdate, settled: true)
        }
    }

    private func prepareHomeDisplay(_ snapshot: WalletSnapshot, database: OathDatabase, token: UUID) async throws {
        try await OathDiagnostics.$operationID.withValue(UUID()) {
            try await prepareHomeDisplaySnapshot(snapshot, database: database, token: token)
        }
    }

    private func prepareHomeDisplaySnapshot(_ snapshot: WalletSnapshot, database: OathDatabase, token: UUID) async throws {
        guard token == generation else { throw CancellationError() }
        // Settings and wallet loading run concurrently at cold launch. Resolve
        // the saved app language from this snapshot rather than an unready mirror.
        let preference = snapshot.settings["language"].flatMap(OathLanguagePreference.init(rawValue:)) ?? .system
        let locale = preference.resolve().locale.identifier
        let input = OathHomePortfolioInput(walletID: snapshot.wallet.id, holdings: snapshot.holdings,
            currency: snapshot.currency, total: snapshot.totalFiat,
            filter: snapshot.assetFilter.adjusted(for: snapshot.currency), query: "",
            formattingLocale: locale, sortingLocale: locale, hiddenAssetIDs: snapshot.hiddenAssetIDs)
        // SQL and formatting run on their own executors. No provider request or
        // authentication callback controls the availability of saved rows.
        async let history = OathDiagnostics.attempt("prepare_home_history") {
            try await database.chainHistory(walletID: snapshot.wallet.id, currency: snapshot.currency,
                                            limit: 51, localeIdentifier: locale)
        }
        let day = BalanceDaySummary.interval(containing: Date())
        async let dailySummary = OathDiagnostics.attempt("prepare_balance_day") {
            try await database.balanceDay(walletID: snapshot.wallet.id, currency: snapshot.currency, interval: day)
        }
        let prepared = try await homePortfolio.prepare(input)
        let items = await history
        let summary = await dailySummary
        guard token == generation, !Task.isCancelled else { throw CancellationError() }
        try homePortfolio.publish(prepared)
        homeHistory = items.map { .init(walletID: snapshot.wallet.id, currency: snapshot.currency,
                                       localeIdentifier: locale, items: $0) }
        // Preserve the matching last-known baseline if this best-effort local
        // read fails; never borrow another wallet/currency/day's comparison.
        if let summary { balanceDaySummary = summary }
        else if balanceDaySummary?.walletID != snapshot.wallet.id || balanceDaySummary?.currency != snapshot.currency
            || balanceDaySummary?.interval != day { balanceDaySummary = nil }
    }

    private func observeWallets(database: OathDatabase, ids: Set<String>, token: UUID) {
        walletsObservation?.cancel()
        walletsObservation = Task { [weak self] in
            do {
                for try await records in database.observeWallets(includingDeleted: true) {
                    guard let self, token == self.generation, self.isUnlocked else { return }
                    self.wallets = records.filter { ids.contains($0.id) && $0.deletedAt == nil }
                    self.recentlyDeletedWallets = records.filter { ids.contains($0.id) && $0.deletedAt != nil }
                }
            } catch is CancellationError { }
            catch { OathDiagnostics.record(error);
                guard !Task.isCancelled, let self, token == self.generation else { return }
                self.notice = .walletUnavailable
            }
        }
    }

    private func observePortfolio(database: OathDatabase, walletID: UUID, token: UUID, currency: String) {
        databaseObservation?.cancel()
        observationCurrency = currency
        databaseObservation = Task { [weak self] in
            do {
                for try await value in database.observeWallet(walletID: walletID.uuidString, currency: currency) {
                    guard let self, token == self.generation, case .home(let active) = self.state,
                          active.id == walletID else { return }
                    let previous = self.portfolio
                    if previous != value { self.portfolio = value }
                    self.observeBalanceDay(database: database, walletID: walletID.uuidString, currency: value.currency,
                        interval: BalanceDaySummary.interval(containing: Date()), token: token)
                    if previous?.currency != value.currency || previous?.totalFiat != value.totalFiat
                        || previous?.valuationComplete != value.valuationComplete || previous?.holdings != value.holdings {
                        self.scheduleBalanceSnapshot(token: token)
                    }
                    let updated = try OathWalletProfile.stored(value)
                    if active != updated { self.publishHome(updated) }
                }
            } catch is CancellationError { }
            catch { OathDiagnostics.record(error);
                guard !Task.isCancelled, let self, token == self.generation else { return }
                self.observationCurrency = nil
                self.notice = .walletUnavailable
            }
        }
    }

    private func publishHome(_ profile: OathWalletProfile) {
        if displayedProfile != profile { displayedProfile = profile }
        lockReason = .automatic
        state = .home(profile)
    }

    func resetFailedLegacyUpgrade() async {
        guard isUpgrading, legacyPhase == .failed, !busy, !resetting, let source = legacySource else { return }
        busy = true
        defer { busy = false }
        let operationID = UUID()
        do {
            try await OathDiagnostics.$operationID.withValue(operationID) {
                try await vault.beginFailedLegacyReset(source: source)
            }
            await continueReset()
        } catch {
            OathDiagnostics.$operationID.withValue(operationID) {
                OathDiagnostics.record(DiagnosticFailure("legacy_recovery_reset_failed"),
                    component: "legacy_upgrade", operation: "begin_reset", context: ["stage": "journal"])
            }
            notice = .resetFailed
        }
    }

    func resetApp(authorization: UUID) async throws {
        try await performReset { [vault] in try await vault.beginReset(authorization: authorization) }
    }

    private func performReset(_ begin: () async throws -> Void) async throws {
        guard isUnlocked, !resetting, !changingWallet else { throw OathWalletError.locked }
        // Consume the capability and commit durable intent before leaving the
        // warning. Failure here erases nothing; reload using the current security mode.
        do { try await begin() }
        catch { OathDiagnostics.record(error);
            // A journal write failure can leave the in-memory vault locked,
            // even when the user disabled their PIN. Reconcile both modes.
            generation = UUID()
            displayedProfile = nil; portfolio = nil; wallets = []; recentlyDeletedWallets = []
            homePortfolio.reset(); homeHistory = nil
            stopBalanceDayObservation(); balanceDaySummary = nil
            deletionTimer?.cancel(); deletionTimer = nil
            completingInitialSetup = false
            state = .loading
            await load()
            throw error
        }
        await continueReset()
        OathHaptics.shared.play(resetFailed ? .error : .success)
    }

    func retryReset() async {
        guard resetting, resetFailed else { return }
        await continueReset()
        OathHaptics.shared.play(resetFailed ? .error : .success)
    }

    private func continueReset() async {
        resetting = true; resetFailed = false
        bitcoinWork?.cancel(); bitcoinWork = nil
        ankrWork?.cancel(); ankrWork = nil
        assetFilterWork?.cancel(); assetFilterWork = nil
        addedTokenPriceWork?.cancel(); addedTokenPriceWork = nil
        tokenSelection.cancel()
        solanaWork?.cancel(); solanaWork = nil
        await OathSendStatusTracking.shared.beginReset()
        await OathPostSendBalanceRefresh.shared.reset()
        await OathBitcoinSync.shared.cancel()
        await OathAnkrSync.shared.cancel()
        generation = UUID()
        backgroundLock?.cancel(); backgroundLock = nil; lockPolicy.reset()
        databaseObservation?.cancel(); databaseObservation = nil
        balanceSnapshotWork?.cancel(); balanceSnapshotWork = nil
        walletsObservation?.cancel(); walletsObservation = nil
        walletWork?.cancel(); walletWork = nil
        unlockWork?.cancel(); unlockWork = nil
        observationCurrency = nil
        displayedProfile = nil; portfolio = nil; wallets = []; recentlyDeletedWallets = []
        homePortfolio.reset(); homeHistory = nil
        stopBalanceDayObservation(); balanceDaySummary = nil
        deletionTimer?.cancel(); deletionTimer = nil
        changingWallet = false; busy = false; notice = nil
        biometricRepairNeeded = false; completingInitialSetup = false; welcomesWithRetainedWallets = false
        legacySource = nil; legacyPhase = .migrating
        lockReason = .automatic
        state = .loading
        do {
            _ = try await vault.resumeResetIfNeeded()
            security = .init()
            state = .onboarding
            resetting = false
            OathSendStatusTracking.shared.endReset()
        } catch { OathDiagnostics.record(error);
            // No rollback to a partially erased wallet, and no false success.
            // The confirmed durable operation may only retry to completion.
            resetFailed = true
        }
    }
}

/// One formatter for the customization preview, Home and background saving.
/// The confirmed text is durable even when the automatic local label changes language.
enum OathWalletNaming {
    static func syncedName(_ wallet: WalletRecord, strings: OathLocalizer = .current) -> String {
        if !wallet.name.isEmpty { return wallet.name }
        if let confirmed = wallet.confirmedName, !confirmed.isEmpty { return confirmed }
        return displayName(wallet, strings: strings)
    }
    static func displayName(_ wallet: WalletRecord?, strings: OathLocalizer) -> String {
        guard let wallet else { return strings.text(.mainWalletName) }
        if !wallet.name.isEmpty { return wallet.name }
        if wallet.kind == "passphrase" {
            return strings.format(.passphraseWalletName, strings.number(max(1, wallet.nameIndex)))
        }
        let base: String
        switch wallet.nameGroup {
        case "multisig": base = strings.text(.multisigNoticeTitle)
        case "imported": base = strings.text(.importedWalletName)
        case "restored": base = strings.text(.restoredWalletName)
        case let group? where group.hasPrefix("network:"):
            let networkID = String(group.dropFirst("network:".count))
            let network = OathImportChain(rawValue: networkID)?.name ?? networkID
            base = strings.format(.networkWalletName, strings.invariant(network))
        default: base = strings.text(.mainWalletName)
        }
        return wallet.nameIndex > 0 ? strings.format(.indexedWalletName, base, strings.number(wallet.nameIndex)) : base
    }

}
