import OathAnkr
import OathDiagnostics
import SwiftUI
import Charts
import OathDatabase
import OathMarketData
import OathNativeRefresh

struct OathAssetDetailScreen: View {
    let route: OathAssetRoute
    let session: OathWalletSession
    @Environment(\.oathLocalizer) private var strings
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model = OathAssetDetailModel()
    @State private var effects = OathHomeScrollEffects()
    @State private var sheet: Sheet?
    @State private var selectedTransaction: HistoryEntry?
    @State private var showsAllActivity = false
    @State private var chartExpanded = false
    private enum Sheet: Identifiable {
        case receive, send, information
        var id: String {
            switch self {
            case .receive: "receive"
            case .send: "send"
            case .information: "information"
            }
        }
    }
    private var holding: Holding {
        if let current = session.portfolio?.holdings.first(where: { $0.id == route.holding.id }) { return current }
        if route.holding.networkID == "solana",
           let activeAddress = session.portfolio?.holdings.first(where: {
               $0.accountID == route.holding.accountID && $0.reference == "native"
           })?.address, activeAddress != route.holding.address {
            return route.holding.withoutBalance(address: activeAddress)
        }
        return route.holding
    }
    private var asset: MarketAsset {
        MarketAsset(id: holding.assetID, networkID: holding.networkID, reference: holding.reference, decimals: holding.decimals)
    }
    private var currency: String { session.portfolio?.currency ?? "USD" }
    private var active: Bool { scenePhase == .active && session.isUnlocked && session.portfolio?.wallet.id == route.walletID }
    private var networkName: String { session.portfolio?.networks.first { $0.id == holding.networkID }?.name ?? holding.networkID }
    private var receiveAddress: OathWalletAddress? {
        guard let chain = OathImportChain(rawValue: holding.networkID) else { return nil }
        let path = session.portfolio?.accounts.first { $0.id == holding.accountID }?.derivationPath ?? ""
        return OathWalletAddress(chain: chain, address: holding.address, path: path,
            accountID: holding.accountID, assetID: holding.assetID,
            storedNetworkName: networkName, storedTicker: chain.ticker, storedLogo: chain.logoAsset)
    }

    private func refresh() async throws {
        // Quote/info/chart requests can run alongside the ledger update. The
        // common refresh owner handles cancellation and the result animation.
        async let market: Void = model.refresh(asset: asset, walletID: route.walletID,
                                               accountID: holding.accountID, force: true)
        do {
            if holding.usesUTXOLedger { try await session.refreshBitcoin() }
            else if holding.networkID == "tron" { try await session.refreshTron() }
            else if holding.networkID == "ton" { try await session.refreshTon() }
            else if holding.networkID == "aptos" { try await session.refreshAptos() }
            else if holding.networkID == "sui" { try await session.refreshSui() }
            else if holding.networkID == "thorchain" { try await session.refreshThorchain() }
            else if holding.networkID == "near" { try await session.refreshNear() }
            else if holding.networkID == "xrpl" { try await session.refreshXrpl() }
            else if holding.networkID == "stellar" { try await session.refreshStellar() }
            else if holding.networkID == "solana" { try await session.refreshSolana() }
            else if holding.networkID == "arc" { try await session.refreshArc() }
            else if let chain = IndexedEVMChain(rawValue: holding.networkID) { try await session.refreshIndexedEVM(chain) }
            else if holding.networkID == "hyperevm" { try await session.refreshHyperEVM() }
            else if holding.networkID == "robinhood" { try await session.refreshRobinhood() }
            else if AnkrSynchronizer.supports(networkID: holding.networkID) { try await session.refreshAnkr() }
            await market
            try Task.checkCancellation()
        } catch { OathDiagnostics.record(error);
            await market
            throw error
        }
    }

    var body: some View {
        GeometryReader { geometry in
            NativeRefreshScroll(identifier: "asset.scroll", tint: .white, indicator: .oathLogo,
                labels: NativeRefreshLabels(pull: strings.text(.pullToRefresh), refreshing: strings.text(.refreshing),
                    succeeded: strings.text(.refreshSucceeded), failed: strings.text(.refreshFailed)),
                isEnabled: active && !session.changingWallet,
                refreshIdentity: "\(route.walletID):\(holding.id):\(holding.address)",
                action: refresh, onFailure: {}, onScroll: { effects.update(origin: $0) },
                feedback: { event in
                    switch event {
                    case .started: OathHaptics.shared.play(.refresh)
                    case .succeeded: OathHaptics.shared.play(.success)
                    case .failed: OathHaptics.shared.play(.error)
                    }
                }) {
                OathHeaderScrollContent(viewportHeight: geometry.size.height, fillsViewport: model.history.isEmpty) {
                    summary.padding(.top, 18).padding(.bottom, 12)
                } content: {
                    OathEmptyStateLayout(centersContent: model.history.isEmpty) {
                        VStack(alignment: .leading, spacing: 28) {
                            market
                            Text(strings.text(.assetActivity)).oathFont(.title3, weight: .bold)
                                .accessibilityAddTraits(.isHeader)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 28)
                        activity.padding(.bottom, 28)
                        OathButton { sheet = .information } label: {
                            OathSettingsRow(title: strings.text(.assetInformation), icon: "info.circle",
                                subtitle: strings.text(.assetInformationDetail))
                        }
                        .buttonStyle(OathSettingsRowButtonStyle())
                        .padding(.horizontal, -20)
                        .accessibilityIdentifier("asset.informationRow")
                    }
                    .padding(.horizontal, 20).padding(.bottom, 40)
                    .frame(maxWidth: 700).frame(maxWidth: .infinity)
                }
            }
            .background {
                OathHomeHeaderSurface(effects: effects, animates: active && sheet == nil,
                                      colorHex: session.portfolio?.wallet.colorHex)
                    .ignoresSafeArea()
            }
        }
        .background(Color(uiColor: OathSurfaceColors.groupedCanvas).ignoresSafeArea())
        .navigationTitle(strings.invariant(holding.name))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarRole(.editor)
        .toolbar(.visible, for: .navigationBar)
        .toolbar(.hidden, for: .bottomBar, .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                OathButton { sheet = .information } label: { Image(systemName: "info.circle") }
                    .oathNeutralControl()
                    .accessibilityLabel(strings.text(.assetInformation))
                    .accessibilityIdentifier("asset.information")
            }
        }
        .navigationDestination(isPresented: Binding(get: { selectedTransaction != nil }, set: { if !$0 { selectedTransaction = nil } })) {
            if let selectedTransaction {
                OathTransactionDetailScreen(entry: model.history.first { $0.id == selectedTransaction.id } ?? selectedTransaction,
                    holding: holding, networkName: networkName, currency: currency, balancesHidden: session.balancesHidden)
            }
        }
        .navigationDestination(isPresented: $showsAllActivity) {
            OathChainActivityScreen(walletID: route.walletID, networkID: holding.networkID,
                networkName: networkName, accountID: holding.accountID, assetID: holding.assetID, session: session)
        }
        .oathNativeLocalization(onArtwork: !effects.usesScrolledStatusBar,
            navigationBackground: effects.usesScrolledStatusBar ? .visible : .hidden)
        .sheet(item: $sheet) { selection in
            Group {
                switch selection {
                case .receive:
                    if let receiveAddress { OathReceiveSheet(address: receiveAddress, session: session) }
                case .send: OathSendFlow(session: session, walletID: route.walletID, holdingID: holding.id)
                case .information:
                    OathAssetInformationSheet(holding: holding, networkName: networkName, currency: currency, model: model)
                }
            }.oathLanguage(strings.language)
        }
        // Keep Receive/Info mounted beneath the lock. Dismissing this sheet
        // on lock also dismisses UIKit's passcode presentation above it.
        .task(id: active) {
            guard active else { return }
            await model.observeHistory(walletID: route.walletID, accountID: holding.accountID, assetID: holding.assetID)
        }
        .task(id: active) {
            guard active else { return }
            await model.open(asset: asset, walletID: route.walletID, accountID: holding.accountID)
            // Only the visible asset refreshes, at a bounded frequency. No
            // account/balance RPCs are part of this screen's market-data service.
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                await model.updateQuote(asset)
            }
        }
        .accessibilityIdentifier("asset.detail")
    }

    private var summary: some View {
        VStack(spacing: 16) {
            OathAssetLogo(holding: holding, information: model.information?.value, size: 56)
            VStack(spacing: 6) {
                Text(session.balancesHidden ? "••••" : String(OathAssetAmountFormat(locale: strings.language.locale,
                    selectedCurrencyCode: currency).fiat(.init(native: holding.nativeDisplayValue ?? .zero,
                    fiat: holding.fiatDisplayValue ?? .zero, currencyCode: currency)).characters))
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                    .lineLimit(1).minimumScaleFactor(0.45).monospacedDigit()
                    .accessibilityIdentifier("asset.fiatBalance")
                Text(session.balancesHidden ? "••••" : strings.invariant(
                    (holding.nativeDisplayValue ?? .zero).formatted(.number.precision(.fractionLength(0...min(holding.decimals, 8))).locale(strings.language.locale)) + " " + holding.symbol))
                    .oathFont(.title3).foregroundStyle(.white.opacity(0.8)).monospacedDigit()
                    .accessibilityIdentifier("asset.balance")
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: OathActionMetrics.spacing) { send; receive }
                VStack(spacing: OathActionMetrics.spacing) { send; receive }
            }.padding(.top, 10).oathActionArea(existingInset: 20)
        }
        .foregroundStyle(.white).padding(.horizontal, 20)
        .frame(maxWidth: 700).frame(maxWidth: .infinity)
    }
    private var send: some View {
        OathActionButton(title: strings.text(.send), icon: "arrow.up.right", appearance: .secondary, foreground: .white) {
            sheet = .send
        }.accessibilityIdentifier("asset.send")
    }
    private var receive: some View {
        OathActionButton(title: strings.text(.receive), icon: "arrow.down.left", accent: .white, foreground: .black) {
            sheet = .receive
        }.disabled(receiveAddress == nil).accessibilityIdentifier("asset.receive")
    }

    private var market: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(strings.format(.assetPrice, strings.invariant(holding.symbol)))
                        .oathFont(.subheadline).foregroundStyle(.secondary)
                    if let price = displayQuote?.value {
                        Text(priceText(price)).oathFont(.title2, weight: .semibold).monospacedDigit()
                            .accessibilityIdentifier("asset.price")
                    } else if model.quoteLoading {
                        ProgressView().accessibilityLabel(strings.text(.assetMarketLoading))
                    } else {
                        Text(strings.text(.assetPriceUnavailable)).oathFont(.body).foregroundStyle(.secondary)
                            .accessibilityIdentifier("asset.priceUnavailable")
                    }
                }
                Spacer(minLength: 4)
                if let chart = availableChart {
                    OathButton {
                        withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) { chartExpanded.toggle() }
                    } label: {
                        VStack(alignment: .trailing, spacing: 7) {
                            if chart.isFresh(lifetime: 600), !model.chartFailed, let change = chart.value.changePercent {
                                Text(change.formatted(.number.sign(strategy: .always()).precision(.fractionLength(2))
                                    .locale(strings.language.locale)) + "%")
                                    .foregroundStyle(change < 0 ? Color.red : Color.green).monospacedDigit()
                            }
                            Label(strings.text(.assetChart24h), systemImage: chartExpanded ? "chevron.up" : "chevron.down")
                                .foregroundStyle(.secondary)
                        }.oathFont(.caption, weight: .medium).padding(.vertical, 8).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("asset.chartToggle")
                }
            }
            if let quote = displayQuote {
                Text(quote.date.formatted(.dateTime.month(.abbreviated).day().hour().minute().locale(strings.language.locale)))
                    .oathFont(.caption2).foregroundStyle(.secondary)
            }
            if chartExpanded { chartContent }
        }
        .padding(18)
        .background(Color(uiColor: OathSurfaceColors.field), in: .rect(cornerRadius: 26))
    }

    private var displayQuote: (value: Decimal, date: Date)? {
        if let quote = model.quote, let value = quote.value.decimal, quote.isFresh(lifetime: 120), !model.quoteFailed {
            return (value, quote.fetchedAt)
        }
        if let text = holding.usdPrice, let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")),
           value > 0, let date = holding.priceObservedAt {
            return (value, Date(timeIntervalSince1970: date))
        }
        if let quote = model.quote, let value = quote.value.decimal { return (value, quote.fetchedAt) }
        return nil
    }

    private var availableChart: CachedMarketValue<MarketChart>? {
        guard let chart = model.chart, chart.value.points.count >= 2 else { return nil }
        return chart
    }

    @ViewBuilder private var chartContent: some View {
        if let saved = availableChart {
            let points = saved.value.points
            let rate = conversionRate
            let minimum = (points.map(\.close).min() ?? 0) * rate
            let maximum = (points.map(\.close).max() ?? 1) * rate
            let inset = max((maximum - minimum) * 0.12, maximum * 0.001)
            Chart(points) { point in
                LineMark(x: .value(strings.text(.assetTime), Date(timeIntervalSince1970: point.time)),
                         y: .value(strings.text(.assetPriceLabel), point.close * rate))
                    .interpolationMethod(.linear).foregroundStyle(Color.accentColor).lineStyle(.init(lineWidth: 2))
            }
            .chartYScale(domain: max(0, minimum - inset)...(maximum + inset))
            .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) }
            .frame(height: 150).padding(.top, 12)
            // Time increases left to right in all languages; surrounding UI is RTL-aware.
            .environment(\.layoutDirection, .leftToRight)
            .accessibilityIdentifier("asset.chart")
            Text(strings.format(.assetChartCurrency, quoteCurrency)).oathFont(.caption2).foregroundStyle(.secondary)
        }
    }
    private var conversionRate: Double {
        guard currency != "USD", let rate = holding.exchangeRate.flatMap(Double.init), rate.isFinite, rate > 0 else { return 1 }
        return rate
    }
    private var quoteCurrency: String { currency == "USD" || holding.exchangeRate != nil ? currency : "USD" }
    private func priceText(_ usd: Decimal) -> String {
        let rate = holding.exchangeRate.flatMap { Decimal(string: $0, locale: Locale(identifier: "en_US_POSIX")) } ?? 1
        let converted = FiatConversion.multiply(usd, currency == "USD" ? 1 : rate) ?? usd
        return converted.formatted(.currency(code: quoteCurrency).precision(.fractionLength(2...8)).locale(strings.language.locale))
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: 16) {
            if model.history.isEmpty {
                if model.loadingHistory {
                    ProgressView().frame(maxWidth: .infinity).padding(24)
                } else {
                    let incomplete = model.historyFailed || session.portfolio?.accountSync.contains(where: {
                        $0.accountID == holding.accountID && $0.stream != "balances" && !$0.complete
                    }) == true
                    OathEmptyState(strings.text(incomplete ? .assetActivity : .assetActivityEmpty),
                        systemImage: "arrow.left.arrow.right", description: strings.text(.assetActivityEmptyDetail))
                        .accessibilityIdentifier("asset.activityEmpty")
                }
            } else {
                VStack(spacing: 0) {
                    OathActivityRows(items: model.history.prefix(5).map { ChainHistoryItem(entry: $0, holding: holding) },
                        currency: currency, balancesHidden: session.balancesHidden) { selectedTransaction = $0.entry }
                }.padding(.horizontal, -20)
            }
            if model.hasMoreHistory {
                OathButton { showsAllActivity = true } label: {
                    HStack {
                        Text(strings.text(.assetViewAllActivity))
                        Spacer()
                        Image(systemName: "chevron.forward").font(.system(size: 14, weight: .semibold))
                    }
                    .oathFont(.body, weight: .semibold)
                    .frame(minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                .accessibilityIdentifier("asset.activity.viewAll")
            }
        }
    }
}

struct OathAssetLogo: View {
    let holding: Holding
    let information: AssetInformation?
    var size: CGFloat = 56
    var body: some View {
        if holding.reference == "native" {
            OathNetworkLogo(asset: OathImportChain(rawValue: holding.networkID)?.logoAsset ?? holding.logo ?? "network-" + holding.networkID, size: size)
        } else {
            OathTokenLogo(source: information?.imageURL ?? holding.logo, symbol: holding.symbol, size: size, fallbackSource: holding.logo, identity: holding.artworkIdentity)
        }
    }
}
