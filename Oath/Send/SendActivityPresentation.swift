import SwiftUI

struct SendActivityPresentation: ViewModifier {
    @Bindable var store: SendActivityStore
    let walletAddress: String
    let canShow: Bool
    let isLocked: Bool
    let database: WalletDatabase
    let securitySettings: WalletSecuritySettings
    let modalCallbacks: WalletCoveringModalCallbacks
    let onAuthenticated: () -> Void
    let onRetry: (SendOperation) -> Void
    var onPendingUpdate: (@MainActor @Sendable () async -> Void)? = nil
    @State private var pendingStatusMonitor = SendPendingStatusMonitor()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var visibleOperation: SendOperation? {
        guard canShow, store.hasDismissedSendSheet, !store.isActivityListPresented, store.presentedOperation == nil else { return nil }
        return store.visibleOperation(walletAddress: walletAddress)
    }

    func body(content: Content) -> some View {
        GeometryReader { geometry in
            content
            .safeAreaInset(edge: .top, spacing: 0) {
                if visibleOperation != nil {
                    SendActivityGroupCapsule(store: store, walletAddress: walletAddress,
                                             maximumHeight: min(560, geometry.size.height * 0.7))
                    .frame(maxWidth: 560)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .transition(reduceMotion ? .identity : .move(edge: .top).combined(with: .opacity))
                }
            }
        }
            .task(id: scenePhase) {
                if scenePhase == .active { await pendingStatusMonitor.run(database: database, onUpdate: onPendingUpdate) }
            }
            .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.88),
                       value: visibleOperation?.capsulePresentationID)
            .sheet(item: $store.presentedOperation, onDismiss: receiptDidDismiss) { operation in
                NavigationStack {
                    SendBroadcastScreen(operation: operation,
                                        onRetry: { store.retry(operation) },
                                        onDone: { store.finishDetails(operation) })
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                WalletCloseButton { store.finishDetails(operation) }
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

    private func receiptDidDismiss() {
        modalCallbacks.didDismiss(.send)
        guard let operation = store.pendingRetry else { return }
        store.pendingRetry = nil
        onRetry(operation)
    }
}
