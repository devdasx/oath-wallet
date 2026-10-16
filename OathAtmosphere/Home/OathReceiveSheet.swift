import OathDiagnostics
import SwiftUI
import OathDatabase
import OathBitcoin

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
    var body: some View { OathReceiveFlow(addresses: [address], initialAddress: address, session: session) }
}

private struct OathReceiveFlow: View {
    let addresses: [OathWalletAddress]
    let session: OathWalletSession
    private let startsWithAddress: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.oathLocalizer) private var strings
    @State private var selected: OathWalletAddress?
    private enum Step: Hashable { case receive, types, about }
    @State private var path: [Step] = []
    @State private var query = ""
    @State private var selectedHolding: Holding?
    @State private var selectionID = UUID()
    @State private var qr: CGImage?
    @State private var qrAddress: String?
    private struct ReceiveIdentity: Hashable {
        let accountID: String
        let assetID: String
        let chain: OathImportChain
        let address: String
    }
    @State private var recorded = Set<ReceiveIdentity>()
    @State private var storageFailed = false
    @State private var bitcoin: BitcoinAccountState?
    @State private var solana: SolanaReceiveState?
    @State private var changingType = false
    @State private var retryReceive = 0
    @State private var typeChange: Task<Void, Never>?

    init(addresses: [OathWalletAddress], initialAddress: OathWalletAddress?, session: OathWalletSession) {
        self.addresses = addresses
        self.session = session
        startsWithAddress = initialAddress != nil
        _selected = State(initialValue: initialAddress)
        _selectedHolding = State(initialValue: session.portfolio?.holdings.first {
            $0.accountID == initialAddress?.accountID && $0.assetID == initialAddress?.assetID
        })
    }

    private var receiving: Bool { startsWithAddress || path.contains(.receive) }
    private var receiveTitle: String {
        guard let selected else { return strings.text(.receive) }
        return strings.format(.receiveAssetTitle, strings.invariant(selectedHolding?.name ?? selected.networkName))
    }

    private var showsAddressChoice: Bool {
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
    private var readyIdentity: ReceiveIdentity? {
        guard allowed, receiving, !preparingAddress, let selected,
              let accountID = selected.accountID, let assetID = selected.assetID else { return nil }
        return ReceiveIdentity(accountID: accountID, assetID: assetID, chain: selected.chain, address: selected.address)
    }

    private var preparingAddress: Bool {
        guard let selected else { return false }
        return (UTXONetwork(rawValue: selected.chain.id) != nil && bitcoin == nil)
            || (selected.chain == .solana && solana == nil)
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
                            Label(strings.text(.back), systemImage: "chevron.backward")
                        }
                        .labelStyle(.iconOnly).oathNeutralControl()
                        .accessibilityIdentifier("receive.back")
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
        .task(id: "\(receiving):\(selectionID):\(retryReceive):\(allowed)") {
            guard allowed, receiving, let selected, let id = selected.accountID else { return }
            await perform("prepare_address", chain: selected.chain) {
                if selected.chain == .solana {
                    try await loadSolanaAddress(accountID: id)
                } else if UTXONetwork(rawValue: selected.chain.id) != nil {
                    try await session.vault.prepareBitcoin(accountID: id)
                    try await loadBitcoinAddress(accountID: id)
                }
            }
        }
        // Pushing guidance keeps the same QR and persisted receive record.
        .task(id: "\(selectionID):\(retryReceive):\(selected?.address ?? "")") {
            guard let value = selected?.address else { return }
            let image = await Task.detached(priority: .userInitiated) {
                OathReceiveQRCode.image(for: value)
            }.value
            guard !Task.isCancelled, selected?.address == value else { return }
            qr = image
            qrAddress = value
            if image == nil {
                OathDiagnostics.$operationID.withValue(UUID()) {
                    OathDiagnostics.record(DiagnosticFailure("qr_generation_failed"), component: "receive",
                        operation: "generate_qr", context: ["chain": selected?.chain.id ?? "unknown"])
                }
                storageFailed = true
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
            if preparingAddress || qr == nil {
                OathButton(strings.text(.tryAgain)) { retryReceive += 1 }
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
        let lastID = assets.last?.id
        return OathEmptyStateScrollView(centersContent: assets.isEmpty) {
            VStack(spacing: 0) {
                if session.portfolio == nil {
                    ProgressView().frame(maxWidth: .infinity).padding(36)
                } else if assets.isEmpty {
                    OathEmptyState(strings.text(.sendNoAssets), systemImage: "magnifyingglass")
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(assets) { asset in
                            OathButton(feedback: .navigate) {
                                guard allowed else { return }
                                typeChange?.cancel()
                                selectionID = UUID()
                                qr = nil; qrAddress = nil; bitcoin = nil; solana = nil
                                selectedHolding = asset.holding
                                selected = asset.address
                                path.append(.receive)
                            } label: {
                                OathAssetSelectionRow(holding: asset.holding, currency: session.portfolio?.currency ?? "USD")
                            }
                            .buttonStyle(OathSettingsRowButtonStyle())
                            .accessibilityIdentifier("receive.asset.\(asset.id)")
                            if asset.id != lastID {
                                OathHairline().padding(.leading, 74).padding(.trailing, 20)
                            }
                        }
                    }
                }
            }.frame(maxWidth: 600).frame(maxWidth: .infinity)
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: strings.text(.searchAssets))
        .scrollDismissesKeyboard(.interactively)
    }

    private var receivePage: some View {
        Group {
            if let selected {
                OathReceiveContent(address: selected, holding: selectedHolding, examples: examples(for: selected),
                    qr: qrAddress == selected.address ? qr : nil,
                    preparingAddress: preparingAddress) { showExplanation(true) }
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

    private func loadSolanaAddress(accountID: String, path: String? = nil) async throws {
        let state = try await session.vault.solanaReceiveState(accountID: accountID, selecting: path)
        try Task.checkCancellation()
        guard let current = selected, current.accountID == accountID, allowed, receiving else { return }
        solana = state
        selected = .init(chain: current.chain, address: state.selected.address, path: state.selected.path,
            accountIndex: current.accountIndex, accountID: accountID, assetID: current.assetID,
            storedNetworkName: current.storedNetworkName, storedTicker: current.storedTicker, storedLogo: current.storedLogo)
    }

    private func loadBitcoinAddress(accountID: String, type: BitcoinAddressType? = nil) async throws {
        let db = try await session.vault.database()
        let address = try await db.bitcoinReceiveAddress(accountID: accountID, type: type)
        let state = try await db.bitcoinState(accountID: accountID)
        try Task.checkCancellation()
        guard selected?.accountID == accountID, allowed, receiving else { return }
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
    let preparingAddress: Bool
    let onExplain: () -> Void
    @Environment(\.oathLocalizer) private var strings
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var copied = false
    @State private var showingShare = false
    private var guide: OathReceiveNetworkGuide { .init(chain: address.chain) }

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
                                        receiveLogo(size: geometry.size.width * OathReceiveQRCode.logoFraction)
                                            .clipShape(Circle())
                                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                                            .accessibilityHidden(true)
                                    }
                                }
                        } else { ProgressView().tint(.black) }
                    }
                    // Use the available width on smaller sheets; keep the encoded quiet
                    // zone and center-logo proportions intact at every display size.
                    .aspectRatio(1, contentMode: .fit)
                    .frame(width: min(360, geometry.size.width * 0.86))
                    .clipShape(.rect(cornerRadius: 16))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(strings.text(.receiveQRCode))
                    .accessibilityIdentifier("receive.qr")

                    // The QR image already includes its required white quiet zone;
                    // do not add another gap before the network notice.
                    Text(strings.format(guide.notice, strings.invariant(address.chain.ticker), strings.invariant(address.chain.name)))
                        .oathFont(.footnote).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 24)
                        .accessibilityIdentifier("receive.networkNotice")

                    OathReceiveExamplesButton(examples: examples, action: onExplain)
                        .padding(.top, 4)

                    // At accessibility sizes the whole page scrolls together;
                    // a tall pinned address must not consume the QR viewport.
                    if typeSize.isAccessibilitySize { addressAndActions.padding() }
                }
                .padding(.top, 4).padding(.bottom, 20)
                .frame(maxWidth: 600).frame(maxWidth: .infinity)
            }
        }
        .oathBottomActions(isPresented: !typeSize.isAccessibilitySize, maximumWidth: 600) {
            addressAndActions
        }
        .onChange(of: address.address) { _, _ in copied = false }
        .sheet(isPresented: $showingShare) { OathShareSheet(items: [address.address]) }
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

    private var addressAndActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { assetSymbol; networkBadge }
                VStack(alignment: .leading, spacing: 8) { assetSymbol; networkBadge }
            }
            if preparingAddress {
                ProgressView().frame(maxWidth: .infinity, alignment: .leading)
            } else {
                OathAddressText(address: address.address, centered: false, emphasizesEnds: true)
                    .environment(\.layoutDirection, .leftToRight)
                    .fixedSize(horizontal: false, vertical: true)
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

    private var assetSymbol: some View {
        Text(strings.invariant(holding?.symbol ?? address.ticker))
            .oathFont(.title3, weight: .semibold).foregroundStyle(.primary)
    }

    private var networkBadge: some View {
        Text(strings.invariant(address.networkName))
            .oathFont(.footnote, weight: .medium).foregroundStyle(Color.primary.opacity(0.8))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color(uiColor: OathSurfaceColors.field), in: .rect(cornerRadius: 7))
    }

    private var copy: some View {
        OathButton {
            OathClipboard.copy(address.address)
            copied = true
        } label: {
            OathActionLabel(title: strings.text(copied ? .addressCopied : .copyAddress))
        }
        .accessibilityIdentifier("receive.copy")
    }

    private var share: some View {
        OathButton(feedback: .share, action: { showingShare = true }) {
            OathActionLabel(title: strings.text(.receiveShare), icon: "square.and.arrow.up")
        }
        .accessibilityLabel(strings.text(.shareAddress))
        .accessibilityIdentifier("receive.share")
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
                    .overlay(Circle().stroke(Color(uiColor: OathSurfaceColors.canvas), lineWidth: 2))
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
