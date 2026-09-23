import Foundation
import Observation
import UIKit
@preconcurrency import UserNotifications

@MainActor
@Observable
final class PushNotificationCoordinator {
    static let shared = PushNotificationCoordinator()

    private(set) var authorizationState: PushAuthorizationState = .unknown
    private(set) var registrationState: PushRegistrationState = .idle
    private(set) var lastSuccessfulRegistrationAt: Date?
    private(set) var permissionWasDenied = false
    var pendingRoute: PushNotificationRoute?

    @ObservationIgnored
    private var database: WalletDatabase?
    @ObservationIgnored
    private weak var notificationSettings: WalletSettingsStore?
    @ObservationIgnored
    private var repository: PushNotificationRegistrationRepository?
    @ObservationIgnored
    private var persistence: PushNotificationPersistence?
    @ObservationIgnored
    private var reconciliationTask: Task<Void, Never>?
    @ObservationIgnored
    private var pendingReconciliation:
        (reason: PushReconciliationReason, generation: UInt64)?
    @ObservationIgnored
    private var retryTask: Task<Void, Never>?
    @ObservationIgnored
    private var openAuditTask: Task<Void, Never>?
    @ObservationIgnored
    private var historySyncTask: Task<Void, Never>?
    @ObservationIgnored
    private var retryCount = 0
    @ObservationIgnored
    private var reconciliationGeneration: UInt64 = 0
    @ObservationIgnored
    private var openAuditGeneration: UInt64 = 0
    @ObservationIgnored
    private var isReconcilingDeliveredNotifications = false
    @ObservationIgnored
    private var requiresRemoteUserRotation = false
    @ObservationIgnored
    private var isDeviceMigrationImporting = false
    @ObservationIgnored
    private var hasStarted = false
    @ObservationIgnored
    private let vault = PushInstallationVault.shared
    @ObservationIgnored
    private let installationLifecycle =
        PushNotificationInstallationLifecycle()

    private init() {}

    func start(
        database: WalletDatabase,
        settings: WalletSettingsStore
    ) async {
        notificationSettings = settings
        configureStorage(database: database)
        guard !hasStarted else {
            await appDidBecomeActive(settings: settings)
            return
        }
        hasStarted = true
        await refreshAuthorizationState()
        await synchronizeMasterPreference(settings: settings)
        if await secureCleanupAllowsRegistration() {
            await applyRegistrationLifecycle(
                settings: settings,
                reason: .appActivation
            )
        }
        await reconcileDeliveredNotifications()
        scheduleOpenAuditDrain()
        scheduleNotificationHistorySync()
    }

    func appDidBecomeActive(
        settings: WalletSettingsStore
    ) async {
        guard hasStarted else { return }
        await refreshAuthorizationState()
        await synchronizeMasterPreference(settings: settings)
        if await secureCleanupAllowsRegistration() {
            await applyRegistrationLifecycle(
                settings: settings,
                reason: .appActivation
            )
        }
        await reconcileDeliveredNotifications()
        scheduleOpenAuditDrain()
        scheduleNotificationHistorySync()
    }

    func enableNotifications(
        settings: WalletSettingsStore
    ) async -> Bool {
        settings.recordNotificationEnableIntent()
        await settings.flush()

        let notificationCenter = UNUserNotificationCenter.current()
        let current = await notificationCenter.notificationSettings()
        let granted: Bool

        switch current.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            granted = true
        case .notDetermined:
            do {
                granted = try await notificationCenter
                    .requestAuthorization(
                        options: [.alert, .badge, .sound]
                    )
            } catch {
                granted = false
                registrationState = .failed(
                    "authorization_\(Self.errorTypeCode(error))"
                )
            }
        case .denied:
            granted = false
        @unknown default:
            granted = false
        }

        await refreshAuthorizationState()
        permissionWasDenied = !granted
        guard granted else {
            settings.synchronizeNotificationsEnabledWithSystem(false)
            settings.markNotificationWelcomePresented()
            await settings.flush()
            await deactivateRemoteRegistration()
            return false
        }

        settings.setNotificationsEnabled(true)
        settings.markNotificationWelcomePresented()
        await settings.flush()
        await activateRemoteRegistration(reason: .preferencesChanged)
        return true
    }

    func disableNotifications(
        settings: WalletSettingsStore
    ) async {
        permissionWasDenied = false
        settings.setNotificationsEnabled(false)
        settings.markNotificationWelcomePresented()
        await settings.flush()
        await deactivateRemoteRegistration()
    }

    func preferencesDidChange(
        settings: WalletSettingsStore
    ) async {
        await settings.flush()
        reconcile(reason: .preferencesChanged)
    }

    func walletDataDidChange() {
        reconcile(reason: .walletChanged)
    }

    func chainSynchronizationDidComplete() {
        reconcile(reason: .chainSynchronization)
    }

    func deviceMigrationDidComplete() {
        isDeviceMigrationImporting = false
        requiresRemoteUserRotation = true
        reconcile(reason: .deviceMigration)
    }

    func beginDeviceMigrationImport() {
        isDeviceMigrationImporting = true
        reconciliationGeneration &+= 1
        openAuditGeneration &+= 1
        pendingReconciliation = nil
        reconciliationTask?.cancel()
        retryTask?.cancel()
        openAuditTask?.cancel()
        historySyncTask?.cancel()
    }

    func preparePersistentStateForDeviceMigrationImport(
        database: WalletDatabase
    ) async {
        let repository = PushNotificationRegistrationRepository(
            database: database
        )
        do {
            let identity = try await identityBoundToRemoteUser(
                repository: repository,
                allowsUnboundProfile: true
            )
            guard let remoteUserID = identity.remoteUserID else {
                throw PushNotificationRegistrationRepositoryError
                    .missingRemoteUserID
            }
            try await repository.prepareInstallationIdentity(
                installationID: identity.installationID,
                remoteUserID: remoteUserID
            )
        } catch {
        }
    }

    func deviceMigrationImportDidFail() {
        isDeviceMigrationImporting = false
        reconcile(reason: .appActivation)
    }

    func didRegisterForRemoteNotifications(deviceToken: Data) {
        do {
            guard try installationLifecycle.acceptAPNSToken(
                deviceToken,
                topic: Self.apnsTopic,
                environment: Self.apnsEnvironment
            ) else {
                return
            }
            retryCount = 0
            reconcile(reason: .apnsTokenChanged)
        } catch {
            let code = Self.errorCode(error)
            registrationState = .failed(code)
        }
    }

    func didFailToRegisterForRemoteNotifications(error: Error) {
        guard installationLifecycle.registrationAllowed else {
            return
        }
        let code = "apns_registration_\(Self.errorTypeCode(error))"
        registrationState = .failed(code)
    }

    func permitsForegroundNotification(userInfo: [AnyHashable: Any]) -> Bool {
        guard let settings = notificationSettings,
              let payload = PushNotificationPayload(userInfo: userInfo) else { return false }
        return PushNotificationPreferencePolicy.allows(
            payload.category, master: settings.notificationsEnabled,
            received: settings.receivedTransactionNotificationsEnabled,
            sent: settings.sentTransactionNotificationsEnabled,
            announcements: settings.adminNotificationsEnabled
        )
    }

    func record(
        notification: UNNotification,
        openedAt: Date? = nil
    ) async -> PushNotificationRoute? {
        if persistence == nil,
           let database = try? WalletDatabaseRuntime.require() {
            configureStorage(database: database)
        }
        guard let persistence else { return nil }
        do {
            return try await persistence.record(
                notification: notification,
                openedAt: openedAt
            )
        } catch {
            return nil
        }
    }

    func handleResponse(_ response: UNNotificationResponse) async {
        guard let route = await record(
            notification: response.notification,
            openedAt: Date()
        ) else {
            return
        }
        pendingRoute = route
        scheduleOpenAuditDrain()
    }

    func consumePendingRoute() -> PushNotificationRoute? {
        defer { pendingRoute = nil }
        return pendingRoute
    }

    private func reconcileDeliveredNotifications() async {
        guard !isReconcilingDeliveredNotifications,
              persistence != nil else {
            return
        }
        isReconcilingDeliveredNotifications = true
        defer {
            isReconcilingDeliveredNotifications = false
        }

        let batch = await withCheckedContinuation {
            continuation in
            UNUserNotificationCenter.current()
                .getDeliveredNotifications {
                    continuation.resume(
                        returning: DeliveredNotificationBatch(
                            notifications: $0
                        )
                    )
                }
        }
        for notification in batch.notifications {
            guard !Task.isCancelled else { return }
            _ = await record(notification: notification)
        }
    }

    func suspendForAppReset() {
        installationLifecycle.suspend()
        reconciliationGeneration &+= 1
        openAuditGeneration &+= 1
        pendingReconciliation = nil
        requiresRemoteUserRotation = false
        isDeviceMigrationImporting = false
        reconciliationTask?.cancel()
        retryTask?.cancel()
        openAuditTask?.cancel()
        historySyncTask?.cancel()
        UIApplication.shared.unregisterForRemoteNotifications()
        registrationState = .idle
        retryCount = 0
    }

    private func secureCleanupAllowsRegistration() async -> Bool {
        guard let database else { return true }
        let result =
            await WalletSecureCleanupRecoveryService.shared
                .retryPendingCleanup(database: database)
        guard !result.hasPendingPushCleanup else {
            installationLifecycle.suspend()
            registrationState = .failed("reset_cleanup_pending")
            return false
        }
        return true
    }

    func reconcile(reason: PushReconciliationReason) {
        guard repository != nil,
              !isDeviceMigrationImporting,
              installationLifecycle.registrationAllowed else {
            return
        }
        retryTask?.cancel()
        reconciliationGeneration &+= 1
        let generation = reconciliationGeneration
        pendingReconciliation = (reason, generation)
        guard reconciliationTask == nil else { return }
        reconciliationTask = Task { @MainActor [weak self] in
            await self?.runReconciliationQueue()
        }
    }

    private func runReconciliationQueue() async {
        while !Task.isCancelled,
              let pending = pendingReconciliation {
            pendingReconciliation = nil
            if pending.reason != .apnsTokenChanged {
                try? await Task.sleep(for: .milliseconds(300))
            }
            guard !Task.isCancelled else { break }
            await performReconciliation(
                reason: pending.reason,
                generation: pending.generation
            )
        }
        reconciliationTask = nil
    }

    private func performReconciliation(
        reason: PushReconciliationReason,
        generation: UInt64
    ) async {
        guard let repository,
              isCurrentReconciliation(generation) else {
            return
        }

        var attemptGeneration: Int64?
        var attemptedInstallationID: String?
        do {
            let forceRemoteUserRotation =
                requiresRemoteUserRotation
            var identity = try await identityBoundToRemoteUser(
                repository: repository,
                allowsUnboundProfile: !forceRemoteUserRotation
            )
            attemptedInstallationID = identity.installationID
            guard let remoteUserID = identity.remoteUserID else {
                throw PushNotificationRegistrationRepositoryError
                    .missingRemoteUserID
            }
            try await repository.prepareInstallationIdentity(
                installationID: identity.installationID,
                remoteUserID: remoteUserID,
                forceRemoteUserRotation: forceRemoteUserRotation
            )
            if forceRemoteUserRotation {
                requiresRemoteUserRotation = false
            }
            guard isCurrentReconciliation(generation) else {
                return
            }
            guard identity.apnsToken != nil else {
                try await repository.markReconciliationNeeded()
                guard isCurrentReconciliation(generation) else {
                    return
                }
                registrationState = .waitingForDeviceToken
                installationLifecycle.requestAPNSTokenIfEnabled()
                return
            }

            registrationState = .registering
            var snapshot = try await repository.snapshot(
                identity: identity,
                apnsEnvironment: Self.apnsEnvironment
            )
            guard isCurrentReconciliation(generation) else {
                return
            }
            attemptGeneration =
                try await repository.markRegistrationAttempt()
            guard isCurrentReconciliation(generation) else {
                return
            }
            let client = try PushNotificationAPIClient.configured()
            let serverRegistrationKnown =
                await repository.hasSuccessfulRegistration(
                    installationID: identity.installationID
                )
            guard isCurrentReconciliation(generation) else {
                return
            }
            let response: PushInstallationSnapshotResponse
            do {
                response = try await client.reconcile(
                    snapshot: snapshot,
                    identity: identity,
                    serverRegistrationKnown: serverRegistrationKnown
                )
            } catch PushNotificationAPIError.credentialRejected {
                identity = try vault
                    .rotateIdentityPreservingAPNSToken()
                attemptedInstallationID = identity.installationID
                snapshot = try await repository.snapshot(
                    identity: identity,
                    apnsEnvironment: Self.apnsEnvironment
                )
                guard isCurrentReconciliation(generation) else {
                    return
                }
                attemptGeneration =
                    try await repository.markRegistrationAttempt()
                guard isCurrentReconciliation(generation) else {
                    return
                }
                response = try await client.reconcile(
                    snapshot: snapshot,
                    identity: identity,
                    serverRegistrationKnown: false
                )
            }
            guard isCurrentReconciliation(generation),
                  let attemptGeneration else {
                return
            }
            let didCommit = try await repository
                .markRegistrationSucceeded(
                    snapshotDigest: response.snapshotDigest,
                    installationID: identity.installationID,
                    reconciliationGeneration: attemptGeneration
                )
            guard didCommit,
                  isCurrentReconciliation(generation) else {
                return
            }
            registrationState = .registered
            lastSuccessfulRegistrationAt =
                PushServiceDate.parse(response.serverTime) ?? Date()
            retryCount = 0
            retryTask?.cancel()
            scheduleNotificationHistorySync()
        } catch {
            guard isCurrentReconciliation(generation) else {
                return
            }
            let code = Self.errorCode(error)
            try? await repository.markRegistrationFailed(
                errorCode: code,
                installationID: attemptedInstallationID,
                reconciliationGeneration: attemptGeneration
            )
            guard isCurrentReconciliation(generation) else {
                return
            }
            registrationState = .failed(code)
            scheduleRetry()
        }
    }

    private func scheduleRetry() {
        retryTask?.cancel()
        retryCount = min(retryCount + 1, 8)
        let exponent = min(retryCount - 1, 6)
        let seconds = min(300, 5 * (1 << exponent))
        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.reconcile(reason: .retry)
        }
    }

    private func scheduleOpenAuditDrain(
        after delay: TimeInterval = 0
    ) {
        guard persistence != nil else { return }
        openAuditGeneration &+= 1
        let generation = openAuditGeneration
        openAuditTask?.cancel()
        openAuditTask = Task { @MainActor [weak self] in
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            guard !Task.isCancelled else { return }
            await self?.drainPendingOpenAudits(
                generation: generation
            )
        }
    }

    private func scheduleNotificationHistorySync() {
        guard persistence != nil,
              historySyncTask == nil else {
            return
        }
        historySyncTask = Task { @MainActor [weak self] in
            await self?.reconcileServerNotificationHistory()
            self?.historySyncTask = nil
        }
    }

    private func reconcileServerNotificationHistory() async {
        guard let repository,
              let persistence else {
            return
        }
        do {
            guard let identity = try vault.currentIdentity(),
                  await repository.hasSuccessfulRegistration(
                      installationID: identity.installationID
                  ) else {
                return
            }
            let client = try PushNotificationAPIClient.configured()
            let pendingBackfill =
                try await persistence.historyBackfillCursor()
            // Once per migrated installation, revisit history to recover asset
            // identity independently of fiat-denominated display arguments.
            if try await persistence.needsLocalizationBackfill() {
                if pendingBackfill != nil {
                    _ = try await syncHistoryPages(
                        client: client, identity: identity, persistence: persistence,
                        initialCursor: nil, stopAfterExisting: true,
                        updatesBackfillCursor: false
                    )
                }
                let completed = try await syncHistoryPages(
                    client: client, identity: identity, persistence: persistence,
                    initialCursor: pendingBackfill, stopAfterExisting: false,
                    updatesBackfillCursor: true
                )
                if completed { try await persistence.completeLocalizationBackfill() }
                return
            }
            let latestReachedExisting = try await syncHistoryPages(
                client: client,
                identity: identity,
                persistence: persistence,
                initialCursor: nil,
                stopAfterExisting: true,
                updatesBackfillCursor: pendingBackfill == nil
            )
            guard latestReachedExisting,
                  !Task.isCancelled else {
                return
            }
            guard let pendingBackfill else {
                try await persistence.setHistoryBackfillCursor(nil)
                return
            }
            _ = try await syncHistoryPages(
                client: client,
                identity: identity,
                persistence: persistence,
                initialCursor: pendingBackfill,
                stopAfterExisting: false,
                updatesBackfillCursor: true
            )
        } catch {
            guard !Task.isCancelled else { return }
        }
    }

    private func syncHistoryPages(
        client: PushNotificationAPIClient,
        identity: PushInstallationIdentity,
        persistence: PushNotificationPersistence,
        initialCursor: String?,
        stopAfterExisting: Bool,
        updatesBackfillCursor: Bool
    ) async throws -> Bool {
        var cursor = initialCursor
        for _ in 0..<100 {
            try Task.checkCancellation()
            let response = try await client.notificationHistory(
                identity: identity,
                cursor: cursor
            )
            let saved = try await persistence.record(
                historyItems: response.items
            )
            if stopAfterExisting && saved.existingCount > 0 {
                return true
            }
            guard let nextCursor = response.nextCursor else {
                if updatesBackfillCursor {
                    try await persistence.setHistoryBackfillCursor(nil)
                }
                return true
            }
            if updatesBackfillCursor {
                try await persistence.setHistoryBackfillCursor(
                    nextCursor
                )
            }
            cursor = nextCursor
        }
        return false
    }

    private func drainPendingOpenAudits(
        generation: UInt64
    ) async {
        guard let persistence,
              isCurrentOpenAuditDrain(generation) else {
            return
        }

        let audits: [DBNotificationOpenAuditRecord]
        do {
            audits = try await persistence.pendingOpenAudits()
        } catch {
            scheduleOpenAuditDrain(after: 30)
            return
        }

        guard !audits.isEmpty else {
            do {
                if let nextDate =
                    try await persistence.nextOpenAuditDate() {
                    scheduleOpenAuditDrain(
                        after: max(
                            0.25,
                            nextDate.timeIntervalSinceNow
                        )
                    )
                }
            } catch {
            }
            return
        }

        let identity: PushInstallationIdentity
        let client: PushNotificationAPIClient
        do {
            guard let current = try vault.currentIdentity() else {
                scheduleOpenAuditDrain(after: 30)
                return
            }
            identity = current
            client = try PushNotificationAPIClient.configured()
        } catch {
            await deferOpenAudits(
                audits,
                errorCode: Self.errorCode(error),
                persistence: persistence
            )
            return
        }

        for audit in audits {
            guard isCurrentOpenAuditDrain(generation) else {
                return
            }
            do {
                try await client.markOpened(
                    notificationID: audit.notificationID,
                    identity: identity
                )
                guard isCurrentOpenAuditDrain(generation) else {
                    return
                }
                try await persistence.markOpenAuditSucceeded(
                    notificationID: audit.notificationID
                )
            } catch {
                guard isCurrentOpenAuditDrain(generation) else {
                    return
                }
                let retryAt = Self.openAuditRetryDate(
                    attemptCount: audit.attemptCount + 1
                )
                do {
                    try await persistence.markOpenAuditFailed(
                        notificationID: audit.notificationID,
                        errorCode: Self.errorCode(error),
                        attemptedAt: Date(),
                        retryAt: retryAt
                    )
                } catch {
                }
            }
        }

        guard isCurrentOpenAuditDrain(generation) else {
            return
        }
        do {
            if let nextDate = try await persistence.nextOpenAuditDate() {
                scheduleOpenAuditDrain(
                    after: max(0.25, nextDate.timeIntervalSinceNow)
                )
            }
        } catch {
        }
    }

    private func deferOpenAudits(
        _ audits: [DBNotificationOpenAuditRecord],
        errorCode: String,
        persistence: PushNotificationPersistence
    ) async {
        var earliestRetry: Date?
        for audit in audits {
            let retryAt = Self.openAuditRetryDate(
                attemptCount: audit.attemptCount + 1
            )
            do {
                try await persistence.markOpenAuditFailed(
                    notificationID: audit.notificationID,
                    errorCode: errorCode,
                    attemptedAt: Date(),
                    retryAt: retryAt
                )
                if let current = earliestRetry {
                    earliestRetry = min(current, retryAt)
                } else {
                    earliestRetry = retryAt
                }
            } catch {
            }
        }
        if let earliestRetry {
            scheduleOpenAuditDrain(
                after: max(0.25, earliestRetry.timeIntervalSinceNow)
            )
        }
    }

    private func isCurrentReconciliation(
        _ generation: UInt64
    ) -> Bool {
        !Task.isCancelled
            && generation == reconciliationGeneration
    }

    private func isCurrentOpenAuditDrain(
        _ generation: UInt64
    ) -> Bool {
        !Task.isCancelled && generation == openAuditGeneration
    }

    private static func openAuditRetryDate(
        attemptCount: Int
    ) -> Date {
        let exponent = min(max(attemptCount - 1, 0), 9)
        let delay = min(3_600, 5 * (1 << exponent))
        return Date().addingTimeInterval(TimeInterval(delay))
    }

    private func identityBoundToRemoteUser(
        repository: PushNotificationRegistrationRepository,
        allowsUnboundProfile: Bool
    ) async throws -> PushInstallationIdentity {
        var identity = try vault.loadOrCreateIdentity()
        guard identity.remoteUserID == nil else {
            return identity
        }

        let existingRemoteUserID =
            await repository.compatibleRemoteUserID(
                installationID: identity.installationID,
                allowsUnboundProfile: allowsUnboundProfile
            )
        identity = try vault.assignRemoteUserID(
            existingRemoteUserID
                ?? UUID().uuidString.lowercased()
        )
        return identity
    }

    private func refreshAuthorizationState() async {
        let status = await UNUserNotificationCenter.current()
            .notificationSettings().authorizationStatus
        authorizationState = switch status {
        case .notDetermined:
            .notDetermined
        case .denied:
            .denied
        case .authorized:
            .authorized
        case .provisional:
            .provisional
        case .ephemeral:
            .ephemeral
        @unknown default:
            .unknown
        }
    }

    private func configureStorage(database: WalletDatabase) {
        guard self.database == nil else { return }
        self.database = database
        repository = PushNotificationRegistrationRepository(
            database: database
        )
        persistence = PushNotificationPersistence(database: database)
    }

    private func applyRegistrationLifecycle(
        settings: WalletSettingsStore,
        reason: PushReconciliationReason
    ) async {
        if settings.notificationsEnabled {
            await activateRemoteRegistration(reason: reason)
        } else {
            await deactivateRemoteRegistration()
        }
    }

    private func activateRemoteRegistration(
        reason: PushReconciliationReason
    ) async {
        do {
            try installationLifecycle.enableRegistration(
                topic: Self.apnsTopic,
                environment: Self.apnsEnvironment
            )
            _ = await installationLifecycle
                .retryPendingDeactivations()
            reconcile(reason: reason)
        } catch {
            let code = Self.errorCode(error)
            registrationState = .failed(code)
        }
    }

    private func deactivateRemoteRegistration() async {
        reconciliationGeneration &+= 1
        pendingReconciliation = nil
        let cancelledReconciliation = reconciliationTask
        cancelledReconciliation?.cancel()
        await cancelledReconciliation?.value
        reconciliationTask = nil
        retryTask?.cancel()
        retryTask = nil
        historySyncTask?.cancel()
        historySyncTask = nil
        let result = await installationLifecycle
            .disableAndDeactivate()
        registrationState = result.pendingCount == 0
            ? .idle
            : .failed(
                "deactivation_pending_"
                    + (result.lastErrorCode ?? "unknown")
            )
        retryCount = 0
    }

    private func synchronizeMasterPreference(
        settings: WalletSettingsStore
    ) async {
        let action = PushNotificationMasterPreferenceAction.resolve(
            authorizationState: authorizationState,
            notificationsEnabled: settings.notificationsEnabled,
            explicitlyDisabled:
                settings.notificationsWereExplicitlyDisabled
        )

        switch action {
        case .none:
            break
        case .enableFromSystemAuthorization:
            settings.synchronizeNotificationsEnabledWithSystem(true)
            settings.markNotificationWelcomePresented()
            await settings.flush()
        case .disableForSystemAuthorization:
            settings.synchronizeNotificationsEnabledWithSystem(false)
            await settings.flush()
        }
    }

    private static var apnsEnvironment: String {
        let configured = Bundle.main.object(
            forInfoDictionaryKey: "PushNotificationEnvironment"
        ) as? String
        return configured == "production" ? "production" : "sandbox"
    }

    private static var apnsTopic: String {
        Bundle.main.bundleIdentifier ?? "com.aperture.wallet"
    }

    private static func errorCode(_ error: Error) -> String {
        if let error = error as? PushNotificationAPIError {
            return error.diagnosticCode
        }
        if let error = error as? PushInstallationVaultError {
            return error.diagnosticCode
        }
        if let error =
            error as? PushNotificationRegistrationRepositoryError {
            return switch error {
            case .missingAPNSToken:
                "registration_missing_apns_token"
            case .missingRemoteUserID:
                "registration_missing_remote_user_id"
            }
        }
        return errorTypeCode(error)
    }

    private static func errorTypeCode(_ error: Error) -> String {
        let raw = String(describing: type(of: error))
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "_.-")
        )
        return String(
            raw.unicodeScalars
                .filter { allowed.contains($0) }
                .prefix(80)
                .map(Character.init)
        )
    }
}

private struct DeliveredNotificationBatch: @unchecked Sendable {
    let notifications: [UNNotification]
}
