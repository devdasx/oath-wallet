import SwiftUI
import OathDatabase
import OathDiagnostics

struct OathChainActivityScreen: View {
    let walletID: String
    var networkID: String? = nil
    var networkName: String? = nil
    var accountID: String? = nil
    var assetID: String? = nil
    let session: OathWalletSession
    var query = ""
    var isVisible = true
    var filterSelection: Binding<OathHistoryFilterSelection>? = nil
    @State private var chainQuery = ""
    @State private var localFilters = OathHistoryFilterSelection()
    @State private var showsFilters = false
    @State private var pendingFilters: OathHistoryFilterSelection?
    @Environment(\.oathLocalizer) private var strings
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model = OathChainActivityModel()
    @State private var selected: ChainHistoryItem?
    @State private var headerHeight: CGFloat = 0

    init(walletID: String, networkID: String? = nil, networkName: String? = nil,
         accountID: String? = nil, assetID: String? = nil, session: OathWalletSession,
         query: String = "", isVisible: Bool = true,
         filterSelection: Binding<OathHistoryFilterSelection>? = nil) {
        self.walletID = walletID; self.networkID = networkID; self.networkName = networkName
        self.accountID = accountID; self.assetID = assetID; self.session = session
        self.query = query; self.isVisible = isVisible; self.filterSelection = filterSelection
        let seed = session.homeHistory
        let canSeed = networkID == nil && accountID == nil && assetID == nil && query.isEmpty
            && (filterSelection?.wrappedValue.activeCount ?? 0) == 0
            && seed?.walletID == walletID && seed?.currency == session.homePortfolio.currency
        _model = State(initialValue: OathChainActivityModel(seed: canSeed ? seed : nil))
    }

    private var filters: Binding<OathHistoryFilterSelection> { filterSelection ?? $localFilters }

    private var currency: String { session.portfolio?.currency ?? "USD" }
    private var active: Bool {
        isVisible && scenePhase == .active && session.isUnlocked && session.portfolio?.wallet.id == walletID
    }
    private var historyIsIncomplete: Bool {
        let accounts = Set((session.portfolio?.accounts ?? []).filter {
            (networkID == nil || $0.networkID == networkID) && (accountID == nil || $0.id == accountID)
        }.map(\.id))
        return session.portfolio?.accountSync.contains {
            accounts.contains($0.accountID) && $0.stream != "balances" && !$0.complete
        } == true
    }

    private var searchText: String { networkID == nil ? query : chainQuery }
    private var databaseQuery: String {
        let text = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let statuses: [(OathStringKey, String)] = [(.assetReceived, "incoming"), (.assetSent, "outgoing"),
            (.assetCanceled, "canceled"), (.assetFailed, "failed"), (.assetReplaced, "replaced"),
            (.assetPending, "pending"), (.assetConfirmed, "confirmed")]
        return statuses.first { strings.text($0.0).localizedCaseInsensitiveCompare(text) == .orderedSame }?.1 ?? text
    }

    var body: some View {
        if networkID != nil {
            activityContent.searchable(text: $chainQuery, prompt: Text(strings.text(.searchTransactions)))
        } else {
            activityContent
        }
    }

    private var activityContent: some View {
        GeometryReader { viewport in
            List {
                if networkName != nil || filters.wrappedValue.activeCount > 0 {
                    VStack(alignment: .leading, spacing: 12) {
                        if let networkName {
                            Text(strings.invariant(networkName))
                                .oathFont(.subheadline).foregroundStyle(.secondary)
                                .padding(.horizontal, 20)
                        }
                        if filters.wrappedValue.activeCount > 0 { activeFilters }
                    }
                    .padding(.vertical, 12)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
                    .listRowInsets(EdgeInsets()).listRowSeparator(.hidden).listRowBackground(Color.clear)
                }
                OathActivityRows(items: model.items, currency: model.displayCurrency,
                    balancesHidden: session.balancesHidden, identifier: "chain.transaction") { selected = $0 }
                    .listRowInsets(EdgeInsets()).listRowSeparator(.hidden).listRowBackground(Color.clear)
                if model.items.isEmpty {
                    emptyContent
                        .frame(minHeight: max(0, viewport.size.height - (networkName != nil || filters.wrappedValue.activeCount > 0 ? headerHeight : 0)))
                        .listRowInsets(EdgeInsets()).listRowSeparator(.hidden).listRowBackground(Color.clear)
                } else if model.loading || model.hasMore || model.failed {
                    pagingContent
                        .padding(.vertical, 20)
                        .listRowInsets(EdgeInsets()).listRowSeparator(.hidden).listRowBackground(Color.clear)
                }
            }
            .id(strings.language.isRightToLeft)
            .listStyle(.plain)
            .listRowSpacing(0)
            .contentMargins(.vertical, 0, for: .scrollContent)
            .scrollContentBackground(.hidden)
            .modifier(OathHomeScrollEdgeAppearance())
            // Stable activity IDs let the native list insert/remove only the
            // changed rows, including transitions to and from an empty result.
            .animation(reduceMotion ? nil : .default, value: model.items.map(\.id))
            .animation(reduceMotion ? nil : .default, value: filters.wrappedValue.activeCategories)
        }
        .background(Color(uiColor: OathSurfaceColors.groupedCanvas).ignoresSafeArea())
        .navigationTitle(strings.text(networkID == nil ? .historyTab : .assetActivity))
        .navigationBarTitleDisplayMode(networkID == nil ? .large : .inline)
        .toolbar(.visible, for: .navigationBar)
        .oathNativeLocalization(navigationMaterial: nil, systemNavigationAppearance: true)
        .toolbar(.hidden, for: .bottomBar)
        .toolbar(networkID == nil ? .visible : .hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { filterButton }
        }
        .sheet(isPresented: $showsFilters, onDismiss: {
            // Apply after the sheet is gone so the native list's diff is visible.
            // Cancel or interactive dismissal leaves the committed filter alone.
            if let pendingFilters { filters.wrappedValue = pendingFilters }
            pendingFilters = nil
        }) {
            OathHistoryFilterSheet(walletID: walletID, networkID: networkID, accountID: accountID, assetID: assetID,
                selection: filters.wrappedValue, locale: strings.language.locale) { pendingFilters = $0 }
                .oathLanguage(strings.language)
        }
        .oathHapticFeedback(.error, trigger: model.failed, when: model.failed)
        .oathHapticFeedback(.navigate, trigger: selected?.id, when: active)
        .accessibilityIdentifier("chain.activity")
        .navigationDestination(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
            if let selected {
                let current = model.items.first { $0.id == selected.id } ?? selected
                OathTransactionDetailScreen(entry: current.entry, holding: current.holding,
                    networkName: OathImportChain(rawValue: current.entry.networkID)?.name ?? current.entry.networkID, currency: model.displayCurrency, balancesHidden: session.balancesHidden)
            }
        }
        .task(id: OathHistoryObservationID(scope: "\(walletID):\(networkID ?? "all"):\(accountID ?? "all"):\(assetID ?? "all"):\(currency):\(active):\(model.limit):\(model.attempt):\(databaseQuery):\(strings.language.locale.identifier)", filter: filters.wrappedValue.resolved())) {
            guard active else { return }
            await OathDiagnostics.$chain.withValue(networkID) {
                await OathDiagnostics.$operationID.withValue(UUID()) {
                    await model.observe(walletID: walletID, networkID: networkID, accountID: accountID, assetID: assetID, currency: currency,
                                        query: databaseQuery, filter: filters.wrappedValue.resolved(), localeIdentifier: strings.language.locale.identifier)
                }
            }
        }
    }

    private var filterButton: some View {
        OathButton { showsFilters = true } label: {
            HStack(spacing: 5) {
                OathNavigationToolbarSymbol(filters.wrappedValue.activeCount == 0
                    ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
                if filters.wrappedValue.activeCount > 0 {
                    Text(strings.number(filters.wrappedValue.activeCount)).oathFont(.caption, weight: .semibold)
                }
            }
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(strings.text(.historyFilters))
        .accessibilityValue(strings.format(.historyActiveCount, strings.number(filters.wrappedValue.activeCount)))
        .accessibilityIdentifier("history.filters")
    }

    @ViewBuilder private var emptyContent: some View {
        if model.loading || model.failed {
            pagingContent
        } else if filters.wrappedValue.activeCount > 0 {
            OathEmptyState(title: strings.text(.historyNoResults), systemImage: "line.3.horizontal.decrease.circle",
                           description: strings.text(.historyNoResultsDetail)) {
                OathButton(strings.text(.historyResetFilters)) { filters.wrappedValue = .init() }
            }
        } else if !searchText.isEmpty {
            OathEmptyState(strings.text(.noSearchResults), systemImage: "magnifyingglass",
                           description: strings.format(.noSearchResultsDetail, searchText))
        } else {
            OathEmptyState(strings.text(historyIsIncomplete ? .historyTab : .assetActivityEmpty),
                systemImage: "clock.arrow.circlepath",
                description: strings.text(networkID == nil ? .historyEmptyDetail : .assetActivityEmptyDetail))
        }
    }

    @ViewBuilder private var pagingContent: some View {
        if model.loading {
            ProgressView().frame(maxWidth: .infinity).padding()
        } else if model.failed {
            OathButton(strings.text(.tryAgain)) { model.loadMoreOrRetry() }
                .oathFont(.body, weight: .semibold)
                .frame(maxWidth: .infinity, minHeight: 44)
                .accessibilityIdentifier("chain.activity.more")
        } else if model.hasMore {
            // List creates this footer as the user approaches the loaded end.
            // Loading replaces it until the next page arrives; the model also
            // guards duplicate requests. Failures require an explicit retry.
            ProgressView()
                .frame(maxWidth: .infinity).padding()
                .accessibilityIdentifier("chain.activity.loadingMore")
                .task(id: active) {
                    guard active, !model.failed, model.hasMore else { return }
                    model.loadMoreOrRetry()
                }
        }
    }

    private var activeFilters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(filters.wrappedValue.activeCategories, id: \.self) { category in
                    let title = filters.wrappedValue.title(category, strings: strings)
                    OathButton {
                        filters.wrappedValue.clear(category)
                    } label: {
                        HStack(spacing: 6) { Text(title); Image(systemName: "xmark").imageScale(.small) }
                            .oathFont(.caption, weight: .semibold)
                    }
                    .buttonStyle(.bordered).buttonBorderShape(.capsule)
                    .oathNeutralControl()
                    .accessibilityLabel(strings.format(.historyRemoveFilter, title))
                }
                OathButton(strings.text(.historyResetFilters)) { filters.wrappedValue = .init() }
                    .oathFont(.caption, weight: .semibold).frame(minHeight: 44)
                    .oathNeutralControl()
            }.padding(.horizontal, 20)
        }
    }
}

private struct OathHistoryObservationID: Hashable {
    let scope: String
    let filter: HistoryFilter
}

/// Both the five-row preview and full history use identical date groups,
/// typography, spacing, separators, amounts and transaction navigation.
struct OathActivityRows: View {
    let items: [ChainHistoryItem]
    let currency: String
    let balancesHidden: Bool
    var identifier = "asset.transaction"
    let onSelect: (ChainHistoryItem) -> Void
    @Environment(\.oathLocalizer) private var strings

    var body: some View {
        // No enclosing stack: full history exposes each stable transaction as
        // a native List row. The compact asset preview supplies its own stack.
        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
            let entry = item.entry
            let startsDay = index == 0 || !Calendar.current.isDate(Date(timeIntervalSince1970: entry.timestamp),
                inSameDayAs: Date(timeIntervalSince1970: items[index - 1].entry.timestamp))
            VStack(spacing: 0) {
                if startsDay && entry.timestamp > 0 {
                    Text(Date(timeIntervalSince1970: entry.timestamp).formatted(
                        .dateTime.day().month(.abbreviated).year().locale(strings.language.locale)))
                        .oathFont(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20).padding(.top, index == 0 ? 0 : 20).padding(.bottom, 8)
                        .accessibilityAddTraits(.isHeader)
                }
                OathButton { onSelect(item) } label: {
                    if item.outputHolding != nil, item.receivedAtomic != nil {
                        OathHistorySwapRow(item: item, currency: currency,
                            balancesHidden: balancesHidden, showsSeparator: !startsDay)
                    } else {
                    OathRefinedListRow(
                        title: OathAssetHistoryFormatting.title(entry, holding: item.holding, strings: strings),
                        subtitle: entry.timestamp > 0 ? Date(timeIntervalSince1970: entry.timestamp).formatted(.dateTime.hour().minute().locale(strings.language.locale)) : strings.text(.assetPending),
                        value: OathAssetHistoryFormatting.fiat(entry, holding: item.holding, currency: currency, locale: strings.language.locale) ?? strings.text(.assetPriceUnavailable),
                        detail: strings.invariant(OathAssetHistoryFormatting.amount(entry, holding: item.holding)),
                        showsSeparator: !startsDay,
                        concealsAmounts: balancesHidden
                    ) { size in
                        OathActivityAssetIcon(item: item, size: size)
                    }
                    }
                }
                .accessibilityHint(strings.invariant(item.holding.name + ", " +
                    (OathImportChain(rawValue: entry.networkID)?.name ?? entry.networkID)) + ", " +
                    strings.text(OathAssetHistoryFormatting.status(entry.state)))
                .buttonStyle(OathSettingsRowButtonStyle())
                .accessibilityIdentifier("\(identifier).\(entry.id)")
            }
            .frame(maxWidth: 700).frame(maxWidth: .infinity)
        }
    }
}

/// Asset identity remains visible; the overlaid symbol communicates the event.
private struct OathActivityAssetIcon: View {
    let item: ChainHistoryItem
    let size: CGFloat
    private var pending: Bool { item.entry.state == "pending" || item.entry.state == "reorged" }
    private var color: Color {
        switch item.entry.state {
        case "failed", "canceled": .red
        case "replaced": .secondary
        case "pending", "reorged": .orange
        default: item.entry.displayDirection == "incoming" ? .green : .primary
        }
    }
    var body: some View {
        Group {
            if item.holding.reference == "native", let chain = OathImportChain(rawValue: item.entry.networkID) {
                OathNetworkLogo(asset: chain.logoAsset, size: size)
            } else {
                OathAssetLogo(holding: item.holding, information: nil, size: size)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: pending ? "clock" : item.bridgeProtocol != nil ? "arrow.left.arrow.right" : OathAssetHistoryFormatting.icon(item.entry))
                .font(.system(size: size * 0.24, weight: .bold))
                .foregroundStyle(color)
                .frame(width: size * 0.46, height: size * 0.46)
                .background(Color(uiColor: OathSurfaceColors.groupedCanvas), in: Circle())
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                .offset(x: size * 0.05, y: size * 0.05)
        }
        .accessibilityHidden(true)
    }
}


/// Compact history uses the received asset and its own price/currency conversion.
/// The source amount remains available in the full transaction receipt.
private struct OathHistorySwapRow: View {
    let item: ChainHistoryItem
    let currency: String
    let balancesHidden: Bool
    let showsSeparator: Bool
    @Environment(\.oathLocalizer) private var strings

    var body: some View {
        if let output = item.outputHolding, let received = item.receivedAtomic {
            OathRefinedListRow(
                title: strings.text(item.bridgeProtocol == nil ? .historySwap : .historyBridge),
                subtitle: item.entry.timestamp > 0 ? Date(timeIntervalSince1970: item.entry.timestamp).formatted(
                    .dateTime.hour().minute().locale(strings.language.locale)) : strings.text(.assetPending),
                value: OathAssetHistoryFormatting.fiat(atomic: received, decimals: output.decimals,
                    price: output.price, state: item.entry.state, direction: "incoming",
                    currency: currency, locale: strings.language.locale) ?? strings.text(.assetPriceUnavailable),
                detail: strings.invariant(OathAssetHistoryFormatting.amount(atomic: received,
                    decimals: output.decimals, symbol: output.symbol, state: item.entry.state, direction: "incoming")),
                showsSeparator: showsSeparator,
                concealsAmounts: balancesHidden,
                customTitle: AnyView(OathHistorySwapTitle(item: item, output: output))
            ) { size in
                OathAssetLogo(holding: output, information: nil, size: size)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: item.bridgeProtocol == nil ? "arrow.triangle.2.circlepath" : "arrow.left.arrow.right")
                            .font(.system(size: size * 0.24, weight: .bold))
                            .foregroundStyle(.primary)
                            .frame(width: size * 0.46, height: size * 0.46)
                            .background(Color(uiColor: OathSurfaceColors.groupedCanvas), in: Circle())
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                            .offset(x: size * 0.05, y: size * 0.05)
                    }
            }
        }
    }
}

private struct OathHistorySwapTitle: View {
    let item: ChainHistoryItem
    let output: Holding
    @Environment(\.oathLocalizer) private var strings
    @ScaledMetric(relativeTo: .callout) private var badgeSize = 14.0

    var body: some View {
        HStack(spacing: 4) {
            Text(strings.text(item.bridgeProtocol == nil ? .historySwap : .historyBridge))
            badge(item.holding.networkID)
            Text(strings.invariant(item.holding.symbol))
            Image(systemName: "arrow.right").imageScale(.small).accessibilityHidden(true)
            badge(output.networkID)
            Text(strings.invariant(output.symbol))
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func badge(_ networkID: String) -> some View {
        if let chain = OathImportChain(rawValue: networkID) {
            OathNetworkLogo(asset: chain.logoAsset, size: badgeSize)
                .fixedSize().accessibilityLabel(chain.name)
        }
    }
}

/// Expanded executed-swap summary for the transaction receipt.
struct OathHistorySwapSummary: View {
    let item: ChainHistoryItem
    let balancesHidden: Bool
    var isReceipt = false
    @Environment(\.oathLocalizer) private var strings

    var body: some View {
        if let output = item.outputHolding, let received = item.receivedAtomic {
            VStack(alignment: isReceipt ? .center : .leading, spacing: 14) {
                HStack(spacing: 6) {
                    Text(strings.text(item.bridgeProtocol == nil ? .historySwap : .historyBridge))
                    badge(item.holding.networkID)
                    Text(strings.invariant(item.holding.symbol))
                    Image(systemName: "arrow.right").font(.caption)
                    badge(output.networkID)
                    Text(strings.invariant(output.symbol))
                }
                .oathFont(.body, weight: .semibold)
                .lineLimit(1).minimumScaleFactor(0.7)
                HStack(spacing: 12) {
                    leg(item.holding, atomic: item.entry.amountAtomic, direction: "outgoing")
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    leg(output, atomic: received, direction: "incoming")
                }
                if !isReceipt {
                    Text(Date(timeIntervalSince1970: item.entry.timestamp).formatted(
                        .dateTime.hour().minute().locale(strings.language.locale)))
                        .oathFont(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: isReceipt ? .center : .leading)
            .foregroundStyle(.primary)
        }
    }
    @ViewBuilder private func badge(_ networkID: String) -> some View {
        if let chain = OathImportChain(rawValue: networkID) {
            OathNetworkLogo(asset: chain.logoAsset, size: 16).accessibilityLabel(chain.name)
        }
    }
    private func leg(_ holding: Holding, atomic: String, direction: String) -> some View {
        VStack(spacing: 8) {
            OathAssetLogo(holding: holding, information: nil, size: isReceipt ? 56 : 32)
            Text(strings.invariant(OathAssetHistoryFormatting.amount(atomic: atomic,
                decimals: holding.decimals, symbol: holding.symbol, state: item.entry.state, direction: direction)))
                .oathFont(.subheadline, weight: .medium)
                .multilineTextAlignment(.center)
                .oathBalanceConcealed(balancesHidden)
        }.frame(maxWidth: .infinity)
    }
}
