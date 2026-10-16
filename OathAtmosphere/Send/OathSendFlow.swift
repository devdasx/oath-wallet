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
    @State private var near = OathNearSendModel()
    @State private var tron = OathTronSendModel()
    @State private var retry = UUID()
    private let scannedRecipient: OathScannedRecipient?

    init(session: OathWalletSession, walletID: String? = nil, holdingID: String? = nil,
         scannedRecipient: OathScannedRecipient? = nil) {
        self.session = session
        self.scannedRecipient = scannedRecipient
        _model = State(initialValue: OathSendModel(walletID: walletID ?? session.displayedProfile?.id.uuidString ?? "",
                                                 holdingID: holdingID))
    }

    private var allowed: Bool { session.isUnlocked && !session.resetting && session.wallets.contains { $0.id == model.walletID } }
    private var observationID: String { "\(allowed)-\(model.walletID)-\(session.portfolio?.currency ?? "USD")-\(retry)" }

    var body: some View {
        NavigationStack(path: $model.path) {
            assetPicker
                .navigationTitle(strings.text(.sendChooseAsset))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarLeading) { OathCloseButton { dismiss() } } }
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
                                    return true
                                }
                                    .navigationTitle(strings.text(.sendAmount))
                            case .review:
                                OathSendReviewPage(model: model, session: session, bitcoin: bitcoin, sui: sui, xrpl: xrpl, stellar: stellar, tron: tron, ton: ton, solana: solana, aptos: aptos, thorchain: thorchain, evm: evm, arc: arc, near: near, onClose: { dismiss() })
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
        .onChange(of: model.path) { _, path in
            if path.last != .review { bitcoin.cancel(); sui.cancel(); xrpl.cancel(); stellar.cancel(); tron.cancel(); near.cancel(); solana.cancel(); aptos.cancel(); thorchain.cancel(); arc.cancel(); evm.cancel(); ton.cancel() }
        }
        .onChange(of: allowed) { _, allowed in
            if !allowed { bitcoin.cancel(); sui.cancel(); xrpl.cancel(); stellar.cancel(); tron.cancel(); near.cancel(); solana.cancel(); aptos.cancel(); thorchain.cancel(); arc.cancel(); evm.cancel(); ton.cancel() }
        }
        .onDisappear { bitcoin.cancel(); sui.cancel(); xrpl.cancel(); stellar.cancel(); tron.cancel(); near.cancel(); solana.cancel(); aptos.cancel(); thorchain.cancel(); arc.cancel(); evm.cancel(); ton.cancel() }
        .accessibilityIdentifier("send.flow")
    }

    private var assetPicker: some View {
        // Capture one list for this update. Lazy row creation must not ask the
        // model to filter the full portfolio again as each row scrolls in.
        let holdings = model.holdings.filter { holding in
            scannedRecipient?.matchesAsset(networkID: holding.networkID, reference: holding.reference) ?? true
        }
        let lastID = holdings.last?.id
        return OathEmptyStateScrollView(centersContent: holdings.isEmpty || model.failed) {
            VStack(spacing: 0) {
                if model.loading && model.snapshot == nil {
                    ProgressView().frame(maxWidth: .infinity).padding(36)
                } else if model.failed {
                    OathEmptyState(title: strings.text(.sendLoadFailed), systemImage: "exclamationmark.circle", isError: true) {
                        OathActionButton(title: strings.text(.tryAgain), appearance: .secondary) { retry = UUID() }
                    }.padding(20)
                } else if holdings.isEmpty {
                    OathEmptyState(strings.text(.sendNoAssets), systemImage: "magnifyingglass")
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(holdings) { holding in
                            OathButton(feedback: .navigate) { model.choose(holding, scannedRecipient: scannedRecipient) } label: {
                                OathAssetSelectionRow(holding: holding, currency: model.currency, showsNetwork: scannedRecipient != nil)
                            }.buttonStyle(OathSettingsRowButtonStyle())
                                .accessibilityIdentifier("send.asset.\(holding.id)")
                            if holding.id != lastID {
                                OathHairline().padding(.leading, 74).padding(.trailing, 20)
                            }
                        }
                    }
                }
            }.frame(maxWidth: 600).frame(maxWidth: .infinity)
        }
        .searchable(text: $model.query, placement: .navigationBarDrawer(displayMode: .always), prompt: strings.text(.searchAssets))
        .scrollDismissesKeyboard(.interactively)
    }

}

/// Keep progress inside the native toolbar's neutral glass. The navigation bar
/// owns its background and sizing; only the ready action uses prominent blue.
struct OathSendToolbarAction: ToolbarContent {
    var title: OathStringKey = .continueAction
    var icon: String? = nil
    var progressLabel: OathStringKey = .sendPreparing
    let isEnabled: Bool
    let isWorking: Bool
    let identifier: String
    let action: () -> Void
    @Environment(\.oathLocalizer) private var strings

    var body: some ToolbarContent {
        if #available(iOS 26.0, *) {
            item.sharedBackgroundVisibility(isWorking ? .visible : .automatic)
        } else {
            item
        }
    }

    private var item: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            if isWorking {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.regular)
                    .tint(.secondary)
                    .accessibilityLabel(strings.text(progressLabel))
                    .accessibilityIdentifier(identifier)
            } else {
                readyButton
            }
        }
    }

    @ViewBuilder private var readyButton: some View {
        let button = OathButton {
            guard isEnabled, !isWorking else { return }
            action()
        } label: {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon).accessibilityHidden(true) }
                Text(strings.text(title))
                    .oathFont(.body, weight: .semibold)
            }
        }
            .tint(isEnabled ? OathOnboardingColors.blue : Color(uiColor: .systemGray3))
            .foregroundStyle(isEnabled ? Color.white : Color(uiColor: .secondaryLabel))
            .disabled(!isEnabled)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(strings.text(title))
            .accessibilityIdentifier(identifier)
        if #available(iOS 26.0, *) {
            button.buttonStyle(.glassProminent)
        } else {
            button.buttonStyle(.borderedProminent)
        }
    }
}

struct OathSendLogo: View {
    let holding: Holding
    var size: CGFloat = 48
    var body: some View {
        Group {
            if holding.reference == "native", let chain = OathImportChain(rawValue: holding.networkID) {
                OathNetworkLogo(asset: chain.logoAsset, size: size)
            } else {
                OathTokenLogo(source: holding.logo, symbol: holding.symbol, size: size, identity: holding.artworkIdentity)
                    .overlay(alignment: .bottomTrailing) {
                        if let chain = OathImportChain(rawValue: holding.networkID) {
                            OathNetworkLogo(asset: chain.logoAsset, size: size * 0.34)
                                .padding(2).background(Color(uiColor: OathSurfaceColors.canvas), in: Circle())
                                .offset(x: 2, y: 2)
                        }
                    }
            }
        }.accessibilityHidden(true)
    }
}

