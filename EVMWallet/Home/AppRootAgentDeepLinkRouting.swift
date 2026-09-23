import SwiftUI

struct WalletAgentDeepLinkPresentationContext: Hashable, Sendable {
    let requestID: UUID?
    let walletIsVisible: Bool
    let sceneIsActive: Bool
    let walletIsRestricted: Bool
    let hasBlockingPresentation: Bool

    var canPresent: Bool {
        requestID != nil
            && walletIsVisible
            && sceneIsActive
            && !walletIsRestricted
            && !hasBlockingPresentation
    }
}

extension AppRootView {
    var agentDeepLinkPresentationContext:
        WalletAgentDeepLinkPresentationContext {
        WalletAgentDeepLinkPresentationContext(
            requestID: deepLinkCoordinator.pendingRequest?.id,
            walletIsVisible: phase == .wallet,
            sceneIsActive: scenePhase == .active,
            walletIsRestricted: isWalletAccessRestricted,
            hasBlockingPresentation:
                hasAgentDeepLinkBlockingPresentation
        )
    }

    var hasAgentDeepLinkBlockingPresentation: Bool {
        isSettingsPresented
            || settingsSecurityNavigation.isAwaitingAuthorization
            || settingsSecurityNavigation.isPasscodePresentationActive
            || isSettingsSecurityAuthenticationPresented
            || isWalletSwitcherPresented
            || homeWalletAddAction != nil
            || walletActionPresentation != nil
            || destructiveFlow.presentation != nil
            || onboardingCompletion.isBlockingHomePresentation
            || isNotificationInboxPresented
    }

    @MainActor
    func presentPendingAgentDeepLinkIfPossible() {
        guard let request = deepLinkCoordinator.pendingRequest,
              request.destination != .physicalEntropy,
              agentDeepLinkPresentationContext.canPresent else {
            return
        }

        switch request.destination {
        case .physicalEntropy:
            return
        case .universalSearch:
            walletHomeSearchPresentationRequestID = request.id
        case .receive:
            resetWalletHomeChildNavigationForAgentDeepLink()
            presentReceiveFlow()
        case .currencyConverter:
            resetWalletHomeChildNavigationForAgentDeepLink()
            presentSettingsSearchRoute(.currencyConverter)
        case .securitySettings:
            resetWalletHomeChildNavigationForAgentDeepLink()
            presentSettingsSearchRoute(.security)
        case .walletManagement:
            resetWalletHomeChildNavigationForAgentDeepLink()
            presentSettingsSearchRoute(.wallets)
        }
        deepLinkCoordinator.consumeRequest(id: request.id)
    }

    @MainActor
    private func resetWalletHomeChildNavigationForAgentDeepLink() {
        walletHomeNavigationResetGeneration &+= 1
    }
}
