import Foundation
import UserNotifications

enum WalletAppResetProgressStage: Int, CaseIterable, Equatable, Sendable {
    case preparing
    case securingCredentials
    case removingWalletData
    case clearingLocalData
    case finishing
    case complete

    var ordinal: Int {
        rawValue + 1
    }

    var total: Int {
        Self.allCases.count
    }

    /// A minimum amount of time for which the UI presents this real reset
    /// phase. Reset work itself is never delayed; the progress sheet consumes
    /// the emitted phases independently while cleanup continues at full speed.
    var minimumPresentationDurationNanoseconds: UInt64 {
        switch self {
        case .preparing:
            650_000_000
        case .securingCredentials:
            900_000_000
        case .removingWalletData:
            1_100_000_000
        case .clearingLocalData:
            900_000_000
        case .finishing:
            750_000_000
        case .complete:
            300_000_000
        }
    }
}

typealias WalletAppResetProgressHandler =
    @MainActor @Sendable (WalletAppResetProgressStage) -> Void

final class WalletAppResetService: @unchecked Sendable {
    static let shared = WalletAppResetService()

    private init() {}

    func eraseAllData(
        database: WalletDatabase,
        applicationSettings: WalletSettingsStore,
        onProgress: WalletAppResetProgressHandler? = nil
    ) async throws {
        await onProgress?(.preparing)
        let preservedPreferences =
            await applicationSettings.prepareForAppReset()
        database.beginAppReset()
        defer {
            database.finishAppReset()
        }

        let cleanupPlan: WalletAppResetCleanupPlan
        do {
            await onProgress?(.securingCredentials)
            cleanupPlan =
                try await WalletSecureCleanupRecoveryService.shared
                    .prepareAppResetCleanupPlan()
        } catch {
            await applicationSettings.recoverAfterFailedAppReset()
            throw error
        }

        // Service shutdown remains a required part of reset preparation, but
        // it is not a separate user-visible progress step.
        await PushNotificationCoordinator.shared.suspendForAppReset()

        do {

            await onProgress?(.removingWalletData)
            _ = try await database.commitAppReset(
                cleanupPlan: cleanupPlan,
                preservedPreferences: preservedPreferences
            )
        } catch {
            await applicationSettings.recoverAfterFailedAppReset()
            await PushNotificationCoordinator.shared.appDidBecomeActive(
                settings: applicationSettings
            )
            throw error
        }

        // The destructive database transaction has committed. Every
        // remaining operation is either best-effort runtime cleanup or a
        // durable journal job. The shared FX snapshot is intentionally kept
        // warm because it contains no wallet or personal data. None of these
        // operations can turn a completed reset into a misleading failure.
        await onProgress?(.clearingLocalData)
        await applicationSettings.resetToDatabaseDefaults(
            preserving: preservedPreferences
        )
        await clearRuntimeData()

        await onProgress?(.finishing)
        _ = await WalletSecureCleanupRecoveryService.shared
            .retryPendingCleanup(database: database)

        await onProgress?(.complete)

        // CloudKit and the non-personal FX-rate cache are intentionally
        // outside the app-reset cleanup boundary. A reset removes this
        // installation's wallet data, Keychain material, resettable settings,
        // and wallet-related caches. The user's language, currency,
        // appearance, and haptic preferences remain local, while
        // password-encrypted wallet backups remain in the user's private
        // iCloud database for another install or another device signed into
        // the same Apple Account.
    }

    private func clearRuntimeData() async {
        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.removeAllPendingNotificationRequests()
        notificationCenter.removeAllDeliveredNotifications()

        async let badgeReset: Void? =
            try? await notificationCenter.setBadgeCount(0)
        async let logoCacheReset: Void =
            AssetLogoCache.shared.removeAllCachedData()
        async let metalRatesCacheReset: Void =
            MetalPriceClient.shared.removeCachedData()
        _ = await (
            badgeReset,
            logoCacheReset,
            metalRatesCacheReset
        )

        URLCache.shared.removeAllCachedResponses()
        HTTPCookieStorage.shared.removeCookies(since: .distantPast)

        removeContentsIfPossible(
            of: FileManager.default.urls(
                for: .cachesDirectory,
                in: .userDomainMask
            ).first
        )
        removeContentsIfPossible(of: FileManager.default.temporaryDirectory)
    }

    private func removeContentsIfPossible(of directory: URL?) {
        guard let directory else { return }
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.path) else { return }

        guard let items = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants]
        ) else {
            return
        }

        for item in items {
            try? fileManager.removeItem(at: item)
        }
    }
}
