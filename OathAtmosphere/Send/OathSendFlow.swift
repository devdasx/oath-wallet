import SwiftUI
import OathDatabase

/// The production send composer uses actual holdings and address-book data.
/// Bitcoin submits through its authenticated, persisted send service.
struct OathSendFlow: View {
    let session: OathWalletSession
    @Environment(\.oathLocalizer) private var strings
    @Environment(\.dismiss) private var dismiss
    @State private var model: OathSendModel
    @State private var bitcoin = OathBitcoinSendModel()
    @State private var sui = OathSuiSendModel()
    @State private var xrpl = OathXrplSendModel()
    @State private var stellar = OathStellarSendModel()
    @State private var ton = OathTonSendModel()
    @State private var solana = OathSolanaSendModel()
    @State private var evm = OathEVMSendModel()
    @State private var arc = OathArcSendModel()
    @State private var aptos = OathAptosSendModel()
    @State private var thorchain = OathThorchainSendModel()
    @State private var polkadot = OathPolkadotSendModel()
    @State private var near = OathNearSendModel()
    @State private var tron = OathTronSendModel()
    @State private var retry = UUID()
    @State private var scannedAssetSearch = OathTokenSearchModel()
    private let scannedRecipient: OathScannedRecipient?

    init(session: OathWalletSession, walletID: String? = nil, holdingID: String? = nil,
         scannedRecipient: OathScannedRecipient? = nil, initialHolding: Holding? = nil,
         recipient: SendRecipient? = nil, startsScannedAmount: Bool = false) {
        self.session = session
        self.scannedRecipient = scannedRecipient
        let model = OathSendModel(walletID: walletID ?? session.displayedProfile?.id.uuidString ?? "",
                                 holdingID: initialHolding == nil ? holdingID : nil, recipient: recipient,
                                 scannedRecipient: scannedRecipient)
        if let initialHolding, let snapshot = session.portfolio {
            if startsScannedAmount, let scannedRecipient {
                model.startScannedSend(initialHolding, from: snapshot, recipient: scannedRecipient)
            } else {
                model.choose(initialHolding, from: snapshot, scannedRecipient: scannedRecipient)
            }
        } else if let snapshot = session.portfolio {
            model.prepareInitialSelection(from: snapshot)
        }
        _model = State(initialValue: model)
    }

    private var allowed: Bool { session.isUnlocked && !session.resetting && session.wallets.contains { $0.id == model.walletID } }
    private var observationID: String { "\(allowed)-\(model.walletID)-\(session.portfolio?.currency ?? "USD")-\(retry)" }
    private var permittedNetworks: Set<OathImportChain>? {
        let scannedNetworks = scannedRecipient.map { Set($0.networks) }
        guard let recipientNetworks = model.recipientNetworks else { return scannedNetworks }
        return scannedNetworks.map { recipientNetworks.intersection($0) } ?? recipientNetworks
    }
    private var tokenSearchRequest: OathTokenSearchRequest {
        .init(query: model.query, walletID: model.walletID,
              active: allowed && !session.changingWallet && model.path.isEmpty,
              snapshot: model.snapshot,
              permittedNetworks: permittedNetworks)
    }

    var body: some View {
        NavigationStack(path: $model.path) {
            assetPicker
                .navigationTitle(strings.text(.sendChooseAsset))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarLeading) {
                    OathCloseButton { dismiss() }.accessibilityIdentifier("send.close")
                } }
                .navigationDestination(for: OathSendModel.Step.self) { step in
                    Group {
                        if model.holding != nil {
                            switch step {
                            case .recipient:
                                OathSendRecipientPage(model: model, allowed: allowed)
                                    .navigationTitle(strings.text(.sendRecipient))
                            case .amount:
                                OathSendAmountPage(model: model, session: session) {
                                    guard model.path.last != .review else { return false }
                                    guard model.prepareReview(locale: strings.language.locale) else { return false }
                                    // Start in this tap, before SwiftUI presents review. The
                                    // flow owns the task across the navigation transition.
                                    bitcoin.prepare(model: model, session: session)
                                    sui.prepare(model: model, session: session)
                                    xrpl.prepare(model: model, session: session)
                                    stellar.prepare(model: model, session: session)
                                    tron.prepare(model: model, session: session)
                                    ton.prepare(model: model, session: session)
                                    solana.prepare(model:model,session:session)
                                    evm.prepare(model:model,session:session)
                                    arc.prepare(model:model,session:session)
                                    aptos.prepare(model: model, session: session)
                                    thorchain.prepare(model: model, session: session)
                                    near.prepare(model: model, session: session)
                                    polkadot.prepare(model: model, session: session)
                                    return true
                                }
                                    .navigationTitle(strings.text(.sendAmount))
                            case .review:
                                OathSendReviewPage(model: model, session: session, bitcoin: bitcoin, sui: sui, xrpl: xrpl, stellar: stellar, tron: tron, ton: ton, solana: solana, aptos: aptos, thorchain: thorchain, evm: evm, arc: arc, polkadot: polkadot, near: near, onClose: { dismiss() })
                            }
                        }
                    }
                    .navigationBarTitleDisplayMode(.inline)
                    .oathNativeLocalization()
                    .background(Color(uiColor: OathSurfaceColors.canvas).ignoresSafeArea())
                }
                .oathNativeLocalization()
                .background(Color(uiColor: OathSurfaceColors.canvas).ignoresSafeArea())
        }
        .background(Color(uiColor: OathSurfaceColors.canvas).ignoresSafeArea())
        .oathLanguage(strings.language)
        .environment(\.oathScanSession, session)
        .oathInteractionBlocked(!allowed)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .task(id: observationID) {
            guard allowed else { return }
            await model.observe(currency: session.portfolio?.currency ?? "USD")
        }
        .task(id: model.scannedAssetResolution?.id) {
            guard allowed, !session.changingWallet else { return }
            await model.resolveScannedAsset { recipient, snapshot in
                guard let reference = recipient.token, reference != "native" else { return nil }
                await scannedAssetSearch.search(reference, available: Set(recipient.networks), requiredReference: reference)
                guard !Task.isCancelled, allowed, !session.changingWallet,
                      session.displayedProfile?.id.uuidString == snapshot.wallet.id,
                      model.walletID == snapshot.wallet.id, model.scannedAssetResolution != nil,
                      let current = model.snapshot, current.wallet.id == snapshot.wallet.id,
                      current.accounts.filter({ account in recipient.networks.contains(where: { $0.id == account.networkID }) }).count == 1 else { return nil }
                let matches = scannedAssetSearch.results.filter {
                    recipient.matchesAsset(networkID: $0.network.id, reference: $0.isNativeRepresentation ? "native" : $0.reference, symbol: $0.symbol)
                }
                guard matches.count == 1, let token = matches.first else { return nil }
                var selected: (Holding, WalletSnapshot)?
                session.tokenSelection.select(token, walletID: current.wallet.id, snapshot: current, add: { token, walletID in
                    try await session.addToken(token, walletID: walletID)
                }, onSelected: { holding, updated in selected = (holding, updated) })
                return selected
            }
        }
        .onChange(of: model.path) { _, path in
            if path.last != .review { bitcoin.cancel(); sui.cancel(); xrpl.cancel(); stellar.cancel(); tron.cancel(); near.cancel(); polkadot.cancel(); solana.cancel(); aptos.cancel(); thorchain.cancel(); arc.cancel(); evm.cancel(); ton.cancel() }
        }
        .onChange(of: allowed) { _, allowed in
            if !allowed { scannedAssetSearch.reset(); bitcoin.cancel(); sui.cancel(); xrpl.cancel(); stellar.cancel(); tron.cancel(); near.cancel(); polkadot.cancel(); solana.cancel(); aptos.cancel(); thorchain.cancel(); arc.cancel(); evm.cancel(); ton.cancel() }
        }
        .onDisappear { scannedAssetSearch.reset(); bitcoin.cancel(); sui.cancel(); xrpl.cancel(); stellar.cancel(); tron.cancel(); near.cancel(); polkadot.cancel(); solana.cancel(); aptos.cancel(); thorchain.cancel(); arc.cancel(); evm.cancel(); ton.cancel() }
        .accessibilityIdentifier("send.flow")
    }

    private var assetPicker: some View {
        // Capture one list for this update. Lazy row creation must not ask the
        // model to filter the full portfolio again as each row scrolls in.
        let available = model.holdings
        let holdings = scannedRecipient?.prioritized(available, network: { $0.networkID }, reference: { $0.reference }, symbol: { $0.symbol }) ?? available
        let firstID = holdings.first?.id
        let searchRequest = tokenSearchRequest
        return OathEmptyStateScrollView(centersContent: (holdings.isEmpty && !searchRequest.hasQuery) || model.failed) {
            VStack(spacing: 0) {
                if model.loading && model.snapshot == nil {
                    ProgressView().frame(maxWidth: .infinity).padding(36)
                } else if model.failed {
                    OathEmptyState(title: strings.text(.sendLoadFailed), systemImage: "exclamationmark.circle", isError: true) {
                        OathActionButton(title: strings.text(.tryAgain), appearance: .secondary) { retry = UUID() }
                    }.padding(20)
                } else if holdings.isEmpty && !searchRequest.hasQuery {
                    OathEmptyState(strings.text(.sendNoAssets), systemImage: "magnifyingglass")
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(holdings) { holding in
                            OathButton(feedback: nil) { model.choose(holding, scannedRecipient: scannedRecipient) } label: {
                                OathAssetSelectionRow(holding: holding, currency: model.currency, showsSeparator: holding.id != firstID)
                            }.buttonStyle(OathSettingsRowButtonStyle())
                                .accessibilityIdentifier("send.asset.\(holding.id)")
                        }
                    }
                }
                if searchRequest.hasQuery && model.snapshot != nil && !model.failed {
                    OathTokenPickerSearch(request: searchRequest, session: session, hasSavedMatches: !holdings.isEmpty) { holding, snapshot in
                        model.choose(holding, from: snapshot, scannedRecipient: scannedRecipient)
                    }
                }
            }.frame(maxWidth: 600).frame(maxWidth: .infinity)
        }
        .searchable(text: $model.query, placement: .navigationBarDrawer(displayMode: .always), prompt: strings.text(.searchAssets))
        .scrollDismissesKeyboard(.interactively)
    }

}

struct OathSendLogo: View {
    let holding: Holding
    var size: CGFloat = 48
    var showsChainBadge = true
    var body: some View {
        OathBadgedAssetLogo(networkID: holding.networkID, isNative: holding.reference == "native",
            source: holding.logo, symbol: holding.symbol, identity: holding.artworkIdentity, size: size,
            showsChainBadge: showsChainBadge)
    }
}
