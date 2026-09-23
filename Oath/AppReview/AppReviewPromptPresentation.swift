import SwiftUI

struct AppReviewLifecycleContext: Equatable {
    let isUsageActive: Bool
    let canPresentSheet: Bool
}

private struct AppReviewPromptPresentationModifier: ViewModifier {
    let coordinator: AppReviewPromptCoordinator
    let database: WalletDatabase
    let securitySettings: WalletSecuritySettings
    let showsWalletLock: Bool
    let callbacks: WalletCoveringModalCallbacks
    let onAuthenticated: () -> Void

    func body(content: Content) -> some View {
        @Bindable var coordinator = coordinator

        content.sheet(
            isPresented: $coordinator.isSheetPresented,
            onDismiss: sheetDidDismiss
        ) {
            AppReviewPromptSheet(coordinator: coordinator)
                .walletLocalePresentation()
                .walletCoveringModal(
                    .appReviewPrompt,
                    callbacks: callbacks
                )
                .walletAppLockOverlay(
                    isPresented: showsWalletLock,
                    database: database,
                    settings: securitySettings,
                    onAuthenticated: onAuthenticated
                )
        }
    }

    private func sheetDidDismiss() {
        callbacks.didDismiss(.appReviewPrompt)
        if coordinator.sheetDidDismiss() {
            AppReviewNativeRatingRequester
                .requestAfterSheetDismissal()
        }
    }
}

extension View {
    func appReviewPromptPresentation(
        coordinator: AppReviewPromptCoordinator,
        database: WalletDatabase,
        securitySettings: WalletSecuritySettings,
        showsWalletLock: Bool,
        callbacks: WalletCoveringModalCallbacks,
        onAuthenticated: @escaping () -> Void
    ) -> some View {
        modifier(
            AppReviewPromptPresentationModifier(
                coordinator: coordinator,
                database: database,
                securitySettings: securitySettings,
                showsWalletLock: showsWalletLock,
                callbacks: callbacks,
                onAuthenticated: onAuthenticated
            )
        )
    }
}
