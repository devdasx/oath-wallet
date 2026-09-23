import SwiftUI

struct NetworkFeeDashboardView: View {
    let database: WalletDatabase
    @State private var model: NetworkFeeDashboardModel
    @State private var search = ""
    @State private var preset = SendNetworkFeePreset.standard
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(database: WalletDatabase, repository: SendNetworkFeeQuoteRepository = .shared,
         priceLoader: NetworkFeeDashboardModel.PriceLoader? = nil) {
        self.database = database
        _model = State(initialValue: NetworkFeeDashboardModel(repository: repository, priceLoader: priceLoader))
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { timeline in
            let entries = model.entries(now: timeline.date, search: search)
            List {
                Group {
                    Section {
                        HStack(spacing: 12) {
                            Text("send.network_fee.option")
                                .foregroundStyle(WalletTheme.primaryLabel)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            Picker("send.network_fee.option", selection: $preset.hapticSelection()) {
                                ForEach([SendNetworkFeePreset.economy, .standard, .fastest], id: \.self) { option in
                                    Text(LocalizedStringKey(option.titleKey)).tag(option)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .tint(WalletTheme.accent)
                            .fixedSize()
                        }
                    }
                    Section {
                        ForEach(entries) { entry in
                            NavigationLink(value: WalletSettingsSearchRoute.networkFeeDetails(entry.id)) {
                                NetworkFeeDashboardRow(entry: entry, preset: preset,
                                                       nativeUnitUSDPrice: model.nativeUSDPrices[entry.id])
                            }
                        }
                        if entries.isEmpty {
                            WalletSearchEmptyStateView()
                        }
                    } header: {
                        Text("network_fees.networks")
                    } footer: {
                        Text("network_fees.footer")
                    }
                    if model.readFailed {
                        Section {
                            Text("network_fees.storage_error")
                                .foregroundStyle(WalletTheme.secondaryLabel)
                        }
                    }
                }
                .walletListRowSurface()
            }
            .walletListAppearance()
            .listStyle(.insetGrouped)
            .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: preset)
            .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: entries.map(\.id))
        }
        .navigationTitle("network_fees.title")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "network_fees.search")
        .refreshable { await model.refresh(database: database, force: true) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: UniHaptic.action {
                    Task { await model.refresh(database: database, force: true) }
                }) {
                    if model.isRefreshing {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(model.isRefreshing)
                .accessibilityLabel("network_fees.refresh")
            }
        }
        .task { await model.observe(database: database) }
        .task { await model.refresh(database: database) }
    }


}

private struct NetworkFeeDashboardRow: View {
    let entry: NetworkFeeDashboardEntry
    let preset: SendNetworkFeePreset
    let nativeUnitUSDPrice: Decimal?
    @Environment(\.dynamicTypeSize) private var textSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.walletCurrencyContext) private var currency

    var body: some View {
        if let tier = entry.quote.tier(for: preset) {
            row(tier: tier)
        }
    }

    private func row(tier: SendNetworkFeeTier) -> some View {
        let value = NetworkFeeDashboardValue(network: entry.network, tier: tier)
        let localValue = value.localCurrencyValue(nativeUnitUSDPrice: nativeUnitUSDPrice, using: currency) ?? "—"
        return HStack(alignment: .center, spacing: 12) {
            AssetLogoView(source: entry.network.logoSource, size: 38, animatesChanges: false)
                .accessibilityHidden(true)
            let layout = textSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
            layout {
                Text(LocalizedStringKey(entry.network.nameKey))
                    .font(.body)
                    .foregroundStyle(WalletTheme.primaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: textSize.isAccessibilitySize ? .leading : .trailing, spacing: 4) {
                    Text(verbatim: value.combined)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(WalletTheme.primaryLabel)
                        .contentTransition(.numericText())
                        .fixedSize(horizontal: false, vertical: true)
                    Text(verbatim: localValue)
                        .font(.caption)
                        .foregroundStyle(WalletTheme.secondaryLabel)
                        .contentTransition(.numericText())
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: tier)
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: localValue)
    }
}

struct NetworkFeeDetailsView: View {
    let database: WalletDatabase
    let networkID: String
    @State private var model: NetworkFeeDashboardModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.walletCurrencyContext) private var currency

    init(database: WalletDatabase, networkID: String, repository: SendNetworkFeeQuoteRepository = .shared,
         priceLoader: NetworkFeeDashboardModel.PriceLoader? = nil) {
        self.database = database
        self.networkID = networkID
        _model = State(initialValue: NetworkFeeDashboardModel(repository: repository, priceLoader: priceLoader))
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { timeline in
            if let entry = model.entries(now: timeline.date).first(where: { $0.id == networkID }) {
                List {
                    Group {
                        Section {
                            HStack(spacing: 16) {
                                AssetLogoView(source: entry.network.logoSource, size: 52, animatesChanges: false)
                                    .accessibilityHidden(true)
                                Text(LocalizedStringKey(entry.network.nameKey))
                                    .font(.title3.weight(.semibold))
                                    .foregroundStyle(WalletTheme.primaryLabel)
                            }
                        }
                        Section {
                            ForEach([SendNetworkFeePreset.economy, .standard, .fastest], id: \.self) { preset in
                                if let tier = entry.quote.tier(for: preset) {
                                    tierRow(tier, entry: entry)
                                }
                            }
                        } header: {
                            Text("network_fees.options")
                        } footer: {
                            Text("network_fees.explanation")
                        }
                    }
                    .walletListRowSurface()
                }
                .walletListAppearance()
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("network_fees.title")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.refresh(database: database, force: true) }
        .task { await model.observe(database: database) }
        .task { await model.refresh(database: database) }
    }

    private func tierRow(_ tier: SendNetworkFeeTier, entry: NetworkFeeDashboardEntry) -> some View {
        let value = NetworkFeeDashboardValue(network: entry.network, tier: tier)
        let localValue = value.localCurrencyValue(nativeUnitUSDPrice: model.nativeUSDPrices[entry.id], using: currency) ?? "—"
        let rate = Double(tier.primaryValue) ?? 0
        let maximum = entry.quote.tiers.compactMap { Double($0.primaryValue) }.max() ?? 0
        let fraction = maximum > 0 ? min(1, max(0, rate / maximum)) : 0
        return VStack(alignment: .leading, spacing: 10) {
            Text(LocalizedStringKey(tier.preset.titleKey))
                .font(.headline)
                .foregroundStyle(WalletTheme.primaryLabel)
            Text(verbatim: value.combined)
                .font(.title2.weight(.semibold))
                .foregroundStyle(WalletTheme.primaryLabel)
                .contentTransition(.numericText())
            Text(verbatim: localValue)
                .font(.caption)
                .foregroundStyle(WalletTheme.secondaryLabel)
                .contentTransition(.numericText())
                .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: localValue)
            ProgressView(value: fraction)
                .tint(WalletTheme.accent)
                .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: fraction)
                .accessibilityHidden(true)
            if let detail = value.detail {
                Text(verbatim: detail)
                    .font(.footnote)
                    .foregroundStyle(WalletTheme.secondaryLabel)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}
