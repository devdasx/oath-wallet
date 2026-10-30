import SwiftUI
import UIKit
import OathDatabase
import OathDiagnostics

extension PortfolioFilter.Sort {
    var title: OathStringKey {
        switch self {
        case .recommended: .assetFilterRecommended
        case .highestValue: .assetFilterHighestValue
        case .lowestValue: .assetFilterLowestValue
        case .nameAscending: .assetFilterNameAscending
        case .nameDescending: .assetFilterNameDescending
        case .mostActive: .assetFilterMostActive
        }
    }
}

extension PortfolioFilter.Kind {
    var title: OathStringKey {
        switch self {
        case .all: .assetFilterAllAssets
        case .coins: .assetFilterCoins
        case .tokens: .assetFilterTokens
        }
    }
}

/// Shared Settings rows with native controls. A local draft makes both the
/// close button and swipe-to-dismiss cancel without touching portfolio results.
/// Apply waits for durable storage. Empty matches, cancellation and invalid
/// ranges are expected UI states; only persistence failures are diagnostics.
struct OathAssetFilterSheet: View {
    let holdings: [Holding]
    let currency: String
    let onApply: (PortfolioFilter) async throws -> Void
    @State private var saving = false
    @State private var saveFailed = false
    @State private var draft: PortfolioFilter
    @State private var initialSelection: PortfolioFilter
    @State private var minimum: String
    @State private var maximum: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.oathLocalizer) private var strings

    init(holdings: [Holding], currency: String, selection: PortfolioFilter,
         onApply: @escaping (PortfolioFilter) async throws -> Void) {
        self.holdings = holdings; self.currency = currency; self.onApply = onApply
        let current = selection.adjusted(for: currency)
        _draft = State(initialValue: current)
        _initialSelection = State(initialValue: current)
        _minimum = State(initialValue: Self.input(current.minimumValue))
        _maximum = State(initialValue: Self.input(current.maximumValue))
    }

    private static func input(_ value: Decimal?) -> String {
        value.map { NSDecimalNumber(decimal: $0).stringValue
            .replacingOccurrences(of: ".", with: Locale.autoupdatingCurrent.decimalSeparator ?? ".") } ?? ""
    }

    private var validDraft: PortfolioFilter? {
        var result = draft
        let low = minimum.trimmingCharacters(in: .whitespacesAndNewlines)
        let high = maximum.trimmingCharacters(in: .whitespacesAndNewlines)
        result.minimumValue = low.isEmpty ? nil : PortfolioFilter.value(low, locale: .autoupdatingCurrent)
        result.maximumValue = high.isEmpty ? nil : PortfolioFilter.value(high, locale: .autoupdatingCurrent)
        result.rangeCurrency = low.isEmpty && high.isEmpty ? nil : currency
        guard low.isEmpty || result.minimumValue != nil,
              high.isEmpty || result.maximumValue != nil, result.isValid else { return nil }
        return result
    }

    private var networks: [OathImportChain] {
        Set(holdings.compactMap { OathImportChain(rawValue: $0.networkID) })
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var networkLabel: String {
        if draft.networkIDs.isEmpty { return strings.text(.assetFilterAllNetworks) }
        if draft.networkIDs.count == 1, let network = networks.first(where: { draft.networkIDs.contains($0.id) }) {
            return strings.invariant(network.name)
        }
        return strings.format(.historySelectedCount, strings.number(draft.networkIDs.count))
    }

    var body: some View {
        NavigationStack {
            OathAssetFilterSettingsPage {
                NavigationLink {
                    OathAssetFilterChoices(title: .assetFilterSort,
                        choices: PortfolioFilter.Sort.allCases, selection: $draft.sort, titleForChoice: { $0.title })
                } label: {
                    OathSettingsRow(title: strings.text(.assetFilterSort), icon: "arrow.up.arrow.down",
                                    value: strings.text(draft.sort.title))
                }
                .buttonStyle(OathSettingsRowButtonStyle())
                .accessibilityIdentifier("assets.filter.sort")
                NavigationLink {
                    OathAssetFilterChoices(title: .assetType,
                        choices: PortfolioFilter.Kind.allCases, selection: $draft.kind, titleForChoice: { $0.title })
                } label: {
                    OathSettingsRow(title: strings.text(.assetType), icon: "square.stack.3d.up",
                                    value: strings.text(draft.kind.title))
                }
                .buttonStyle(OathSettingsRowButtonStyle())
                .accessibilityIdentifier("assets.filter.kind")
                NavigationLink {
                    OathAssetNetworkFilter(networks: networks, selected: $draft.networkIDs)
                } label: {
                    OathSettingsRow(title: strings.text(.historyNetworks), icon: "network", value: networkLabel)
                }
                .buttonStyle(OathSettingsRowButtonStyle())
                .accessibilityIdentifier("assets.filter.networks")

                OathSettingsSectionRule()
                Toggle(isOn: $draft.groupsTokensByChain) {
                    OathSettingsRow(title: strings.text(.assetFilterGroupTokens), icon: "list.bullet.indent", accessory: .none)
                }
                .oathSwitchStyle()
                .padding(.trailing, 20)
                .accessibilityIdentifier("assets.filter.groupTokens")
                Toggle(isOn: $draft.hidesUnverifiedTokens) {
                    OathSettingsRow(title: strings.text(.assetFilterHideUnverified), icon: "checkmark.shield", accessory: .none)
                }
                .oathSwitchStyle()
                .padding(.trailing, 20)
                .accessibilityIdentifier("assets.filter.hideUnverified")
                Toggle(isOn: $draft.hidesZeroBalances) {
                    OathSettingsRow(title: strings.text(.assetFilterHideZero), icon: "eye.slash", accessory: .none)
                }
                .oathSwitchStyle()
                .padding(.trailing, 20)
                .accessibilityIdentifier("assets.filter.hideZero")
                Toggle(isOn: $draft.onlyWithActivity) {
                    OathSettingsRow(title: strings.text(.assetFilterWithActivity), icon: "clock.arrow.circlepath", accessory: .none)
                }
                .oathSwitchStyle()
                .padding(.trailing, 20)
                .accessibilityIdentifier("assets.filter.activity")
                OathSettingsFooter { Text(strings.text(.assetFilterBalanceDetail)) }

                OathSettingsSectionRule()
                OathSettingsFooter {
                    Text(strings.format(.assetFilterValueRange, currency))
                        .oathFont(.subheadline, weight: .semibold)
                }
                OathInputGroup {
                    valueField(.historyMinimum, text: $minimum, identifier: "assets.filter.minimum")
                    OathInputSeparator()
                    valueField(.historyMaximum, text: $maximum, identifier: "assets.filter.maximum")
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
                OathSettingsFooter {
                    Text(strings.text(.assetFilterValueDetail))
                    if validDraft == nil {
                        Text(strings.text(.historyInvalidRange)).foregroundStyle(.red)
                            .accessibilityIdentifier("assets.filter.invalid")
                    }
                }

                OathSettingsSectionRule()
                if saveFailed {
                    OathSettingsFooter {
                        Text(strings.text(.assetFilterSaveFailed)).foregroundStyle(.red)
                            .accessibilityIdentifier("assets.filter.saveError")
                    }
                }
                if let validDraft, validDraft.hidesUnverifiedTokens == initialSelection.hidesUnverifiedTokens {
                    OathSettingsRow(title: strings.text(.assetFilterMatches), icon: "line.3.horizontal.decrease",
                        value: strings.number(validDraft.applying(to: holdings, currency: currency,
                            locale: strings.language.locale).count), accessory: .none)
                        .accessibilityIdentifier("assets.filter.matches")
                }
                OathButton(feedback: .selection) {
                    draft = .init(); minimum = ""; maximum = ""
                } label: {
                    OathSettingsRow(title: strings.text(.historyResetFilters), icon: "arrow.counterclockwise", accessory: .none)
                }
                .buttonStyle(OathSettingsRowButtonStyle())
                .disabled(draft.activeCount == 0 && !draft.groupsTokensByChain && minimum.isEmpty && maximum.isEmpty)
                .accessibilityIdentifier("assets.filter.reset")
            }
            .disabled(saving)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(strings.text(.assetFilterTitle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    OathCloseButton { dismiss() }.disabled(saving).accessibilityIdentifier("assets.filter.close")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if saving { ProgressView() }
                    else {
                        OathDoneButton(label: .apply) {
                        guard let selection = validDraft, selection != initialSelection, !saving else { return }
                        saving = true; saveFailed = false
                        Task {
                            defer { saving = false }
                            do {
                                try await OathDiagnostics.$operationID.withValue(UUID()) { try await onApply(selection) }
                                dismiss()
                            } catch is CancellationError { }
                            catch {
                                OathDiagnostics.record(error, component: "asset_filters", operation: "save")
                                saveFailed = true
                            }
                        }
                        }
                        .disabled(validDraft == nil || validDraft == initialSelection)
                        .accessibilityIdentifier("assets.filter.apply")
                    }
                }
            }
            .onChange(of: currency) { _, value in
                draft = draft.adjusted(for: value)
                initialSelection = initialSelection.adjusted(for: value)
                minimum = ""; maximum = ""
            }
            .oathNativeLocalization()
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(saving)
        .presentationDragIndicator(.visible)
        .oathLanguage(strings.language)
    }

    private func valueField(_ title: OathStringKey, text: Binding<String>, identifier: String) -> some View {
        HStack {
            Text(strings.text(title)).fixedSize(horizontal: false, vertical: true)
            TextField(strings.text(.historyNoLimit), text: text)
                .multilineTextAlignment(.trailing)
                .keyboardType(.decimalPad)
                .accessibilityLabel(strings.format(.assetFilterValueLabel, strings.text(title), currency))
                .accessibilityIdentifier(identifier)
                .frame(minHeight: OathInputMetrics.minimumContentHeight)
        }
        .oathInputRow()
    }
}

/// Same canvas, row spacing and readable width as Settings, without Form cards.
private struct OathAssetFilterSettingsPage<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(spacing: 0, content: content)
                .padding(.vertical, 12)
                .frame(maxWidth: 700, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(Color(uiColor: OathSurfaceColors.canvas).ignoresSafeArea())
    }
}

private struct OathAssetFilterChoices<Choice: Hashable>: View {
    let title: OathStringKey
    let choices: [Choice]
    @Binding var selection: Choice
    let titleForChoice: (Choice) -> OathStringKey
    @Environment(\.dismiss) private var dismiss
    @Environment(\.oathLocalizer) private var strings

    var body: some View {
        OathAssetFilterSettingsPage {
            ForEach(choices, id: \.self) { choice in
                OathButton(feedback: .selection) { selection = choice; dismiss() } label: {
                    OathSettingsRow(title: strings.text(titleForChoice(choice)), accessory: .selection(selection == choice))
                }
                .buttonStyle(OathSettingsRowButtonStyle())
                .accessibilityAddTraits(selection == choice ? .isSelected : [])
            }
        }
        .navigationTitle(strings.text(title))
        .navigationBarTitleDisplayMode(.inline)
        .oathNativeLocalization()
    }
}

private struct OathAssetNetworkFilter: View {
    let networks: [OathImportChain]
    @Binding var selected: Set<String>
    @State private var query = ""
    @Environment(\.oathLocalizer) private var strings

    private var matches: [OathImportChain] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return networks.filter { query.isEmpty || $0.searchTerms.localizedStandardContains(query) }
    }

    var body: some View {
        List {
            OathButton(feedback: .selection) { selected.removeAll() } label: {
                OathSettingsRow(title: strings.text(.assetFilterAllNetworks), icon: "network",
                                accessory: .selection(selected.isEmpty))
            }
            .buttonStyle(OathSettingsRowButtonStyle())
            .accessibilityAddTraits(selected.isEmpty ? .isSelected : [])
            .accessibilityIdentifier("assets.filter.network.all")
            .listRowInsets(EdgeInsets()).listRowSeparator(.hidden).listRowBackground(Color.clear)
            OathSettingsListSectionRule()
            ForEach(matches) { network in
                OathButton(feedback: .selection) {
                    if selected.contains(network.id) { selected.remove(network.id) }
                    else { selected.insert(network.id) }
                    if selected == Set(networks.map(\.id)) { selected.removeAll() }
                } label: {
                    OathSettingsRow(title: strings.invariant(network.name),
                                    accessory: .selection(selected.contains(network.id)), networkLogo: network.logoAsset)
                }
                .buttonStyle(OathSettingsRowButtonStyle())
                .accessibilityAddTraits(selected.contains(network.id) ? .isSelected : [])
                .accessibilityIdentifier("assets.filter.network.\(network.id)")
                .listRowInsets(EdgeInsets()).listRowSeparator(.hidden).listRowBackground(Color.clear)
            }
        }
        .id(strings.language.isRightToLeft)
        .listStyle(.plain).scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 0)
        .background(Color(uiColor: OathSurfaceColors.canvas).ignoresSafeArea())
        .scrollDismissesKeyboard(.interactively)
        .overlay {
            if matches.isEmpty && !query.isEmpty {
                OathEmptyState(strings.text(.noSearchResults), systemImage: "magnifyingglass",
                               description: strings.format(.noSearchResultsDetail, query))
                    .allowsHitTesting(false)
            }
        }
        .navigationTitle(strings.text(.historyNetworks))
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: Text(strings.text(.assetFilterSearchNetworks)))
        .oathNativeLocalization()
    }
}

/// An embedded native toolbar for the Assets panel. UIKit owns bar-item
/// layout, glass, hit targets and the filter badge; no nested navigation stack.
struct OathAssetsToolbar: UIViewRepresentable {
    let activeCount: Int
    let isEnabled: Bool
    let action: () -> Void
    @Environment(\.oathLocalizer) private var strings
    @ScaledMetric(relativeTo: .headline) private var barHeight = 44.0

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIToolbar {
        let bar = UIToolbar()
        // The panel supplies the same 20-point inset as the asset rows.
        // Do not add a second set of native toolbar edge margins.
        bar.preservesSuperviewLayoutMargins = false
        bar.insetsLayoutMarginsFromSafeArea = false
        bar.directionalLayoutMargins = .zero
        bar.tintColor = .label
        bar.accessibilityIdentifier = "home.assetsToolbar"
        if #available(iOS 26, *) {
            context.coordinator.title.hidesSharedBackground = true
        } else {
            let appearance = UIToolbarAppearance()
            appearance.configureWithTransparentBackground()
            bar.standardAppearance = appearance
            bar.scrollEdgeAppearance = appearance
        }
        if #available(iOS 27, *) {
            context.coordinator.title.isPaddingRemoved = true
        }
        bar.setItems([context.coordinator.title, .flexibleSpace(), context.coordinator.filter], animated: false)
        return bar
    }

    func updateUIView(_ bar: UIToolbar, context: Context) {
        context.coordinator.update(bar, strings: strings, activeCount: activeCount, isEnabled: isEnabled, action: action)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIToolbar, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? uiView.sizeThatFits(.zero).width, height: barHeight)
    }

    @MainActor final class Coordinator {
        let heading = UILabel()
        let title: UIBarButtonItem
        let filter = UIBarButtonItem(image: UIImage(systemName: "line.3.horizontal.decrease"), style: .plain, target: nil, action: nil)
        var action: (() -> Void)?
        var badgeText: String?

        func update(_ bar: UIToolbar, strings: OathLocalizer, activeCount: Int, isEnabled: Bool, action: @escaping () -> Void) {
            self.action = action
            OathLayoutDirection.apply(strings.language, to: bar)
            let heading = strings.text(.assets)
            let font = strings.language == .arabic
                ? OathArabicFont.semibold.uiFont(size: 17, relativeTo: .headline)
                : UIFont.preferredFont(forTextStyle: .headline)
            // UIKit lays out this custom view inside a SwiftUI list. Resizing it or
            // replacing an equal badge on every update feeds another layout back
            // into that list, which can keep the main run loop busy indefinitely.
            if self.heading.text != heading || self.heading.font != font {
                self.heading.text = heading
                self.heading.font = font
                self.heading.sizeToFit()
            }
            if self.filter.isEnabled != isEnabled { self.filter.isEnabled = isEnabled }
            let label = strings.text(.assetFilterTitle)
            let value = strings.format(.historyActiveCount, strings.number(activeCount))
            if self.filter.accessibilityLabel != label { self.filter.accessibilityLabel = label }
            if self.filter.accessibilityValue != value { self.filter.accessibilityValue = value }
            let badgeText = activeCount > 0 ? strings.number(activeCount) : nil
            if self.badgeText != badgeText {
                self.badgeText = badgeText
                if #available(iOS 26, *) {
                    self.filter.badge = badgeText.map { .string($0) }
                } else {
                    self.filter.title = badgeText
                }
            }
        }

        init() {
            // A native heading label avoids the internal padding and button
            // accessibility semantics of an actionless bar button.
            heading.textColor = .label
            heading.directionalLayoutMargins = .zero
            heading.adjustsFontForContentSizeCategory = true
            heading.accessibilityTraits = .header
            title = UIBarButtonItem(customView: heading)
            filter.accessibilityIdentifier = "home.assetFilters"
            filter.primaryAction = UIAction { [weak self] _ in
                guard let self, self.filter.isEnabled, let action = self.action else { return }
                OathHaptics.shared.perform(.tap, action: action)
            }
        }
    }
}
