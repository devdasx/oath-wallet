import SwiftUI

enum WalletActionPresentationAuthorizationBlocker:
    String,
    Equatable,
    Sendable {
    case wrongRootPhase = "wrong_root_phase"
    case backgroundScene = "background_scene"
    case walletRestricted = "wallet_restricted"
    case staleWalletContext = "stale_wallet_context"
}

enum WalletActionPresentationAuthorization {
    static func blocker(
        phase: AppRootPhase,
        scenePhase: ScenePhase,
        isWalletAccessRestricted: Bool,
        presentation: AppRootWalletPresentation,
        context: AppRootResolvedWalletContext
    ) -> WalletActionPresentationAuthorizationBlocker? {
        guard phase == .wallet else { return .wrongRootPhase }
        guard scenePhase != .background else { return .backgroundScene }
        guard !isWalletAccessRestricted else { return .walletRestricted }
        guard presentation.accepts(context) else {
            return .staleWalletContext
        }
        return nil
    }

    static func allows(
        phase: AppRootPhase,
        scenePhase: ScenePhase,
        isWalletAccessRestricted: Bool,
        presentation: AppRootWalletPresentation,
        context: AppRootResolvedWalletContext
    ) -> Bool {
        blocker(
            phase: phase,
            scenePhase: scenePhase,
            isWalletAccessRestricted: isWalletAccessRestricted,
            presentation: presentation,
            context: context
        ) == nil
    }
}

struct WalletActionBalanceSource: Sendable {
    let requestID: UUID
    let identity: PersistedWalletIdentity
    let stateRevision: UUID
    let assets: [WalletAsset]

    func matches(
        _ context: AppRootResolvedWalletContext
    ) -> Bool {
        requestID == context.requestID
            && identity == context.identity
    }
}

struct WalletReceivePresentationPayload {
    let id = UUID()
    let walletAddress: String
    let capabilities: WalletCapabilities
    let walletAssets: [WalletAsset]
    let transactions: [WalletTransaction]
    let preparation: ReceiveAssetSelectionPreparation
    let contentRevision: UUID
}

struct WalletSelectedReceivePresentationPayload {
    let id = UUID()
    let asset: WalletAsset
    let walletAddress: String
}

struct WalletSendPresentationPayload {
    let id = UUID()
    let walletAddress: String
    let capabilities: WalletCapabilities
    let walletAssets: [WalletAsset]
    let transactions: [WalletTransaction]
    let preparation: SendInitialAssetSelectionPreparation
    let initialRoute: SendFlowRoute?
    let contentRevision: UUID
}

struct WalletScannerPresentationPayload {
    let id = UUID()
    let walletAddress: String
    let capabilities: WalletCapabilities
    let walletAssets: [WalletAsset]
    let transactions: [WalletTransaction]
    let sendPreparation: SendInitialAssetSelectionPreparation
    let selectedAsset: SendAssetChoice?
    let contentRevision: UUID

    init(
        walletAddress: String,
        capabilities: WalletCapabilities,
        walletAssets: [WalletAsset],
        transactions: [WalletTransaction],
        sendPreparation: SendInitialAssetSelectionPreparation,
        selectedAsset: SendAssetChoice? = nil,
        contentRevision: UUID
    ) {
        self.walletAddress = walletAddress
        self.capabilities = capabilities
        self.walletAssets = walletAssets
        self.transactions = transactions
        self.sendPreparation = sendPreparation
        self.selectedAsset = selectedAsset
        self.contentRevision = contentRevision
    }
}

enum WalletActionSheetDestination {
    case receive(WalletReceivePresentationPayload)
    case selectedReceive(WalletSelectedReceivePresentationPayload)
    case send(WalletSendPresentationPayload)
    case scanner(WalletScannerPresentationPayload)

    var id: UUID {
        switch self {
        case let .receive(payload):
            payload.id
        case let .selectedReceive(payload):
            payload.id
        case let .send(payload):
            payload.id
        case let .scanner(payload):
            payload.id
        }
    }

    var coveringModalID: WalletCoveringModalID {
        switch self {
        case .receive:
            .receive
        case .selectedReceive:
            .selectedReceiveAsset
        case .send:
            .send
        case .scanner:
            .scanner
        }
    }


}

struct WalletActionPresentation: Identifiable {
    let id = UUID()
    let context: AppRootResolvedWalletContext
    let initialDestination: WalletActionSheetDestination

    init(
        context: AppRootResolvedWalletContext,
        initialDestination: WalletActionSheetDestination
    ) {
        self.context = context
        self.initialDestination = initialDestination

    }
}

struct WalletActionPresentationSheet: View {
    let presentation: WalletActionPresentation
    @Binding private var currentPreparation:
        WalletActionPresentationPreparation?
    @Binding private var currentBalanceSource:
        WalletActionBalanceSource?
    let database: WalletDatabase
    let onAssetSelected: (WalletAsset) -> Void
    let resolveScannedRoute:
        (
            WalletActionPresentation,
            WalletScannerPresentationPayload,
            SendFlowRoute
        ) -> WalletActionSheetDestination?
    let onPresentationAppeared:
        (WalletActionPresentation, WalletCoveringModalID) -> Bool
    let onTransactionBroadcast: (SendPostBroadcastRefreshRequest) -> Void
    let onModalDismissed: (WalletCoveringModalID) -> Void

    @State private var destination: WalletActionSheetDestination
    @State private var registeredModalID: WalletCoveringModalID?
    @State private var isVisible = false

    init(
        presentation: WalletActionPresentation,
        currentPreparation:
            Binding<WalletActionPresentationPreparation?>,
        currentBalanceSource:
            Binding<WalletActionBalanceSource?>,
        database: WalletDatabase,
        onAssetSelected: @escaping (WalletAsset) -> Void,
        resolveScannedRoute: @escaping (
            WalletActionPresentation,
            WalletScannerPresentationPayload,
            SendFlowRoute
        ) -> WalletActionSheetDestination?,
        onPresentationAppeared: @escaping (
            WalletActionPresentation,
            WalletCoveringModalID
        ) -> Bool,
        onTransactionBroadcast: @escaping (
            SendPostBroadcastRefreshRequest
        ) -> Void,
        onModalDismissed: @escaping (WalletCoveringModalID) -> Void
    ) {
        self.presentation = presentation
        _currentPreparation = currentPreparation
        _currentBalanceSource = currentBalanceSource
        self.database = database
        self.onAssetSelected = onAssetSelected
        self.resolveScannedRoute = resolveScannedRoute
        self.onPresentationAppeared = onPresentationAppeared
        self.onTransactionBroadcast = onTransactionBroadcast
        self.onModalDismissed = onModalDismissed
        _destination = State(
            initialValue: presentation.initialDestination
        )
    }

    var body: some View {
        destinationContent
            .walletSheetPresentation(nativeGlass: false)
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .onAppear {
                isVisible = true
                registerCurrentModal()
            }
            .onDisappear {
                isVisible = false
                unregisterCurrentModal()
            }
    }

    @ViewBuilder
    private var destinationContent: some View {
        switch destination {
        case let .receive(payload):
            let live = matchingCurrentPreparation
            let balances = matchingCurrentBalanceSource
            NavigationStack {
                Group {
                    ReceiveAssetFlowView(
                        database: database,
                        walletAddress: payload.walletAddress,
                        capabilities: payload.capabilities,
                        walletAssets: live?.flowAssets
                            ?? payload.walletAssets,
                        transactions: live?.transactions
                            ?? payload.transactions,
                        preparation: live?.receive
                            ?? payload.preparation,
                        preparationRevision: live?.stateRevision
                            ?? payload.contentRevision,
                        balanceAssets: balances?.assets,
                        balanceRevision: balances?.stateRevision,
                        onAssetSelected: onAssetSelected
                    )
                }

            }
        case let .selectedReceive(payload):
            NavigationStack {
                Group {
                    SelectedAssetReceiveScreen(
                        asset: payload.asset,
                        walletAddress: payload.walletAddress,
                        database: database
                    )
                }

            }
        case let .send(payload):
            let live = matchingCurrentPreparation
            let balances = matchingCurrentBalanceSource
            SendFlowView(
                database: database,
                walletAddress: payload.walletAddress,
                capabilities: payload.capabilities,
                walletAssets: live?.flowAssets
                    ?? payload.walletAssets,
                transactions: live?.transactions
                    ?? payload.transactions,
                preparation: live?.send
                    ?? payload.preparation,
                preparationRevision: live?.stateRevision
                    ?? payload.contentRevision,
                balanceAssets: balances?.assets,
                balanceRevision: balances?.stateRevision,
                initialRoute: payload.initialRoute,
                onTransactionBroadcast: onTransactionBroadcast
            )
        case let .scanner(payload):
            let refreshedPayload = scannerPayload(
                payload,
                preparation: matchingCurrentPreparation,
                balances: matchingCurrentBalanceSource
            )
            WalletAddressScannerScreen(
                prepareRequest: {
                    SendFlowPreparation.prepare(
                        $0,
                        walletAssets: refreshedPayload.walletAssets,
                        capabilities: refreshedPayload.capabilities,
                        selectedAsset: refreshedPayload.selectedAsset
                    )
                },
                onProceed: { route in
                    guard let nextDestination = resolveScannedRoute(
                        presentation,
                        refreshedPayload,
                        route
                    ) else {
                        return
                    }
                    transition(to: nextDestination)
                }
            )
        }
    }

    private var matchingCurrentPreparation:
        WalletActionPresentationPreparation? {
        guard let currentPreparation,
              currentPreparation.requestID
                == presentation.context.requestID,
              currentPreparation.identity
                == presentation.context.identity,
              currentPreparation.capabilities
                == presentation.context.capabilities else {
            return nil
        }
        return currentPreparation
    }

    private var matchingCurrentBalanceSource:
        WalletActionBalanceSource? {
        guard let currentBalanceSource,
              currentBalanceSource.matches(presentation.context) else {
            return nil
        }
        return currentBalanceSource
    }

    private func scannerPayload(
        _ payload: WalletScannerPresentationPayload,
        preparation: WalletActionPresentationPreparation?,
        balances: WalletActionBalanceSource?
    ) -> WalletScannerPresentationPayload {
        let candidates = preparation?.flowAssets
            ?? payload.walletAssets
        let walletAssets = balances.map {
            WalletAssetBalanceSnapshot(assets: $0.assets).projecting(
                candidates: candidates
            )
        } ?? candidates
        return WalletScannerPresentationPayload(
            walletAddress: payload.walletAddress,
            capabilities: payload.capabilities,
            walletAssets: walletAssets,
            transactions: preparation?.transactions
                ?? payload.transactions,
            sendPreparation: preparation?.send
                ?? payload.sendPreparation,
            selectedAsset: refreshedSelectedAsset(
                payload.selectedAsset,
                walletAssets: walletAssets,
                capabilities: payload.capabilities
            ),
            contentRevision: balances?.stateRevision
                ?? preparation?.stateRevision
                ?? payload.contentRevision
        )
    }

    private func refreshedSelectedAsset(
        _ selectedAsset: SendAssetChoice?,
        walletAssets: [WalletAsset],
        capabilities: WalletCapabilities
    ) -> SendAssetChoice? {
        guard let selectedAsset else { return nil }
        let identity = AssetIdentityKey.canonical(selectedAsset.id)
        guard let currentAsset = walletAssets.first(where: {
            AssetIdentityKey.canonical($0.id) == identity
        }) else {
            return selectedAsset
        }
        return SendAssetChoiceCatalog.choice(
            for: currentAsset,
            refreshedFrom: [currentAsset],
            capabilities: capabilities
        ) ?? selectedAsset
    }

    @MainActor
    private func transition(
        to nextDestination: WalletActionSheetDestination
    ) {
        let previousModalID = destination.coveringModalID
        let nextModalID = nextDestination.coveringModalID
        if previousModalID != nextModalID {
            unregisterCurrentModal()
        }
        destination = nextDestination
        if isVisible, previousModalID != nextModalID {
            registerCurrentModal()
        }
    }

    @MainActor
    private func registerCurrentModal() {
        guard registeredModalID == nil else { return }
        let modalID = destination.coveringModalID
        guard onPresentationAppeared(presentation, modalID) else {
            return
        }
        registeredModalID = modalID
    }

    @MainActor
    private func unregisterCurrentModal() {
        guard let registeredModalID else { return }
        self.registeredModalID = nil
        onModalDismissed(registeredModalID)
    }
}
