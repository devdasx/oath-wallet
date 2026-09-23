import Foundation

enum WalletSnapshotPublicationScope: Equatable, Sendable {
    case portfolio
    case activity
    case portfolioAndActivity
    case all
}

extension WalletSyncProgressEvent.Stage {
    var publicationScope: WalletSnapshotPublicationScope {
        switch self {
        case .balancesPersisted:
            .portfolio
        case .transactionsPersisted:
            .activity
        case .snapshotPersisted, .valuationPersisted:
            .portfolioAndActivity
        }
    }
}

extension AppRootView {
    @MainActor
    func assetCatalogDidChange() {
        let catalogGeneration = ReceiveAssetCatalogRuntime.snapshot.generation
        walletPortfolioPublicationGeneration &+= 1
        invalidateWalletActionPreparation()
        scheduleWalletActionPreparation()
        Task {
            await WalletActionCatalogPrewarmer.shared.prepare()
        }
        Task { @MainActor in
            guard let context = reboundCurrentWalletContext() else {
                return
            }
            // Artwork and metadata must update even with no funded holdings,
            // unchanged prices, or an unavailable pricing service.
            await publishCachedSnapshot(
                context: context,
                scope: .portfolioAndActivity
            )
            if await refreshWalletUSDValuations(
                walletID: context.identity.walletID
            ) {
                await publishCachedSnapshot(
                    context: context,
                    scope: .portfolioAndActivity
                )
            }
        }
        Task { @MainActor in
            if let activeLoad = walletLoadTask, !activeLoad.isCancelled {
                await activeLoad.value
            }
            guard ReceiveAssetCatalogRuntime.snapshot.generation
                    == catalogGeneration,
                  case .wallet = phase,
                  let context = reboundCurrentWalletContext(),
                  context.capabilities.walletSyncSources.contains(.evm)
            else {
                return
            }
            await scheduleWalletLoad(
                context: context,
                showsLoadingState: false,
                operation: "asset_catalog_changed"
            ).value
        }
    }

    @MainActor
    func publishCachedSnapshot(
        context: AppRootResolvedWalletContext,
        scope: WalletSnapshotPublicationScope = .all
    ) async {
        guard !Task.isCancelled,
              walletPresentation.accepts(context) else {
            return
        }
        switch scope {
        case .portfolio:
            await publishCachedPortfolio(context: context)
        case .activity:
            await publishCachedActivity(context: context)
        case .portfolioAndActivity:
            await publishCachedPortfolioAndActivity(context: context)
        case .all:
            await publishCompleteCachedSnapshot(context: context)
        }
    }

    @MainActor
    private func publishCachedPortfolio(
        context: AppRootResolvedWalletContext
    ) async {
        walletPortfolioPublicationGeneration &+= 1
        let generation = walletPortfolioPublicationGeneration
        do {
            guard let portfolio = try await database
                .cachedWalletPortfolioSlice(
                    walletID: context.identity.walletID
                ),
                generation == walletPortfolioPublicationGeneration,
                let current = walletPresentation.publicationMergeSnapshot,
                commitPublishedSnapshot(
                    current.replacingPortfolio(portfolio),
                    context: context,
                    dataset: "portfolio"
                )
            else {
                return
            }
        } catch {
        }
    }

    @MainActor
    private func publishCachedActivity(
        context: AppRootResolvedWalletContext
    ) async {
        walletActivityPublicationGeneration &+= 1
        let generation = walletActivityPublicationGeneration
        do {
            guard let activity = try await database
                .cachedWalletActivitySlice(
                    walletID: context.identity.walletID
                ),
                generation == walletActivityPublicationGeneration,
                let current = walletPresentation.publicationMergeSnapshot,
                commitPublishedSnapshot(
                    current.replacingActivity(activity),
                    context: context,
                    dataset: "activity"
                )
            else {
                return
            }
        } catch {
        }
    }

    @MainActor
    private func publishCachedPortfolioAndActivity(
        context: AppRootResolvedWalletContext
    ) async {
        walletPortfolioPublicationGeneration &+= 1
        walletActivityPublicationGeneration &+= 1
        let portfolioGeneration = walletPortfolioPublicationGeneration
        let activityGeneration = walletActivityPublicationGeneration
        let database = database
        let walletID = context.identity.walletID
        var resolvedPortfolio: WalletHomePortfolioSnapshotSlice?
        var resolvedActivity: WalletHomeActivitySnapshotSlice?

        await withTaskGroup(
            of: WalletSnapshotPublicationResult.self
        ) { group in
            group.addTask {
                do {
                    return .portfolio(
                        try await database.cachedWalletPortfolioSlice(
                            walletID: walletID
                        )
                    )
                } catch {
                    return .failure(.portfolio, error)
                }
            }
            group.addTask {
                do {
                    return .activity(
                        try await database.cachedWalletActivitySlice(
                            walletID: walletID
                        )
                    )
                } catch {
                    return .failure(.activity, error)
                }
            }

            for await result in group {
                guard !Task.isCancelled,
                      walletPresentation.accepts(context) else {
                    group.cancelAll()
                    return
                }
                switch result {
                case let .portfolio(portfolio):
                    guard portfolioGeneration
                        == walletPortfolioPublicationGeneration
                    else { continue }
                    resolvedPortfolio = portfolio
                case let .activity(activity):
                    guard activityGeneration
                        == walletActivityPublicationGeneration
                    else { continue }
                    resolvedActivity = activity
                case .failure:
                    break
                }
            }
        }

        guard !Task.isCancelled,
              portfolioGeneration == walletPortfolioPublicationGeneration,
              activityGeneration == walletActivityPublicationGeneration,
              walletPresentation.accepts(context),
              let current = walletPresentation.publicationMergeSnapshot
        else {
            return
        }
        var merged = current
        var publishedDatasets: [String] = []
        if let resolvedPortfolio {
            merged = merged.replacingPortfolio(resolvedPortfolio)
            publishedDatasets.append("portfolio")
        }
        if let resolvedActivity {
            merged = merged.replacingActivity(resolvedActivity)
            publishedDatasets.append("activity")
        }
        guard !publishedDatasets.isEmpty else { return }
        _ = commitPublishedSnapshot(
            merged,
            context: context,
            dataset: publishedDatasets.joined(separator: "+")
        )
    }

    @MainActor
    private func publishCompleteCachedSnapshot(
        context: AppRootResolvedWalletContext
    ) async {
        walletPortfolioPublicationGeneration &+= 1
        walletActivityPublicationGeneration &+= 1
        let portfolioGeneration = walletPortfolioPublicationGeneration
        let activityGeneration = walletActivityPublicationGeneration
        do {
            guard let snapshot = try await database.cachedWalletSnapshot(
                walletID: context.identity.walletID
            ),
                portfolioGeneration == walletPortfolioPublicationGeneration,
                activityGeneration == walletActivityPublicationGeneration
            else {
                return
            }
            _ = commitPublishedSnapshot(
                snapshot,
                context: context,
                dataset: "complete"
            )
        } catch {
        }
    }

    @MainActor
    private func commitPublishedSnapshot(
        _ snapshot: WalletHomeSnapshot,
        context: AppRootResolvedWalletContext,
        dataset: String
    ) -> Bool {
        let scoped = context.capabilities.scopedSnapshot(snapshot)
        guard commitWalletState(
            .content(scoped),
            context: context,
            preparationPublicationStage: .progressiveChainSnapshot
        ) else {
            return false
        }
        return true
    }

    @MainActor
    func commitWalletState(
        _ state: WalletHomeLoadState,
        context: AppRootResolvedWalletContext,
        preparationPublicationStage:
            WalletActionPreparationPublicationStage = .immediateState
    ) -> Bool {
        guard WalletPresentationStateRevisionPolicy.requiresReplacement(
            current: walletPresentation.state,
            incoming: state
        ) else {
            return true
        }
        guard let updated = walletPresentation.replacingState(
            state,
            for: context
        ) else {
            return false
        }
        walletPresentation = updated
        if preparationPublicationStage.schedulesPreparation {
            scheduleWalletActionPreparation()
        }
        return true
    }
}

enum WalletPresentationStateRevisionPolicy {
    static func requiresReplacement(
        current: WalletHomeLoadState,
        incoming: WalletHomeLoadState
    ) -> Bool {
        guard case let .content(currentSnapshot) = current,
              case let .content(incomingSnapshot) = incoming else {
            return true
        }
        return currentSnapshot != incomingSnapshot
    }
}

private extension AppRootWalletPresentation {
    var publicationMergeSnapshot: WalletHomeSnapshot? {
        state.displayedSnapshot
    }
}

private enum WalletSnapshotPublicationDataset: Sendable {
    case portfolio
    case activity

}

private enum WalletSnapshotPublicationResult: @unchecked Sendable {
    case portfolio(WalletHomePortfolioSnapshotSlice?)
    case activity(WalletHomeActivitySnapshotSlice?)
    case failure(WalletSnapshotPublicationDataset, Error)
}
