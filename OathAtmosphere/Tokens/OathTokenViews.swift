import OathDiagnostics
import SwiftUI
import OathTokenImages
import OathDatabase
import OathMarketData

/// Uses the same identity-validated metadata as the asset detail screen. Missing
/// optional provider coverage is normal; outages still use shared diagnostics.
private struct OathTokenArtworkMetadata: TokenArtworkMetadata {
    func sources(for token: TokenArtworkIdentity, cachedOnly: Bool) async -> [String] {
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
        .init(networkID: networkID, reference: reference, decimals: decimals)
    }
}
extension OathTokenDefinition {
    var artworkIdentity: TokenArtworkIdentity? {
        isNativeRepresentation ? nil : .init(networkID: network.id, reference: reference, decimals: decimals)
    }
}

/// All token surfaces share both image bytes and resolved token identity.
struct OathTokenLogo: View {
    let source: String?
    let symbol: String
    var size: CGFloat = 38
    var fallbackSource: String? = nil
    var identity: TokenArtworkIdentity? = nil
    var onResolved: ((ArtworkImage) -> Void)? = nil
    private static let resolver = TokenArtworkResolver(metadata: OathTokenArtworkMetadata())
    @Environment(\.scenePhase) private var scenePhase
    @State private var artwork: ArtworkImage?
    @State private var loadedRequest: Request?
    private struct Request: Hashable { let sources: [String]; let identity: TokenArtworkIdentity? }
    private var request: Request { .init(sources: [source, fallbackSource].compactMap { $0 }, identity: identity) }
    private struct LoadID: Hashable { let request: Request; let active: Bool }
    private var currentArtwork: ArtworkImage? { loadedRequest == request ? artwork : nil }

    var body: some View {
        OathTokenLogoArtwork(artwork: currentArtwork, symbol: symbol, size: size)
        .task(id: LoadID(request: request, active: scenePhase == .active)) {
            guard scenePhase == .active else { return }
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
                if let cached = await ArtworkLoader.shared.cached(for: requested.sources), !Task.isCancelled {
                    accept(cached, for: requested)
                }
                let image = await ArtworkLoader.shared.image(for: requested.sources)
                guard !Task.isCancelled else { return }
                if image != nil || currentArtwork == nil { accept(image, for: requested) }
                if image == nil {
                    do { try await Task.sleep(for: .seconds(35)) } catch { return }
                    let retried = await ArtworkLoader.shared.image(for: requested.sources)
                    guard !Task.isCancelled else { return }
                    if retried != nil || currentArtwork == nil { accept(retried, for: requested) }
                }
            }
        }
        .task(id: LoadID(request: request, active: scenePhase == .active)) {
            guard scenePhase == .active, let token = request.identity else { return }
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
        loadedRequest = requested
        artwork = image
        if let image { onResolved?(image) }
    }
}

/// The same synchronous artwork presentation is used on screen and in exports;
/// ImageRenderer cannot run the asynchronous resolver tasks above.
struct OathTokenLogoArtwork: View {
    let artwork: ArtworkImage?
    let symbol: String
    var size: CGFloat = 38

    var body: some View {
        Group {
            if let artwork { ArtworkImageView(artwork) }
            else {
                Text(String(symbol.prefix(2)).uppercased())
                    .font(.system(size: size * 0.3, weight: .semibold))
                    .foregroundStyle(Color(uiColor: .secondaryLabel))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: size, height: size)
        .background(artwork == nil ? Color(uiColor: OathSurfaceColors.field) : .white, in: Circle())
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}

struct OathTokenSearchResults: View {
    let model: OathTokenSearchModel
    let hasSavedMatches: Bool
    let onSelect: (OathTokenDefinition) -> Void
    let retry: () -> Void
    @Environment(\.oathLocalizer) private var strings

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !model.results.isEmpty {
                Text(strings.text(.tokenSearchFound)).oathFont(.headline)
                Text(strings.text(.tokenSearchReview)).oathFont(.subheadline).foregroundStyle(.secondary)
                ForEach(model.results) { token in
                    OathButton { onSelect(token) } label: {
                        OathListRow {
                            OathTokenLogo(source: token.logoURL?.absoluteString, symbol: token.symbol, identity: token.artworkIdentity)
                        } content: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(strings.invariant(token.name)).oathFont(.body).foregroundStyle(.primary)
                                Text(strings.invariant("\(token.symbol) · \(token.network.chain.name)"))
                                    .oathFont(.caption).foregroundStyle(.secondary)
                                Text(strings.text(.tokenDecimals) + ": " + strings.number(token.decimals))
                                    .oathFont(.caption).foregroundStyle(.secondary)
                                Text(token.address).font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary).environment(\.layoutDirection, .leftToRight)
                                    .fixedSize(horizontal: false, vertical: true)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        } accessory: {
                            Image(systemName: "plus.circle").foregroundStyle(Color(uiColor: .label)).font(.title3)
                        }
                    }
                    .buttonStyle(OathSettingsRowButtonStyle())
                    .accessibilityLabel(strings.text(.addToken) + ", " + token.name + ", " + token.network.chain.name)
                    .accessibilityIdentifier("token.result.\(token.network.id)")
                }
                .padding(.horizontal, -20)
            }
            if model.isSearching {
                HStack(spacing: 12) {
                    ProgressView()
                    Text(strings.text(.tokenSearching)).oathFont(.subheadline).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).padding(.vertical, 20)
                    .accessibilityIdentifier("token.searching")
            } else if model.unavailableForWallet {
                message(.tokenNetworkUnavailable, icon: "network.slash")
            } else if model.invalidAddress {
                message(.tokenInvalidAddress, icon: "exclamationmark.magnifyingglass")
            } else if model.results.isEmpty && !hasSavedMatches && model.failedNetworks.isEmpty {
                message(.tokenNotFound, icon: "magnifyingglass")
            }
            if !model.failedNetworks.isEmpty && model.results.isEmpty && !hasSavedMatches && !model.isSearching {
                OathEmptyState(title: strings.text(.tokenSearchIncomplete), systemImage: "exclamationmark.magnifyingglass",
                    description: strings.invariant(model.failedNetworks.map { $0.chain.name }.joined(separator: ", "))) {
                    OathActionButton(title: strings.text(.tryAgain), appearance: .secondary, action: retry)
                        .accessibilityIdentifier("token.retry")
                }
            } else if !model.failedNetworks.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(strings.text(.tokenSearchIncomplete)).oathFont(.subheadline)
                    Text(strings.invariant(model.failedNetworks.map { $0.chain.name }.joined(separator: ", ")))
                        .oathFont(.caption).foregroundStyle(.secondary)
                    OathActionButton(title: strings.text(.tryAgain), appearance: .secondary, action: retry)
                        .disabled(model.isSearching)
                        .accessibilityIdentifier("token.retry")
                }.padding(.top, 12)
            }
        }
    }

    private func message(_ key: OathStringKey, icon: String) -> some View {
        OathEmptyState(strings.text(key), systemImage: icon)
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
            onClose: { dismiss() }, actionsEnabled: !adding)) {
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
                    detail(.tokenStandard, value: token.standard, id: "standard")
                    detail(.tokenDecimals, value: String(token.decimals), id: "decimals")
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
        .interactiveDismissDisabled(adding)
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

    private func detail(_ title: OathStringKey, value: String, id: String) -> some View {
        HStack(spacing: 20) {
            Text(strings.text(title)).oathFont(.body).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(strings.invariant(value)).oathFont(.body).multilineTextAlignment(.trailing)
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
