import SwiftUI

struct SendFlowView: View {
    let database: WalletDatabase
    private let feePreferences: SendNetworkFeePreferenceRepository
    let walletAddress: String
    let walletAssets: [WalletAsset]
    let transactions: [WalletTransaction]
    let capabilities: WalletCapabilities
    private let preparation: SendInitialAssetSelectionPreparation
    private let selectionProjection: WalletAssetSelectionProjection
    private let preparationRevision: UUID
    private let onTransactionBroadcast: (SendPostBroadcastRefreshRequest) -> Void

    @Environment(SendActivityStore.self) private var sendActivities
    @State private var submissionRequestID = UUID()
    @State private var didHandOffSubmission = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(WalletSettingsStore.self) private var applicationSettings
    @State private var path: [SendFlowRoute]
    @State private var amountEntries: [SendDraft: SendAmountEntryState] = [:]
    @State private var authorizationPreparationError: String?
    @State private var authorizationNavigation =
        SendAuthorizationNavigationState()
    @State private var authorizationFullScreenRoute:
        SendAuthorizationFullScreenRoute?
    @State private var authorizationFullScreenCompletion:
        SendAuthorizationFullScreenCompletion?

    init(
        database: WalletDatabase,
        walletAddress: String,
        capabilities: WalletCapabilities = .fullWallet,
        walletAssets: [WalletAsset],
        transactions: [WalletTransaction] = [],
        preparation: SendInitialAssetSelectionPreparation? = nil,
        preparationRevision: UUID,
        balanceAssets: [WalletAsset]? = nil,
        balanceRevision: UUID? = nil,
        initialRoute: SendFlowRoute? = nil,
        onTransactionBroadcast: @escaping (
            SendPostBroadcastRefreshRequest
        ) -> Void = { _ in }
    ) {
        self.database = database
        feePreferences = SendNetworkFeePreferenceRepository(
            database: database
        )
        self.walletAddress = walletAddress
        self.capabilities = capabilities
        let prepared = preparation
            ?? SendInitialAssetSelectionPreparation.make(
                walletAssets: walletAssets,
                transactions: transactions,
                capabilities: capabilities
            )
        let projection = prepared.projection(
            revision: balanceRevision ?? preparationRevision,
            balanceAssets: balanceAssets
        )
        selectionProjection = projection
        self.walletAssets = projection.assets
        self.transactions = prepared.transactions
        self.preparation = prepared
        self.preparationRevision = balanceRevision
            ?? preparationRevision

        self.onTransactionBroadcast = onTransactionBroadcast
        _path = State(
            initialValue: initialRoute.map { [$0] } ?? []
        )
    }

    var body: some View {
        NavigationStack(path: ($path)) {
            SendInitialAssetSelectionScreen(
                database: database,
                walletAddress: walletAddress,
                capabilities: capabilities,
                walletAssets: walletAssets,
                transactions: transactions,
                preparation: preparation,
                preparationRevision: preparationRevision,
                projection: selectionProjection,
                onSelected: beginManualSend
            )
            .navigationDestination(for: SendFlowRoute.self) { route in
                destination(for: route)
            }
        }
        .fullScreenCover(
            item: $authorizationFullScreenRoute,
            onDismiss: authorizationFullScreenDidDismiss
        ) { route in
            WalletAuthenticationFullScreenContainer(
                title: "security.authentication.navigation_title"
            ) {
                SendTransactionAuthorizationScreen(
                    database: database,
                    draft: route.draft,
                    initialErrorKey: route.initialErrorKey,
                    onAuthorized: { authorization in
                        completeAuthorizationFullScreen(
                            context: route.context,
                            authorization: authorization
                        )
                    }
                )
            }
        }
        .alert(
            "send.broadcast.failed.title",
            isPresented: authorizationPreparationErrorIsPresented
        ) {
            Button("common.ok", role: .cancel, action: UniHaptic.action {
                authorizationPreparationError = nil
            })
        } message: {
            Text(verbatim: authorizationPreparationError ?? "")
        }
        .onChange(of: scenePhase) { _, newPhase in
            handleAuthorizationScenePhase(newPhase)
        }
        .onChange(of: path) { _, routes in
            let activeAmountDrafts = Set(routes.compactMap { route -> SendDraft? in
                guard case let .amount(draft, _) = route else { return nil }
                return draft
            })
            amountEntries = amountEntries.filter { activeAmountDrafts.contains($0.key) }
        }
    }

    @ViewBuilder
    private func destination(
        for route: SendFlowRoute
    ) -> some View {
        switch route {
        case .textAddressEntry:
            SendTextAddressScreen(
                prepareRequest: prepare,
                onProceed: { preparedRoute in
                    path.append(preparedRoute)
                }
            )
        case let .assetSelection(request):
            SendAssetSelectionScreen(
                request: request,
                choices: choices(for: request),
                transactions: transactions,
                onSelected: { asset in
                    continueAfterSelecting(
                        asset,
                        request: request
                    )
                }
            )
        case let .recipient(draft, initialFailure):
            SendRecipientScreen(
                database: database,
                feePreferences: feePreferences,
                draft: draft,
                initialValidationFailure: initialFailure,
                isBalanceHidden: applicationSettings.balancePrivacyEnabled,
                onContinue: { recipientDraft in
                    path.append(SendFlowPlanner.amountEntryRoute(afterRecipient: recipientDraft))
                }
            )
        case let .amount(draft, initialFailure):
            SendAmountScreen(
                database: database,
                feePreferences: feePreferences,
                draft: draft,
                nativeUnitUSDPrice: nativeUnitUSDPrice(
                    for: draft.asset.networkID
                ),
                initialValidationFailure: initialFailure,
                initialState: amountEntries[draft],
                onStateChange: { entry in
                    // The disappearance callback can run after native Back
                    // has removed the route. Never recreate an abandoned draft.
                    guard path.contains(where: {
                        if case let .amount(active, _) = $0 { return active == draft }
                        return false
                    }) else { return }
                    amountEntries[draft] = entry
                },
                onReview: { reviewedDraft in
                    path.append(.review(reviewedDraft))
                }
            )
        case let .review(draft):
            SendReviewScreen(
                database: database,
                feePreferences: feePreferences,
                draft: draft,
                nativeUnitUSDPrice: nativeUnitUSDPrice(
                    for: draft.asset.networkID
                ),
                isAuthorizing: authorizationNavigation.isAuthorizing,
                slideResetID: authorizationNavigation.reviewResetID,
                onContinue: { reviewedDraft in
                    Task {
                        await continueAfterReview(
                            reviewedDraft,
                            sourceRouteDraft: draft
                        )
                    }
                }
            )
        }
    }

    private func beginManualSend(_ asset: SendAssetChoice) {
        path.append(SendFlowPlanner.manualEntryRoute(for: asset))
    }

    @MainActor
    private func continueAfterReview(
        _ reviewedDraft: SendDraft,
        sourceRouteDraft: SendDraft
    ) async {
        let context = SendAuthorizationReviewContext(
            sourceRouteDraft: sourceRouteDraft,
            reviewedDraft: reviewedDraft
        )
        guard context.isCurrent(in: path) else { return }
        guard let requestID = authorizationNavigation
            .beginAuthorization() else {
            return
        }
        do {
            let outcome = try await SendAuthorizationRouter(
                database: database
            ).prepare(for: reviewedDraft)
            authorizationNavigation.receive(
                outcome,
                context: context,
                requestID: requestID,
                sceneIsActive: scenePhase == .active,
                sceneIsBackground: scenePhase == .background
            )
            presentPendingAuthorizationNavigation()
        } catch let error as SendTransactionAuthorizationRoutingError {
            guard authorizationNavigation.fail(
                requestID: requestID
            ) else {
                return
            }
            authorizationPreparationError = error.localizedMessage
        } catch let error as SendTransactionSubmissionError {
            guard authorizationNavigation.fail(
                requestID: requestID
            ) else {
                return
            }
            authorizationPreparationError = error.localizedMessage
        } catch {
            guard authorizationNavigation.fail(
                requestID: requestID
            ) else {
                return
            }
            let diagnostic = SendTransactionSubmissionError
                .sanitizedErrorType(error)
            authorizationPreparationError = SendTransactionSubmissionError
                .signing(
                    code: "authorization_preparation",
                    message: diagnostic
                )
                .localizedMessage
        }
    }

    @MainActor
    private func acceptPasscodeAuthorization(
        context: SendAuthorizationReviewContext,
        authorization: SendTransactionAuthorization
    ) {
        authorizationNavigation.acceptAfterPasscode(
            context: context,
            authorization: authorization,
            sceneIsActive: scenePhase == .active,
            sceneIsBackground: scenePhase == .background
        )
        presentPendingAuthorizationNavigation()
    }

    @MainActor
    private func handleAuthorizationScenePhase(
        _ newPhase: ScenePhase
    ) {
        switch newPhase {
        case .active:
            authorizationNavigation.resumeAfterInactive()
            presentPendingAuthorizationNavigation()
        case .background:
            authorizationFullScreenCompletion = nil
            authorizationNavigation.invalidateForBackground()
        case .inactive:
            break
        @unknown default:
            authorizationNavigation.invalidateForBackground()
        }
    }

    @MainActor
    private func presentPendingAuthorizationNavigation() {
        guard scenePhase != .background,
              let presentation = authorizationNavigation
                .takePendingPresentation(sceneIsActive: scenePhase == .active) else {
            return
        }

        switch presentation {
        case let .broadcast(context, authorization):
            guard context.isCurrent(in: path) else { return }
            showBroadcast(
                draft: context.reviewedDraft,
                authorization: authorization
            )
        case let .passcode(context, initialErrorKey):
            guard context.isCurrent(in: path) else { return }
            authorizationFullScreenRoute =
                SendAuthorizationFullScreenRoute(
                    context: context,
                    initialErrorKey: initialErrorKey
                )
        }
    }

    @MainActor
    private func completeAuthorizationFullScreen(
        context: SendAuthorizationReviewContext,
        authorization: SendTransactionAuthorization
    ) {
        authorizationFullScreenCompletion =
            SendAuthorizationFullScreenCompletion(
                context: context,
                authorization: authorization
            )
        authorizationFullScreenRoute = nil
    }

    @MainActor
    private func authorizationFullScreenDidDismiss() {
        guard let completion = authorizationFullScreenCompletion else {
            authorizationNavigation.cancelAuthorization()
            return
        }
        authorizationFullScreenCompletion = nil
        acceptPasscodeAuthorization(
            context: completion.context,
            authorization: completion.authorization
        )
    }

    @MainActor
    private func showBroadcast(
        draft: SendDraft,
        authorization: SendTransactionAuthorization
    ) {
        guard !didHandOffSubmission else { return }
        didHandOffSubmission = true
        sendActivities.start(
            requestID: submissionRequestID, database: database, draft: draft, authorization: authorization,
            walletAddress: walletAddress, nativeUnitUSDPrice: nativeUnitUSDPrice(for: draft.asset.networkID),
            onTransactionBroadcast: onTransactionBroadcast
        )
        dismiss()
    }

    private var authorizationPreparationErrorIsPresented: Binding<Bool> {
        Binding(
            get: {
                authorizationPreparationError != nil
            },
            set: { isPresented in
                if !isPresented {
                    authorizationPreparationError = nil
                }
            }
        )
    }

    @MainActor
    private func prepare(
        _ request: SendPaymentRequest
    ) -> SendScanPreparation {
        SendFlowPreparation.prepare(
            request,
            walletAssets: walletAssets,
            capabilities: capabilities
        )
    }

    @MainActor
    private func continueAfterSelecting(
        _ asset: SendAssetChoice,
        request: SendPaymentRequest
    ) -> String? {
        do {
            let nextRoute = try SendFlowPlanner.route(
                afterSelecting: asset,
                for: request
            )
            path.append(nextRoute)
            return nil
        } catch let error as SendFlowPlanningError {
            return error.localizedMessage
        } catch let error as SendRecipientNameError {
            return error.localizedMessage
        } catch {
            return WalletLocalization.string(
                "send.error.unsupported_format"
            )
        }
    }

    private func choices(
        for request: SendPaymentRequest
    ) -> [SendAssetChoice] {
        SendAssetChoiceCatalog.choices(
            from: walletAssets,
            capabilities: capabilities,
            for: request
        )
    }

    private func nativeUnitUSDPrice(
        for networkID: String
    ) -> Decimal? {
        let nativeAssetID = AssetIdentityKey.make(
            networkID: networkID,
            contractAddress: nil
        )
        guard let asset = walletAssets.first(where: {
            AssetIdentityKey.canonical($0.id) == nativeAssetID
        }), asset.balance > 0, asset.fiatValue > 0 else {
            return nil
        }
        return asset.fiatValue / asset.balance
    }
}

struct SendAuthorizationFullScreenRoute: Identifiable {
    let id = UUID()
    let context: SendAuthorizationReviewContext
    let initialErrorKey: String?

    var draft: SendDraft { context.reviewedDraft }
}

struct SendAuthorizationFullScreenCompletion {
    let context: SendAuthorizationReviewContext
    let authorization: SendTransactionAuthorization
}

struct SendAuthorizationReviewContext: Hashable, Sendable {
    let sourceRouteDraft: SendDraft
    let reviewedDraft: SendDraft

    func isCurrent(in path: [SendFlowRoute]) -> Bool {
        path.last == .review(sourceRouteDraft)
    }
}

enum SendAuthorizationRoutingOutcome: Sendable {
    case authorized(SendTransactionAuthorization)
    case requiresPasscode(initialErrorKey: String?)
    case cancelled
}

enum SendAuthorizationNavigationPresentation: Hashable, Sendable {
    case broadcast(
        SendAuthorizationReviewContext,
        SendTransactionAuthorization
    )
    case passcode(
        SendAuthorizationReviewContext,
        initialErrorKey: String?
    )
}

struct SendAuthorizationNavigationState {
    private(set) var isAuthorizing = false
    private(set) var activeRequestID: UUID?
    private(set) var reviewResetID = UUID()

    private var deferredPresentation:
        SendAuthorizationNavigationPresentation?
    private var pendingPresentation:
        SendAuthorizationNavigationPresentation?

    mutating func beginAuthorization() -> UUID? {
        guard !isAuthorizing else { return nil }
        let requestID = UUID()
        activeRequestID = requestID
        isAuthorizing = true
        deferredPresentation = nil
        pendingPresentation = nil
        return requestID
    }

    mutating func receive(
        _ outcome: SendAuthorizationRoutingOutcome,
        context: SendAuthorizationReviewContext,
        requestID: UUID,
        sceneIsActive: Bool,
        sceneIsBackground: Bool = false
    ) {
        guard activeRequestID == requestID else { return }
        guard !sceneIsBackground else {
            invalidateForBackground()
            return
        }
        activeRequestID = nil
        isAuthorizing = false
        guard let presentation = Self.presentation(
            for: outcome,
            context: context
        ) else {
            reviewResetID = UUID()
            return
        }
        stage(
            presentation,
            sceneIsActive: sceneIsActive
        )
    }

    @discardableResult
    mutating func fail(requestID: UUID) -> Bool {
        guard activeRequestID == requestID else { return false }
        activeRequestID = nil
        isAuthorizing = false
        reviewResetID = UUID()
        return true
    }

    mutating func acceptAfterPasscode(
        context: SendAuthorizationReviewContext,
        authorization: SendTransactionAuthorization,
        sceneIsActive: Bool,
        sceneIsBackground: Bool
    ) {
        guard !sceneIsBackground else { return }
        stage(
            .broadcast(context, authorization),
            sceneIsActive: sceneIsActive
        )
    }

    mutating func resumeAfterInactive() {
        guard let deferredPresentation else { return }
        self.deferredPresentation = nil
        pendingPresentation = deferredPresentation
    }

    mutating func invalidateForBackground() {
        let hadPendingAuthorization = isAuthorizing || activeRequestID != nil
            || deferredPresentation != nil || pendingPresentation != nil
        activeRequestID = nil
        isAuthorizing = false
        deferredPresentation = nil
        pendingPresentation = nil
        if hadPendingAuthorization { reviewResetID = UUID() }
    }

    mutating func cancelAuthorization() {
        invalidateForBackground()
        reviewResetID = UUID()
    }

    mutating func takePendingPresentation(sceneIsActive: Bool = true)
        -> SendAuthorizationNavigationPresentation? {
        guard sceneIsActive else { return nil }
        defer { pendingPresentation = nil }
        return pendingPresentation
    }

    private mutating func stage(
        _ presentation: SendAuthorizationNavigationPresentation,
        sceneIsActive: Bool
    ) {
        if sceneIsActive {
            pendingPresentation = presentation
        } else {
            deferredPresentation = presentation
        }
    }

    private static func presentation(
        for outcome: SendAuthorizationRoutingOutcome,
        context: SendAuthorizationReviewContext
    ) -> SendAuthorizationNavigationPresentation? {
        switch outcome {
        case let .authorized(authorization):
            .broadcast(context, authorization)
        case let .requiresPasscode(initialErrorKey):
            .passcode(
                context,
                initialErrorKey: initialErrorKey
            )
        case .cancelled:
            nil
        }
    }
}

struct SendAuthorizationRouter: Sendable {
    typealias AuthenticationAction = @MainActor @Sendable (
        WalletSecuritySettings
    ) async -> WalletAuthenticationActionPreparation

    let database: WalletDatabase
    private let authenticationAction: AuthenticationAction

    init(
        database: WalletDatabase,
        authenticationAction: @escaping AuthenticationAction = {
            settings in
            await WalletAuthenticationAction.prepare(
                settings: settings,
                purpose: .sendTransaction
            )
        }
    ) {
        self.database = database
        self.authenticationAction = authenticationAction
    }

    func prepare(
        for draft: SendDraft
    ) async throws -> SendAuthorizationRoutingOutcome {
        guard let identity = try await database
            .selectedWalletIdentity() else {
            throw SendTransactionAuthorizationRoutingError
                .walletUnavailable
        }
        let settings = try await database.walletSecuritySettings()
        let issuer = SendTransactionAuthorizationIssuer(
            database: database
        )
        guard settings.requiresAuthentication else {
            return .authorized(
                try await issuer.issueWithoutProtection(
                    reviewedDraft: draft,
                    walletID: identity.walletID
                )
            )
        }

        switch await authenticationAction(settings) {
        case let .authorized(grant):
            return .authorized(
                try await issuer.issue(
                    reviewedDraft: draft,
                    walletID: identity.walletID,
                    authenticationGrant: grant
                )
            )
        case let .requiresPasscode(context):
            return .requiresPasscode(
                initialErrorKey: context.initialErrorKey
            )
        case .cancelled:
            return .cancelled
        }
    }
}

enum SendTransactionAuthorizationRoutingError: Error {
    case walletUnavailable

    var localizedMessage: String {
        switch self {
        case .walletUnavailable:
            WalletLocalization.string(
                "send.submit.error.wallet_unavailable"
            )
        }
    }
}
