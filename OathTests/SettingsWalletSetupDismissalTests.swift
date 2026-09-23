import Testing
@testable import Aperture

struct SettingsWalletSetupDismissalTests {
    @Test
    func homeAddSheetRoutesSetupActionsToTheExpectedFlows() {
        #expect(
            HomeWalletAddAction.allCases
                == [.create, .importWallet, .restoreICloud]
        )
        #expect(HomeWalletAddAction.create.systemImage == "plus.circle")
        #expect(
            HomeWalletAddAction.importWallet.systemImage
                == "square.and.arrow.down"
        )
        #expect(
            HomeWalletAddAction.restoreICloud.systemImage
                == "icloud.and.arrow.down"
        )
        #expect(HomeWalletAddAction.create.sheetDetent == .large)
        #expect(HomeWalletAddAction.importWallet.sheetDetent == .large)
        #expect(HomeWalletAddAction.restoreICloud.sheetDetent == .large)

        #expect(
            HomeWalletAddAction.create.onboardingStartAction
                == nil
        )
        #expect(
            HomeWalletAddAction.importWallet.onboardingStartAction
                == .importWallet
        )
        #expect(
            HomeWalletAddAction.restoreICloud.onboardingStartAction
                == .restoreICloud
        )
    }

    @Test
    func walletSwitcherOnlyAllowsTheLargeDetent() {
        #expect(
            WalletSwitcherSheetDetentPolicy.allowedDetents == [.large]
        )
        #expect(
            !WalletSwitcherSheetDetentPolicy.allowedDetents.contains(.medium)
        )
    }

    @Test
    func walletSwitchWaitsForSettingsDismissal() {
        var dismissal = SettingsWalletSetupDismissal()

        let requested = dismissal.request(
            walletAddress: " 0x1234567890abcdef "
        )

        #expect(requested)
        #expect(
            dismissal.pendingWalletAddress
                == "0x1234567890abcdef"
        )

        let address = dismissal.consumeAfterSettingsDismissal()

        #expect(address == "0x1234567890abcdef")
        #expect(dismissal.pendingWalletAddress == nil)
        #expect(dismissal.consumeAfterSettingsDismissal() == nil)
    }

    @Test
    func reopeningSettingsCancelsAStaleWalletSwitch() {
        var dismissal = SettingsWalletSetupDismissal()

        let requested = dismissal.request(
            walletAddress: "TWalletAddress"
        )
        #expect(requested)

        dismissal.cancel()

        #expect(dismissal.consumeAfterSettingsDismissal() == nil)
    }

    @Test
    func invalidWalletAddressCannotDismissSettings() {
        var dismissal = SettingsWalletSetupDismissal()

        let requested = dismissal.request(walletAddress: "   ")

        #expect(!requested)
        #expect(dismissal.pendingWalletAddress == nil)
    }
}

struct AppRootDestructiveFlowCoordinatorTests {
    @Test(arguments: [AppRootDestructiveFlowCompletion.appReset, .lastWalletRemoved])
    func successfulCompletionIsConsumedOnceAfterCoverDismissal(
        completion: AppRootDestructiveFlowCompletion
    ) {
        var flow = AppRootDestructiveFlowCoordinator()
        let requested = flow.request(
            action: completion == .appReset ? .resetAppData : .removeWallet(walletID: "last-wallet"),
            returnTarget: .settingsRoot,
            waitsForSourceDismissal: false
        )
        #expect(requested)

        flow.dismissAfterCompletion(completion)
        #expect(flow.presentation == nil)
        #expect(flow.takeReturnTargetAfterDismissal() == nil)
        #expect(flow.activeRestorationTarget == nil)
        // The cover is closing; a second request must not replace its callback.
        let requestedWhileDismissing = flow.request(
            action: .resetAppData, returnTarget: .settingsRoot,
            waitsForSourceDismissal: false
        )
        #expect(!requestedWhileDismissing)
        flow.dismissAfterCompletion(completion)
        #expect(flow.takeCompletionAfterDismissal() == completion)
        #expect(flow.takeCompletionAfterDismissal() == nil)
        let requestedAfterDismissal = flow.request(
            action: .resetAppData, returnTarget: .settingsRoot,
            waitsForSourceDismissal: false
        )
        #expect(requestedAfterDismissal)
    }

    @Test
    func cancellationClearsAQueuedCompletion() {
        var flow = AppRootDestructiveFlowCoordinator()
        let requested = flow.request(
            action: .resetAppData, returnTarget: .settingsRoot,
            waitsForSourceDismissal: false
        )
        #expect(requested)
        flow.dismissAfterCompletion(.appReset)
        flow.cancel()
        #expect(flow.takeCompletionAfterDismissal() == nil)
        #expect(flow.takeReturnTargetAfterDismissal() == nil)
    }

    @Test
    func completionWithoutAPresentedFlowCannotChangeTheRoot() {
        var flow = AppRootDestructiveFlowCoordinator()
        flow.dismissAfterCompletion(.appReset)
        #expect(flow.takeCompletionAfterDismissal() == nil)
    }

    @Test
    func resetWaitsForSettingsToDismissBeforePresentation() {
        var flow = AppRootDestructiveFlowCoordinator()

        let requested = flow.request(
            action: .resetAppData,
            returnTarget: .settingsRoot,
            waitsForSourceDismissal: true
        )
        #expect(requested)
        #expect(flow.presentation == nil)
        let wrongSourceDismissed = flow.sourceDidDismiss(.walletSwitcher)
        #expect(!wrongSourceDismissed)
        let settingsDismissed = flow.sourceDidDismiss(.settings)
        #expect(settingsDismissed)
        #expect(flow.presentation?.action == .resetAppData)
    }

    @Test
    func notNowRestoresTheOriginatingWalletSettingsScreen() {
        var flow = AppRootDestructiveFlowCoordinator()

        let requested = flow.request(
            action: .removeWallet(walletID: "wallet-1"),
            returnTarget: .settingsWallet(walletID: "wallet-1"),
            waitsForSourceDismissal: true
        )
        #expect(requested)
        let settingsDismissed = flow.sourceDidDismiss(.settings)
        #expect(settingsDismissed)

        flow.dismissForNotNow()

        #expect(flow.presentation == nil)
        let returnTarget = flow.takeReturnTargetAfterDismissal()
        #expect(returnTarget == .settingsWallet(walletID: "wallet-1"))
        #expect(
            flow.activeRestorationTarget
                == .settingsWallet(walletID: "wallet-1")
        )

        flow.sourceRestorationDidEnd(.settings)
        #expect(flow.activeRestorationTarget == nil)
    }

    @Test
    func completedRemovalDoesNotRestoreAParentSheet() {
        let returnTargets: [AppRootDestructiveFlowReturnTarget] = [
            .settingsWallet(walletID: "wallet-1"),
            .walletSwitcherWallet(walletID: "wallet-2")
        ]

        for returnTarget in returnTargets {
            var flow = AppRootDestructiveFlowCoordinator()
            let requested = flow.request(
                action: .removeWallet(walletID: "removed-wallet"),
                returnTarget: returnTarget,
                waitsForSourceDismissal: false
            )
            #expect(requested)

            flow.dismissAfterCompletedWalletRemoval()

            #expect(flow.presentation == nil)
            #expect(flow.takeReturnTargetAfterDismissal() == nil)
            #expect(flow.activeRestorationTarget == nil)
        }
    }

    @Test
    func cancellationNeverRestoresAParentSheet() {
        var flow = AppRootDestructiveFlowCoordinator()

        let requested = flow.request(
            action: .resetAppData,
            returnTarget: .settingsRoot,
            waitsForSourceDismissal: false
        )
        #expect(requested)
        flow.cancel()

        #expect(flow.presentation == nil)
        let returnTarget = flow.takeReturnTargetAfterDismissal()
        #expect(returnTarget == nil)
        #expect(flow.activeRestorationTarget == nil)
    }
}
