import Foundation

enum BitcoinFamilyPullRefreshPolicy {
    static func requiresIndependentBalanceRefresh(
        hasActiveWalletLoad: Bool,
        sources: Set<WalletSyncSource>
    ) -> Bool {
        hasActiveWalletLoad && sources.contains(.bitcoinFamily)
    }
}

extension AppRootView {
    @MainActor
    func reloadWallet(showsLoadingState: Bool) {
        guard let context = reboundCurrentWalletContext() else {
            clearWalletPresentationWhenUnresolved()
            return
        }
        scheduleWalletReload(
            context: context,
            showsLoadingState: showsLoadingState,
            operation: "wallet_reload"
        )
    }

    @MainActor
    func refreshWallet() {
        guard let context = reboundCurrentWalletContext() else {
            clearWalletPresentationWhenUnresolved()
            return
        }
        scheduleWalletReload(
            context: context,
            showsLoadingState: false,
            operation: "pull_to_refresh"
        )
    }

    @MainActor
    private func scheduleWalletReload(
        context: AppRootResolvedWalletContext,
        showsLoadingState: Bool,
        operation: String
    ) {
        let hadActiveWalletLoad = walletLoadTask.map {
            !$0.isCancelled
        } ?? false
        scheduleWalletLoad(
            context: context,
            showsLoadingState: showsLoadingState,
            operation: operation
        )
        if BitcoinFamilyPullRefreshPolicy.requiresIndependentBalanceRefresh(
            hasActiveWalletLoad: hadActiveWalletLoad,
            sources: context.capabilities.walletSyncSources
        ) {
            scheduleBitcoinFamilyBalanceRefresh(context: context)
        }
    }

    @MainActor
    private func clearWalletPresentationWhenUnresolved() {
        guard walletPresentation.address.isEmpty else { return }
        invalidateWalletActionPreparation()
        walletPresentation = .empty()
    }

    @MainActor
    @discardableResult
    func scheduleBitcoinFamilyBalanceRefresh(
        context: AppRootResolvedWalletContext
    ) -> Task<Void, Never> {
        bitcoinFamilyBalanceRefreshTask?.cancel()
        bitcoinFamilyBalanceRefreshGeneration &+= 1
        let generation = bitcoinFamilyBalanceRefreshGeneration
        let onProgress: WalletSyncProgressHandler = { event in
            guard !Task.isCancelled,
                  event.source == .bitcoinFamily,
                  walletPresentation.accepts(context) else {
                return
            }
            await publishCachedSnapshot(context: context, scope: .portfolio)
        }
        let task = Task { @MainActor in
            guard await permitsWalletRefresh(context: context) else { return }
            _ = await BitcoinFamilySyncService.shared.refreshBalances(
                walletID: context.identity.walletID,
                onProgress: onProgress
            )
            guard generation == bitcoinFamilyBalanceRefreshGeneration else {
                return
            }
            bitcoinFamilyBalanceRefreshTask = nil
        }
        bitcoinFamilyBalanceRefreshTask = task
        return task
    }

    @MainActor
    func cancelBitcoinFamilyBalanceRefresh() {
        bitcoinFamilyBalanceRefreshGeneration &+= 1
        bitcoinFamilyBalanceRefreshTask?.cancel()
        bitcoinFamilyBalanceRefreshTask = nil
    }

    @MainActor
    func startBitcoinFamilyBalanceMonitor(
        context: AppRootResolvedWalletContext
    ) {
        guard context.capabilities.walletSyncSources.contains(
            .bitcoinFamily
        ) else {
            cancelBitcoinFamilyBalanceMonitor()
            return
        }
        if bitcoinFamilyBalanceMonitorRequestID == context.requestID,
           let task = bitcoinFamilyBalanceMonitorTask,
           !task.isCancelled {
            return
        }

        cancelBitcoinFamilyBalanceMonitor()
        bitcoinFamilyBalanceMonitorRequestID = context.requestID
        let onProgress: WalletSyncProgressHandler = { event in
            guard !Task.isCancelled,
                  event.source == .bitcoinFamily,
                  walletPresentation.accepts(context) else {
                return
            }
            await publishCachedSnapshot(context: context, scope: .portfolio)
        }
        bitcoinFamilyBalanceMonitorTask = Task { @MainActor in
            await BitcoinFamilyBalanceMonitorService.shared.monitor(
                walletID: context.identity.walletID,
                onProgress: onProgress
            )
            guard bitcoinFamilyBalanceMonitorRequestID == context.requestID
            else {
                return
            }
            bitcoinFamilyBalanceMonitorTask = nil
            bitcoinFamilyBalanceMonitorRequestID = nil
        }
    }

    @MainActor
    func cancelBitcoinFamilyBalanceMonitor() {
        bitcoinFamilyBalanceMonitorTask?.cancel()
        bitcoinFamilyBalanceMonitorTask = nil
        bitcoinFamilyBalanceMonitorRequestID = nil
    }
}
