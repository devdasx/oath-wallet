import OathDiagnostics
import SwiftUI
import OathDatabase
import OathAnkr
import OathTokenImages

struct OathTransactionDetailScreen: View {
    let entry: HistoryEntry
    let holding: Holding
    let networkName: String
    let currency: String
    let balancesHidden: Bool
    @Environment(\.oathLocalizer) private var strings
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.displayScale) private var displayScale
    @Environment(\.openURL) private var openURL
    @State private var swapProgress: ThorchainSwapProgress?
    @State private var details: TransactionDetails?
    @State private var copiedKey: OathStringKey?
    @State private var share: OathTransactionSharePayload?
    @State private var exportFailed = false
    @State private var contentWidth: CGFloat = 390
    @State private var tokenArtwork: ArtworkImage?

    private var currentEntry: HistoryEntry { entry.updatingState(details?.state ?? entry.state) }
    private var badge: OathTransactionBadge { .init(state: currentEntry.state, direction: currentEntry.direction) }

    private var explorerURL: URL? {
        OathImportChain(rawValue: entry.networkID)?.transactionExplorerURL(hash: entry.hash)
    }

    var body: some View {
        ScrollView {
            receipt()
                .background {
                    GeometryReader { proxy in
                        Color.clear.onAppear { contentWidth = proxy.size.width }
                            .onChange(of: proxy.size.width) { _, width in contentWidth = width }
                    }
                }
        }
        .background(Color(uiColor: OathSurfaceColors.groupedCanvas).ignoresSafeArea())
        .navigationTitle(strings.text(.assetTransaction))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarRole(.editor)
        .toolbar(.visible, for: .navigationBar)
        .toolbar(.hidden, for: .bottomBar, .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    OathButton(strings.text(.transactionShareImage), systemImage: "photo", feedback: .share) { exportImage() }
                        .accessibilityIdentifier("transaction.shareImage")
                    if let explorerURL {
                        OathButton(strings.text(.transactionShareLink), systemImage: "link", feedback: .share) {
                            share = OathTransactionSharePayload(items: [explorerURL])
                        }
                        .accessibilityIdentifier("transaction.shareLink")
                        OathButton(strings.text(.transactionViewExplorer), systemImage: "arrow.up.right.square") {
                            openURL(explorerURL)
                        }
                        .accessibilityIdentifier("transaction.explorer")
                    }
                } label: { Image(systemName: "ellipsis") }
                .oathNeutralControl()
                .accessibilityLabel(strings.text(.moreOptions))
                .accessibilityIdentifier("transaction.share")
            }
        }
        .oathNativeLocalization(navigationTint: .label)
        .accessibilityIdentifier("transaction.details")
        .sheet(item: $share) { payload in
            OathShareSheet(items: payload.items)
        }
        .oathHapticFeedback(.error, trigger: exportFailed, when: exportFailed)
        .alert(strings.text(.transactionShareFailed), isPresented: $exportFailed) {
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
        .task(id: "\(entry.accountID)|\(entry.transactionID)|\(currency)") {
            details = nil
            do {
                let database = try await OathDataEnvironment.shared.database()
                for try await value in database.observeTransactionDetails(accountID: entry.accountID,
                    transactionID: entry.transactionID, currency: currency) {
                    try Task.checkCancellation()
                    details = value
                }
            } catch { OathDiagnostics.record(error); /* Preserve the last cached projection on interruption. */ }
        }
        .task(id: entry.hash) {
            guard entry.networkID == "thorchain" else { return }
            // Ordinary transfers, absent indexing and unsupported memo variants
            // return nil; they are not failed swaps or application errors.
            let progress = await OathDiagnostics.attemptOptional("activity_swap_progress") {
                try await ThorchainClient().swapProgress(hash: entry.hash)
            }
            guard !Task.isCancelled else { return }
            swapProgress = progress
        }
        .task(id: copiedKey) {
            guard copiedKey != nil else { return }
            do {
                try await Task.sleep(for: .seconds(2))
                copiedKey = nil
            } catch { OathDiagnostics.record(error);}
        }
    }

    /// On-screen content and exported image deliberately use the same view.
    private func receipt(exporting: Bool = false) -> some View {
        let entry = currentEntry
        return VStack(spacing: 28) {
            VStack(spacing: 14) {
                assetLogo(exporting: exporting)
                Text(OathAssetHistoryFormatting.title(entry, holding: holding, strings: strings))
                    .oathFont(.title2, weight: .semibold)
                Text(balancesHidden ? "••••" : strings.invariant(OathAssetHistoryFormatting.fiat(entry, holding: holding,
                    currency: currency, locale: strings.language.locale) ?? strings.text(.assetPriceUnavailable)))
                    .oathFont(.largeTitle, weight: .semibold).minimumScaleFactor(0.5).lineLimit(1)
                    .accessibilityIdentifier("transaction.amountFiat")
                Text(balancesHidden ? "••••" : strings.invariant(OathAssetHistoryFormatting.amount(entry, holding: holding)))
                    .oathFont(.body).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity).padding(.vertical, 20)
            VStack(spacing: 20) {
                row(.transactionStatus, strings.text(OathAssetHistoryFormatting.status(entry.state)))
                if entry.timestamp > 0 {
                    row(.assetTime, Date(timeIntervalSince1970: entry.timestamp).formatted(
                        .dateTime.day().month(.abbreviated).year().hour().minute().locale(strings.language.locale)))
                }
                row(.tokenNetwork, networkName, isInvariant: true)
                if !["canceled", "replaced", "reorged"].contains(entry.state), details?.transaction.feeAtomic != nil {
                    row(.transactionNetworkFee, feeText, isInvariant: true)
                        .accessibilityIdentifier("transaction.fee")
                }
            }
            OathSettingsSectionRule()
            VStack(spacing: 12) {
                if !entry.counterparty.isEmpty {
                    identifierRow(entry.direction == "incoming" ? .transactionFrom : .transactionTo, entry.counterparty)
                }
                if let replacement = details?.replacementHash {
                    identifierRow(.transactionReplacement, replacement)
                }
                identifierRow(.assetTransactionID, entry.hash)
            }
            if let swapProgress {
                NavigationLink { OathWCThorchainProgress(initial: swapProgress) } label: {
                    OathSettingsRow(title: strings.text(.wcSwapProgress), icon: "arrow.triangle.swap")
                }.buttonStyle(OathSettingsRowButtonStyle()).accessibilityIdentifier("transaction.swapProgress")
            }
        }
        .padding(20).frame(maxWidth: 700).frame(maxWidth: .infinity)
    }

    private func assetLogo(exporting: Bool) -> some View {
        Group {
            if holding.reference == "native", let chain = OathImportChain(rawValue: holding.networkID) {
                OathNetworkLogo(asset: chain.logoAsset, size: 72)
            } else if exporting {
                // ImageRenderer does not run asynchronous view tasks. Reuse the
                // actual artwork already resolved for the on-screen receipt.
                OathTokenLogoArtwork(artwork: tokenArtwork, symbol: holding.symbol, size: 72)
            } else {
                OathTokenLogo(source: holding.logo, symbol: holding.symbol, size: 72,
                    identity: holding.artworkIdentity, onResolved: { tokenArtwork = $0 })
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: badge.symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(badgeColor)
                .frame(width: 28, height: 28)
                .background {
                    Circle().fill(Color(uiColor: OathSurfaceColors.groupedCanvas))
                    Circle().fill(badgeColor.opacity(0.1))
                }
                .overlay { Circle().strokeBorder(Color(uiColor: OathSurfaceColors.groupedCanvas), lineWidth: 3) }
                .offset(x: 4, y: 4)
        }
        .padding(4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(strings.invariant(holding.name))
        .accessibilityValue(strings.text(OathAssetHistoryFormatting.status(currentEntry.state)))
        .accessibilityIdentifier("transaction.assetLogo")
    }

    private var badgeColor: Color {
        switch badge.tone {
        case .neutral: Color(uiColor: .secondaryLabel)
        case .positive: .green
        case .warning: .orange
        case .negative: .red
        }
    }

    private var feeText: String {
        if balancesHidden { return "••••" }
        return OathAssetAmountFormat(locale: strings.language.locale, selectedCurrencyCode: currency)
            .fee(details?.feeFiatValue) ?? strings.text(.assetPriceUnavailable)
    }

    private func row(_ key: OathStringKey, _ value: String, isInvariant: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 20) {
            Text(strings.text(key)).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(isInvariant ? strings.invariant(value) : value).multilineTextAlignment(.trailing)
        }.oathFont(.body)
    }

    private func identifierRow(_ key: OathStringKey, _ value: String) -> some View {
        HStack(spacing: 12) {
            Text(strings.text(key)).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.8).layoutPriority(1)
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                Text(value).lineLimit(1).truncationMode(.middle)
                    .accessibilityLabel(value)
                OathButton {
                    OathClipboard.copy(value)
                    copiedKey = key
                } label: {
                    Image(systemName: copiedKey == key ? "checkmark" : "doc.on.doc")
                        .foregroundStyle(copiedKey == key ? OathOnboardingColors.blue : Color(uiColor: .label))
                        .font(.system(size: 17, weight: .regular))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(strings.text(key == .assetTransactionID || key == .transactionReplacement ? .assetCopyTransaction : .copyAddress))
                .accessibilityValue(copiedKey == key ? strings.text(.addressCopied) : "")
                .accessibilityIdentifier("transaction.copy.\(key.rawValue)")
            }
            .environment(\.layoutDirection, .leftToRight)
        }
        .oathFont(.body)
    }

    @MainActor private func exportImage() {
        // Render the entire receipt, even below the fold, without capturing
        // another window, the share menu, or any sensitive screen behind it.
        let imageContent = VStack(spacing: 0) {
            Text(strings.text(.assetTransaction)).oathFont(.headline, weight: .semibold)
                .frame(maxWidth: .infinity).padding(.vertical, 16)
            receipt(exporting: true)
        }
        .frame(width: max(320, min(contentWidth, 700)))
        .background(Color(uiColor: OathSurfaceColors.groupedCanvas))
        .environment(\.colorScheme, colorScheme)
        .environment(\.dynamicTypeSize, dynamicTypeSize)
        .oathLanguage(strings.language)
        let renderer = ImageRenderer(content: imageContent)
        renderer.scale = min(displayScale, 3)
        renderer.isOpaque = true
        guard let image = renderer.uiImage else {
            OathDiagnostics.record(DiagnosticFailure("Receipt image rendering failed"),
                component: "transaction_details", operation: "share_image", context: ["chain": entry.networkID])
            exportFailed = true
            return
        }
        share = OathTransactionSharePayload(items: [image])
    }
}

/// Terminal outcomes take precedence over transfer direction. Unknown states
/// remain pending instead of being presented as a completed transfer.
struct OathTransactionBadge: Equatable {
    enum Tone: Equatable { case neutral, positive, warning, negative }
    let symbol: String
    let tone: Tone

    init(state: String, direction: String) {
        switch state {
        case "failed": symbol = "exclamationmark"; tone = .negative
        case "canceled": symbol = "xmark"; tone = .neutral
        case "replaced": symbol = "arrow.triangle.2.circlepath"; tone = .warning
        case "reorged": symbol = "arrow.counterclockwise"; tone = .warning
        case "confirmed":
            switch direction {
            case "incoming": symbol = "arrow.down.left"; tone = .positive
            case "outgoing": symbol = "arrow.up.right"; tone = .neutral
            default: symbol = "arrow.left.arrow.right"; tone = .neutral
            }
        default: symbol = "clock"; tone = .neutral
        }
    }
}

private struct OathTransactionSharePayload: Identifiable {
    let id = UUID()
    let items: [Any]
}

enum OathAssetHistoryFormatting {
    static func title(_ entry: HistoryEntry, holding: Holding, strings: OathLocalizer) -> String {
        let symbol = holding.symbol.trimmingCharacters(in: .whitespacesAndNewlines)
        return strings.format(.transactionAssetTitle, strings.text(action(entry)),
                              strings.invariant(symbol.isEmpty ? holding.name : symbol))
    }

    private static func action(_ entry: HistoryEntry) -> OathStringKey {
        switch entry.state {
        case "canceled": .assetCanceled
        case "replaced": .assetReplaced
        case "failed": .assetFailed
        case "reorged": .assetReorged
        default: entry.direction == "incoming" ? .assetReceived : entry.direction == "outgoing" ? .assetSent : .assetSelfTransfer
        }
    }
    static func icon(_ entry: HistoryEntry) -> String {
        switch entry.state {
        case "canceled", "failed": "xmark"
        case "replaced": "arrow.triangle.2.circlepath"
        case "reorged": "clock"
        default: entry.direction == "incoming" ? "arrow.down.left" : entry.direction == "outgoing" ? "arrow.up.right" : "arrow.left.arrow.right"
        }
    }
    static func amount(_ entry: HistoryEntry, holding: Holding) -> String {
        var quantity = (try? AtomicAmount(entry.amountAtomic).units(decimals: holding.decimals)) ?? "0"
        if quantity.contains(".") {
            while quantity.last == "0" { quantity.removeLast() }
            if quantity.last == "." { quantity.removeLast() }
        }
        return sign(entry) + quantity + " " + holding.symbol
    }
    static func fiat(_ entry: HistoryEntry, holding: Holding, currency: String, locale: Locale) -> String? {
        guard let units = try? AtomicAmount(entry.amountAtomic).units(decimals: holding.decimals),
              let quantity = Decimal(string: units, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        if quantity == 0 { return Decimal.zero.formatted(.currency(code: currency).locale(locale)) }
        guard let price = holding.price, let rate = Decimal(string: price, locale: Locale(identifier: "en_US_POSIX")),
              let value = FiatConversion.multiply(quantity, rate) else { return nil }
        return sign(entry) + value.formatted(.currency(code: currency).locale(locale))
    }
    static func sign(_ entry: HistoryEntry) -> String {
        guard !["canceled", "replaced", "failed", "reorged"].contains(entry.state), entry.amountAtomic != "0" else { return "" }
        return entry.direction == "incoming" ? "+" : entry.direction == "outgoing" ? "−" : ""
    }
    static func status(_ state: String) -> OathStringKey {
        switch state {
        case "confirmed": .assetConfirmed
        case "failed": .assetFailed
        case "canceled": .assetCanceled
        case "replaced": .assetReplaced
        case "reorged": .assetReorged
        default: .assetPending
        }
    }
}
