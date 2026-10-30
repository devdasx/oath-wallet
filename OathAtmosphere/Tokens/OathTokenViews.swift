import OathDiagnostics
import OathAnkr
import SwiftUI
import OathTokenImages
import OathDatabase
import OathMarketData

/// Uses the same identity-validated metadata as the asset detail screen. Missing
/// optional provider coverage is normal; outages still use shared diagnostics.
private struct OathTokenArtworkMetadata: TokenArtworkMetadata {
    func sources(for token: TokenArtworkIdentity, cachedOnly: Bool) async -> [String] {
        if token.decimals == nil {
            return await TokenDiscoveryCatalog.shared.sources(for: token, cachedOnly: cachedOnly)
        }
        // XRPL's free token list is empty and NEAR's list omits some tokens.
        // Exact currency + issuer / contract batch metadata can still supply
        // artwork for saved holdings. Amount scale never affects image identity.
        if token.networkID == "xrpl" || token.networkID == "near" {
            let sources = await TokenDiscoveryCatalog.shared.sources(for: token, cachedOnly: cachedOnly)
            if !sources.isEmpty { return sources }
        }
        do {
            let service = try await OathMarketEnvironment.shared.service()
            return await service.sources(for: token, cachedOnly: cachedOnly)
        } catch {
            if error as? MarketDataError != .notListed {
                OathDiagnostics.record(error, component: "artwork", operation: "token_metadata",
                    context: ["chain": token.networkID, "stage": cachedOnly ? "cache" : "refresh"])
            }
            return []
        }
    }
}

extension Holding {
    var artworkIdentity: TokenArtworkIdentity? {
        return .init(networkID: networkID, reference: reference, decimals: isCatalogPreview ? nil : decimals)
    }
}

enum OathArtworkPipeline {
    static let loader = ArtworkLoader(fallbackCatalog:
        ArtworkFallbackCatalog(transport: PublicArtworkCatalogTransport()))
}

/// All token surfaces share both image bytes and resolved token identity.
struct OathTokenLogo: View {
    let source: String?
    let symbol: String
    var size: CGFloat = 38
    var fallbackSource: String? = nil
    var identity: TokenArtworkIdentity? = nil
    var onResolved: ((ArtworkImage) -> Void)? = nil
    private static let loader = OathArtworkPipeline.loader
    private static let resolver = TokenArtworkResolver(loader: loader, metadata: OathTokenArtworkMetadata())
    @Environment(\.scenePhase) private var scenePhase
    @State private var artwork: ArtworkImage?
    @State private var loadedRequest: Request?
    private struct Request: Hashable {
        let sources: [String]
        let identity: TokenArtworkIdentity?
    }
    private var request: Request {
        .init(sources: [source, fallbackSource].compactMap { $0 }, identity: identity)
    }
    private struct LoadID: Hashable { let request: Request; let active: Bool }
    private var currentArtwork: ArtworkImage? { loadedRequest == request ? artwork : nil }
    private var usesBundledArtwork: Bool {
        guard let identity else { return false }
        return OathReceiveExampleCatalog.bundled.redesignedArtwork(networkID: identity.networkID, reference: identity.reference) != nil
    }

    var body: some View {
        OathTokenLogoArtwork(artwork: currentArtwork, symbol: symbol, size: size, identity: identity)
        .task(id: LoadID(request: request, active: scenePhase == .active)) {
            guard scenePhase == .active, !usesBundledArtwork else { return }
            let requested = request
            if let token = requested.identity {
                if let cached = await Self.resolver.cached(for: token, sources: requested.sources), !Task.isCancelled {
                    accept(cached, for: requested)
                }
                let image = await Self.resolver.image(for: token, sources: requested.sources)
                guard !Task.isCancelled else { return }
                if image != nil || currentArtwork == nil { accept(image, for: requested) }
                if image == nil {
                    do { try await Task.sleep(for: .seconds(35)) } catch { return }
                    let retried = await Self.resolver.image(for: token, sources: requested.sources)
                    guard !Task.isCancelled else { return }
                    if retried != nil || currentArtwork == nil { accept(retried, for: requested) }
                }
            } else {
                guard !requested.sources.isEmpty else { return }
                if let cached = await Self.loader.cached(for: requested.sources), !Task.isCancelled {
                    accept(cached, for: requested)
                }
                let image = await Self.loader.image(for: requested.sources)
                guard !Task.isCancelled else { return }
                if image != nil || currentArtwork == nil { accept(image, for: requested) }
                if image == nil {
                    do { try await Task.sleep(for: .seconds(35)) } catch { return }
                    let retried = await Self.loader.image(for: requested.sources)
                    guard !Task.isCancelled else { return }
                    if retried != nil || currentArtwork == nil { accept(retried, for: requested) }
                }
            }
        }
        .task(id: LoadID(request: request, active: scenePhase == .active)) {
            guard scenePhase == .active, !usesBundledArtwork, let token = request.identity else { return }
            let requested = request, observerID = UUID()
            // Observe independently of network/retry work: a result from another
            // screen must update this row immediately, even during its cooldown.
            // Registration also replays the cached image if resolution won the race.
            let updates = await Self.resolver.updates(for: token, observerID: observerID)
            defer { Task { await Self.resolver.stopUpdates(for: token, observerID: observerID) } }
            for await image in updates {
                guard !Task.isCancelled else { return }
                accept(image, for: requested)
            }
        }
    }

    private func accept(_ image: ArtworkImage?, for requested: Request) {
        guard !Task.isCancelled, requested == request else { return }
        loadedRequest = requested
        artwork = image
        // Receipts receive the same unmodified artwork displayed on screen.
        if let image { onResolved?(image) }
    }
}

/// The same synchronous artwork presentation is used on screen and in exports;
/// ImageRenderer cannot run the asynchronous resolver tasks above. The decoded
/// image carries its sampled background color, so receipts match visible rows.
struct OathTokenLogoArtwork: View {
    let artwork: ArtworkImage?
    let symbol: String
    var size: CGFloat = 38
    var identity: TokenArtworkIdentity? = nil

    private var bundledArtwork: String? {
        guard let identity else { return nil }
        return OathReceiveExampleCatalog.bundled.redesignedArtwork(networkID: identity.networkID, reference: identity.reference)
    }

    var body: some View {
        Group {
            if let bundledArtwork { OathNetworkLogo(asset: bundledArtwork, size: size) }
            else if let artwork { TokenArtworkView(artwork, size: size) }
            else {
                Text(String(symbol.prefix(2)).uppercased())
                    .font(.system(size: size * 0.3, weight: .semibold))
                    .foregroundStyle(Color(uiColor: .secondaryLabel))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(uiColor: .secondarySystemFill))
                    .clipShape(RoundedRectangle(cornerRadius: size * TokenArtworkStyle.cornerRadiusFraction,
                                                style: .continuous), style: FillStyle(antialiased: true))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Discovery rows navigate immediately; the wallet session tracks selections
/// silently even after this search view leaves the hierarchy.
struct OathTokenSearchResults: View {
    let model: OathTokenSearchModel
    let session: OathWalletSession
    let walletID: String?
    let active: Bool
    let hasSavedMatches: Bool
    var balancesHidden = false
    let onSelected: (Holding, WalletSnapshot) -> Void
    let retry: () -> Void
    @State private var didSelect = false
    @Environment(\.oathLocalizer) private var strings

    var body: some View {
        let format = OathAssetAmountFormat(locale: strings.language.locale,
            selectedCurrencyCode: session.portfolio?.currency ?? "USD")
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(model.results) { token in
                OathButton(feedback: nil) { select(token) } label: {
                    // Match Home's display fallback, without creating a zero
                    // balance or guessing decimals in the database.
                    OathRefinedListRow(title: strings.invariant(token.name),
                        subtitle: strings.invariant(format.nativeSummary(nil, ticker: token.symbol)),
                        value: String(format.fiat(.unavailable).characters),
                        showsSeparator: hasSavedMatches || token.id != model.results.first?.id,
                        concealsAmounts: balancesHidden, concealsSubtitle: balancesHidden,
                        emphasizesBalanceSubtitle: true,
                        titleBadgeAsset: token.isNativeRepresentation ? nil : token.network.chain.logoAsset) { size in
                            OathBadgedAssetLogo(networkID: token.network.id, isNative: token.isNativeRepresentation,
                                source: token.logoURL?.absoluteString, symbol: token.symbol,
                                identity: token.artworkIdentity, size: size, showsChainBadge: false)
                        }
                }
                .buttonStyle(OathSettingsRowButtonStyle())
                .accessibilityLabel([token.name, token.network.chain.name,
                    balancesHidden ? strings.text(.balanceHidden) : format.nativeSummary(nil, ticker: token.symbol),
                    balancesHidden ? "" : String(format.fiat(.unavailable).characters)].joined(separator: ", "))
                .accessibilityIdentifier("token.result.\(token.id)")
            }
            if model.isSearching || (!model.isCatalogQuery && active) {
                ProgressView().frame(maxWidth: .infinity).padding(20)
                    .accessibilityIdentifier("token.searching")
            } else if model.unavailableForWallet {
                message(.tokenNetworkUnavailable, icon: "network.slash")
            } else if model.invalidAddress {
                message(.tokenInvalidAddress, icon: "exclamationmark.magnifyingglass")
            } else if model.results.isEmpty && !hasSavedMatches && model.failedNetworks.isEmpty {
                message(.tokenNotFound, icon: "magnifyingglass")
            }
            if !model.failedNetworks.isEmpty && !model.isSearching {
                OathEmptyState(title: strings.text(.tokenSearchIncomplete), systemImage: "exclamationmark.magnifyingglass",
                    description: strings.invariant(model.failedNetworks.map { $0.chain.name }.joined(separator: ", "))) {
                    OathActionButton(title: strings.text(.tryAgain), appearance: .secondary, action: retry)
                        .accessibilityIdentifier("token.retry")
                }.padding(20)
            }
        }
        .onAppear { didSelect = false }
        .onChange(of: walletID) { _, _ in didSelect = false }
        .onChange(of: active) { _, active in if active { didSelect = false } }
    }

    private func select(_ token: OathTokenDefinition) {
        guard !didSelect, active, session.isUnlocked, !session.changingWallet, !session.resetting,
              let walletID, session.displayedProfile?.id.uuidString == walletID,
              let snapshot = session.portfolio, snapshot.wallet.id == walletID else { return }
        session.tokenSelection.select(token, walletID: walletID, snapshot: snapshot, add: { token, walletID in
            try await session.addToken(token, walletID: walletID)
        }, onSelected: { holding, snapshot in
            didSelect = true
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            onSelected(holding, snapshot)
        })
    }

    private func message(_ key: OathStringKey, icon: String) -> some View {
        OathEmptyState(strings.text(key), systemImage: icon).padding(20)
    }
}

struct OathTokenPickerSearch: View {
    let request: OathTokenSearchRequest
    let session: OathWalletSession
    let hasSavedMatches: Bool
    let onSelected: (Holding, WalletSnapshot) -> Void
    @State private var model = OathTokenSearchModel()
    @State private var attempt = 0
    @Environment(\.oathLocalizer) private var strings

    private var searchRequest: OathTokenSearchRequest {
        var value = request
        value.attempt = attempt
        return value
    }

    var body: some View {
        Group {
            if request.active {
                OathTokenSearchResults(model: model, session: session, walletID: request.walletID,
                    active: request.active, hasSavedMatches: hasSavedMatches, onSelected: onSelected,
                    retry: { attempt += 1 })
            } else if !hasSavedMatches {
                OathEmptyState(strings.text(.tokenNetworkUnavailable), systemImage: "network.slash").padding(20)
            }
        }
        .task(id: searchRequest) { await model.search(searchRequest) }
        .onDisappear { model.reset() }
    }
}

struct OathTokenDetailsSheet: View {
    let token: OathTokenDefinition
    let session: OathWalletSession
    let walletID: String
    let onAdded: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.oathLocalizer) private var strings
    @State private var adding = false
    @State private var added = false
    @State private var failed = false
    @State private var copied = false
    @State private var work: Task<Void, Never>?

    var body: some View {
        OathContentSizedSheet(contentID: "token-details-\(token.id)-\(added)", navigation: .init(
            strings: strings, title: .tokenDetails, backIdentifier: "token.back", onBack: nil,
            onClose: { work?.cancel(); dismiss() }, actionsEnabled: true)) {
            VStack(spacing: 20) {
                VStack(spacing: 10) {
                    OathTokenLogo(source: token.logoURL?.absoluteString, symbol: token.symbol, size: 68, identity: token.artworkIdentity)
                    Text(strings.invariant(token.name)).oathFont(.title2, weight: .semibold)
                        .multilineTextAlignment(.center).accessibilityIdentifier("token.details.name")
                    Text(strings.invariant(token.symbol)).oathFont(.subheadline).foregroundStyle(.secondary)
                        .accessibilityIdentifier("token.details.symbol")
                }.padding(.top, 16)
                VStack(spacing: 0) {
                    detail(.tokenNetwork, value: token.network.chain.name, id: "network")
                    detail(.tokenStandard, value: token.standardText(strings: strings), id: "standard", invariant: false)
                    if let decimals = token.decimals {
                        detail(.tokenDecimals, value: String(decimals), id: "decimals")
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text(strings.text(.tokenContract)).oathFont(.caption).foregroundStyle(.secondary)
                    Text(token.address).font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled).environment(\.layoutDirection, .leftToRight)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("token.details.address")
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20)
                Text(strings.text(.tokenVerifyDetail)).oathFont(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20)
                VStack(spacing: OathActionMetrics.spacing) {
                    OathActionButton(title: strings.text(copied ? .addressCopied : .tokenCopyAddress), appearance: .secondary) {
                        OathClipboard.copy(token.address); copied = true
                    }.accessibilityIdentifier("token.copy")
                    Group {
                        if added {
                            OathDoneButton { dismiss() }
                                .oathActionStyle()
                        } else {
                            OathActionButton(title: strings.text(.addToken), icon: "plus", isWorking: adding) {
                                add()
                            }
                        }
                    }
                    .disabled(adding || !session.isUnlocked || session.displayedProfile?.id.uuidString != walletID)
                    .accessibilityIdentifier(added ? "token.done" : "token.confirm")
                }.oathActionArea().padding(.bottom, 20)
            }
        }
        .oathHapticFeedback(.error, trigger: failed, when: failed)
        .alert(strings.text(.tokenAddFailed), isPresented: $failed) {
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
        .onChange(of: session.isUnlocked) { _, unlocked in if !unlocked { work?.cancel(); dismiss() } }
        .onDisappear { work?.cancel() }
    }

    private func detail(_ title: OathStringKey, value: String, id: String, invariant: Bool = true) -> some View {
        HStack(spacing: 20) {
            Text(strings.text(title)).oathFont(.body).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(invariant ? strings.invariant(value) : value).oathFont(.body).multilineTextAlignment(.trailing)
                .accessibilityIdentifier("token.details.\(id)")
        }.padding(.horizontal, 20).padding(.vertical, 12)
    }

    private func add() {
        guard !adding else { return }
        adding = true
        work = Task {
            defer { adding = false }
            do {
                try await session.addToken(token, walletID: walletID)
                guard !Task.isCancelled else { return }
                added = true; onAdded()
            } catch is CancellationError { }
            catch { OathDiagnostics.record(error); failed = true }
        }
    }
}
