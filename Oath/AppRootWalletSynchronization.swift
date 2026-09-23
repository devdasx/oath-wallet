import SwiftUI

struct AppRootResolvedWalletContext: Equatable, Sendable {
    let requestID: UUID
    let identity: PersistedWalletIdentity
    let name: String
    let capabilities: WalletCapabilities
    let appearanceColor: WalletAppearanceColor
    let accountAddresses: WalletAccountAddressIndex

    init(
        requestID: UUID,
        identity: PersistedWalletIdentity,
        name: String,
        capabilities: WalletCapabilities,
        appearanceColor: WalletAppearanceColor = .blue,
        accountAddresses: WalletAccountAddressIndex = .empty
    ) {
        self.requestID = requestID
        self.identity = identity
        self.name = name
        self.capabilities = capabilities
        self.appearanceColor = appearanceColor
        self.accountAddresses = accountAddresses
    }

    func replacingRequestID(
        _ requestID: UUID
    ) -> AppRootResolvedWalletContext {
        AppRootResolvedWalletContext(
            requestID: requestID,
            identity: identity,
            name: name,
            capabilities: capabilities,
            appearanceColor: appearanceColor,
            accountAddresses: accountAddresses
        )
    }
}

struct AppRootWalletPresentation {
    let requestID: UUID
    let identity: PersistedWalletIdentity?
    let name: String
    let address: String
    let capabilities: WalletCapabilities
    let appearanceColor: WalletAppearanceColor
    let accountAddresses: WalletAccountAddressIndex
    let state: WalletHomeLoadState
    let stateRevision: UUID

    static func empty(
        requestID: UUID = UUID()
    ) -> AppRootWalletPresentation {
        AppRootWalletPresentation(
            requestID: requestID,
            identity: nil,
            name: defaultWalletName,
            address: "",
            capabilities: .fullWallet,
            appearanceColor: .blue,
            accountAddresses: .empty,
            state: .content(.empty),
            stateRevision: UUID()
        )
    }

    static func pending(
        requestID: UUID,
        address: String,
        suggestedName: String?,
        suggestedAppearanceColor: WalletAppearanceColor? = nil
    ) -> AppRootWalletPresentation {
        let normalizedName = suggestedName?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return AppRootWalletPresentation(
            requestID: requestID,
            identity: nil,
            name: normalizedName?.isEmpty == false
                ? normalizedName!
                : defaultWalletName,
            address: address,
            capabilities: .fullWallet,
            appearanceColor: suggestedAppearanceColor ?? .blue,
            accountAddresses: .empty,
            state: .loading,
            stateRevision: UUID()
        )
    }

    static func resolved(
        context: AppRootResolvedWalletContext,
        state: WalletHomeLoadState,
        stateRevision: UUID = UUID()
    ) -> AppRootWalletPresentation {
        AppRootWalletPresentation(
            requestID: context.requestID,
            identity: context.identity,
            name: context.name,
            address: context.identity.address,
            capabilities: context.capabilities,
            appearanceColor: context.appearanceColor,
            accountAddresses: context.accountAddresses,
            state: state,
            stateRevision: stateRevision
        )
    }

    var resolvedContext: AppRootResolvedWalletContext? {
        guard let identity,
              AppRootWalletAddressMatcher.matches(
                identity.address,
                address
              )
        else {
            return nil
        }
        return AppRootResolvedWalletContext(
            requestID: requestID,
            identity: identity,
            name: name,
            capabilities: capabilities,
            appearanceColor: appearanceColor,
            accountAddresses: accountAddresses
        )
    }

    var isReadyForWalletActions: Bool {
        resolvedContext != nil
    }

    func acceptsPending(
        requestID: UUID,
        address: String
    ) -> Bool {
        self.requestID == requestID
            && identity == nil
            && AppRootWalletAddressMatcher.matches(self.address, address)
    }

    func accepts(
        _ context: AppRootResolvedWalletContext
    ) -> Bool {
        requestID == context.requestID
            && identity == context.identity
            && AppRootWalletAddressMatcher.matches(
                address,
                context.identity.address
            )
            && capabilities == context.capabilities
            && accountAddresses == context.accountAddresses
    }

    func rebinding(
        to context: AppRootResolvedWalletContext
    ) -> AppRootWalletPresentation? {
        guard let current = resolvedContext,
              current.identity == context.identity,
              current.capabilities == context.capabilities
        else {
            return nil
        }
        return .resolved(
            context: context,
            state: state,
            stateRevision: stateRevision
        )
    }

    func replacingState(
        _ state: WalletHomeLoadState,
        for context: AppRootResolvedWalletContext
    ) -> AppRootWalletPresentation? {
        guard accepts(context) else { return nil }
        let currentContext = AppRootResolvedWalletContext(
            requestID: context.requestID,
            identity: context.identity,
            name: name,
            capabilities: context.capabilities,
            appearanceColor: appearanceColor,
            accountAddresses: context.accountAddresses
        )
        return .resolved(context: currentContext, state: state)
    }

    func replacingName(
        _ name: String,
        matchingAddress address: String
    ) -> AppRootWalletPresentation? {
        guard let context = resolvedContext,
              AppRootWalletAddressMatcher.matches(
                context.identity.address,
                address
              )
        else {
            return nil
        }
        let renamed = AppRootResolvedWalletContext(
            requestID: context.requestID,
            identity: context.identity,
            name: name,
            capabilities: context.capabilities,
            appearanceColor: context.appearanceColor,
            accountAddresses: context.accountAddresses
        )
        return .resolved(
            context: renamed,
            state: state,
            stateRevision: stateRevision
        )
    }

    func replacingAppearanceColor(
        _ appearanceColor: WalletAppearanceColor,
        matchingWalletID walletID: String
    ) -> AppRootWalletPresentation? {
        guard let context = resolvedContext,
              context.identity.walletID == walletID
        else {
            return nil
        }
        let recolored = AppRootResolvedWalletContext(
            requestID: context.requestID,
            identity: context.identity,
            name: context.name,
            capabilities: context.capabilities,
            appearanceColor: appearanceColor,
            accountAddresses: context.accountAddresses
        )
        return .resolved(
            context: recolored,
            state: state,
            stateRevision: stateRevision
        )
    }

    var contentSnapshot: WalletHomeSnapshot? {
        guard case let .content(snapshot) = state else { return nil }
        return snapshot
    }

    var walletActionPreparationInput:
        (snapshot: WalletHomeSnapshot, source: WalletActionPreparationSource)? {
        switch state {
        case .loading:
            (.empty, .loading)
        case let .content(snapshot):
            (snapshot, .content)
        case .failed:
            nil
        }
    }

    private static var defaultWalletName: String {
        WalletLocalization.string("wallet.home.wallet.name.default")
    }
}

enum AppRootWalletAddressMatcher {
    static func matches(_ lhs: String, _ rhs: String) -> Bool {
        let normalizedLeft = lhs.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let normalizedRight = rhs.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if normalizedLeft.lowercased().hasPrefix("0x"),
           normalizedRight.lowercased().hasPrefix("0x") {
            return normalizedLeft.caseInsensitiveCompare(normalizedRight)
                == .orderedSame
        }
        return normalizedLeft == normalizedRight
    }
}

extension AppRootView {
    var walletState: WalletHomeLoadState {
        walletPresentation.state
    }

    var walletName: String {
        walletPresentation.name
    }

    var walletAddress: String {
        walletPresentation.address
    }

    var walletCapabilities: WalletCapabilities {
        walletPresentation.capabilities
    }

    var walletAppearanceColor: WalletAppearanceColor {
        walletPresentation.appearanceColor
    }

    @MainActor
    @discardableResult
    func loadWalletAddress(
        _ address: String,
        suggestedName: String? = nil,
        suggestedAppearanceColor: WalletAppearanceColor? = nil
    ) -> UUID {
        let normalizedAddress = address.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        walletContextReadinessRequest?.gate.resolve(false)
        walletContextReadinessRequest = nil
        walletLoadTask?.cancel()
        cancelBitcoinFamilyBalanceRefresh()
        cancelBitcoinFamilyBalanceMonitor()
        invalidateWalletActionPreparation()

        let requestID = UUID()
        let readiness = AppRootWalletContextReadinessRequest(
            requestID: requestID
        )
        walletContextReadinessRequest = readiness
        guard !normalizedAddress.isEmpty else {
            readiness.gate.resolve(false)
            walletPresentation = .empty(requestID: requestID)
            walletLoadTask = nil
            return requestID
        }

        walletPresentation = .pending(
            requestID: requestID,
            address: normalizedAddress,
            suggestedName: suggestedName,
            suggestedAppearanceColor: suggestedAppearanceColor
        )

        let task = Task { @MainActor in
            let identity: PersistedWalletIdentity
            do {
                guard let selected =
                    try await database.selectedWalletIdentity()
                else {
                    markPendingWalletLoadFailed(
                        requestID: requestID,
                        address: normalizedAddress,
                        reason: "selected_wallet_missing"
                    )
                    return
                }
                guard AppRootWalletAddressMatcher.matches(
                    selected.address,
                    normalizedAddress
                ) else {
                    markPendingWalletLoadFailed(
                        requestID: requestID,
                        address: normalizedAddress,
                        reason: "selected_wallet_address_mismatch"
                    )
                    return
                }
                identity = selected
            } catch {
                markPendingWalletLoadFailed(
                    requestID: requestID,
                    address: normalizedAddress,
                    reason: WalletSyncDiagnosticErrorDetail.value(for: error)
                )
                return
            }

            async let capabilitiesTask = database.walletCapabilities(
                walletID: identity.walletID
            )
            async let walletTask = database.managedWallet(
                walletID: identity.walletID
            )
            async let snapshotTask = database.cachedWalletSnapshot(
                walletID: identity.walletID
            )

            let capabilities: WalletCapabilities
            do {
                capabilities = try await capabilitiesTask
            } catch {
                markPendingWalletLoadFailed(
                    requestID: requestID,
                    address: normalizedAddress,
                    reason: WalletSyncDiagnosticErrorDetail.value(for: error)
                )
                return
            }

            if capabilities == .fullWallet {
                do {
                    try await database.ensureFullWalletAccountsPersisted(
                        walletID: identity.walletID
                    )
                } catch {
                    markPendingWalletLoadFailed(
                        requestID: requestID,
                        address: normalizedAddress,
                        reason: WalletSyncDiagnosticErrorDetail.value(for: error)
                    )
                    return
                }
            }

            let accountAddresses: WalletAccountAddressIndex
            do {
                accountAddresses = try await database.accountAddressIndex(
                    walletID: identity.walletID
                )
                guard accountAddresses.accountCount > 0 else {
                    throw WalletDataStoreError.invalidState
                }
            } catch {
                markPendingWalletLoadFailed(
                    requestID: requestID,
                    address: normalizedAddress,
                    reason: WalletSyncDiagnosticErrorDetail.value(for: error)
                )
                return
            }

            let managedWallet: ManagedWallet?
            do {
                managedWallet = try await walletTask
            } catch {
                managedWallet = nil
            }

            let cachedSnapshot: WalletHomeSnapshot?
            do {
                cachedSnapshot = try await snapshotTask
            } catch {
                cachedSnapshot = nil
            }

            guard !Task.isCancelled,
                  walletPresentation.acceptsPending(
                    requestID: requestID,
                    address: normalizedAddress
                  )
            else {
                rejectStaleCommit(
                    requestID: requestID,
                    operation: "wallet_selection",
                    stage: "resolved_context_commit"
                )
                return
            }

            let name = managedWallet?.name
                ?? suggestedName
                ?? WalletLocalization.string(
                    "wallet.home.wallet.name.default"
                )
            let context = AppRootResolvedWalletContext(
                requestID: requestID,
                identity: identity,
                name: name,
                capabilities: capabilities,
                appearanceColor: managedWallet?.appearanceColor
                    ?? walletPresentation.appearanceColor,
                accountAddresses: accountAddresses
            )
            let state = cachedSnapshot.map {
                WalletHomeLoadState.content(
                    capabilities.scopedSnapshot($0)
                )
            } ?? .loading
            walletPresentation = .resolved(
                context: context,
                state: state
            )
            readiness.gate.resolve(true)
            startBitcoinFamilyBalanceMonitor(context: context)
            scheduleWalletActionPreparation()

            await loadWallet(
                context: context,
                showsLoadingState: false,
                operation: "wallet_selection"
            )
            guard walletPresentation.accepts(context) else { return }
            walletLoadTask = nil
        }
        walletLoadTask = task
        return requestID
    }

    @MainActor
    func updateCurrentWalletName(
        address: String,
        name: String
    ) {
        guard let renamed = walletPresentation.replacingName(
            name,
            matchingAddress: address
        ) else {
            return
        }
        walletPresentation = renamed
    }

    @MainActor
    func updateCurrentWalletAppearanceColor(
        walletID: String,
        color: WalletAppearanceColor
    ) {
        guard let recolored = walletPresentation
            .replacingAppearanceColor(
                color,
                matchingWalletID: walletID
            )
        else {
            return
        }
        walletPresentation = recolored
    }

    @MainActor
    @discardableResult
    func scheduleWalletLoad(
        context: AppRootResolvedWalletContext,
        showsLoadingState: Bool,
        operation: String
    ) -> Task<Void, Never> {
        if let walletLoadTask, !walletLoadTask.isCancelled {
            return walletLoadTask
        }
        walletLoadTask?.cancel()

        let task = Task { @MainActor in
            await loadWallet(
                context: context,
                showsLoadingState: showsLoadingState,
                operation: operation
            )
            guard walletPresentation.accepts(context) else {
                rejectStaleCommit(
                    requestID: context.requestID,
                    operation: operation,
                    stage: "task_completion"
                )
                return
            }
            walletLoadTask = nil
        }
        walletLoadTask = task
        return task
    }

    @MainActor
    func reboundCurrentWalletContext()
        -> AppRootResolvedWalletContext? {
        guard let current = walletPresentation.resolvedContext else {
            return nil
        }
        return current
    }

    @MainActor
    private func loadWallet(
        context: AppRootResolvedWalletContext,
        showsLoadingState: Bool,
        operation: String
    ) async {
        if showsLoadingState {
            do {
                let cached = try await database.cachedWalletSnapshot(
                    walletID: context.identity.walletID
                )
                guard !Task.isCancelled else {
                    rejectStaleCommit(
                        requestID: context.requestID,
                        operation: operation,
                        stage: "initial_cache_commit"
                    )
                    return
                }
                let state = cached.map {
                    WalletHomeLoadState.content(
                        context.capabilities.scopedSnapshot($0)
                    )
                } ?? .loading
                guard commitWalletState(state, context: context) else {
                    rejectStaleCommit(
                        requestID: context.requestID,
                        operation: operation,
                        stage: "initial_cache_commit"
                    )
                    return
                }
            } catch {
                guard commitWalletState(.loading, context: context) else {
                    rejectStaleCommit(
                        requestID: context.requestID,
                        operation: operation,
                        stage: "initial_cache_failure_commit"
                    )
                    return
                }
            }
        }

        guard await permitsWalletRefresh(context: context) else { return }
        startBitcoinFamilyBalanceMonitor(context: context)
        _ = await synchronizeWalletChains(
            context: context
        )
        guard !Task.isCancelled,
              walletPresentation.accepts(context) else {
            return
        }
    }

    @MainActor
    private func synchronizeWalletChains(
        context: AppRootResolvedWalletContext
    ) async -> WalletSynchronizationReport {
        let database = database
        let sources = context.capabilities.walletSyncSources
        let onProgress: WalletSyncProgressHandler = { event in
            guard !Task.isCancelled,
                  walletPresentation.accepts(context) else {
                return
            }
            await publishCachedSnapshot(
                context: context,
                scope: event.stage.publicationScope
            )
        }
        let report = await withTaskGroup(
            of: WalletChainSyncOutcome.self,
            returning: WalletSynchronizationReport.self
        ) { group in
            var outcomes: [WalletChainSyncOutcome] = []

            if sources.contains(.evm) {
                group.addTask {
                    await Self.synchronizeEVMWallet(
                        database: database,
                        walletID: context.identity.walletID,
                        address: context.identity.address,
                        onProgress: onProgress
                    )
                }
            }
            if sources.contains(.bitcoinFamily) {
                group.addTask {
                    await BitcoinFamilySyncService.shared.sync(
                        walletID: context.identity.walletID,
                        onProgress: onProgress
                    )
                }
            }
            if sources.contains(.tron) {
                group.addTask {
                    await TronSyncService.shared.sync(
                        walletID: context.identity.walletID,
                        onProgress: onProgress
                    )
                }
            }
            if sources.contains(.solana) {
                group.addTask {
                    await SolanaSyncService.shared.sync(
                        walletID: context.identity.walletID,
                        onProgress: onProgress
                    )
                }
            }
            if sources.contains(.ton) {
                group.addTask {
                    await TONSyncService.shared.sync(
                        walletID: context.identity.walletID,
                        onProgress: onProgress
                    )
                }
            }
            if sources.contains(.sui) {
                group.addTask {
                    await SuiSyncService.shared.sync(
                        walletID: context.identity.walletID,
                        onProgress: onProgress
                    )
                }
            }
            if sources.contains(.xrp) {
                group.addTask {
                    await XRPSyncService.shared.sync(
                        walletID: context.identity.walletID,
                        onProgress: onProgress
                    )
                }
            }
            if sources.contains(.near) {
                group.addTask {
                    await NEARSyncService.shared.sync(
                        walletID: context.identity.walletID,
                        onProgress: onProgress
                    )
                }
            }
            if sources.contains(.aptos) {
                group.addTask {
                    await AptosSyncService.shared.sync(
                        walletID: context.identity.walletID,
                        onProgress: onProgress
                    )
                }
            }
            if sources.contains(.stellar) {
                group.addTask {
                    await StellarSyncService.shared.sync(
                        walletID: context.identity.walletID,
                        onProgress: onProgress
                    )
                }
            }
            for await outcome in group {
                guard !Task.isCancelled,
                      walletPresentation.accepts(context) else {
                    group.cancelAll()
                    rejectStaleCommit(
                        requestID: context.requestID,
                        operation: "chain_synchronization",
                        stage: "chain_completion"
                    )
                    return WalletSynchronizationReport(
                        outcomes: outcomes
                    )
                }
                outcomes.append(outcome)
                // Dataset-specific progress events publish persisted portfolio
                // and activity state without waiting for another chain.
            }
            return WalletSynchronizationReport(outcomes: outcomes)
        }

        guard !Task.isCancelled,
              walletPresentation.accepts(context) else {
            rejectStaleCommit(
                requestID: context.requestID,
                operation: "chain_synchronization",
                stage: "notification_reconciliation"
            )
            return report
        }
        if await refreshWalletUSDValuations(
            walletID: context.identity.walletID
        ) {
            await publishCachedSnapshot(
                context: context,
                scope: .portfolioAndActivity
            )
        }
        guard !Task.isCancelled,
              walletPresentation.accepts(context) else {
            rejectStaleCommit(
                requestID: context.requestID,
                operation: "chain_synchronization",
                stage: "wallet_price_enrichment"
            )
            return report
        }
        if WalletActionPreparationPublicationStage
            .synchronizedAggregate
            .schedulesPreparation {
            scheduleWalletActionPreparation()
        }
        if report.didPersistData {
            PushNotificationCoordinator.shared
                .chainSynchronizationDidComplete()
        }
        return report
    }

    /// Balance/identity changes restart this task; fiat-only publications do not.
    var walletValuationRefreshID: String {
        let assets = walletPresentation.contentSnapshot?.assets ?? []
        let identity = walletPresentation.identity?.walletID ?? "pending"
        return walletPresentation.requestID.uuidString + "|" + identity + "|" + String(describing: scenePhase) + "|" + assets
            .map { $0.id + ":" + $0.displayBalanceText }.sorted().joined(separator: "|")
    }

    @MainActor
    func refreshVisibleWalletPrices() async {
        guard scenePhase == .active, let context = walletPresentation.resolvedContext else { return }
        let held = walletPresentation.contentSnapshot?.assets ?? []
        let visibleNative = WalletHomeAssetCatalog.mainScreenAssets(from: WalletHomeAssetCatalog.availableAssets(from: held))
        let assets = context.capabilities.filteredAssets(held + visibleNative)
        guard !assets.isEmpty else { return }
        var attempt = 0
        while !Task.isCancelled, walletPresentation.accepts(context) {
            guard await permitsWalletRefresh(context: context) else { return }
            await WalletAssetPriceRefresh.refresh(database: database, assets: assets) { @MainActor in
                guard !Task.isCancelled, walletPresentation.accepts(context) else { return }
                await publishCachedSnapshot(context: context, scope: .portfolioAndActivity)
            }
            attempt += 1
            // Retry cold failures promptly; cached reads still publish immediately.
            do { try await Task.sleep(for: .seconds(attempt < 3 ? 5 : 60)) }
            catch { return }
        }
    }

    func refreshWalletUSDValuations(
        walletID: String
    ) async -> Bool {
        let assets: [WalletAsset]
        do {
            assets = try await database.walletAssetsRequiringUSDValuation(
                walletID: walletID
            )
        } catch {
            return false
        }
        guard !assets.isEmpty else { return false }
        do { try Task.checkCancellation() }
        catch { return false }
        let prices = await AssetPriceClient.usdPrices(for: assets)
        guard !prices.isEmpty else { return false }
        do {
            return try await database.applyAssetUSDPrices(prices) > 0
        } catch {
            return false
        }
    }

    @MainActor
    private func markPendingWalletLoadFailed(
        requestID: UUID,
        address: String,
        reason: String
    ) {
        guard walletPresentation.acceptsPending(
            requestID: requestID,
            address: address
        ) else {
            rejectStaleCommit(
                requestID: requestID,
                operation: "wallet_selection",
                stage: "failure_commit"
            )
            return
        }
        walletPresentation = AppRootWalletPresentation(
            requestID: requestID,
            identity: nil,
            name: walletPresentation.name,
            address: walletPresentation.address,
            capabilities: .fullWallet,
            appearanceColor: walletPresentation.appearanceColor,
            accountAddresses: .empty,
            state: .failed,
            stateRevision: UUID()
        )
        if walletContextReadinessRequest?.requestID == requestID {
            walletContextReadinessRequest?.gate.resolve(false)
        }
        invalidateWalletActionPreparation()
        walletLoadTask = nil
    }

    @MainActor
    private func rejectStaleCommit(
        requestID: UUID,
        operation: String,
        stage: String
    ) {
    }
}
