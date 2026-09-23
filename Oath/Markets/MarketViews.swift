import SwiftUI
import Charts

struct WalletMarketsSection: View {
    let assets: [WalletAsset]
    @State private var store = MarketStore.shared
    @State private var sentiment = MarketSentimentStore.shared
    @State private var discovery = MarketDiscoveryStore.shared
    @Environment(\.scenePhase) private var scenePhase

    init(assets: [WalletAsset], store: MarketStore = .shared, discovery: MarketDiscoveryStore = .shared) {
        self.assets = assets
        _store = State(initialValue: store)
        _discovery = State(initialValue: discovery)
    }

    private var coins: [MarketCoin] {
        let catalog = store.catalog(assets: assets)
        let byID = Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, $0) })
        let changes = store.records.compactMapValues { record -> Double? in
            guard let quote = record.quote,
                  Date().timeIntervalSince(quote.changeUpdatedAt ?? quote.updatedAt) < 900
            else { return nil }
            return quote.change24h
        }
        return discovery.category.orderedIDs(candidates: catalog.map(\.id),
            changes: changes, trending: discovery.trending?.coins.map(\.id) ?? [],
            favorites: discovery.favorites.map(\.id)).compactMap { byID[$0] }
    }

    var body: some View {
        Section {
            ScrollView(.horizontal) {
                LazyHStack(spacing: 12) {
                    MarketSentimentCard(store: sentiment)
                    if coins.isEmpty {
                        VStack(spacing: 8) {
                            if discovery.isLoading && discovery.category == .trending {
                                ProgressView()
                            } else {
                                Image(systemName: discovery.category == .favorites ? "star" : "chart.line.uptrend.xyaxis")
                                Text(WalletLocalization.string(discovery.category == .favorites
                                    ? "markets.favorites.empty" : "markets.category.empty"))
                                    .font(.caption)
                                    .multilineTextAlignment(.center)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .modifier(MarketOverviewCardSurface())
                    }
                    ForEach(coins) { coin in
                        NavigationLink {
                            MarketDetailView(coin: coin, store: store, discovery: discovery)
                        } label: {
                            MarketCard(coin: coin, quote: store.records[coin.id]?.quote)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("markets.coin.\(coin.id)")
                    }
                }
                .padding(.vertical, 4)
            }
            .id(discovery.category)
            .scrollIndicators(.hidden)
            .contentMargins(.horizontal, 20, for: .scrollContent)
            .scrollClipDisabled()
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        } header: {
            HStack {
                NavigationLink {
                    AllMarketsView(assets: assets, store: store, discovery: discovery)
                } label: {
                    HStack(spacing: 6) {
                        Text(WalletLocalization.string("markets.title"))
                        Image(systemName: "chevron.forward")
                            .font(.caption.weight(.semibold))
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("home.markets")
                Spacer(minLength: 8)
                Menu {
                    Picker(WalletLocalization.string("markets.sort"), selection: $discovery.category) {
                        ForEach(MarketCategory.allCases) { category in
                            Text(WalletLocalization.string(category.localizationKey)).tag(category)
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(WalletLocalization.string(discovery.category.localizationKey))
                        Image(systemName: "chevron.down").font(.caption)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("markets.category")
            }
            .textCase(nil)
            .padding(.horizontal, 20)
        }
        .walletZeroHorizontalListSectionMargins()
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                async let mood: Void = sentiment.refresh()
                async let trends: Void = discovery.refresh()
                _ = await (mood, trends)
                do { try await Task.sleep(for: .seconds(60)) }
                catch { return }
            }
        }
        .task(id: "\(discovery.trending?.date.timeIntervalSince1970 ?? 0)|" + discovery.favorites.map(\.id).joined(separator: "|")) {
            await store.trackDiscovery(discovery)
        }
        .task(id: assets.map { AssetIdentityKey.canonical($0.id) }.sorted().joined(separator: "|")) {
            await store.trackVisibleAssets(assets)
        }
    }
}

struct AllMarketsView: View {
    let assets: [WalletAsset]
    let store: MarketStore
    @State private var discovery = MarketDiscoveryStore.shared
    @State private var search = ""
    @State private var sort = MarketListSort.catalog

    init(assets: [WalletAsset], store: MarketStore, discovery: MarketDiscoveryStore = .shared) {
        self.assets = assets
        self.store = store
        _discovery = State(initialValue: discovery)
    }

    private var coins: [MarketCoin] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = store.catalog(assets: assets).filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
                || $0.symbol.localizedCaseInsensitiveContains(query)
        }
        switch sort {
        case .catalog: return matches
        case .name: return matches.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .change, .losers, .favorites, .trending:
            let category: MarketCategory = switch sort {
            case .change: .gainers
            case .losers: .losers
            case .favorites: .favorites
            default: .trending
            }
            let byID = Dictionary(uniqueKeysWithValues: matches.map { ($0.id, $0) })
            let changes = store.records.compactMapValues { record -> Double? in
                guard let quote = record.quote,
                      Date().timeIntervalSince(quote.changeUpdatedAt ?? quote.updatedAt) < 900 else { return nil }
                return quote.change24h
            }
            return category.orderedIDs(candidates: matches.map(\.id), changes: changes,
                trending: discovery.trending?.coins.map(\.id) ?? [],
                favorites: discovery.favorites.map(\.id)).compactMap { byID[$0] }
        }
    }

    var body: some View {
        List {
            Group {
                Section {
                    ForEach(coins) { coin in
                        NavigationLink {
                            MarketDetailView(coin: coin, store: store, discovery: discovery)
                        } label: {
                            MarketListRow(coin: coin, quote: store.records[coin.id]?.quote)
                        }
                        .listRowBackground(WalletTheme.groupedSurface)
                        .accessibilityIdentifier("markets.all.\(coin.id)")
                    }
                } header: {
                    HStack {
                        Text(WalletLocalization.string("markets.all"))
                        Spacer()
                        Text(coins.count, format: .number)
                    }
                    .textCase(nil)
                }
            }
            .walletListRowSurface()
        }
        .walletListAppearance()
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(WalletTheme.groupedBackground)
        .navigationTitle(WalletLocalization.string("markets.title"))
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $search, prompt: Text(WalletLocalization.string("markets.search")))
        .overlay {
            if coins.isEmpty {
                if search.isEmpty {
                    ContentUnavailableView {
                        Label(WalletLocalization.string(sort == .favorites
                            ? "markets.category.favorites" : "markets.title"),
                            systemImage: sort == .favorites ? "star" : "chart.line.uptrend.xyaxis")
                    } description: {
                        Text(WalletLocalization.string(sort == .favorites
                            ? "markets.favorites.empty" : "markets.category.empty"))
                    }
                } else {
                    ContentUnavailableView.search(text: search)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker(WalletLocalization.string("markets.sort"), selection: $sort) {
                        ForEach(MarketListSort.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                } label: {
                    Label(WalletLocalization.string("markets.sort"), systemImage: "line.3.horizontal.decrease")
                }
            }
        }
        .accessibilityIdentifier("markets.all-screen")
    }
}

private enum MarketListSort: String, CaseIterable, Identifiable {
    case catalog = "markets.sort.default"
    case name = "markets.sort.name"
    case change = "markets.category.gainers"
    case trending = "markets.category.trending"
    case losers = "markets.category.losers"
    case favorites = "markets.category.favorites"
    var id: Self { self }
    var title: String {
        switch self {
        case .catalog: WalletLocalization.string("markets.sort.default")
        case .name: WalletLocalization.string("markets.sort.name")
        case .change: WalletLocalization.string("markets.category.gainers")
        case .trending: WalletLocalization.string("markets.category.trending")
        case .losers: WalletLocalization.string("markets.category.losers")
        case .favorites: WalletLocalization.string("markets.category.favorites")
        }
    }
}

/// Keep the native list sizing and separator guide, with a centered icon.
private struct MarketCenteredLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: 16) {
            configuration.icon
            configuration.title
                .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
        }
    }
}

private struct MarketListRow: View {
    let coin: MarketCoin
    let quote: MarketQuote?
    @Environment(\.walletCurrencyContext) private var currency
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Label {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 12) {
                        identity
                        valuation
                    }
                } else {
                    HStack(spacing: 14) {
                        identity
                        Spacer(minLength: 12)
                        valuation
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } icon: {
            MarketLogo(coin: coin, image: quote?.image)
        }
        .labelStyle(MarketCenteredLabelStyle())
        .foregroundStyle(WalletTheme.primaryLabel)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(coin.name).font(WalletTypography.listRowTitle).lineLimit(2)
            Text(coin.symbol).font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private var valuation: some View {
        VStack(alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .trailing, spacing: 4) {
            if let quote {
                Text(MarketDisplay.price(quote.price, currency: currency))
                    .font(.subheadline.weight(.semibold)).monospacedDigit()
                    .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .trailing)
                MarketChange(value: quote.change24h)
            } else {
                MarketShimmer().frame(width: 96, height: 18)
                MarketShimmer().frame(width: 56, height: 12)
            }
        }
    }
}


private struct MarketConverterCard: View {
    let coin: MarketCoin
    let quote: MarketQuote?
    @Environment(\.walletCurrencyContext) private var currency
    @State private var amount = "1"
    var editing: FocusState<Bool>.Binding
    @State private var fiatToCoin = false

    private var result: String {
        if fiatToCoin {
            guard let value = MarketConversion.coinValue(amount: amount, price: quote?.price, rate: currency.ratePerUSD) else {
                return EnglishNumbers.decimal(0, minimumFractionDigits: 2, maximumFractionDigits: 2) + " " + coin.symbol
            }
            return EnglishNumbers.decimal(value, maximumFractionDigits: 12) + " " + coin.symbol
        }
        guard let value = MarketConversion.localValue(amount: amount, price: quote?.price, rate: currency.ratePerUSD) else {
            return EnglishNumbers.currency(0, using: currency)
        }
        return EnglishNumbers.currency(value, currencyCode: currency.code)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(WalletLocalization.string("markets.converter")).font(.headline)
                Spacer()
                Button {
                    fiatToCoin.toggle()
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .walletSecondaryActionButtonStyle()
                .accessibilityLabel(WalletLocalization.string("markets.converter.swap"))
                .accessibilityIdentifier("markets.converter.swap")
            }
            HStack(spacing: 12) {
                if !fiatToCoin { MarketLogo(coin: coin, image: quote?.image) }
                Text(fiatToCoin ? currency.code : coin.symbol).font(.body.weight(.semibold))
                TextField("0", text: $amount)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .font(.title2.weight(.semibold)).monospacedDigit()
                    .focused(editing)
                    .accessibilityLabel(EnglishNumbers.localized("markets.converter.amount", fiatToCoin ? currency.code : coin.symbol))
                    .accessibilityIdentifier("markets.converter.amount")
                    .onChange(of: amount) { _, value in
                        let normalized = MarketConversion.sanitizedAmount(value)
                        if normalized != value { amount = normalized }
                    }
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text(fiatToCoin ? coin.symbol : currency.code).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Text(verbatim: result)
                    .font(.title2.weight(.semibold)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.5)
                    .contentTransition(.numericText())
                    .accessibilityIdentifier("markets.converter.result")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(WalletTheme.primaryLabel)
        .padding(18)
        .background(WalletTheme.groupedSurface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

private struct MarketLogo: View {
    let coin: MarketCoin
    let image: String?
    var size: CGFloat = 36
    var body: some View {
        if let network = coin.networks.first {
            AssetLogoView(source: .nativeCoin(blockchain: network), size: size)
        } else if let asset = coin.ownedAsset {
            AssetLogoView(source: asset.logoSource, size: size)
        } else {
            AsyncImage(url: (image ?? coin.discoveryImage).flatMap(URL.init(string:))) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                Text(String(coin.symbol.prefix(1))).font(.headline)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.accentColor.opacity(0.12))
            }
            .frame(width: size, height: size).clipShape(Circle())
        }
    }
}

private struct MarketOverviewCardSurface: ViewModifier {
    @ScaledMetric(relativeTo: .body) private var width = 126.0
    @ScaledMetric(relativeTo: .body) private var height = 126.0

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(width: width, height: height)
            .foregroundStyle(WalletTheme.primaryLabel)
            .background(WalletTheme.groupedSurface, in: RoundedRectangle(cornerRadius: 24))
    }
}

private struct MarketCard: View {
    let coin: MarketCoin
    let quote: MarketQuote?

    var body: some View {
        VStack(spacing: 10) {
            MarketLogo(coin: coin, image: quote?.image, size: 44)
            Text(coin.name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if let change = quote?.change24h, change.isFinite {
                Text(String(format: "%+.2f%%", change))
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(change < 0 ? Color.red : change > 0 ? Color.green : WalletTheme.secondaryLabel)
                    .accessibilityLabel(EnglishNumbers.localized("markets.change_accessibility", String(format: "%+.2f", change)))
            } else {
                Image(systemName: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text("wallet.asset.details.price.loading"))
            }
        }
        .modifier(MarketOverviewCardSurface())
        .accessibilityElement(children: .combine)
    }
}

private struct MarketSentimentCard: View {
    let store: MarketSentimentStore
    @State private var showsExplanation = false

    var body: some View {
        Button {
            showsExplanation = true
        } label: {
            VStack(spacing: 6) {
                Group {
                    if let reading = store.reading {
                        Gauge(value: Double(reading.value), in: 0...100) {
                            EmptyView()
                        } currentValueLabel: {
                            Text(reading.value, format: .number)
                                .foregroundStyle(WalletTheme.primaryLabel)
                        }
                        .gaugeStyle(.accessoryCircular)
                        .scaleEffect(0.75)
                        .frame(width: 44, height: 44)
                        .tint(Gradient(colors: [.red, .orange, .yellow, .green]))
                        .accessibilityLabel(Text("markets.sentiment.title"))
                        .accessibilityValue(Text("\(reading.value) / 100"))
                    } else if store.isLoading {
                        ProgressView()
                    } else {
                        Image(systemName: "gauge.with.needle")
                            .font(.title)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(height: 44)

                Text("markets.sentiment.title")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1).minimumScaleFactor(0.75)
                Text(WalletLocalization.string(store.reading?.classification.localizationKey ?? "markets.sentiment.unavailable"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.75)
            }
            .modifier(MarketOverviewCardSurface())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("markets.sentiment")
        .sheet(isPresented: $showsExplanation) {
            MarketSentimentExplanationSheet()
        }
    }
}

private struct MarketSentimentExplanationSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("markets.sentiment.title")
                        .font(.largeTitle.bold())
                        .accessibilityAddTraits(.isHeader)
                    Text("markets.sentiment.explanation")
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("markets.sentiment.source")
                        .font(.footnote)
                        .foregroundStyle(WalletTheme.secondaryLabel)
                }
                .foregroundStyle(WalletTheme.primaryLabel)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    WalletCloseButton { dismiss() }
                }
            }
        }
        .walletSheetPresentation()
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("markets.sentiment.explanation-sheet")
    }
}

private struct MarketChange: View {
    let value: Double?
    var body: some View {
        if let value {
            Label(String(format: "%.2f%%", abs(value)), systemImage: value < 0 ? "arrow.down.right" : "arrow.up.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(value < 0 ? Color.red : Color.green)
                .accessibilityLabel(EnglishNumbers.localized("markets.change_accessibility", String(format: "%+.2f", value)))
        }
    }
}

struct MarketDetailView: View {
    let coin: MarketCoin
    @State private var store = MarketStore.shared
    @State private var discovery = MarketDiscoveryStore.shared
    init(coin: MarketCoin, store: MarketStore = .shared, discovery: MarketDiscoveryStore = .shared) {
        self.coin = coin
        _store = State(initialValue: store)
        _discovery = State(initialValue: discovery)
    }

    @State private var range: MarketRange = .day
    @State private var selectedDate: Date?
    @FocusState private var converterEditing: Bool
    @State private var scrubFeedback = MarketScrubFeedback()
    @Environment(\.walletCurrencyContext) private var currency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var record: MarketRecord? { store.records[coin.id] }
    private var statistics: MarketQuote? { record?.statistics }
    private var history: MarketHistory? { record?.histories[range.rawValue] }
    private var points: [MarketPoint] { history?.points ?? [] }
    private var selected: MarketPoint? {
        guard let selectedDate else { return nil }
        return points.min { abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate)) }
    }
    private var chartColor: Color {
        guard let first = points.first, let last = points.last else { return .accentColor }
        return last.price >= first.price ? .green : .red
    }
    private var multiplier: Double { NSDecimalNumber(decimal: currency.ratePerUSD).doubleValue }
    private var priceDomain: ClosedRange<Double> {
        let prices = points.map { $0.price * multiplier }
        let low = prices.min() ?? 0
        let high = prices.max() ?? 1
        let padding = max((high - low) * 0.12, max(high * 0.001, 0.000001))
        return max(0, low - padding)...(high + padding)
    }

    private var axisDates: [Date] {
        guard let first = points.first?.date, let last = points.last?.date else { return [] }
        // Interior ticks leave room for labels on compact phone charts.
        return [0.2, 0.5, 0.8].map { first.addingTimeInterval(last.timeIntervalSince(first) * $0) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 12) {
                    MarketLogo(coin: coin, image: record?.quote?.image ?? statistics?.image)
                    Text(coin.name).font(.title2.bold())
                        .accessibilityIdentifier("markets.detail.\(coin.id)")
                    Spacer()
                    if let rank = record?.quote?.rank { Text("#\(rank)").font(.subheadline).foregroundStyle(.secondary) }
                }
                VStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        if let price = selected?.price ?? record?.quote?.price {
                            Text(MarketDisplay.price(price, currency: currency)).font(.largeTitle.bold()).monospacedDigit().minimumScaleFactor(0.5).lineLimit(1)
                        } else { MarketShimmer().frame(height: 40) }
                        if let selected {
                            Text(selected.date, format: .dateTime.month(.abbreviated).day().year().hour().minute()).font(.caption).foregroundStyle(.secondary)
                        } else {
                            HStack(spacing: 8) {
                                MarketChange(value: record?.quote?.change24h)
                                Text(WalletLocalization.string("markets.24h")).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.horizontal, 18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    chart
                    Picker(WalletLocalization.string("markets.range"), selection: $range) {
                        ForEach(MarketRange.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 18)
                    .onChange(of: range) {
                        selectedDate = nil
                        scrubFeedback.reset()
                    }
                }
                .padding(.vertical, 18)
                .background(WalletTheme.groupedSurface, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                MarketConverterCard(coin: coin, quote: record?.quote, editing: $converterEditing)
                if let quote = record?.quote {
                    VStack(spacing: 0) {
                        statistic(WalletLocalization.string("markets.cap"), statistics?.marketCap.map { MarketDisplay.compact($0, currency: currency) })
                        Divider()
                        statistic(WalletLocalization.string("markets.volume"), statistics?.volume.map { MarketDisplay.compact($0, currency: currency) })
                        Divider()
                        statistic(WalletLocalization.string("markets.high"), (quote.high24h ?? statistics?.high24h).map { MarketDisplay.price($0, currency: currency) })
                        Divider()
                        statistic(WalletLocalization.string("markets.low"), (quote.low24h ?? statistics?.low24h).map { MarketDisplay.price($0, currency: currency) })
                        Divider()
                        statistic(WalletLocalization.string("markets.supply"), statistics?.supply.map { $0.formatted(.number.notation(.compactName)) + " " + coin.symbol } ?? EnglishNumbers.decimal(0, minimumFractionDigits: 2, maximumFractionDigits: 2) + " " + coin.symbol)
                    }
                    .padding(.horizontal, 16)
                    .background(WalletTheme.groupedSurface, in: RoundedRectangle(cornerRadius: 24))

                }
                if let info = record?.info {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(EnglishNumbers.localized("markets.about", coin.name)).font(.title3.bold())
                        Text(info.description).font(.subheadline).textSelection(.enabled)
                        if let raw = info.website, let url = URL(string: raw), url.scheme == "https" {
                            Link(WalletLocalization.string("markets.website"), destination: url)
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(WalletTheme.groupedSurface, in: RoundedRectangle(cornerRadius: 24))
                }
            }
            .padding(20)
        }
        .background {
            // Extend the canvas through the keyboard safe area. A ShapeStyle
            // background only fills the container, exposing the hosting view
            // when the scroll view shrinks for the software keyboard.
            WalletTheme.groupedBackground.ignoresSafeArea()
        }
        .navigationTitle(coin.symbol)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    UniHaptic.play(.selection)
                    withAnimation(reduceMotion ? nil : .snappy) {
                        discovery.toggleFavorite(MarketDiscoveryCoin(id: coin.id, name: coin.name,
                            symbol: coin.symbol, image: record?.quote?.image ?? coin.discoveryImage))
                    }
                } label: {
                    Image(systemName: discovery.isFavorite(coin.id) ? "star.fill" : "star")
                        .contentTransition(.symbolEffect(.replace))
                }
                .accessibilityLabel(Text(WalletLocalization.string(discovery.isFavorite(coin.id)
                    ? "markets.favorite.remove" : "markets.favorite.add")))
                .accessibilityIdentifier("markets.favorite")
            }
        }
        .task(id: range) { await store.detail(coin, range: range) }
    }

    private var chart: some View {
        ZStack {
            chartContent
                .id(range)
                .transition(.opacity)
        }
        .frame(height: 240)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.5), value: points.count > 1)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.4), value: range)
    }

    @ViewBuilder private var chartContent: some View {
        if points.count > 1 {
            let domain = priceDomain
            Chart {
                ForEach(points) { point in
                    AreaMark(x: .value("Date", point.date), yStart: .value(currency.code, domain.lowerBound), yEnd: .value(currency.code, point.price * multiplier))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(LinearGradient(colors: [chartColor.opacity(0.22), chartColor.opacity(0.015)], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Date", point.date), y: .value(currency.code, point.price * multiplier))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(chartColor)
                        .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                }
                if let selected {
                    RuleMark(x: .value("Date", selected.date))
                        .foregroundStyle(chartColor.opacity(0.35))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                    PointMark(x: .value("Date", selected.date), y: .value(currency.code, selected.price * multiplier))
                        .symbolSize(140).foregroundStyle(WalletTheme.groupedSurface)
                    PointMark(x: .value("Date", selected.date), y: .value(currency.code, selected.price * multiplier))
                        .symbolSize(65).foregroundStyle(chartColor)
                }
            }
            .chartXScale(domain: points.first!.date...points.last!.date, range: .plotDimension(startPadding: 0, endPadding: 0))
            .chartYScale(domain: domain)
            .chartXSelection(value: $selectedDate)
            .chartGesture { proxy in
                DragGesture(minimumDistance: 0)
                    .onChanged { proxy.selectXValue(at: $0.location.x) }
                    .onEnded { _ in
                        selectedDate = nil
                        scrubFeedback.reset()
                    }
            }
            .onChange(of: selected?.id) { _, _ in
                guard let selected else { scrubFeedback.reset(); return }
                let low = points.map(\.price).min() ?? selected.price
                let high = points.map(\.price).max() ?? selected.price
                if let intensity = scrubFeedback.intensity(for: selected, span: high - low, endpoint: selected.id == points.first?.id || selected.id == points.last?.id, time: ProcessInfo.processInfo.systemUptime) {
                    UniHapticEngine.shared.playMarketScrub(intensity: intensity)
                }
            }
            .chartXAxis {
                AxisMarks(values: axisDates) { _ in
                    AxisValueLabel(format: range == .day ? .dateTime.hour().minute() : .dateTime.month(.abbreviated).day())
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 4]))
                        .foregroundStyle(.secondary.opacity(0.15))
                    AxisValueLabel().font(.caption2)
                }
            }
            .frame(height: 240)
            .padding(.trailing, 18)
            .accessibilityLabel(EnglishNumbers.localized("markets.chart_accessibility", coin.name, range.rawValue, currency.code))
            .transition(.opacity)
        } else {
            MarketChartLoadingView()
                .transition(.opacity)
        }
    }
    private func statistic(_ title: String, _ value: String?) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value ?? EnglishNumbers.currency(0, using: currency)).fontWeight(.medium).multilineTextAlignment(.trailing)
        }.font(.subheadline).padding(.vertical, 14)
    }
}

/// A decorative loading curve, kept separate from market data and chart selection.
private struct MarketChartLoadingView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || scenePhase != .active)) { context in
            let phase = reduceMotion ? 0.5 : context.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: 1.8) / 1.8

            GeometryReader { geometry in
                ZStack {
                    Path { path in
                        for fraction in [0.25, 0.65] {
                            let y = geometry.size.height * fraction
                            path.move(to: CGPoint(x: 0, y: y))
                            path.addLine(to: CGPoint(x: geometry.size.width, y: y))
                        }
                    }
                    .stroke(.secondary.opacity(0.10), style: StrokeStyle(lineWidth: 0.5, dash: [3, 5]))

                    MarketLoadingCurve(isArea: true)
                        .fill(LinearGradient(
                            colors: [.gray.opacity(0.15), .gray.opacity(0.015)],
                            startPoint: .top, endPoint: .bottom
                        ))

                    MarketLoadingCurve()
                        .stroke(.gray.opacity(0.38), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))

                    if !reduceMotion {
                        LinearGradient(
                            colors: [.clear, .white.opacity(colorScheme == .dark ? 0.55 : 0.95), .clear],
                            startPoint: .leading, endPoint: .trailing
                        )
                        .frame(width: geometry.size.width * 0.55)
                        .offset(x: geometry.size.width * (phase * 1.6 - 0.8))
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .mask {
                            MarketLoadingCurve()
                                .stroke(style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
                        }
                    }
                }
            }
        }
        // Keep the chart height steady, but let the loading curve span the full width.
        .padding(.bottom, 24)
        .frame(height: 240)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(WalletLocalization.string("markets.history_pending"))
    }
}

private struct MarketLoadingCurve: Shape {
    var isArea = false

    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        var path = Path()
        path.move(to: point(0, 0.66))
        path.addCurve(to: point(0.16, 0.59), control1: point(0.055, 0.72), control2: point(0.085, 0.43))
        path.addCurve(to: point(0.32, 0.43), control1: point(0.23, 0.76), control2: point(0.255, 0.31))
        path.addCurve(to: point(0.48, 0.51), control1: point(0.38, 0.54), control2: point(0.40, 0.65))
        path.addCurve(to: point(0.64, 0.34), control1: point(0.55, 0.25), control2: point(0.575, 0.48))
        path.addCurve(to: point(0.80, 0.28), control1: point(0.715, 0.17), control2: point(0.735, 0.46))
        path.addCurve(to: point(1, 0.24), control1: point(0.88, 0.12), control2: point(0.925, 0.32))
        if isArea {
            path.addLine(to: point(1, 1))
            path.addLine(to: point(0, 1))
            path.closeSubpath()
        }
        return path
    }
}

private struct MarketShimmer: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animate = false
    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(.secondary.opacity(0.10))
            .overlay {
                GeometryReader { geometry in
                    LinearGradient(colors: [.clear, .white.opacity(0.35), .clear], startPoint: .leading, endPoint: .trailing)
                        .offset(x: animate ? geometry.size.width : -geometry.size.width)
                }.clipped()
            }
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) { animate = true }
            }
            .accessibilityLabel(WalletLocalization.string("markets.pending"))
    }
}

private enum MarketDisplay {
    static func price(_ value: Double, currency: WalletCurrencyContext) -> String {
        let converted = value * NSDecimalNumber(decimal: currency.ratePerUSD).doubleValue
        return converted.formatted(.currency(code: currency.code).precision(.fractionLength(converted > 0 && converted < 0.01 ? 6 : 2)))
    }
    static func compact(_ value: Double, currency: WalletCurrencyContext) -> String {
        let converted = value * NSDecimalNumber(decimal: currency.ratePerUSD).doubleValue
        return currency.code + " " + converted.formatted(.number.notation(.compactName).precision(.fractionLength(0...2)))
    }
}
