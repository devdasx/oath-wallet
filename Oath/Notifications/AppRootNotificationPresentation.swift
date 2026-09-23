import SwiftUI

/// Claims the native prompt once per app session, independently of the retired
/// welcome-sheet preference. iOS remains authoritative after a user's decision.
struct NotificationPermissionPromptState {
    private var hasRequested = false

    mutating func claim(
        authorizationState: PushAuthorizationState,
        explicitlyDisabled: Bool,
        isHomeReady: Bool
    ) -> Bool {
        guard isHomeReady,
              authorizationState == .notDetermined,
              !explicitlyDisabled,
              !hasRequested else { return false }
        hasRequested = true
        return true
    }
}

extension AppRootView {
    var isHomeReadyForNotificationPermission: Bool {
        phase == .wallet
            && scenePhase == .active
            && !isWalletAccessRestricted
            && !onboardingCompletion.isBlockingHomePresentation
            && !isNotificationInboxPresented
            && !isSettingsPresented
            && !isWalletSwitcherPresented
            && homeWalletAddAction == nil
            && walletActionPresentation == nil
            && destructiveFlow.presentation == nil
            && !sensitiveLockPresentation.hasPresentedModal
    }

    var canRequestNotificationPermission: Bool {
        isHomeReadyForNotificationPermission
            && pushNotifications.authorizationState == .notDetermined
            && !applicationSettings.notificationsWereExplicitlyDisabled
    }

    @MainActor
    func requestNotificationPermissionIfNeeded() {
        Task { @MainActor in
            guard notificationPermissionPrompt.claim(
                authorizationState: pushNotifications.authorizationState,
                explicitlyDisabled:
                    applicationSettings.notificationsWereExplicitlyDisabled,
                isHomeReady: isHomeReadyForNotificationPermission
            ) else { return }

            // The existing coordinator calls UNUserNotificationCenter directly
            // and persists the user's choice before reconciling registration.
            _ = await pushNotifications.enableNotifications(
                settings: applicationSettings
            )
        }
    }

    @MainActor
    func notificationInboxDidDismiss() {
        notificationToOpenID = nil
        coveringModalDidDismiss(.notificationInbox)
    }
}
