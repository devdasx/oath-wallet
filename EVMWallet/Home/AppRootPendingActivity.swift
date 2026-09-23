import SwiftUI

extension AppRootView {
    var pendingActivityReceiptPresentation: WalletPendingActivityReceiptPresentation {
        WalletPendingActivityReceiptPresentation(transaction: $pendingActivityReceipt,
            isLocked: isWalletLocked, database: database, securitySettings: securitySettings,
            modalCallbacks: coveringModalCallbacks, onAuthenticated: unlockWallet)
    }
}

struct WalletPendingActivityReceiptPresentation: ViewModifier {
    @Binding var transaction: WalletTransaction?
    let isLocked: Bool
    let database: WalletDatabase
    let securitySettings: WalletSecuritySettings
    let modalCallbacks: WalletCoveringModalCallbacks
    let onAuthenticated: () -> Void
    @Environment(WalletSettingsStore.self) private var settings

    func body(content: Content) -> some View {
        content.sheet(item: $transaction, onDismiss: { modalCallbacks.didDismiss(.send) }) { transaction in
            NavigationStack {
                WalletPendingTransactionDetailsScreen(transaction: transaction, database: database,
                    isBalanceHidden: settings.balancePrivacyEnabled)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            WalletCloseButton(action: UniHaptic.action(nil) { self.transaction = nil })
                        }
                    }
            }
            .walletSheetPresentation(nativeGlass: false)
            .walletCoveringModal(.send, callbacks: modalCallbacks)
            .walletAppLockOverlay(isPresented: isLocked, database: database,
                settings: securitySettings, onAuthenticated: onAuthenticated)
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
    }
}
