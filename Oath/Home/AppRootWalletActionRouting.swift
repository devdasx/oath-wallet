import SwiftUI

enum WalletActionReadinessRequirement: Equatable, Sendable {
    case presentationSafe
    case currentSnapshot

    func isSatisfied(
        hasCurrentPreparation: Bool,
        hasStablePreparation: Bool
    ) -> Bool {
        switch self {
        case .presentationSafe:
            hasCurrentPreparation || hasStablePreparation
        case .currentSnapshot:
            hasCurrentPreparation
        }
    }
}

struct WalletHomePasteFailure: Error, Equatable, Sendable {
    let localizedMessage: String
}

enum WalletHomePastePreparation {
    static func request(
        from payload: String
    ) -> Result<SendPaymentRequest, WalletHomePasteFailure> {
        do {
            return .success(
                try ScannerPayloadPolicy.sendRequest(from: payload)
            )
        } catch let error as SendPaymentRequestError {
            return .failure(
                WalletHomePasteFailure(
                    localizedMessage: error.localizedMessage
                )
            )
        } catch let error as SendRecipientNameError {
            return .failure(
                WalletHomePasteFailure(
                    localizedMessage: error.localizedMessage
                )
            )
        } catch {
            return .failure(
                WalletHomePasteFailure(
                    localizedMessage: WalletLocalization.string(
                        "send.error.unsupported_format"
                    )
                )
            )
        }
    }

    static func prepare(
        _ request: SendPaymentRequest,
        walletAssets: [WalletAsset],
        capabilities: WalletCapabilities,
        selectedAsset: SendAssetChoice? = nil
    ) -> SendScanPreparation {
        SendFlowPreparation.prepare(
            request,
            walletAssets: walletAssets,
            capabilities: capabilities,
            selectedAsset: selectedAsset
        )
    }
}

extension AppRootView {
    @MainActor
    func awaitWalletActionReadiness(
        requestID: UUID,
        requirement: WalletActionReadinessRequirement =
            .presentationSafe
    ) async -> Bool {
        while !Task.isCancelled,
              walletPresentation.requestID == requestID {
            if requirement.isSatisfied(
                hasCurrentPreparation:
                    currentWalletActionPreparation != nil,
                hasStablePreparation:
                    currentWalletStableActionPreparation != nil
            ) {
                return true
            }

            if walletPresentation.resolvedContext != nil {
                if walletActionPreparationTask == nil {
                    scheduleWalletActionPreparation()
                }
                guard let preparationTask =
                    walletActionPreparationTask else {
                    return false
                }
                await preparationTask.value
            } else {
                guard walletLoadTask != nil else {
                    return false
                }
                await Task.yield()
            }
        }
        return false
    }

    @MainActor
    func presentReceiveFlow() {
        if deferWalletActionUntilPresentationSafePreparation(.receive) {
            return
        }
        let context = authorizedWalletActionContext(action: .receive)
        guard walletActionPresentation == nil else {
            return
        }
        guard let context else {
            return
        }
        guard let preparation = preparedWalletActions(for: context) else {
            return
        }

        if let candidate = preparation.directSingleCoinAsset
            ?? preparation.bitcoinFamilyAsset {
            let asset = balanceResolvedAsset(
                candidate,
                preparation: preparation
            )
            presentWalletAction(
                selectedReceiveDestination(
                    asset: asset,
                    context: context
                ),
                context: context
            )
            enableAssetVisibilityAfterPresenting(asset)
        } else {
            let walletAssets = balanceResolvedFlowAssets(preparation)
            presentWalletAction(
                .receive(
                    WalletReceivePresentationPayload(
                        walletAddress: context.identity.address,
                        capabilities: context.capabilities,
                        walletAssets: walletAssets,
                        transactions: preparation.transactions,
                        preparation: preparation.receive,
                        contentRevision: preparation.stateRevision
                    )
                ),
                context: context
            )
        }
    }

    @MainActor
    func presentSendFlow() {
        if deferWalletActionUntilPresentationSafePreparation(.send) {
            return
        }
        let context = authorizedWalletActionContext(action: .send)
        guard walletActionPresentation == nil else {
            return
        }
        guard let context else {
            return
        }
        guard let preparation = preparedWalletActions(for: context) else {
            return
        }
        presentWalletAction(
            .send(
                sendPayload(
                    context: context,
                    preparation: preparation,
                    initialRoute: nil
                )
            ),
            context: context
        )
    }

    @MainActor
    func presentPastedSendFlow(
        _ payload: String,
        for selectedAsset: WalletAsset? = nil
    ) {
        switch WalletHomePastePreparation.request(from: payload) {
        case let .success(request):
            presentPastedSendRequest(
                request,
                selectedAsset: selectedAsset
            )
        case let .failure(failure):
            walletHomePasteErrorMessage = failure.localizedMessage
            UniHaptic.play(.error)
        }
    }

    @MainActor
    private func presentPastedSendRequest(
        _ request: SendPaymentRequest,
        selectedAsset: WalletAsset? = nil
    ) {
        if deferPastedSendUntilPresentationSafePreparation(
            request,
            selectedAsset: selectedAsset
        ) {
            return
        }
        let context = authorizedWalletActionContext(action: .send)
        guard walletActionPresentation == nil else {
            return
        }
        guard let context else {
            return
        }
        guard let preparation = preparedWalletActions(for: context) else {
            return
        }

        let selectedChoice: SendAssetChoice?
        if let selectedAsset {
            guard let choice = preparedSendChoice(
                for: selectedAsset,
                preparation: preparation,
                capabilities: context.capabilities
            ) else {
                walletHomePasteErrorMessage = WalletLocalization.string(
                    "send.recipient.error.paste_asset_mismatch"
                )
                UniHaptic.play(.error)
                return
            }
            selectedChoice = choice
        } else {
            selectedChoice = nil
        }

        switch WalletHomePastePreparation.prepare(
            request,
            walletAssets: balanceResolvedFlowAssets(preparation),
            capabilities: context.capabilities,
            selectedAsset: selectedChoice
        ) {
        case let .ready(route):
            presentWalletAction(
                .send(
                    sendPayload(
                        context: context,
                        preparation: preparation,
                        initialRoute: route
                    )
                ),
                context: context
            )
            if let selectedAsset {
                enableAssetVisibilityAfterPresenting(selectedAsset)
            }
        case let .failed(message):
            walletHomePasteErrorMessage = message
            UniHaptic.play(.error)
        }
    }

    @MainActor
    func presentSendAsset(_ asset: WalletAsset) {
        if deferSelectedSendUntilPresentationSafePreparation(asset) {
            return
        }
        let context = authorizedWalletActionContext(action: .send)
        guard walletActionPresentation == nil else {
            return
        }
        guard let context else {
            return
        }
        guard let preparation = preparedWalletActions(for: context) else {
            return
        }
        guard let choice = preparedSendChoice(
            for: asset,
            preparation: preparation,
            capabilities: context.capabilities
        ) else {
            return
        }
        presentWalletAction(
            .send(
                sendPayload(
                    context: context,
                    preparation: preparation,
                    initialRoute:
                        SendFlowPlanner.manualEntryRoute(for: choice)
                )
            ),
            context: context
        )
        enableAssetVisibilityAfterPresenting(asset)
    }

    @MainActor
    func presentReceiveAsset(_ asset: WalletAsset) {
        let context = authorizedWalletActionContext(action: .receive)
        guard walletActionPresentation == nil else {
            return
        }
        guard let context else {
            return
        }
        presentWalletAction(
            selectedReceiveDestination(
                asset: asset,
                context: context
            ),
            context: context
        )
        enableAssetVisibilityAfterPresenting(asset)
    }

    @MainActor
    func presentScannerFlow(for selectedAsset: WalletAsset? = nil) {
        if let selectedAsset {
            if deferSelectedScannerUntilPresentationSafePreparation(
                selectedAsset
            ) {
                return
            }
        } else if deferWalletActionUntilPresentationSafePreparation(
            .scanner
        ) {
            return
        }
        let context = authorizedWalletActionContext(action: .scanner)
        guard walletActionPresentation == nil else {
            return
        }
        guard let context else {
            return
        }
        guard let preparation = preparedWalletActions(for: context) else {
            return
        }
        let selectedChoice: SendAssetChoice?
        if let selectedAsset {
            guard let choice = preparedSendChoice(
                for: selectedAsset,
                preparation: preparation,
                capabilities: context.capabilities
            ) else {
                return
            }
            selectedChoice = choice
        } else {
            selectedChoice = nil
        }
        presentWalletAction(
            .scanner(
                WalletScannerPresentationPayload(
                    walletAddress: context.identity.address,
                    capabilities: context.capabilities,
                    walletAssets:
                        balanceResolvedFlowAssets(preparation),
                    transactions: preparation.transactions,
                    sendPreparation: preparation.send,
                    selectedAsset: selectedChoice,
                    contentRevision: preparation.stateRevision
                )
            ),
            context: context
        )
        if let selectedAsset {
            enableAssetVisibilityAfterPresenting(selectedAsset)
        }
    }

    @MainActor
    func resolveScannedWalletActionRoute(
        _ presentation: WalletActionPresentation,
        _ scanner: WalletScannerPresentationPayload,
        _ route: SendFlowRoute
    ) -> WalletActionSheetDestination? {
        guard walletActionPresentationIsAuthorized(
            presentation,
            stage: "scanner_continuation"
        ) else {
            walletActionPresentation = nil
            return nil
        }
        return .send(
            WalletSendPresentationPayload(
                walletAddress: scanner.walletAddress,
                capabilities: scanner.capabilities,
                walletAssets: scanner.walletAssets,
                transactions: scanner.transactions,
                preparation: scanner.sendPreparation,
                initialRoute: route,
                contentRevision: scanner.contentRevision
            )
        )
    }

    @MainActor
    func walletActionPresentationDidAppear(
        _ presentation: WalletActionPresentation,
        _ modalID: WalletCoveringModalID
    ) -> Bool {
        guard walletActionPresentationIsAuthorized(
            presentation,
            stage: "sheet_on_appear"
        ) else {
            walletActionPresentation = nil
            return false
        }
        coveringModalDidPresent(modalID)
        return true
    }

    @MainActor
    func presentWalletAction(
        _ destination: WalletActionSheetDestination,
        context: AppRootResolvedWalletContext
    ) {
        guard !confirmedTronChecks.contains(where: { $0.showsWarning(for: context.identity.walletID) }) else { return }
        walletActionPresentation = WalletActionPresentation(
            context: context,
            initialDestination: destination
        )
    }

    @MainActor
    private func selectedReceiveDestination(
        asset: WalletAsset,
        context: AppRootResolvedWalletContext
    ) -> WalletActionSheetDestination {
        .selectedReceive(
            WalletSelectedReceivePresentationPayload(
                asset: asset,
                walletAddress:
                    asset.receiveAddress ?? context.identity.address
            )
        )
    }

    @MainActor
    func sendPayload(
        context: AppRootResolvedWalletContext,
        preparation: WalletActionPresentationPreparation,
        initialRoute: SendFlowRoute?
    ) -> WalletSendPresentationPayload {
        WalletSendPresentationPayload(
            walletAddress: context.identity.address,
            capabilities: context.capabilities,
            walletAssets: balanceResolvedFlowAssets(preparation),
            transactions: preparation.transactions,
            preparation: preparation.send,
            initialRoute: initialRoute,
            contentRevision: preparation.stateRevision
        )
    }

    @MainActor
    func authorizedWalletActionContext(
        action: WalletActionKind
    )
        -> AppRootResolvedWalletContext? {
        let context = walletPresentation.resolvedContext
        let blocker: WalletActionPresentationAuthorizationBlocker?
        if let context {
            blocker = WalletActionPresentationAuthorization.blocker(
                phase: phase,
                scenePhase: scenePhase,
                isWalletAccessRestricted: isWalletAccessRestricted,
                presentation: walletPresentation,
                context: context
            )
        } else {
            blocker = nil
        }
        guard blocker == nil, !isWalletMultisigRestricted else { return nil }
        return context
    }

    @MainActor
    func preparedWalletActions(
        for context: AppRootResolvedWalletContext
    ) -> WalletActionPresentationPreparation? {
        guard walletPresentation.accepts(context) else { return nil }
        return currentWalletActionPreparation
            ?? currentWalletStableActionPreparation
    }

    @MainActor
    private func deferWalletActionUntilPresentationSafePreparation(
        _ action: WalletActionKind
    ) -> Bool {
        guard walletActionPresentation == nil,
              let context = authorizedWalletActionContext(action: action),
              currentWalletActionPreparation == nil,
              currentWalletStableActionPreparation == nil else {
            return false
        }
        let requestID = context.requestID
        Task { @MainActor in
            guard await awaitWalletActionReadiness(
                requestID: requestID,
                requirement: .presentationSafe
            ), walletActionPresentation == nil else {
                return
            }
            switch action {
            case .send:
                presentSendFlow()
            case .receive:
                presentReceiveFlow()
            case .scanner:
                presentScannerFlow()
            }
        }
        return true
    }

    @MainActor
    private func deferSelectedSendUntilPresentationSafePreparation(
        _ asset: WalletAsset
    ) -> Bool {
        guard walletActionPresentation == nil,
              let context = authorizedWalletActionContext(action: .send),
              currentWalletActionPreparation == nil,
              currentWalletStableActionPreparation == nil else {
            return false
        }
        let requestID = context.requestID
        Task { @MainActor in
            guard await awaitWalletActionReadiness(
                requestID: requestID,
                requirement: .presentationSafe
            ), walletActionPresentation == nil else {
                return
            }
            presentSendAsset(asset)
        }
        return true
    }

    @MainActor
    private func deferPastedSendUntilPresentationSafePreparation(
        _ request: SendPaymentRequest,
        selectedAsset: WalletAsset? = nil
    ) -> Bool {
        guard walletActionPresentation == nil,
              let context = authorizedWalletActionContext(action: .send),
              currentWalletActionPreparation == nil,
              currentWalletStableActionPreparation == nil else {
            return false
        }
        let requestID = context.requestID
        Task { @MainActor in
            guard await awaitWalletActionReadiness(
                requestID: requestID,
                requirement: .presentationSafe
            ), walletActionPresentation == nil else {
                return
            }
            presentPastedSendRequest(
                request,
                selectedAsset: selectedAsset
            )
        }
        return true
    }

    var walletHomePasteErrorIsPresented: Binding<Bool> {
        Binding(
            get: { walletHomePasteErrorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    walletHomePasteErrorMessage = nil
                }
            }
        )
    }

    @MainActor
    private func deferSelectedScannerUntilPresentationSafePreparation(
        _ asset: WalletAsset
    ) -> Bool {
        guard walletActionPresentation == nil,
              let context = authorizedWalletActionContext(action: .scanner),
              currentWalletActionPreparation == nil,
              currentWalletStableActionPreparation == nil else {
            return false
        }
        let requestID = context.requestID
        Task { @MainActor in
            guard await awaitWalletActionReadiness(
                requestID: requestID,
                requirement: .presentationSafe
            ), walletActionPresentation == nil else {
                return
            }
            presentScannerFlow(for: asset)
        }
        return true
    }

    @MainActor
    private func walletActionPresentationIsAuthorized(
        _ presentation: WalletActionPresentation,
        stage: String
    ) -> Bool {
        let presentationMatches =
            walletActionPresentation?.id == presentation.id
        let blocker = WalletActionPresentationAuthorization.blocker(
            phase: phase,
            scenePhase: scenePhase,
            isWalletAccessRestricted: isWalletAccessRestricted,
            presentation: walletPresentation,
            context: presentation.context
        )
        return presentationMatches && blocker == nil
    }
}
