import SwiftUI

extension AppRootView {
    var isWalletLocked: Bool {
        get { appLock.isLocked }
        nonmutating set { appLock.setLocked(newValue) }
    }

    var isAppSwitcherPrivacyActive: Bool {
        securitySettings.privacyShieldEnabled
            && isPrivacyShieldVisible
            && scenePhase != .active
    }

    @MainActor
    func coveringModalDidPresent(_ id: WalletCoveringModalID) {
        sensitiveLockPresentation.modalDidPresent(id)
    }

    @MainActor
    func coveringModalDidDismiss(_ id: WalletCoveringModalID) {
        if sensitiveLockPresentation.modalDidDismiss(id) {
            isWalletLocked = true
        }
    }

    var coveringModalCallbacks: WalletCoveringModalCallbacks {
        WalletCoveringModalCallbacks(
            didPresent: coveringModalDidPresent,
            didDismiss: coveringModalDidDismiss
        )
    }

    var isWalletAccessRestricted: Bool {
        isWalletLocked
    }

    func shouldShowWalletLock(
        in modalID: WalletCoveringModalID
    ) -> Bool {
        isWalletLocked
            && sensitiveLockPresentation.isPresented(modalID)
    }
}
