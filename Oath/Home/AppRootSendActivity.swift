import SwiftUI

extension AppRootView {
    var sendActivityPresentation: SendActivityPresentation {
        SendActivityPresentation(
            store: sendActivities, walletAddress: walletAddress,
            canShow: phase == .wallet && scenePhase == .active && !isWalletAccessRestricted
                && !isAppSwitcherPrivacyActive && walletActionPresentation == nil
                && !sensitiveLockPresentation.hasPresentedModal,
            isLocked: isWalletLocked, database: database,
            securitySettings: securitySettings, modalCallbacks: coveringModalCallbacks,
            onAuthenticated: unlockWallet, onRetry: retrySendActivity,
            onPendingUpdate: {
                guard let context = reboundCurrentWalletContext() else { return }
                await publishCachedSnapshot(context: context, scope: .portfolioAndActivity)
            }
        )
    }

    private func retrySendActivity(_ operation: SendOperation) {
        guard operation.canRetry, walletActionPresentation == nil,
              let context = authorizedWalletActionContext(action: .send),
              context.identity.address == operation.walletAddress,
              let preparation = preparedWalletActions(for: context) else { return }
        // A retry returns to Review: refresh fees and require a fresh slide and authorization.
        presentWalletAction(.send(sendPayload(context: context, preparation: preparation,
            initialRoute: .review(operation.draft.replacingPreparedNetworkFee(nil)))), context: context)
        operation.isAcknowledged = true
    }
}
