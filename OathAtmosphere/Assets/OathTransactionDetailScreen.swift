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
    @State private var share: OathTransactionSharePayload?
    @State private var exportFailed = false
    @State private var contentWidth: CGFloat = 390
    @State private var tokenArtwork: ArtworkImage?

    private var currentEntry: HistoryEntry {
        if let projection = details?.swap { return projection.entry }
        if entry.direction == "swap" || entry.direction.hasPrefix("bridge"), let details {
            // A reorg or changed evidence can invalidate an open projection.
            // Immediately return to an actual underlying transfer.
            if let raw = details.historyEntries.first(where: { $0.assetID == holding.assetID })
                ?? details.historyEntries.first { return raw.updatingState(details.state) }
        }
        return details?.historyEntries.first(where: { $0.id == entry.id })
            ?? entry.updatingState(details?.state ?? entry.state)
    }

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

    }

    /// History and exported images use the same receipt.
    private func receipt(exporting: Bool = false) -> some View {
        let entry = currentEntry
        return OathTransactionReceiptContent(state: details?.state ?? entry.state, timestamp: details?.transaction.timestamp ?? entry.timestamp,
            networkName: networkName, fee: details?.transaction.feeAtomic == nil ? nil : feeText,
            fromAddresses: details?.fromAddresses ?? [], toAddresses: details?.toAddresses ?? [],
            replacement: details?.replacementHash, hash: details?.transaction.hash ?? entry.hash,
            confirmations: details?.confirmations, inputs: details?.inputs, outputs: details?.outputs,
            nativeSymbol: details?.feeAsset?.symbol ?? holding.symbol,
            nativeDecimals: details?.feeAsset?.decimals ?? holding.decimals,
            exporting: exporting, balancesHidden: balancesHidden) {
            if let swap = details?.swap, swap.outputHolding != nil {
                OathHistorySwapSummary(item: swap, balancesHidden: balancesHidden, isReceipt: true)
                    .padding(.horizontal, 20).padding(.vertical, 28)
            } else {
            OathTransactionReceiptHeader(title: OathAssetHistoryFormatting.title(entry, holding: holding, strings: strings),
                fiat: OathAssetHistoryFormatting.fiat(entry, holding: holding, currency: currency, locale: strings.language.locale),
                amount: OathAssetHistoryFormatting.amount(entry, holding: holding), balancesHidden: balancesHidden) {
                OathTransactionReceiptLogo(networkID: holding.networkID, reference: holding.reference,
                    name: holding.name, symbol: holding.symbol, source: holding.logo, identity: holding.artworkIdentity,
                    state: entry.state, direction: entry.direction, exporting: exporting, artwork: tokenArtwork,
                    onResolved: { tokenArtwork = $0 })
            }
            }
        } supplement: {
            if let bridge = details?.swap, bridge.bridgeProtocol != nil,
               let output = bridge.outputHolding, let hash = bridge.outputTransactionHash,
               let chain = OathImportChain(rawValue: output.networkID),
               let url = chain.transactionExplorerURL(hash: hash), output.networkID != self.entry.networkID {
                OathButton { openURL(url) } label: {
                    OathSettingsRow(title: strings.text(.assetTransaction), value: chain.name)
                }.buttonStyle(OathSettingsRowButtonStyle())
            }
            if let swapProgress {
                NavigationLink { OathWCThorchainProgress(initial: swapProgress) } label: {
                    OathSettingsRow(title: strings.text(.wcSwapProgress))
                }.buttonStyle(OathSettingsRowButtonStyle()).accessibilityIdentifier("transaction.swapProgress")
            }
        }
    }

    private var feeText: String {
        return OathAssetAmountFormat(locale: strings.language.locale, selectedCurrencyCode: currency)
            .fee(details?.feeFiatValue) ?? strings.text(.assetPriceUnavailable)
    }

    @MainActor private func exportImage() {
        // Render the entire receipt, even below the fold, without capturing
        // another window, the share menu, or any sensitive screen behind it.
        guard let image = OathTransactionReceiptExport.image(receipt(exporting: true), strings: strings,
            width: contentWidth, scale: displayScale, colorScheme: colorScheme, dynamicTypeSize: dynamicTypeSize) else {
            OathDiagnostics.record(DiagnosticFailure("Receipt image rendering failed"),
                component: "transaction_details", operation: "share_image", context: ["chain": entry.networkID])
            exportFailed = true
            return
        }
        share = OathTransactionSharePayload(items: [image])
    }
}

/// The receipt layout for transaction history. This view owns
/// copy feedback, typography, row order and accessibility for both entry points.
struct OathTransactionReceiptContent<Header: View, Supplement: View>: View {
    let state: String
    let timestamp: Double
    let networkName: String
    let fee: String?
    let fromAddresses: [String]
    let toAddresses: [String]
    let replacement: String?
    let hash: String
    var confirmations: Int64? = nil
    var inputs: [TransactionEndpoint]? = nil
    var outputs: [TransactionEndpoint]? = nil
    var nativeSymbol = ""
    var nativeDecimals = 8
    var exporting = false
    var balancesHidden = false
    @ViewBuilder let header: () -> Header
    @ViewBuilder let supplement: () -> Supplement
    @Environment(\.oathLocalizer) private var strings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var copiedKey: String?
    @State private var expandedInputs = false
    @State private var expandedOutputs = false
    @State private var selectedDataOutput: TransactionEndpoint?
    @ScaledMetric(relativeTo: .body) private var indentation = 28.0

    private var inputRows: [TransactionEndpoint] {
        inputs ?? fromAddresses.map { .init(id: $0, address: $0) }
    }
    private var outputRows: [TransactionEndpoint] {
        outputs ?? toAddresses.map { .init(id: $0, address: $0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header().padding(.horizontal, 20).padding(.bottom, 12)
            VStack(spacing: 0) {
                row(.transactionStatus, strings.text(OathAssetHistoryFormatting.status(state)))
                if timestamp > 0 {
                    row(.assetTime, Date(timeIntervalSince1970: timestamp).formatted(
                        .dateTime.day().month(.abbreviated).year().hour().minute().locale(strings.language.locale)))
                        .accessibilityIdentifier("transaction.time")
                }
                if let confirmations {
                    row(.transactionConfirmations, confirmations.formatted(.number.grouping(.never).locale(strings.language.locale)))
                        .accessibilityIdentifier("transaction.confirmations")
                }
                row(.tokenNetwork, strings.invariant(networkName))
                if !["canceled", "replaced", "reorged"].contains(state), let fee {
                    field(title: strings.text(.transactionNetworkFee)) {
                        Text(strings.invariant(fee)).foregroundStyle(.secondary)
                            .oathBalanceConcealed(balancesHidden)
                    }.accessibilityIdentifier("transaction.fee")
                }
            }
            OathSettingsSectionRule()
            VStack(spacing: 0) {
                addressGroup(isInput: true, rows: inputRows)
                addressGroup(isInput: false, rows: outputRows)
            }
            OathSettingsSectionRule()
            if let replacement { identifierRow(.transactionReplacement, replacement) }
            identifierRow(.assetTransactionID, hash)
            supplement()
        }
        .padding(.vertical, 20).frame(maxWidth: .infinity)
        .sheet(item: $selectedDataOutput) { endpoint in
            OathWalletSheet(title: .sendOnChainMessage) {
                if let output = endpoint.dataOutput {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(verbatim: "OP_RETURN").oathFont(.subheadline, weight: .semibold)
                        Text(verbatim: output.displayValue).oathFont(.body).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("transaction.output.fullMessage")
                    }.padding(.vertical, 12)
                }
            }.oathLanguage(strings.language)
        }
        .task(id: copiedKey) {
            guard copiedKey != nil else { return }
            do { try await Task.sleep(for: .seconds(2)); copiedKey = nil }
            catch is CancellationError { /* A new copy or dismissed receipt cancels feedback. */ }
            catch { OathDiagnostics.record(error, component: "transaction_details", operation: "copy_feedback") }
        }
    }

    private func row(_ key: OathStringKey, _ value: String) -> some View {
        field(title: strings.text(key)) {
            Text(value).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
    }

    private func field<Value: View>(title: String, @ViewBuilder value: @escaping () -> Value) -> some View {
        HStack(spacing: 12) {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    Text(title).foregroundStyle(.primary)
                    value()
                }
                Spacer(minLength: 0)
            } else {
                Text(title).foregroundStyle(.primary).layoutPriority(1)
                Spacer(minLength: 12)
                value()
            }
        }
        .oathFont(.body)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .frame(minHeight: 48)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func identifierRow(_ key: OathStringKey, _ value: String) -> some View {
        field(title: strings.text(key)) { copyValue(value, key: key.rawValue) }
    }

    private func copyValue(_ value: String, key: String, amount: String? = nil) -> some View {
        let copyID = key + ":" + value
        return HStack(spacing: 8) {
            VStack(alignment: .trailing, spacing: 4) {
                Text(value).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    .accessibilityLabel(value)
                if let amount {
                    Text(strings.invariant(amount))
                        .oathFont(.footnote).foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .oathBalanceConcealed(balancesHidden)
                }
            }
            OathButton {
                OathClipboard.copy(value)
                copiedKey = copyID
            } label: {
                Image(systemName: copiedKey == copyID ? "checkmark" : "doc.on.doc")
                    .foregroundStyle(copiedKey == copyID ? OathOnboardingColors.blue : Color(uiColor: .secondaryLabel))
                    .font(.system(size: 17, weight: .regular))
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(strings.text(key == OathStringKey.assetTransactionID.rawValue || key == OathStringKey.transactionReplacement.rawValue ? .assetCopyTransaction : .copyAddress))
            .accessibilityValue(copiedKey == copyID ? strings.text(.addressCopied) : "")
            .accessibilityIdentifier("transaction.copy.\(key)")
        }.environment(\.layoutDirection, .leftToRight)
    }

    @ViewBuilder private func addressGroup(isInput: Bool, rows: [TransactionEndpoint]) -> some View {
        let title: OathStringKey = inputs != nil || outputs != nil
            ? (isInput ? .transactionInputs : .transactionOutputs)
            : (isInput ? .transactionFrom : .transactionTo)
        let expanded = exporting || (isInput ? expandedInputs : expandedOutputs)
        let depth = isInput ? 0 : 1
        Group {
            if rows.count > 1 {
                OathButton {
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) {
                        if isInput { expandedInputs.toggle() } else { expandedOutputs.toggle() }
                    }
                } label: {
                    field(title: strings.text(title)) {
                        HStack(spacing: 8) {
                            // The label and number already use the app language.
                            // Do not extract a second, untranslated format key.
                            Text(verbatim: "\(strings.text(isInput ? .transactionMultipleSenders : .transactionMultipleRecipients)) (\(rows.count.formatted(.number.locale(strings.language.locale))))")
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                            Image(systemName: "chevron.forward")
                                .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                                .rotationEffect(.degrees(expanded ? 90 : 0))
                                .accessibilityHidden(true)
                        }
                    }
                }.buttonStyle(OathSettingsRowButtonStyle())
                    .accessibilityValue(expanded ? strings.text(.transactionExpanded) : strings.text(.transactionCollapsed))
                    .accessibilityIdentifier(isInput ? "transaction.inputs.expand" : "transaction.outputs.expand")
            } else if let endpoint = rows.first {
                endpointRow(endpoint, title: strings.text(title), key: isInput ? "input" : "output")
            } else {
                row(title, "—")
            }
        }
        .padding(.leading, CGFloat(depth) * indentation)
        .overlay {
            OathTransactionTreeBranch(depth: depth, indentation: indentation,
                continues: isInput, hasChildren: rows.count > 1 && expanded)
                .stroke(Color(uiColor: .separator), style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
                .allowsHitTesting(false).accessibilityHidden(true)
        }
        if rows.count > 1 && expanded {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, endpoint in
                endpointRow(endpoint, title: (index + 1).formatted(.number.locale(strings.language.locale)), key: "\(isInput ? "input" : "output").\(endpoint.id)")
                    .padding(.leading, CGFloat(depth + 1) * indentation)
                    .overlay {
                        OathTransactionTreeBranch(depth: depth + 1, indentation: indentation,
                            continues: index < rows.count - 1 || isInput, hasChildren: false)
                            .stroke(Color(uiColor: .separator), style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
            }
        }
    }

    private func endpointRow(_ endpoint: TransactionEndpoint, title: String, key: String) -> some View {
        let amount = endpoint.amountAtomic.flatMap { try? AtomicAmount($0).units(decimals: nativeDecimals) }
            .map { OathAssetAmountFormat.boundedUnits($0) + " " + nativeSymbol }
        return field(title: title) {
            if let output = endpoint.dataOutput {
                VStack(alignment: .trailing, spacing: 4) {
                    Text(verbatim: "OP_RETURN").oathFont(.subheadline, weight: .semibold)
                        .foregroundStyle(.secondary)
                    OathButton(feedback: .navigate) { selectedDataOutput = endpoint } label: {
                        Text(verbatim: output.displayValue)
                            .underline(pattern: .dot, color: .gray.opacity(0.65))
                            .oathFont(.body)
                            .lineLimit(2).truncationMode(.tail)
                            .multilineTextAlignment(.trailing)
                    }.buttonStyle(.plain).oathNeutralControl().disabled(exporting)
                        .accessibilityLabel(strings.text(.sendOnChainMessage))
                        .accessibilityValue(output.displayValue)
                        .accessibilityIdentifier("transaction.output.message.\(endpoint.id)")
                    if let amount {
                        Text(strings.invariant(amount))
                            .oathFont(.footnote).foregroundStyle(.secondary)
                            .oathBalanceConcealed(balancesHidden)
                    }
                }
            } else if let address = endpoint.address {
                copyValue(address, key: key, amount: amount)
            } else {
                VStack(alignment: .trailing, spacing: 4) {
                    Text(verbatim: "—").foregroundStyle(.secondary)
                    if let amount {
                        Text(strings.invariant(amount))
                            .oathFont(.footnote).foregroundStyle(.secondary)
                            .oathBalanceConcealed(balancesHidden)
                    }
                }
            }
        }
    }
}

/// Same rounded, semantic-direction connectors and indentation as the wallet
/// family list. Inputs are the root; outputs and expanded endpoints branch below.
private struct OathTransactionTreeBranch: Shape {
    let depth: Int
    let indentation: CGFloat
    let continues: Bool
    let hasChildren: Bool
    var layoutDirectionBehavior: LayoutDirectionBehavior { .mirrors }
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let x = rect.minX + 20 + CGFloat(max(0, depth - 1)) * indentation
        if depth > 0 {
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x, y: continues ? rect.maxY : rect.midY))
            path.move(to: CGPoint(x: x, y: rect.midY))
            path.addLine(to: CGPoint(x: x + indentation - 8, y: rect.midY))
        }
        if depth == 0 || hasChildren {
            let childX = rect.minX + 20 + CGFloat(depth) * indentation
            path.move(to: CGPoint(x: childX, y: rect.midY + 16))
            path.addLine(to: CGPoint(x: childX, y: rect.maxY))
        }
        return path
    }
}

struct OathTransactionReceiptHeader<Logo: View>: View {
    let title: String
    let fiat: String?
    let amount: String
    let balancesHidden: Bool
    @ViewBuilder let logo: () -> Logo
    @Environment(\.oathLocalizer) private var strings
    var body: some View {
        VStack(spacing: 14) {
            logo()
            Text(title).oathFont(.title2, weight: .semibold)
            Text(strings.invariant(fiat ?? strings.text(.assetPriceUnavailable)))
                .oathFont(.largeTitle, weight: .semibold).minimumScaleFactor(0.5).lineLimit(1)
                .oathBalanceConcealed(balancesHidden, radius: 16)
                .accessibilityIdentifier("transaction.amountFiat")
            Text(strings.invariant(amount))
                .oathFont(.body).foregroundStyle(.secondary)
                .oathBalanceConcealed(balancesHidden)
        }.frame(maxWidth: .infinity).padding(.vertical, 20)
    }
}

struct OathTransactionReceiptLogo: View {
    let networkID: String
    let reference: String
    let name: String
    let symbol: String
    let source: String?
    let identity: TokenArtworkIdentity?
    let state: String
    let direction: String
    var exporting = false
    var artwork: ArtworkImage?
    var onResolved: ((ArtworkImage) -> Void)? = nil
    @Environment(\.oathLocalizer) private var strings
    private var badge: OathTransactionBadge { .init(state: state, direction: direction) }
    private var badgeColor: Color {
        switch badge.tone {
        case .neutral: Color(uiColor: .secondaryLabel)
        case .positive: .green
        case .warning: .orange
        case .negative: .red
        }
    }
    var body: some View {
        Group {
            if reference == "native", let chain = OathImportChain(rawValue: networkID) {
                OathNetworkLogo(asset: chain.logoAsset, size: 72)
            } else if exporting {
                OathTokenLogoArtwork(artwork: artwork, symbol: symbol, size: 72, identity: identity)
            } else {
                OathTokenLogo(source: source, symbol: symbol, size: 72, identity: identity, onResolved: onResolved)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: badge.symbol)
                .font(.system(size: 13, weight: .bold)).foregroundStyle(badgeColor)
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
        .accessibilityLabel(strings.invariant(name))
        .accessibilityValue(strings.text(OathAssetHistoryFormatting.status(state)))
        .accessibilityIdentifier("transaction.assetLogo")
    }
}

struct OathReceiptField: View {
    let title: String
    let value: String
    var concealsValue = false
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) { Text(title).foregroundStyle(.secondary); Spacer(minLength: 16); Text(value).oathBalanceConcealed(concealsValue).multilineTextAlignment(.trailing) }
            VStack(alignment: .leading, spacing: 6) { Text(title).foregroundStyle(.secondary); Text(value).oathBalanceConcealed(concealsValue) }.frame(maxWidth: .infinity, alignment: .leading)
        }.accessibilityElement(children: .combine)
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

struct OathTransactionSharePayload: Identifiable {
    let id = UUID()
    let items: [Any]
}

@MainActor enum OathTransactionReceiptExport {
    static func image<Content: View>(_ receipt: Content, strings: OathLocalizer, width: CGFloat,
        scale: CGFloat, colorScheme: ColorScheme, dynamicTypeSize: DynamicTypeSize) -> UIImage? {
        let content = VStack(spacing: 0) {
            Text(strings.text(.assetTransaction)).oathFont(.headline, weight: .semibold)
                .frame(maxWidth: .infinity).padding(.vertical, 16)
            receipt
        }
        .frame(width: max(320, min(width, 700)))
        .background(Color(uiColor: OathSurfaceColors.groupedCanvas))
        .environment(\.colorScheme, colorScheme)
        .environment(\.dynamicTypeSize, dynamicTypeSize)
        .oathLanguage(strings.language)
        let renderer = ImageRenderer(content: content)
        renderer.scale = min(scale, 3)
        renderer.isOpaque = true
        return renderer.uiImage
    }
}

enum OathAssetHistoryFormatting {
    static func title(_ entry: HistoryEntry, holding: Holding, strings: OathLocalizer) -> String {
        switch entry.contractKind {
        case "approval": return strings.text(.historyTokenApproval)
        case "approvalRemoval": return strings.text(.historyApprovalRemoval)
        case "contractInteraction": return strings.text(.wcContractCall)
        default: break
        }
        let symbol = holding.symbol.trimmingCharacters(in: .whitespacesAndNewlines)
        return strings.format(.transactionAssetTitle, strings.text(action(entry)),
                                   strings.invariant(symbol.isEmpty ? holding.name : symbol))
    }

    private static func action(_ entry: HistoryEntry) -> OathStringKey {
        action(state: entry.state, direction: entry.direction)
    }
    static func action(state: String, direction: String) -> OathStringKey {
        switch state {
        case "canceled": .assetCanceled
        case "replaced": .assetReplaced
        case "failed": .assetFailed
        case "reorged": .assetReorged
        default: direction == "swap" ? .historySwap : ["incoming", "bridgeIncoming"].contains(direction) ? .assetReceived : ["outgoing", "bridgeOutgoing"].contains(direction) ? .assetSent : .assetSelfTransfer
        }
    }
    static func icon(_ entry: HistoryEntry) -> String {
        switch entry.state {
        case "canceled", "failed": "xmark"
        case "replaced": "arrow.triangle.2.circlepath"
        case "reorged": "clock"
        default: entry.displayDirection == "incoming" ? "arrow.down.left" : entry.displayDirection == "outgoing" ? "arrow.up.right" : "arrow.left.arrow.right"
        }
    }
    static func amount(_ entry: HistoryEntry, holding: Holding) -> String {
        guard let atomic = entry.displayAmountAtomic else { return "— " + holding.symbol }
        return amount(atomic: atomic, decimals: holding.decimals, symbol: holding.symbol,
               state: entry.state, direction: entry.displayDirection)
    }
    static func amount(atomic: String, decimals: Int, symbol: String, state: String, direction: String) -> String {
        let quantity = OathAssetAmountFormat.boundedUnits((try? AtomicAmount(atomic).units(decimals: decimals)) ?? "—")
        let prefix = sign(state: state, direction: direction, amount: atomic)
        if quantity.hasPrefix("< ") {
            return (prefix == "−" ? "> −" : "< " + prefix) + quantity.dropFirst(2) + " " + symbol
        }
        return prefix + quantity + " " + symbol
    }
    static func fiat(_ entry: HistoryEntry, holding: Holding, currency: String, locale: Locale) -> String? {
        guard let atomic = entry.displayAmountAtomic else { return nil }
        return fiat(atomic: atomic, decimals: holding.decimals, price: holding.price,
             state: entry.state, direction: entry.displayDirection, currency: currency, locale: locale)
    }
    static func fiat(atomic: String, decimals: Int, price: String?, state: String, direction: String, currency: String, locale: Locale) -> String? {
        guard let units = try? AtomicAmount(atomic).units(decimals: decimals),
              let quantity = Decimal(string: units, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        if quantity == 0 { return OathAssetAmountFormat(locale: locale, selectedCurrencyCode: currency).money(.zero) }
        guard let price, let rate = Decimal(string: price, locale: Locale(identifier: "en_US_POSIX")),
              let value = FiatConversion.multiply(quantity, rate) else { return nil }
        let prefix = sign(state: state, direction: direction, amount: atomic)
        return OathAssetAmountFormat(locale: locale, selectedCurrencyCode: currency)
            .money(prefix == "−" ? -value : value, signed: !prefix.isEmpty)
    }
    static func sign(_ entry: HistoryEntry) -> String {
        guard let atomic = entry.displayAmountAtomic else { return "" }
        return sign(state: entry.state, direction: entry.displayDirection, amount: atomic)
    }
    static func sign(state: String, direction: String, amount: String) -> String {
        guard !["canceled", "replaced", "failed", "reorged"].contains(state), amount != "0" else { return "" }
        return ["incoming", "bridgeIncoming"].contains(direction) ? "+" : ["outgoing", "bridgeOutgoing"].contains(direction) ? "−" : ""
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
