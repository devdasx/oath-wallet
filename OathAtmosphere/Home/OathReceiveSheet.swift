import OathDiagnostics
import SwiftUI
import OathDatabase
import OathBitcoin
import OathAnkr
import OathTokenImages

/// Home needs an address choice before receiving. Asset details already know
/// the address and enter the same flow directly. Address variants live in the bar.
struct OathReceivePicker: View {
    let addresses: [OathWalletAddress]
    let session: OathWalletSession
    var body: some View { OathReceiveFlow(addresses: addresses, initialAddress: nil, session: session) }
}

struct OathReceiveSheet: View {
    let address: OathWalletAddress
    let session: OathWalletSession
    var holding: Holding? = nil
    var allowsAddressChoice = true
    var body: some View { OathReceiveFlow(addresses: [address], initialAddress: address, session: session, initialHolding: holding, allowsAddressChoice: allowsAddressChoice) }
}

private struct OathReceiveFlow: View {
    let addresses: [OathWalletAddress]
    let session: OathWalletSession
    private let startsWithAddress: Bool
    private let allowsAddressChoice: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.oathLocalizer) private var strings
    @Environment(\.scenePhase) private var scenePhase
    @State private var selected: OathWalletAddress?
    private enum Step: Hashable { case receive, types, about }
    @State private var path: [Step] = []
    @State private var query = ""
    @State private var selectedHolding: Holding?
    @State private var selectionID = UUID()
    @State private var qr: CGImage?
    @State private var qrAddress: String?
    @State private var receivePayload: String?
    @State private var qrFailed = false
    private struct ReceiveIdentity: Hashable {
        let accountID: String
        let assetID: String
        let chain: OathImportChain
        let address: String
    }
    private struct QRRequest: Hashable {
        let selectionID: UUID
        let retry: Int
        let accountID: String?
        let address: String?
    }
    @State private var recorded = Set<ReceiveIdentity>()
    @State private var storageFailed = false
    @State private var bitcoin: BitcoinAccountState?
    @State private var solana: SolanaReceiveState?
    @State private var changingType = false
    @State private var retryReceive = 0
    @State private var typeChange: Task<Void, Never>?
    private struct ActivationRequest: Hashable {
        let walletID: UUID
        let chain: OathImportChain
        let address: String
    }
    @State private var activationChecker: ReceiveActivationCheck?
    @State private var checkedActivationRequest: ActivationRequest?
    @State private var activationRequirement: ReceiveActivationRequirement?

    private var activationRequest: ActivationRequest? {
        guard allowed, scenePhase == .active, !preparingAddress,
              path.last == .receive || (startsWithAddress && path.isEmpty),
              let selected, let walletID = session.displayedProfile?.id,
              ReceiveActivationCheck.networks.contains(selected.chain.id) else { return nil }
        return .init(walletID: walletID, chain: selected.chain, address: selected.address)
    }

    init(addresses: [OathWalletAddress], initialAddress: OathWalletAddress?, session: OathWalletSession,
         initialHolding: Holding? = nil, allowsAddressChoice: Bool = true) {
        self.addresses = addresses
        self.session = session
        self.allowsAddressChoice = allowsAddressChoice
        let initialAddress = initialAddress ?? OathReceiveAsset.directAddress(in: addresses)
        startsWithAddress = initialAddress != nil
        _selected = State(initialValue: initialAddress)
        _selectedHolding = State(initialValue: initialHolding ?? session.portfolio?.holdings.first {
            $0.accountID == initialAddress?.accountID && $0.assetID == initialAddress?.assetID
        })
    }

    private var receiving: Bool { startsWithAddress || path.contains(.receive) }
    private var currentHolding: Holding? {
        session.portfolio?.holdings.first { $0.accountID == selected?.accountID && $0.assetID == selected?.assetID }
            ?? selectedHolding
    }
    private var receiveTitle: String {
        guard let selected else { return strings.text(.receive) }
        return strings.format(.receiveAssetTitle, strings.invariant(currentHolding?.name ?? selected.networkName))
    }

    private var showsAddressChoice: Bool {
        guard allowsAddressChoice else { return false }
        if let bitcoin { return bitcoin.descriptor.types.count > 1 }
        if let solana { return solana.addresses.count > 1 }
        return selected?.chain == .bitcoin || selected?.chain == .litecoin
            || (selected?.chain == .solana && selected?.path != "imported")
    }

    private var addressChoiceTitle: String {
        if let solana { return solanaTitle(solana.selected) }
        if let bitcoin { return bitcoin.preferredType.localizedTitle(using: strings) }
        return strings.text(selected?.chain == .solana ? .solanaPreparing : .bitcoinPreparing)
    }
    private var allowed: Bool { session.isUnlocked && !session.changingWallet && !session.resetting }
    private var tokenSearchRequest: OathTokenSearchRequest {
        .init(query: query, walletID: session.displayedProfile?.id.uuidString,
              active: allowed && !receiving && path.isEmpty, snapshot: session.portfolio,
              permittedNetworks: Set(addresses.map(\.chain)))
    }
    private var readyIdentity: ReceiveIdentity? {
        guard allowed, receiving, !preparingAddress, currentHolding?.isCatalogPreview != true, let selected,
              let accountID = selected.accountID, let assetID = selected.assetID else { return nil }
        return ReceiveIdentity(accountID: accountID, assetID: assetID, chain: selected.chain, address: selected.address)
    }

    private var preparingAddress: Bool {
        guard let selected else { return false }
        return (UTXONetwork(rawValue: selected.chain.id) != nil && bitcoin == nil)
            || (selected.chain == .solana && solana == nil)
    }

    private var qrRequest: QRRequest {
        QRRequest(selectionID: selectionID, retry: retryReceive,
                  accountID: allowed && receiving ? selected?.accountID : nil,
                  address: allowed && receiving ? selected?.address : nil)
    }

    private func solanaTitle(_ address: SolanaReceiveAddress) -> String {
        address.derivation?.title ?? strings.text(.solanaOriginalAddress)
    }

    private func examples(for address: OathWalletAddress) -> [OathReceiveExample] {
        let chain = address.chain
        let order = PortfolioAssetOrder(session.portfolio?.holdings ?? [])
        return AssetOrdering.sorted(OathReceiveExampleCatalog.bundled.examples(for: chain)) { example in
            let reference = String(example.id.dropFirst(chain.id.count + 1))
            return order.key(networkID: chain.id, reference: chain.isEVM ? reference.lowercased() : reference,
                             accountID: address.accountID, name: example.name)
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if startsWithAddress { receivePage }
                else { assetPicker }
            }
            .navigationTitle(startsWithAddress ? receiveTitle : strings.text(.receive))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if path.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        OathButton(feedback: .dismiss, action: { dismiss() }) {
                            Label(strings.text(startsWithAddress ? .close : .back),
                                  systemImage: startsWithAddress ? "xmark" : "chevron.backward")
                        }
                        .labelStyle(.iconOnly).oathNeutralControl()
                        .accessibilityIdentifier(startsWithAddress ? "receive.close" : "receive.back")
                    }
                }
            }
            .oathNativeLocalization()
            .background(Color(uiColor: OathSurfaceColors.canvas))
            .navigationDestination(for: Step.self) { step in
                Group {
                    switch step {
                    case .receive: receivePage
                    case .types: addressTypesPage
                    case .about:
                        if let selected {
                            ScrollView {
                                OathReceiveExplanation(chain: selected.chain, examples: examples(for: selected))
                            }
                        }
                    }
                }
                .navigationTitle(step == .receive ? receiveTitle : strings.text(step == .types
                    ? (selected?.chain == .solana ? .solanaReceivePath : .bitcoinAddressType)
                    : .receiveAboutTitle))
                .navigationBarTitleDisplayMode(.inline)
                .oathNativeLocalization()
                .background(Color(uiColor: OathSurfaceColors.canvas))
            }
        }
        .oathLanguage(strings.language)
        .oathInteractionBlocked(!allowed)
        // One opaque, large sheet for the complete flow. Only the navigation
        // stack changes; QR, path selection and guidance never resize the sheet.
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color(uiColor: OathSurfaceColors.canvas))
        .task(id: activationRequest) {
            let request = activationRequest
            activationRequirement = nil
            checkedActivationRequest = nil
            guard let request else { return }
            if activationChecker == nil {
                activationChecker = await Task.detached(priority: .utility) {
                    OathDiagnostics.attempt("receive_activation_configuration") {
                        try OathTokenRPCConfiguration.bundled().makeReceiveActivationCheck()
                    }
                }.value
            }
            guard let checker = activationChecker else { return }
            while !Task.isCancelled, activationRequest == request {
                let status = await checker.check(network: request.chain.id, address: request.address)
                guard !Task.isCancelled, activationRequest == request else { return }
                checkedActivationRequest = request
                if case .inactive(let requirement) = status { activationRequirement = requirement }
                else { activationRequirement = nil }
                // Refresh an unfunded account while this screen is visible so
                // an incoming activation removes the notice without reopening.
                // Never poll active accounts, block QR work, or show check progress.
                if status == .active { return }
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            }
        }
        .task(id: qrRequest) {
            let request = qrRequest
            guard allowed, receiving, let selected else { return }
            qrFailed = false
            let completed = await perform("prepare_receive", chain: selected.chain) {
                guard let id = request.accountID else { throw StoreError.missingRecord }
                if selected.chain == .solana {
                    try await loadSolanaAddress(accountID: id)
                } else if UTXONetwork(rawValue: selected.chain.id) != nil {
                    try await loadBitcoinAddress(accountID: id)
                }
                try Task.checkCancellation()
                guard qrRequest == request else { return }
                try await loadQRCode()
            }
            if !completed, !Task.isCancelled, qrRequest == request { qrFailed = true }
        }
        // A blocked first-time legacy preparation must offer recovery rather
        // than an endless spinner. This timer never waits for the vault task.
        .task(id: qrRequest) {
            let request = qrRequest
            guard allowed, receiving else { return }
            do { try await Task.sleep(for: .seconds(8)) }
            catch is CancellationError { return }
            catch { OathDiagnostics.record(error, component: "receive", operation: "preparation_timer"); return }
            guard !Task.isCancelled, qrRequest == request, !qrFailed,
                  qr == nil || qrAddress != selected?.address else { return }
            qrFailed = true
            storageFailed = true
            OathDiagnostics.$operationID.withValue(UUID()) {
                OathDiagnostics.record(DiagnosticFailure("receive_preparation_timeout"), component: "receive",
                    operation: "prepare_receive", context: ["chain": selected?.chain.id ?? "unknown"])
            }
        }
        .task(id: readyIdentity) {
            guard let identity = readyIdentity, !recorded.contains(identity) else { return }
            await perform("save_receive", chain: identity.chain) {
                let database = try await session.vault.database()
                try Task.checkCancellation()
                try await database.saveReceive(ReceiveRecord(id: UUID().uuidString, accountID: identity.accountID,
                    networkID: identity.chain.id, assetID: identity.assetID, address: identity.address,
                    state: "open", createdAt: Date.now.timeIntervalSince1970))
                recorded.insert(identity)
            }
        }
        .oathHapticFeedback(.error, trigger: storageFailed, when: storageFailed)
        .alert(strings.text(.walletUnavailable), isPresented: $storageFailed) {
            if preparingAddress || qr == nil || qrAddress != selected?.address || qrFailed {
                OathButton(strings.text(.tryAgain), action: retryQRCode)
            }
            if #available(iOS 26.0, *) {
                OathButton(role: .confirm) {}
                    .accessibilityLabel(strings.text(.done))
                    .accessibilityIdentifier("confirmation.done")
                    .oathConfirmationControl()
            } else {
                OathButton(strings.text(.done)) {}
                    .accessibilityIdentifier("confirmation.done")
                    .oathConfirmationControl()
            }
        }
        .onDisappear { typeChange?.cancel() }
        .onChange(of: session.isUnlocked) { _, unlocked in
            if !unlocked { typeChange?.cancel() }
        }
        .onChange(of: path) { _, value in
            if value.last != .types { typeChange?.cancel() }
        }
    }

    private var assetPicker: some View {
        let assets = OathReceiveAsset.available(holdings: session.portfolio?.holdings ?? [],
                                               addresses: addresses, query: query)
        let firstID = assets.first?.id
        let searchRequest = tokenSearchRequest
        return OathEmptyStateScrollView(centersContent: assets.isEmpty && !searchRequest.hasQuery) {
            VStack(spacing: 0) {
                if session.portfolio == nil {
                    ProgressView().frame(maxWidth: .infinity).padding(36)
                } else if assets.isEmpty && !searchRequest.hasQuery {
                    OathEmptyState(strings.text(.sendNoAssets), systemImage: "magnifyingglass")
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(assets) { asset in
                            OathButton(feedback: nil) {
                                choose(asset)
                            } label: {
                                OathAssetSelectionRow(holding: asset.holding, currency: session.portfolio?.currency ?? "USD",
                                    showsSeparator: asset.id != firstID)
                            }
                            .buttonStyle(OathSettingsRowButtonStyle())
                            .accessibilityIdentifier("receive.asset.\(asset.id)")
                        }
                    }
                }
                if searchRequest.hasQuery && session.portfolio != nil {
                    OathTokenPickerSearch(request: searchRequest, session: session, hasSavedMatches: !assets.isEmpty) { holding, _ in
                        if let asset = OathReceiveAsset.available(holdings: [holding], addresses: addresses, query: "").first {
                            choose(asset)
                        }
                    }
                }
            }.frame(maxWidth: 600).frame(maxWidth: .infinity)
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: strings.text(.searchAssets))
        .scrollDismissesKeyboard(.interactively)
    }

    private func choose(_ asset: OathReceiveAsset) {
        guard allowed else { return }
        typeChange?.cancel()
        selectionID = UUID()
        qr = nil; qrAddress = nil; receivePayload = nil; qrFailed = false; bitcoin = nil; solana = nil
        selectedHolding = asset.holding
        selected = asset.address
        path.append(.receive)
    }

    private var receivePage: some View {
        Group {
            if let selected {
                OathReceiveContent(address: selected, holding: currentHolding, examples: examples(for: selected),
                    qr: qrAddress == selected.address ? qr : nil,
                    payload: qrAddress == selected.address ? receivePayload : nil,
                    preparingAddress: preparingAddress, qrFailed: qrFailed,
                    activation: checkedActivationRequest == activationRequest ? activationRequirement : nil,
                    onRetry: retryQRCode) { showExplanation(true) }
            }
        }
        .toolbar {
            if showsAddressChoice && (path.last == .receive || (startsWithAddress && path.isEmpty)) {
                ToolbarItem(placement: .topBarTrailing) {
                    OathButton(feedback: .navigate, action: { path.append(.types) }) {
                        Label(strings.text(selected?.chain == .solana ? .solanaReceivePath : .bitcoinAddressType),
                              systemImage: "slider.horizontal.3")
                    }
                    .labelStyle(.iconOnly).oathNeutralControl()
                    .disabled(preparingAddress || changingType)
                    .accessibilityValue(addressChoiceTitle)
                    .accessibilityIdentifier(selected?.chain == .solana
                        ? "receive.solana.addressPath" : "receive.bitcoin.addressType")
                }
            }
        }
    }

    private var addressTypesPage: some View {
        ScrollView {
            VStack(spacing: 0) {
                if let solana {
                    ForEach(solana.addresses) { address in
                        OathButton { changeSolanaPath(address.path) } label: {
                            OathSettingsRow(title: solanaTitle(address),
                                accessory: .selection(address == solana.selected),
                                subtitle: strings.invariant(address.path))
                        }
                        .buttonStyle(OathSettingsRowButtonStyle())
                        .disabled(changingType)
                        .accessibilityIdentifier("receive.solana.path.\(address.derivation?.rawValue ?? "original")")
                        .accessibilityAddTraits(address == solana.selected ? .isSelected : [])
                    }
                    Text(strings.text(.solanaReceivePathDetail))
                        .oathFont(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).padding(20)
                } else if let bitcoin {
                    ForEach(bitcoin.descriptor.types) { type in
                        OathButton { changeBitcoinType(type) } label: {
                            OathSettingsRow(title: type.localizedTitle(using: strings),
                                accessory: .selection(type == bitcoin.preferredType))
                        }
                        .buttonStyle(OathSettingsRowButtonStyle())
                        .disabled(changingType)
                        .accessibilityIdentifier("receive.bitcoin.type.\(type.rawValue)")
                    }
                    Text(strings.text(bitcoin.descriptor.scopedImport ? .bitcoinScopedKey
                        : bitcoin.descriptor.branches.allSatisfy({ !$0.isHD }) ? .bitcoinSingleKey : .bitcoinAllTypes))
                        .oathFont(.footnote).foregroundStyle(.secondary).padding(20)
                }
            }.padding(.vertical, 12)
                .frame(maxWidth: 600).frame(maxWidth: .infinity)
        }
    }

    private func showExplanation(_ value: Bool) {
        if value { path.append(.about) }
        else if path.last == .about { path.removeLast() }
    }

    private func changeBitcoinType(_ type: BitcoinAddressType) {
        guard allowed, let selected, let id = selected.accountID, !changingType else { return }
        changingType = true
        typeChange?.cancel()
        typeChange = Task {
            defer { changingType = false }
            if await perform("change_address_type", chain: selected.chain, body: {
                try await loadBitcoinAddress(accountID: id, type: type)
            }), path.last == .types { path.removeLast() }
        }
    }

    private func changeSolanaPath(_ receivePath: String) {
        guard allowed, let id = selected?.accountID, !changingType else { return }
        changingType = true
        typeChange?.cancel()
        typeChange = Task {
            defer { changingType = false }
            if await perform("change_receive_path", chain: .solana, body: {
                try await loadSolanaAddress(accountID: id, path: receivePath)
            }) {
                if path.last == .types { path.removeLast() }
                session.solanaReceivePathChanged()
            }
        }
    }

    @discardableResult
    private func perform(_ operation: String, chain: OathImportChain,
                         body: () async throws -> Void) async -> Bool {
        await OathDiagnostics.$chain.withValue(chain.id) {
            await OathDiagnostics.$operationID.withValue(UUID()) {
                do { try await body(); return true }
                catch is CancellationError { return false }
                catch {
                    OathDiagnostics.record(error, component: "receive", operation: operation)
                    if !Task.isCancelled, allowed { storageFailed = true }
                    return false
                }
            }
        }
    }

    private func retryQRCode() {
        qrFailed = false
        storageFailed = false
        retryReceive += 1
    }

    private func loadQRCode() async throws {
        guard allowed, receiving, !preparingAddress, let selected,
              let id = selected.accountID else { throw StoreError.missingRecord }
        let selection = selectionID
        let value = selected.address
        let db = try await session.vault.database()
        let presentation = try await db.receivePresentation(accountID: id, address: value)
        try Task.checkCancellation()
        guard allowed, receiving, selectionID == selection, self.selected?.accountID == id,
              self.selected?.address == value else { return }
        qr = presentation.image; receivePayload = presentation.address; qrAddress = value; qrFailed = false
    }

    private func loadSolanaAddress(accountID: String, path: String? = nil) async throws {
        guard allowed, let walletID = session.displayedProfile?.id.uuidString else { throw CancellationError() }
        let selection = selectionID
        let db = try await session.vault.database()
        let state = try await OathReceivePreparation.solana(database: db, accountID: accountID,
            walletID: walletID, path: path) { [vault = session.vault] in
                try await vault.solanaReceiveState(accountID: accountID)
            }
        try Task.checkCancellation()
        guard let current = selected, current.accountID == accountID, selectionID == selection,
              session.displayedProfile?.id.uuidString == walletID, allowed, receiving else { return }
        solana = state
        selected = .init(chain: current.chain, address: state.selected.address, path: state.selected.path,
            accountIndex: current.accountIndex, accountID: accountID, assetID: current.assetID,
            storedNetworkName: current.storedNetworkName, storedTicker: current.storedTicker, storedLogo: current.storedLogo)
    }

    private func loadBitcoinAddress(accountID: String, type: BitcoinAddressType? = nil) async throws {
        guard allowed, let walletID = session.displayedProfile?.id.uuidString,
              let network = selected.flatMap({ UTXONetwork(rawValue: $0.chain.id) }) else { throw CancellationError() }
        let selection = selectionID
        let db = try await session.vault.database()
        let (address, state) = try await OathReceivePreparation.bitcoin(database: db, accountID: accountID,
            walletID: walletID, network: network, type: type) { [vault = session.vault] in
                try await vault.prepareBitcoin(accountID: accountID)
            }
        try Task.checkCancellation()
        guard selected?.accountID == accountID, selectionID == selection,
              session.displayedProfile?.id.uuidString == walletID, allowed, receiving else { return }
        bitcoin = state
        guard let chain = selected?.chain else { return }
        selected = .init(chain: chain, address: address.address, path: address.path,
                         accountIndex: selected?.accountIndex ?? 0, accountID: accountID, assetID: chain.id + ":native")
    }
}

private struct OathReceiveContent: View {
    let address: OathWalletAddress
    let holding: Holding?
    let examples: [OathReceiveExample]
    let qr: CGImage?
    let payload: String?
    let preparingAddress: Bool
    let qrFailed: Bool
    let activation: ReceiveActivationRequirement?
    let onRetry: () -> Void
    let onExplain: () -> Void
    @Environment(\.oathLocalizer) private var strings
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var copied = false
    @State private var showingShare = false
    @State private var pendingShare: OathReceiveShareItem?
    @State private var shareItem: OathReceiveShareItem?
    private var guide: OathReceiveNetworkGuide { .init(chain: address.chain) }
    private var isNativeAsset: Bool { (holding?.reference ?? "native") == "native" }
    private var noticeSymbol: String { isNativeAsset ? address.chain.ticker : (holding?.symbol ?? address.ticker) }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    ZStack {
                        Color.white
                        if let qr, !preparingAddress {
                            Image(decorative: qr, scale: 1).interpolation(.none).resizable().scaledToFit()
                                .overlay {
                                    GeometryReader { geometry in
                                        let badgeSide = geometry.size.width * OathReceiveQRCode.badgeFraction
                                        ZStack {
                                            // Also covers the circular cutout in older cached QR images.
                                            RoundedRectangle(cornerRadius: badgeSide * TokenArtworkStyle.cornerRadiusFraction,
                                                             style: .continuous)
                                                .fill(.white)
                                                .frame(width: badgeSide, height: badgeSide)
                                            receiveLogo(size: geometry.size.width * OathReceiveQRCode.logoFraction)
                                        }
                                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                                            .accessibilityHidden(true)
                                    }
                                }
                        } else if qrFailed {
                            OathButton(strings.text(.tryAgain), action: onRetry)
                                .oathFont(.body, weight: .semibold)
                                .foregroundStyle(.black)
                                .accessibilityIdentifier("receive.qr.retry")
                        } else { ProgressView().tint(.black) }
                    }
                    // Use the available width on smaller sheets; keep the encoded quiet
                    // zone and center-logo proportions intact at every display size.
                    .aspectRatio(1, contentMode: .fit)
                    .frame(width: min(360, geometry.size.width * 0.86) * 1.05)
                    .clipShape(.rect(cornerRadius: 16))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(strings.text(.receiveQRCode))
                    .accessibilityIdentifier("receive.qr")

                    receiveAddress
                        .padding(.horizontal, 24)
                        .padding(.bottom, 16)

                    OathReceiveNetworkNotice(key: isNativeAsset ? guide.notice : .receiveSelectedTokenNotice,
                        symbol: noticeSymbol, chain: address.chain)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 24)
                        .accessibilityIdentifier("receive.networkNotice")

                    if isNativeAsset && guide.supportsTokens {
                        OathReceiveExamplesButton(examples: examples, action: onExplain)
                            .padding(.top, 4)
                    }

                    // At accessibility sizes the actions scroll with the page
                    // so they cannot consume the QR and address viewport.
                    if typeSize.isAccessibilitySize { receiveActions.padding() }
                }
                .padding(.top, 4).padding(.bottom, 20)
                .frame(maxWidth: 600).frame(maxWidth: .infinity)
            }
        }
        .oathBottomActions(isPresented: !typeSize.isAccessibilitySize, maximumWidth: 600) {
            receiveActions
        }
        .onChange(of: payload) { _, _ in
            copied = false
            pendingShare = nil
            showingShare = false
            shareItem = nil
        }
        .sheet(isPresented: $showingShare, onDismiss: {
            // Present the activity controller only after the options sheet has
            // finished dismissing, using the exact selected address/image.
            shareItem = pendingShare
            pendingShare = nil
        }) {
            OathReceiveShareOptions { format in
                guard showingShare, !preparingAddress, let payload, let qr else { return }
                switch format {
                case .qrCode: pendingShare = OathReceiveShareItem(items: [UIImage(cgImage: qr)])
                case .address: pendingShare = OathReceiveShareItem(items: [payload])
                case .link:
                    guard let link = OathWalletLink.paymentURL(address: payload, chain: address.chain) else {
                        OathDiagnostics.record(OathScanProblem.invalidAddress, component: "receive", operation: "share_payment_link",
                                               context: ["chain": address.chain.rawValue])
                        return
                    }
                    pendingShare = OathReceiveShareItem(items: [link])
                }
                showingShare = false
            }
            .oathLanguage(strings.language)
        }
        .sheet(item: $shareItem) { item in
            OathShareSheet(items: item.items)
        }
        .task(id: copied) {
            guard copied else { return }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            copied = false
        }
    }

    @ViewBuilder private func receiveLogo(size: CGFloat) -> some View {
        if let holding, holding.reference != "native" {
            OathTokenLogo(source: holding.logo, symbol: holding.symbol, size: size, identity: holding.artworkIdentity)
        } else {
            OathNetworkLogo(asset: address.chain.logoAsset, size: size)
        }
    }

    @ViewBuilder private var receiveAddress: some View {
        if preparingAddress || payload == nil {
            ProgressView().frame(maxWidth: .infinity)
        } else {
            OathAddressText(address: payload ?? "", emphasizesEnds: true)
                .environment(\.layoutDirection, .leftToRight)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var receiveActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !preparingAddress, let activation {
                Label {
                    Text(activationNotice(activation))
                        .oathFont(.footnote)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.10), in: .rect(cornerRadius: 18))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("receive.activationWarning")
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: OathActionMetrics.spacing) { copy; share }
                VStack(spacing: OathActionMetrics.spacing) { copy; share }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.extraLarge)
            .buttonBorderShape(.capsule)
            .tint(Color(uiColor: OathSurfaceColors.field))
            .foregroundStyle(Color.primary.opacity(0.8))
            .oathFont(.body, weight: .semibold)
            .padding(.top, 12)
            .disabled(preparingAddress || qr == nil)
        }
    }

    private func activationNotice(_ requirement: ReceiveActivationRequirement) -> AttributedString {
        var notice = AttributedString(requirement.notice(strings: strings) + " ")
        var learnMore = AttributedString(strings.text(.accountLearnMore))
        learnMore.link = OathSupportLinks.accountActivation
        learnMore.foregroundColor = OathOnboardingColors.blue
        learnMore.underlineStyle = .single
        notice.append(learnMore)
        // Native inline links use the shared in-app browser and its diagnostics.
        // No wallet address or account identifier is included in the URL.
        return notice
    }

    private var copy: some View {
        OathButton {
            guard let payload else { return }
            OathClipboard.copy(payload)
            copied = true
        } label: {
            OathActionLabel(title: strings.text(copied ? .addressCopied : .copyAddress))
        }
        .accessibilityIdentifier("receive.copy")
    }

    private var share: some View {
        OathButton(feedback: .share, action: {
            guard !preparingAddress, payload != nil, qr != nil else { return }
            pendingShare = nil
            showingShare = true
        }) {
            OathActionLabel(title: strings.text(.receiveShare), icon: "square.and.arrow.up")
        }
        .accessibilityLabel(strings.text(.receiveShare))
        .accessibilityIdentifier("receive.share")
    }
}

/// Keep one naturally wrapping, localized sentence. Markers style the actual
/// format arguments without assuming English word order or matching substrings
/// in token names. VoiceOver reads the sentence once, without the decorative logo.
struct OathReceiveNetworkNotice: View {
    let key: OathStringKey
    let symbol: String
    let chain: OathImportChain
    var isError = false
    var inlineLink: AttributedString? = nil
    @Environment(\.oathLocalizer) private var strings
    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .footnote) private var badgeSize: CGFloat = 14
    @ScaledMetric(relativeTo: .footnote) private var badgeBaseline: CGFloat = -2
    @State private var badge: UIImage?

    private struct BadgeRequest: Equatable {
        let asset: String
        let size: CGFloat
        let scale: CGFloat
        let scheme: ColorScheme
    }
    private var badgeRequest: BadgeRequest {
        .init(asset: chain.logoAsset, size: badgeSize, scale: displayScale, scheme: colorScheme)
    }

    private func emphasized(_ value: String) -> Text {
        let text = Text(strings.invariant(value)).foregroundColor(isError ? .red : .primary)
        return strings.language == .arabic
            ? text.font(.custom(OathArabicFont.bold.rawValue, size: 13, relativeTo: .footnote))
            : text.bold()
    }

    private var notice: Text {
        let symbolMarker = "{oath-receive-symbol}"
        let chainMarker = "{oath-receive-chain}"
        let template = strings.format(key, symbolMarker, chainMarker)
        let chainText: Text
        if let badge {
            let icon = Text(Image(uiImage: badge).renderingMode(.original)).baselineOffset(badgeBaseline)
            chainText = Text("\(icon) \(emphasized(chain.name))")
        } else { chainText = emphasized(chain.name) }
        return template.components(separatedBy: chainMarker).enumerated().reduce(Text("")) { result, chainPart in
            let part = chainPart.element.components(separatedBy: symbolMarker).enumerated().reduce(Text("")) { result, symbolPart in
                Text("\(result)\(symbolPart.offset == 0 ? Text("") : emphasized(symbol))\(Text(symbolPart.element))")
            }
            return Text("\(result)\(chainPart.offset == 0 ? Text("") : chainText)\(part)")
        }
    }

    private var noticeWithLink: Text {
        guard let inlineLink else { return notice }
        let link = strings.language == .arabic
            ? Text(inlineLink).font(.custom(OathArabicFont.bold.rawValue, size: 13, relativeTo: .footnote))
            : Text(inlineLink).bold()
        return Text("\(notice) \(link)")
    }

    private var accessibilityText: String {
        let message = strings.format(key, strings.invariant(symbol), strings.invariant(chain.name))
        return message + (inlineLink.map { " " + String($0.characters) } ?? "")
    }

    var body: some View {
        noticeWithLink
            .oathFont(.footnote).foregroundStyle(isError ? Color.red : Color.secondary)
            .accessibilityLabel(accessibilityText)
            .task(id: badgeRequest) {
                let renderer = ImageRenderer(content: OathNetworkLogo(asset: chain.logoAsset, size: badgeSize)
                    .environment(\.colorScheme, colorScheme))
                renderer.scale = displayScale
                badge = renderer.uiImage
                if badge == nil {
                    OathDiagnostics.record(DiagnosticFailure("receive_notice_logo_render_failed"),
                        component: "receive", operation: "notice_logo", context: ["chain": chain.id])
                }
            }
    }
}

/// Share one explicit representation, never both text and image implicitly.
private struct OathReceiveShareItem: Identifiable {
    let id = UUID()
    let items: [Any]
}

private struct OathReceiveShareOptions: View {
    enum Format { case qrCode, address, link }
    let onChoose: (Format) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.oathLocalizer) private var strings

    var body: some View {
        OathContentSizedSheet(contentID: "receive.shareOptions", navigation: .init(
            strings: strings, title: .receiveShare, backIdentifier: "receive.shareOptions.back",
            onBack: nil, onClose: { dismiss() }, closeOnLeadingEdgeAtRoot: true
        ), opaqueBackground: true) {
            VStack(spacing: 0) {
                OathButton(feedback: .share) { onChoose(.qrCode) } label: {
                    OathSettingsRow(title: strings.text(.shareQRCode), icon: "qrcode")
                }
                .buttonStyle(OathSettingsRowButtonStyle())
                .accessibilityIdentifier("receive.shareQR")
                OathButton(feedback: .share) { onChoose(.address) } label: {
                    OathSettingsRow(title: strings.text(.shareAddress), icon: "text.alignleft")
                }
                .buttonStyle(OathSettingsRowButtonStyle())
                .accessibilityIdentifier("receive.shareAddress")
                OathButton(feedback: .share) { onChoose(.link) } label: {
                    OathSettingsRow(title: strings.text(.transactionShareLink), icon: "link")
                }
                .buttonStyle(OathSettingsRowButtonStyle())
                .accessibilityIdentifier("receive.shareLink")
            }
            .padding(.vertical, 12)
            .fixedSize(horizontal: false, vertical: true)
        }
        .presentationDragIndicator(.visible)
    }
}

private extension ReceiveActivationRequirement {
    func notice(strings: OathLocalizer) -> String {
        func amount(_ atomic: UInt64, _ decimals: Int, _ symbol: String) -> String {
            strings.invariant(OathAssetAmountFormat.boundedUnits(OathSendAmount.units(String(atomic), decimals: decimals) ?? "—") + " " + symbol)
        }
        switch self {
        case .stellar(let minimum): return strings.format(.receiveAccountReserve, strings.invariant("Stellar"), amount(minimum, 7, "XLM"))
        case .xrpl(let minimum): return strings.format(.receiveAccountReserve, strings.invariant("XRP Ledger"), amount(minimum, 6, "XRP"))
        case .solana(let minimum): return strings.format(.receiveAccountReserve, strings.invariant("Solana"), amount(minimum, 9, "SOL"))
        case .tron: return strings.text(.receiveTronActivation)
        case .near: return strings.text(.receiveNearActivation)
        case .ton(let needsFunding):
            return strings.format(needsFunding ? .receiveTonActivation : .receiveTonDeployment,
                                  strings.invariant(OathImportChain.ton.ticker))
        }
    }
}

private struct OathReceiveIdentity: View {
    let chain: OathImportChain
    var holding: Holding? = nil
    var showsLogo = true
    @Environment(\.oathLocalizer) private var strings
    var body: some View {
        VStack(spacing: 8) {
            if showsLogo {
                if let holding {
                    OathSendLogo(holding: holding, size: 44)
                } else {
                    OathNetworkLogo(asset: chain.logoAsset, size: 44)
                }
            }
            Text(strings.invariant(holding?.name ?? chain.name)).oathFont(.title3, weight: .semibold)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("receive.networkName")
            if let holding, holding.reference != "native" {
                Text(strings.invariant(chain.name)).oathFont(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}

private struct OathReceiveExamplesButton: View {
    let examples: [OathReceiveExample]
    let action: () -> Void
    @Environment(\.oathLocalizer) private var strings

    var body: some View {
        OathButton(action: action) {
            HStack(spacing: 14) {
                if examples.isEmpty {
                    Text(strings.text(.receiveAboutTitle)).oathFont(.subheadline)
                } else {
                    logos
                }
                Image(systemName: "chevron.forward")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(uiColor: .secondaryLabel))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 20).padding(.vertical, 8)
            .frame(minHeight: 44)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .foregroundStyle(.primary)
        }
        .buttonStyle(OathSettingsRowButtonStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(strings.text(examples.isEmpty ? .receiveAboutTitle : .receiveExampleAssets))
        .accessibilityValue(strings.list(examples.map(\.symbol)))
        .accessibilityHint(strings.text(.receiveExamplesHint))
        .accessibilityIdentifier("receive.examples")
    }

    private var logos: some View {
        HStack(spacing: -8) {
            ForEach(examples) { asset in
                OathNetworkLogo(asset: asset.artwork, size: 26)
                    .overlay {
                        if asset.usesRedesignedArtwork == true {
                            RoundedRectangle(cornerRadius: 26 * TokenArtworkStyle.cornerRadiusFraction, style: .continuous)
                                .stroke(Color(uiColor: OathSurfaceColors.canvas), lineWidth: 2)
                        } else { Circle().stroke(Color(uiColor: OathSurfaceColors.canvas), lineWidth: 2) }
                    }
            }
        }.fixedSize().accessibilityHidden(true)
    }
}

private struct OathReceiveExplanation: View {
    let chain: OathImportChain
    let examples: [OathReceiveExample]
    @Environment(\.oathLocalizer) private var strings
    @State private var robinhoodIndexAvailable = false
    @State private var arcIndexAvailable = false
    private var guide: OathReceiveNetworkGuide { .init(chain: chain, robinhoodIndexAvailable: robinhoodIndexAvailable, arcIndexAvailable: arcIndexAvailable) }

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 12) {
                OathReceiveIdentity(chain: chain)
                Text(strings.text(guide.supportsTokens ? .receiveManyAssetsTitle : .receiveNativeTitle))
                    .oathFont(.title2, weight: .semibold).multilineTextAlignment(.center)
                Text(strings.format(guide.explanation, strings.invariant(chain.name)))
                    .oathFont(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 22) {
                explanation(.receiveMatchNetworkTitle, detail: strings.format(.receiveMatchNetworkDetail,
                    strings.invariant(chain.name)), icon: "network")
                if guide.supportsTokens {
                    explanation(.receiveExamplesTitle, detail: strings.text(.receiveExamplesDetail), icon: "square.stack.3d.up")
                }
                explanation(.receiveAfterTransferTitle, detail: strings.text(guide.trackingExplanation), icon: "tray.and.arrow.down")
            }

            if !examples.isEmpty {
                VStack(alignment: .leading, spacing: 16) {
                    Text(strings.format(.receiveExamplesOnNetwork, strings.invariant(chain.name)))
                        .oathFont(.subheadline, weight: .semibold)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 54), spacing: 12)], spacing: 16) {
                        ForEach(examples) { asset in
                            VStack(spacing: 6) {
                                OathNetworkLogo(asset: asset.artwork, size: 34)
                                Text(strings.invariant(asset.symbol)).oathFont(.caption2, weight: .medium)
                                    .lineLimit(1).minimumScaleFactor(0.75)
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(strings.invariant(asset.name + ", " + asset.symbol))
                        }
                    }
                    Text(strings.text(.receiveAndMore)).oathFont(.caption).foregroundStyle(.secondary)
                }
                .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(uiColor: OathSurfaceColors.field), in: .rect(cornerRadius: 26))
            }

        }
        .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 24)
        .frame(maxWidth: 600).frame(maxWidth: .infinity)
        .accessibilityIdentifier("receive.explanation")
        .task(id: chain) {
            guard chain == .robinhood || chain == .arc else { return }
            let available = await Task.detached {
                let config = OathTokenRPCConfiguration.bundled()
                return (config.hasRobinhoodIndex, config.hasArcIndex)
            }.value
            guard !Task.isCancelled else { return }
            robinhoodIndexAvailable = available.0; arcIndexAvailable = available.1
        }
    }

    private func explanation(_ title: OathStringKey, detail: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            OathSettingsIcon(symbol: icon)
            VStack(alignment: .leading, spacing: 6) {
                Text(strings.text(title)).oathFont(.body, weight: .semibold)
                Text(detail).oathFont(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
