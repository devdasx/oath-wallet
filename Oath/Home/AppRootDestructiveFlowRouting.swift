import SwiftUI

enum AppRootDestructiveFlowSourceModal: Equatable, Sendable {
    case settings
    case walletSwitcher
}

enum AppRootDestructiveFlowReturnTarget: Equatable, Sendable {
    case settingsRoot
    case settingsWalletList
    case settingsWallet(walletID: String)
    case walletSwitcherRoot
    case walletSwitcherWallet(walletID: String)

    var sourceModal: AppRootDestructiveFlowSourceModal {
        switch self {
        case .settingsRoot, .settingsWalletList, .settingsWallet:
            .settings
        case .walletSwitcherRoot, .walletSwitcherWallet:
            .walletSwitcher
        }
    }
}

enum AppRootDestructiveFlowAction: Equatable, Sendable {
    case resetAppData
    case removeWallet(walletID: String)
}

enum AppRootDestructiveFlowCompletion: Equatable, Sendable {
    case appReset
    case lastWalletRemoved
}

struct AppRootDestructiveFlowPresentation:
    Identifiable,
    Equatable,
    Sendable
{
    let id: UUID
    let action: AppRootDestructiveFlowAction
    let returnTarget: AppRootDestructiveFlowReturnTarget

    init(
        id: UUID = UUID(),
        action: AppRootDestructiveFlowAction,
        returnTarget: AppRootDestructiveFlowReturnTarget
    ) {
        self.id = id
        self.action = action
        self.returnTarget = returnTarget
    }
}

struct AppRootDestructiveFlowCoordinator: Equatable, Sendable {
    private var pendingPresentation:
        AppRootDestructiveFlowPresentation?
    var presentation: AppRootDestructiveFlowPresentation?
    private var returnTargetAfterDismissal:
        AppRootDestructiveFlowReturnTarget?
    private(set) var activeRestorationTarget:
        AppRootDestructiveFlowReturnTarget?
    private var completionAfterDismissal: AppRootDestructiveFlowCompletion?

    @discardableResult
    mutating func request(
        action: AppRootDestructiveFlowAction,
        returnTarget: AppRootDestructiveFlowReturnTarget,
        waitsForSourceDismissal: Bool
    ) -> Bool {
        guard pendingPresentation == nil, presentation == nil,
              completionAfterDismissal == nil else {
            return false
        }

        returnTargetAfterDismissal = nil
        activeRestorationTarget = nil
        let requested = AppRootDestructiveFlowPresentation(
            action: action,
            returnTarget: returnTarget
        )
        if waitsForSourceDismissal {
            pendingPresentation = requested
        } else {
            presentation = requested
        }
        return true
    }

    @discardableResult
    mutating func sourceDidDismiss(
        _ source: AppRootDestructiveFlowSourceModal
    ) -> Bool {
        guard let pendingPresentation,
              pendingPresentation.returnTarget.sourceModal == source else {
            return false
        }

        self.pendingPresentation = nil
        presentation = pendingPresentation
        return true
    }

    mutating func dismissForNotNow() {
        dismissPresentedFlow(restoring: presentation?.returnTarget)
    }

    mutating func dismissAfterCompletedWalletRemoval() {
        dismissPresentedFlow(restoring: nil)
    }

    /// Keep the presenting root alive until UIKit finishes dismissing its cover.
    mutating func dismissAfterCompletion(_ completion: AppRootDestructiveFlowCompletion) {
        guard presentation != nil, completionAfterDismissal == nil else { return }
        completionAfterDismissal = completion
        dismissPresentedFlow(restoring: nil)
    }

    mutating func takeCompletionAfterDismissal() -> AppRootDestructiveFlowCompletion? {
        defer { completionAfterDismissal = nil }
        return completionAfterDismissal
    }

    mutating func takeReturnTargetAfterDismissal()
        -> AppRootDestructiveFlowReturnTarget?
    {
        defer {
            returnTargetAfterDismissal = nil
        }
        return returnTargetAfterDismissal
    }

    mutating func sourceRestorationDidEnd(
        _ source: AppRootDestructiveFlowSourceModal
    ) {
        guard activeRestorationTarget?.sourceModal == source else {
            return
        }
        activeRestorationTarget = nil
    }

    mutating func cancel() {
        pendingPresentation = nil
        presentation = nil
        returnTargetAfterDismissal = nil
        activeRestorationTarget = nil
        completionAfterDismissal = nil
    }

    private mutating func dismissPresentedFlow(
        restoring returnTarget: AppRootDestructiveFlowReturnTarget?
    ) {
        guard presentation != nil else { return }
        returnTargetAfterDismissal = returnTarget
        activeRestorationTarget = returnTarget
        presentation = nil
    }
}

extension AppRootView {
    @MainActor
    func requestResetAppDataFlow() {
        settingsWalletSetupDismissal.cancel()
        let waitsForSettingsDismissal = isSettingsPresented
        guard destructiveFlow.request(
            action: .resetAppData,
            returnTarget: .settingsRoot,
            waitsForSourceDismissal: waitsForSettingsDismissal
        ) else {
            return
        }

        if waitsForSettingsDismissal {
            isSettingsPresented = false
        }
    }

    @MainActor
    func requestSettingsWalletRemoval(walletID: String) {
        settingsWalletSetupDismissal.cancel()
        let waitsForSettingsDismissal = isSettingsPresented
        guard destructiveFlow.request(
            action: .removeWallet(walletID: walletID),
            returnTarget: .settingsWallet(walletID: walletID),
            waitsForSourceDismissal: waitsForSettingsDismissal
        ) else {
            return
        }

        if waitsForSettingsDismissal {
            isSettingsPresented = false
        }
    }

    @MainActor
    func requestWalletSwitcherWalletRemoval(walletID: String) {
        let waitsForWalletSwitcherDismissal =
            isWalletSwitcherPresented
        guard destructiveFlow.request(
            action: .removeWallet(walletID: walletID),
            returnTarget: .walletSwitcherWallet(walletID: walletID),
            waitsForSourceDismissal: waitsForWalletSwitcherDismissal
        ) else {
            return
        }

        if waitsForWalletSwitcherDismissal {
            isWalletSwitcherPresented = false
        }
    }

    @ViewBuilder
    func destructiveFlowDestination(
        _ presentation: AppRootDestructiveFlowPresentation
    ) -> some View {
        NavigationStack {
            Group {
                switch presentation.action {
                case .resetAppData:
                    ResetAppIntroductionScreen(
                        database: database,
                        onResetComplete: completeAppReset,
                        onNotNow: dismissDestructiveFlowForNotNow
                    )
                case let .removeWallet(walletID):
                    RemoveWalletIntroductionScreen(
                        database: database,
                        walletID: walletID,
                        onRemoved: completeWalletRemoval,
                        onNotNow: dismissDestructiveFlowForNotNow
                    )
                }
            }

        }
        .walletSheetPresentation(nativeGlass: false)
        .walletCoveringModal(
            .destructiveFlow,
            callbacks: coveringModalCallbacks
        )
        .walletAppLockOverlay(
            isPresented: shouldShowWalletLock(in: .destructiveFlow),
            database: database,
            settings: securitySettings,
            onAuthenticated: unlockWallet
        )
        .interactiveDismissDisabled()
    }

    @MainActor
    func dismissDestructiveFlowForNotNow() {
        destructiveFlow.dismissForNotNow()
    }

    @MainActor
    func completeWalletRemoval(_ result: WalletRemovalResult) {
        PushNotificationCoordinator.shared.walletDataDidChange()
        guard result.hasWallets else {
            destructiveFlow.dismissAfterCompletion(.lastWalletRemoved)
            return
        }

        if let selected = result.selectedWallet {
            loadWalletAddress(selected.address)
        }
        walletSwitcherContentDidChange()
        destructiveFlow.dismissAfterCompletedWalletRemoval()
    }

    @MainActor
    func destructiveFlowDidDismiss() {
        if let completion = destructiveFlow.takeCompletionAfterDismissal() {
            switch completion {
            case .appReset:
                finishAppResetAfterDismissal()
            case .lastWalletRemoved:
                returnToOnboarding()
            }
            return
        }
        coveringModalDidDismiss(.destructiveFlow)
        guard phase == .wallet,
              let returnTarget = destructiveFlow
                .takeReturnTargetAfterDismissal() else {
            return
        }

        switch returnTarget {
        case .settingsRoot:
            settingsNavigationPath.removeAll()
            isSettingsPresented = true
        case .settingsWalletList, .settingsWallet:
            settingsNavigationPath = [.wallets]
            isSettingsPresented = true
        case .walletSwitcherRoot:
            walletSwitcherNavigationPath.removeAll()
            isWalletSwitcherPresented = true
        case let .walletSwitcherWallet(walletID):
            walletSwitcherNavigationPath = [
                .settings(walletID: walletID)
            ]
            isWalletSwitcherPresented = true
        }
    }

    var settingsWalletIDRestoredAfterDestructiveFlow: String? {
        guard case let .settingsWallet(walletID) =
            destructiveFlow.activeRestorationTarget else {
            return nil
        }
        return walletID
    }
}
