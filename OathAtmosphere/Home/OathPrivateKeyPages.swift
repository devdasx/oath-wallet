import SwiftUI
import OathBitcoin
import OathDatabase

struct OathPrivateKeyChainsPage: View {
    let model: OathPrivateKeyModel
    let session: OathWalletSession
    let onBrowse: () -> Void
    @Environment(\.oathLocalizer) private var strings
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(strings.text(.privateKeyChooseChain))
                    .oathFont(.subheadline).foregroundStyle(.secondary)
                    .padding(24)
                ForEach(model.accounts) { account in
                    OathButton {
                        guard scenePhase != .background, !model.busy else { return }
                        if UTXONetwork(rawValue: account.chain.id) != nil {
                            model.browse(account); onBrowse()
                        } else {
                            model.select(account, reason: strings.format(.privateKeyAuthenticationReason,
                                strings.invariant(account.displayName)))
                        }
                    } label: {
                        OathSettingsRow(title: strings.invariant(account.displayName), icon: "network",
                            networkLogo: account.chain.logoAsset, titleWeight: .medium)
                    }
                    .buttonStyle(OathSettingsRowButtonStyle())
                    .disabled(!session.isUnlocked)
                    .oathInteractionBlocked(model.busy)
                    .accessibilityIdentifier("privateKey.chain.\(account.id)")
                }
                if let notice = model.notice {
                    Text(strings.text(notice)).oathFont(.footnote).foregroundStyle(.red).padding(24)
                    if !model.loaded {
                        OathActionButton(title: strings.text(.tryAgain), appearance: .secondary,
                                         isInteractionBlocked: model.busy) { Task { await model.load() } }
                            .oathActionArea()
                            .disabled(!session.isUnlocked)
                    }
                }
            }
            .frame(maxWidth: 700).frame(maxWidth: .infinity)
        }
        .task(id: session.isUnlocked) { if session.isUnlocked { await model.load() } }
        .accessibilityElement(children: .contain)
        .oathErrorFeedback(model.notice)
        .accessibilityIdentifier("privateKey.chains")
    }
}

struct OathPrivateKeyTypesPage: View {
    let model: OathPrivateKeyModel
    let onAddresses: () -> Void
    @Environment(\.oathLocalizer) private var strings
    @Environment(\.scenePhase) private var scenePhase
    private var types: [BitcoinAddressType] {
        BitcoinAddressType.allCases.filter { type in model.branches.contains { $0.type == type } }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Text(strings.text(.privateKeyGeneratedDetail)).oathFont(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(24)
                ForEach(types) { type in
                    OathButton {
                        guard scenePhase != .background, !model.busy,
                              let branch = model.branches.first(where: { $0.type == type }) else { return }
                        model.chooseBranch(branch); onAddresses()
                    } label: {
                        OathSettingsRow(title: type.localizedTitle(using: strings))
                    }
                    .buttonStyle(OathSettingsRowButtonStyle())
                    .accessibilityIdentifier("privateKey.type.\(type.rawValue)")
                }
                if model.busy { ProgressView().padding(24) }
                if let notice = model.notice {
                    Text(strings.text(notice)).oathFont(.footnote).foregroundStyle(.red).padding(24)
                    OathActionButton(title: strings.text(.tryAgain), isInteractionBlocked: model.busy) {
                        Task { await model.loadBranches() }
                    }.oathActionArea()
                }
            }.frame(maxWidth: 700).frame(maxWidth: .infinity)
        }
        .task { await model.loadBranches() }
        .accessibilityIdentifier("privateKey.types")
    }
}

struct OathPrivateKeyAddressesPage: View {
    let model: OathPrivateKeyModel
    let session: OathWalletSession
    @Environment(\.oathLocalizer) private var strings
    @Environment(\.scenePhase) private var scenePhase
    @State private var query = ""
    private var branches: [BitcoinBranch] { model.branches.filter { $0.type == model.branch?.type } }
    private var search: BitcoinAddressSearch {
        .init(query: query, nameFormat: strings.text(.privateKeyAddressNumber),
              localeIdentifier: strings.language.locale.identifier)
    }
    private struct SearchRequest: Equatable {
        let branchID: String?
        let search: BitcoinAddressSearch
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if let branch = model.branch {
                    Text(branch.type.localizedTitle(using: strings)).oathFont(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(24)
                    Picker(strings.text(.privateKeyPath), selection: Binding(get: { branch.id }, set: { id in
                        guard scenePhase != .background, let value = branches.first(where: { $0.id == id }) else { return }
                        model.chooseBranch(value)
                    })) {
                        ForEach(branches) { item in
                            Text(strings.text(item.change == 0 ? .privateKeyReceiveAddresses : .privateKeyChangeAddresses)).tag(item.id)
                        }
                    }
                    .pickerStyle(.segmented).padding(.horizontal, 24).padding(.bottom, 16)
                    .disabled(!session.isUnlocked)
                    .oathInteractionBlocked(model.phase != .chains)
                    .accessibilityIdentifier("privateKey.branch")
                }
                ForEach(model.addresses) { account in
                    OathButton {
                        guard scenePhase != .background, session.isUnlocked else { return }
                        model.select(account, reason: strings.format(.privateKeyAuthenticationReason, strings.invariant(account.displayName)))
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(strings.format(.privateKeyAddressNumber, strings.number(Int(account.utxo?.address.index ?? 0))))
                                    .oathFont(.body, weight: .medium)
                                Spacer()
                                Image(systemName: "chevron.forward").font(.footnote).foregroundStyle(.secondary)
                            }
                            Text(verbatim: account.address).oathFont(.subheadline).lineLimit(1).truncationMode(.middle)
                                .environment(\.layoutDirection, .leftToRight)
                            Text(verbatim: account.path).oathFont(.caption).foregroundStyle(.secondary)
                                .environment(\.layoutDirection, .leftToRight)
                        }.padding(.horizontal, 24).padding(.vertical, 16)
                            .foregroundStyle(Color(uiColor: .label))
                    }
                    .buttonStyle(OathSettingsRowButtonStyle())
                    .disabled(!session.isUnlocked)
                    .oathInteractionBlocked(model.busy)
                    .accessibilityIdentifier("privateKey.address.\(account.utxo?.address.id ?? account.id)")
                    OathSettingsSectionRule()
                }
                if model.busy { ProgressView().padding(24) }
                if !model.busy, model.notice == nil, model.addresses.isEmpty, !search.query.isEmpty {
                    OathEmptyState(strings.text(.noSearchResults), systemImage: "magnifyingglass")
                        .padding(24)
                }
                if let notice = model.notice {
                    Text(strings.text(notice)).oathFont(.footnote).foregroundStyle(.red).padding(24)
                }
                if model.hasMoreAddresses {
                    OathActionButton(title: strings.text(model.notice == nil ? .privateKeyLoadMore : .tryAgain),
                        appearance: .text, isInteractionBlocked: model.busy) {
                        Task { await model.loadAddresses() }
                    }.oathActionArea().padding(.vertical, 16)
                }
            }.frame(maxWidth: 700).frame(maxWidth: .infinity)
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: strings.text(.searchTitle))
        .scrollDismissesKeyboard(.interactively)
        .task(id: SearchRequest(branchID: model.branch?.id, search: search)) {
            model.setAddressSearch(search)
            if model.addresses.isEmpty { await model.loadAddresses() }
        }
        .accessibilityIdentifier("privateKey.addresses")
    }
}

struct OathPrivateKeyWarningPage: View {
    let model: OathPrivateKeyModel
    let session: OathWalletSession
    @Environment(\.oathLocalizer) private var strings
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                VStack(alignment: .leading, spacing: 18) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 38, weight: .medium)).foregroundStyle(.orange)
                        .frame(width: 76, height: 76)
                        .background(Color.orange.opacity(0.1), in: .rect(cornerRadius: 24))
                        .accessibilityHidden(true)
                    Text(strings.text(.privateKeyWarningTitle)).oathFont(.title, weight: .semibold)
                        .accessibilityAddTraits(.isHeader)
                    Text(strings.format(.privateKeyWarningDetail, strings.invariant(model.selected?.displayName ?? "")))
                        .oathFont(.body).foregroundStyle(.secondary)
                }
                warning("person.crop.circle.badge.xmark", title: .privateKeyNeverShare, detail: .privateKeyNeverShareDetail)
                warning("camera", title: .recoveryAvoidScreenshots, detail: .privateKeyAvoidScreenshotsDetail)
                warning("lock.shield", title: .recoveryStoreSecurely, detail: .privateKeyStoreSecurelyDetail)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(24)
            .frame(maxWidth: 600, alignment: .leading).frame(maxWidth: .infinity)
        }
        .oathBottomActions {
            OathBottomAction(title: strings.text(.recoveryUnderstand),
                         identifier: "privateKey.understand",
                         isEnabled: model.phase == .warning && session.isUnlocked) {
                guard model.phase == .warning, session.isUnlocked, scenePhase != .background else { return }
                model.acknowledge()
            }
        }
        .toolbar(.hidden, for: .bottomBar)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("privateKey.warning")
    }

    private func warning(_ icon: String, title: OathStringKey, detail: OathStringKey) -> some View {
        HStack(alignment: .top, spacing: 16) {
            OathSettingsIcon(symbol: icon)
            VStack(alignment: .leading, spacing: 6) {
                Text(strings.text(title)).oathFont(.body, weight: .semibold)
                Text(strings.text(detail)).oathFont(.subheadline).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct OathPrivateKeyValuePage: View {
    let model: OathPrivateKeyModel
    let session: OathWalletSession
    @Environment(\.oathLocalizer) private var strings
    @Environment(\.scenePhase) private var scenePhase
    @State private var copied = false
    @State private var showingQRCode = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let account = model.selected {
                    HStack(spacing: 12) {
                        OathNetworkLogo(asset: account.chain.logoAsset, size: 38)
                        Text(strings.invariant(account.displayName)).oathFont(.title2, weight: .semibold)
                    }
                    Text(strings.format(.privateKeyViewDetail, strings.invariant(account.displayName)))
                        .oathFont(.body).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Label(privateKeySafetyWarning(strings: strings, isEVM: account.chain.isEVM), systemImage: "exclamationmark.shield")
                        .oathFont(.subheadline, weight: .semibold).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    if let key = model.key {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(strings.format(.privateKeyFormat, strings.invariant(key.format)))
                                .oathFont(.caption).foregroundStyle(.secondary)
                            OathPrivateKeyText(value: key.value)
                                .environment(\.layoutDirection, .leftToRight)
                        }
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(uiColor: OathSurfaceColors.field), in: .rect(cornerRadius: 20))
                    }
                    if let origin = account.utxo {
                        Text(origin.address.type.localizedTitle(using: strings)).oathFont(.subheadline)
                        Text(verbatim: account.path).oathFont(.footnote).foregroundStyle(.secondary)
                            .environment(\.layoutDirection, .leftToRight)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(strings.text(.privateKeyAccount)).oathFont(.caption).foregroundStyle(.secondary)
                        Text(verbatim: account.address).font(.footnote.monospaced())
                            .lineLimit(2).truncationMode(.middle)
                            .environment(\.layoutDirection, .leftToRight)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 600, alignment: .leading).frame(maxWidth: .infinity)
        }
        .oathBottomActions {
            OathBottomAction(title: strings.text(copied ? .recoveryCopied : .recoveryCopy),
                         identifier: "privateKey.copy", appearance: .secondary,
                         isEnabled: model.key != nil && model.phase == .revealed && session.isUnlocked) {
                guard let key = model.key, !key.value.isEmpty, model.phase == .revealed,
                      session.isUnlocked, scenePhase != .background else { return }
                OathSensitiveClipboard.copy(key.value)
                copied = true
            }
        }
        .toolbar(.hidden, for: .bottomBar)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("privateKey.value")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                OathButton {
                    guard session.isUnlocked, scenePhase != .background, model.phase == .revealed, model.key != nil else { return }
                    showingQRCode = true
                } label: { Label(strings.text(.privateKeyQRCode), systemImage: "qrcode") }
                .labelStyle(.iconOnly).oathNeutralControl()
                .disabled(!session.isUnlocked || model.key == nil)
                .oathInteractionBlocked()
                .accessibilityIdentifier("privateKey.showQR")
            }
        }
        .sheet(isPresented: $showingQRCode) {
            NavigationStack {
                OathPrivateKeyQRCodePage(model: model, session: session)
                    .navigationTitle(strings.text(.privateKeyQRCode)).navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) { OathCloseButton { showingQRCode = false } }
                    }
            }
        }
        .onChange(of: session.isUnlocked) { _, unlocked in if !unlocked { showingQRCode = false } }
        .onChange(of: scenePhase) { _, phase in if phase == .background { showingQRCode = false } }
        .onDisappear { showingQRCode = false }
    }
}

private struct OathPrivateKeyQRCodePage: View {
    let model: OathPrivateKeyModel
    let session: OathWalletSession
    @Environment(\.oathLocalizer) private var strings

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Text(privateKeySafetyWarning(strings: strings, isEVM: model.selected?.chain.isEVM == true)).oathFont(.headline).foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                if session.isUnlocked, model.phase == .revealed, let key = model.key {
                    if let image = OathPrivateKeyQRCode.image(for: key.value) {
                        Image(decorative: image, scale: 1).interpolation(.none).resizable().scaledToFit()
                            .frame(maxWidth: 320).background(.white).accessibilityLabel(strings.text(.privateKeyQRCode))
                            .accessibilityIdentifier("privateKey.qr")
                    } else {
                        Text(strings.text(.walletUnavailable)).foregroundStyle(.secondary)
                    }
                    Text(strings.format(.privateKeyFormat, strings.invariant(key.format))).oathFont(.subheadline)
                    Text(strings.text(.privateKeyQRDetail)).oathFont(.footnote).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }.padding(24).frame(maxWidth: 600).frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: OathSurfaceColors.canvas).ignoresSafeArea())
    }
}

/// Character wrapping without hyphenation or bidi reordering: the rendered
/// key must never acquire a character that isn't in the copied value.
private struct OathPrivateKeyText: UIViewRepresentable {
    let value: String
    func makeUIView(context: Context) -> UILabel {
        let label = UILabel()
        label.numberOfLines = 0
        label.textAlignment = .left
        label.lineBreakMode = .byCharWrapping
        label.lineBreakStrategy = []
        label.semanticContentAttribute = .forceLeftToRight
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.accessibilityIdentifier = "privateKey.text"
        return label
    }
    func updateUIView(_ label: UILabel, context: Context) {
        label.text = value
        label.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .monospacedSystemFont(ofSize: 17, weight: .medium))
        label.textColor = .label
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UILabel, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        return uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    }
}

/// Share the same scope warning between the revealed key and its QR screen.
private func privateKeySafetyWarning(strings: OathLocalizer, isEVM: Bool) -> String {
    let warning = strings.text(.privateKeyKeepSafe)
    return isEVM ? warning + "\n\n" + strings.text(.privateKeyEVMScopeWarning) : warning
}
