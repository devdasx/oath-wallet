import Foundation

extension AppRootView {
    var currentWalletActionBalanceSource:
        WalletActionBalanceSource? {
        guard let context = walletPresentation.resolvedContext,
              let snapshot = walletPresentation.contentSnapshot else {
            return nil
        }
        return WalletActionBalanceSource(
            requestID: context.requestID,
            identity: context.identity,
            stateRevision: walletPresentation.stateRevision,
            assets: snapshot.assets
        )
    }

    var currentWalletActionPreparation:
        WalletActionPresentationPreparation? {
        guard let preparation = walletActionPreparation,
              preparation.matches(
                presentation: walletPresentation,
                visibilityPreferencesJSON:
                    applicationSettings.assetVisibilityPreferencesJSON
              ) else {
            return nil
        }
        return preparation
    }

    var currentWalletHomeDisplayPreparation:
        WalletHomePortfolioPreparation? {
        guard let preparation = walletActionPreparation,
              preparation.matchesHomeDisplay(
                presentation: walletPresentation,
                visibilityPreferencesJSON:
                    applicationSettings
                    .assetVisibilityPreferencesJSON
              ) else {
            return nil
        }
        return preparation.home
    }

    var currentWalletStableActionPreparation:
        WalletActionPresentationPreparation? {
        guard let preparation = walletActionPreparation,
              preparation.matchesStableActionPresentation(
                presentation: walletPresentation,
                visibilityPreferencesJSON:
                    applicationSettings
                    .assetVisibilityPreferencesJSON
              ) else {
            return nil
        }
        return preparation
    }

    @MainActor
    func invalidateWalletActionPreparation() {
        walletActionPreparationTask?.cancel()
        walletActionPreparationTask = nil
        walletActionPreparationGeneration = UUID()
        walletActionPreparation = nil
    }

    @MainActor
    func enableAssetVisibilityAfterPresenting(_ asset: WalletAsset) {
        let requestID = walletPresentation.requestID
        Task { @MainActor in
            await Task.yield()
            guard walletPresentation.requestID == requestID else {
                return
            }
            enableAssetVisibility(asset)
        }
    }

    @MainActor
    func scheduleWalletActionPreparation() {
        guard let context = walletPresentation.resolvedContext,
              let input =
                walletPresentation.walletActionPreparationInput else {
            walletActionPreparation = nil
            return
        }

        if walletActionPreparationTask != nil {
            return
        }

        let generation = UUID()
        walletActionPreparationGeneration = generation
        let preferencesJSON =
            applicationSettings.assetVisibilityPreferencesJSON
        let stateRevision = walletPresentation.stateRevision
        walletActionPreparationTask = Task { @MainActor in
            defer {
                completeWalletActionPreparationTask(
                    generation: generation
                )
            }
            let startsRevisionMatches =
                walletPresentation.stateRevision == stateRevision
                && walletPresentation.walletActionPreparationInput?.source
                    == input.source
            let startsValid = !Task.isCancelled
                && walletActionPreparationGeneration == generation
                && walletPresentation.accepts(context)
                && startsRevisionMatches
            guard startsValid else {
                return
            }
            await WalletActionCatalogPrewarmer.shared.prepare()
            let eligibleSolanaTokenMints: Set<String>
            if context.capabilities.permits(
                networkID: SolanaConstants.networkID
            ) {
                eligibleSolanaTokenMints =
                    (try? await database.eligibleSolanaTokenMints()) ?? []
            } else {
                eligibleSolanaTokenMints = []
            }
            let warmupRevisionMatches =
                walletPresentation.stateRevision == stateRevision
                && walletPresentation.walletActionPreparationInput?.source
                    == input.source
            let warmupValid = !Task.isCancelled
                && walletActionPreparationGeneration == generation
                && walletPresentation.accepts(context)
                && warmupRevisionMatches
            guard warmupValid else {
                return
            }
            let cpuPreparation =
                await WalletActionPresentationPreparationBuilder.make(
                    snapshot: input.snapshot,
                    capabilities: context.capabilities,
                    walletAddress: context.identity.address,
                    visibilityPreferencesJSON: preferencesJSON,
                    accountAddresses: context.accountAddresses,
                    eligibleSolanaTokenMints:
                        eligibleSolanaTokenMints,
                    stateRevision: stateRevision
                )
            let preferencesMatch =
                applicationSettings.assetVisibilityPreferencesJSON
                == preferencesJSON
            let cpuRevisionMatches =
                walletPresentation.stateRevision == stateRevision
                && walletPresentation.walletActionPreparationInput?.source
                    == input.source
            let cpuValid = !Task.isCancelled
                && walletActionPreparationGeneration == generation
                && walletPresentation.accepts(context)
                && preferencesMatch
                && cpuRevisionMatches
            guard cpuValid else {
                return
            }

            let bitcoinFamilyAsset: WalletAsset?
            if let chain = context.capabilities.privateKeyNetwork?
                .bitcoinFamilyChain {
                bitcoinFamilyAsset =
                    await WalletReceivePresentationPreparation
                    .bitcoinFamilyAsset(
                        database: database,
                        chain: chain
                    )
            } else {
                bitcoinFamilyAsset = nil
            }
            let accountPreferencesMatch =
                applicationSettings.assetVisibilityPreferencesJSON
                == preferencesJSON
            let accountRevisionMatches =
                walletPresentation.stateRevision == stateRevision
                && walletPresentation.walletActionPreparationInput?.source
                    == input.source
            let accountValid = !Task.isCancelled
                && walletActionPreparationGeneration == generation
                && walletPresentation.accepts(context)
                && accountPreferencesMatch
                && accountRevisionMatches
            guard accountValid else {
                return
            }

            walletActionPreparation =
                WalletActionPresentationPreparation(
                    requestID: context.requestID,
                    identity: context.identity,
                    capabilities: context.capabilities,
                    source: input.source,
                    visibilityPreferencesJSON: preferencesJSON,
                    stateRevision: stateRevision,
                    home: cpuPreparation.home,
                    assetLists: cpuPreparation.assetLists,
                    flowAssets: cpuPreparation.flowAssets,
                    transactions: cpuPreparation.transactions,
                    receive: cpuPreparation.receive,
                    send: cpuPreparation.send,
                    directSingleCoinAsset:
                        cpuPreparation.directSingleCoinAsset,
                    bitcoinFamilyAsset: bitcoinFamilyAsset
                )
        }
    }

    @MainActor
    private func completeWalletActionPreparationTask(
        generation: UUID
    ) {
        guard walletActionPreparationGeneration == generation else {
            return
        }
        walletActionPreparationTask = nil
        let needsCurrentPreparation =
            currentWalletActionPreparation == nil
            && walletPresentation.resolvedContext != nil
            && walletPresentation.walletActionPreparationInput != nil
        let shouldRefresh = needsCurrentPreparation
        if shouldRefresh {
            scheduleWalletActionPreparation()
        }
    }
}

enum OnboardingWalletPostOpenAction: Equatable, Sendable {
    case backUpWallet(
        walletID: String,
        words: [String],
        passphrase: String
    )
    case fundWallet
}

struct OnboardingCreatedWalletOpenRequest: Equatable, Sendable {
    let walletAddress: String
    let action: OnboardingWalletPostOpenAction
}

struct PostCreationWalletBackupPresentation: Identifiable, Sendable {
    let id = UUID()
    let walletID: String
    let words: [String]
    let passphrase: String
}

struct AppRootOnboardingCompletionState {
    private var pendingRequestID: UUID?
    private var pendingAction: OnboardingWalletPostOpenAction?
    var backupPresentation: PostCreationWalletBackupPresentation?
    private(set) var isBackupPresentationActive = false
    private(set) var isFundingPresentationActive = false

    var isBlockingHomePresentation: Bool {
        pendingAction != nil
            || isBackupPresentationActive
            || isFundingPresentationActive
    }

    mutating func stage(
        requestID: UUID,
        action: OnboardingWalletPostOpenAction
    ) {
        cancel()
        pendingRequestID = requestID
        pendingAction = action
    }

    mutating func cancelPendingAction(for requestID: UUID) {
        guard pendingRequestID == requestID else { return }
        pendingRequestID = nil
        pendingAction = nil
    }

    mutating func consumePendingAction(
        for requestID: UUID
    ) -> OnboardingWalletPostOpenAction? {
        guard pendingRequestID == requestID,
              let pendingAction else {
            return nil
        }
        pendingRequestID = nil
        self.pendingAction = nil
        return pendingAction
    }

    mutating func beginBackupPresentation(
        walletID: String,
        words: [String],
        passphrase: String
    ) {
        backupPresentation = PostCreationWalletBackupPresentation(
            walletID: walletID,
            words: words,
            passphrase: passphrase
        )
        isBackupPresentationActive = true
    }

    mutating func beginFundingPresentation() {
        isFundingPresentationActive = true
    }

    @discardableResult
    mutating func finishBackupPresentation() -> Bool {
        guard isBackupPresentationActive else { return false }
        isBackupPresentationActive = false
        backupPresentation = nil
        return true
    }

    @discardableResult
    mutating func finishFundingPresentation() -> Bool {
        guard isFundingPresentationActive else { return false }
        isFundingPresentationActive = false
        return true
    }

    mutating func cancel() {
        pendingRequestID = nil
        pendingAction = nil
        backupPresentation = nil
        isBackupPresentationActive = false
        isFundingPresentationActive = false
    }
}

extension AppRootView {
    @MainActor
    func presentOnboardingCompletionActionIfNeeded() {
        guard phase == .wallet,
              let action = onboardingCompletion.consumePendingAction(
                for: walletPresentation.requestID
              ) else {
            return
        }

        switch action {
        case let .backUpWallet(walletID, words, passphrase):
            onboardingCompletion.beginBackupPresentation(
                walletID: walletID,
                words: words,
                passphrase: passphrase
            )
        case .fundWallet:
            onboardingCompletion.beginFundingPresentation()
            presentReceiveFlow()
        }
    }

    @MainActor
    func postCreationWalletBackupDidComplete() {
        PushNotificationCoordinator.shared.walletDataDidChange()
    }

    @MainActor
    func postCreationWalletBackupDidDismiss() {
        guard onboardingCompletion.finishBackupPresentation() else {
            return
        }
        resumeDeferredHomePresentationAfterOnboardingAction()
    }

    @MainActor
    func walletActionSheetDidDismiss() {
        sendActivities.hasDismissedSendSheet = true
        if onboardingCompletion.finishFundingPresentation() {
            resumeDeferredHomePresentationAfterOnboardingAction()
        }
    }

    @MainActor
    private func resumeDeferredHomePresentationAfterOnboardingAction() {
        guard phase == .wallet, !isWalletAccessRestricted else { return }
        presentPendingNotificationIfPossible()
    }
}

extension AppRootView {
    private var loadedWalletAssets: [WalletAsset] {
        guard case let .content(snapshot) = walletState else { return [] }
        return snapshot.assets
    }

    var loadedWalletTransactions: [WalletTransaction] {
        if let preparation = currentWalletActionPreparation {
            return preparation.transactions
        }
        guard case let .content(snapshot) = walletState else { return [] }
        return snapshot.transactions
    }

    var flowWalletAssets: [WalletAsset] {
        if let preparation = currentWalletActionPreparation {
            return preparation.flowAssets
        }
        return WalletHomeAssetCatalog.availableAssets(
            from: loadedWalletAssets
        )
        .filter {
            WalletHomeAssetVisibility.isAvailableOutsideManagement(
                $0,
                walletAddress: walletAddress,
                preferencesJSON:
                    applicationSettings.assetVisibilityPreferencesJSON
            )
        }
    }

    var directSingleCoinAsset: WalletAsset? {
        if let preparation = currentWalletActionPreparation {
            return preparation.directSingleCoinAsset
        }
        guard
            let network = walletCapabilities.privateKeyNetwork,
            !network.supportsMultipleAssets
        else {
            return nil
        }
        return WalletHomeAssetCatalog.availableAssets(
            from: loadedWalletAssets
        )
        .filter { $0.network == network.blockchain }
        .max { lhs, rhs in lhs.fiatValue < rhs.fiatValue }
    }

    @MainActor
    func enableAssetVisibility(_ asset: WalletAsset) {
        guard let json = WalletHomeAssetVisibility.updatedPreferencesJSON(
            setting: true,
            for: asset,
            walletAddress: walletAddress,
            preferencesJSON:
                applicationSettings.assetVisibilityPreferencesJSON
        ) else {
            return
        }
        applicationSettings.setAssetVisibilityPreferencesJSON(json)
    }
}
