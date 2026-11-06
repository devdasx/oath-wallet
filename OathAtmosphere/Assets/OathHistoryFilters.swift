import OathDiagnostics
import SwiftUI
import OathDatabase

struct OathHistoryFilterSelection: Hashable {
    enum Category: CaseIterable { case networks, assets, direction, status, date, amount }
    enum Period: String, CaseIterable {
        case anytime, today, week, month, custom
        var title: OathStringKey {
            switch self {
            case .anytime: .historyAnytime
            case .today: .historyToday
            case .week: .historyWeek
            case .month: .historyMonth
            case .custom: .historyCustomDates
            }
        }
    }
    var values = HistoryFilter()
    var period: Period = .anytime
    var customStart = Calendar.current.startOfDay(for: Date())
    var customEnd = Date()

    var activeCount: Int {
        activeCategories.count
    }

    var activeCategories: [Category] {
        Category.allCases.filter {
            switch $0 {
            case .networks: !values.networkIDs.isEmpty
            case .assets: !values.assetIDs.isEmpty
            case .direction: !values.directions.isEmpty
            case .status: !values.statuses.isEmpty
            case .date: period != .anytime
            case .amount: values.minimumAmount != nil || values.maximumAmount != nil
            }
        }
    }

    mutating func clear(_ category: Category) {
        switch category {
        case .networks: values.networkIDs = []
        case .assets: values.assetIDs = []
        case .direction: values.directions = []
        case .status: values.statuses = []
        case .date: period = .anytime
        case .amount: values.minimumAmount = nil; values.maximumAmount = nil
        }
    }

    func title(_ category: Category, strings: OathLocalizer) -> String {
        switch category {
        case .networks: strings.text(.historyNetworks) + " · " + strings.number(values.networkIDs.count)
        case .assets: strings.text(.assets) + " · " + strings.number(values.assetIDs.count)
        case .direction: values.directions.count == 1 ? strings.text(values.directions.first!.title) : strings.text(.historyType)
        case .status: values.statuses.count == 1 ? strings.text(values.statuses.first!.title) : strings.text(.transactionStatus)
        case .date: strings.text(period.title)
        case .amount: strings.text(.historyAmount)
        }
    }

    func resolved(now: Date = Date(), calendar: Calendar = .current) -> HistoryFilter {
        var filter = values
        let today = calendar.startOfDay(for: now)
        switch period {
        case .anytime: filter.startDate = nil; filter.endDate = nil
        case .today, .week, .month:
            let days = period == .week ? 6 : period == .month ? 29 : 0
            filter.startDate = calendar.date(byAdding: .day, value: -days, to: today)
            filter.endDate = calendar.date(byAdding: .day, value: 1, to: today)
        case .custom:
            filter.startDate = calendar.startOfDay(for: customStart)
            filter.endDate = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: customEnd))
        }
        return filter
    }
}

extension HistoryFilter.Direction {
    var title: OathStringKey {
        switch self { case .incoming: .assetReceived; case .outgoing: .assetSent; case .self: .assetSelfTransfer; case .swap: .historySwap }
    }
}

extension HistoryFilter.Status {
    var title: OathStringKey { OathAssetHistoryFormatting.status(rawValue) }
}

/// A draft belongs to the sheet. Close/interactive dismissal never changes
/// the results; Apply commits the complete selection in one state update.
struct OathHistoryFilterSheet: View {
    let walletID: String
    let networkID: String?
    let accountID: String?
    let assetID: String?
    let onApply: (OathHistoryFilterSelection) -> Void
    @State private var initialSelection: OathHistoryFilterSelection
    @State private var draft: OathHistoryFilterSelection
    @State private var minimum: String
    @State private var maximum: String
    @State private var options: [HistoryFilterAsset] = []
    @State private var loading = true
    @State private var failed = false
    @State private var attempt = 0
    @State private var pickerPath: [PickerDestination] = []
    private enum PickerDestination: Hashable { case networks, assets }
    @Environment(\.dismiss) private var dismiss
    @Environment(\.oathLocalizer) private var strings

    init(walletID: String, networkID: String?, accountID: String?, assetID: String?,
         selection: OathHistoryFilterSelection, locale: Locale,
         onApply: @escaping (OathHistoryFilterSelection) -> Void) {
        self.walletID = walletID; self.networkID = networkID; self.accountID = accountID; self.assetID = assetID
        self.onApply = onApply
        _initialSelection = State(initialValue: selection)
        _draft = State(initialValue: selection)
        _minimum = State(initialValue: (selection.values.minimumAmount ?? "").replacingOccurrences(of: ".", with: locale.decimalSeparator ?? "."))
        _maximum = State(initialValue: (selection.values.maximumAmount ?? "").replacingOccurrences(of: ".", with: locale.decimalSeparator ?? "."))
    }

    private var validDraft: OathHistoryFilterSelection? {
        var result = draft
        let low = minimum.trimmingCharacters(in: .whitespacesAndNewlines)
        let high = maximum.trimmingCharacters(in: .whitespacesAndNewlines)
        result.values.minimumAmount = low.isEmpty ? nil : HistoryFilter.canonicalAmount(low, locale: strings.language.locale)
        result.values.maximumAmount = high.isEmpty ? nil : HistoryFilter.canonicalAmount(high, locale: strings.language.locale)
        guard low.isEmpty || result.values.minimumAmount != nil,
              high.isEmpty || result.values.maximumAmount != nil,
              result.resolved().isValid else { return nil }
        return result
    }

    private var changedDraft: OathHistoryFilterSelection? {
        guard let candidate = validDraft else { return nil }
        // Resolve both at the same instant. Unused custom dates and Reset's
        // newly initialized dates must not make unchanged filters look edited.
        let now = Date()
        guard candidate.period != initialSelection.period
            || candidate.resolved(now: now) != initialSelection.resolved(now: now) else { return nil }
        return candidate
    }

    var body: some View {
        NavigationStack(path: $pickerPath) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(strings.text(.historyFilterDetail))
                        .oathFont(.subheadline).foregroundStyle(.secondary)
                        .padding(20)
                    if assetID == nil {
                        if networkID == nil {
                            NavigationLink(value: PickerDestination.networks) {
                                OathSettingsRow(title: strings.text(.historyNetworks), icon: "globe",
                                    value: selectionText(draft.values.networkIDs, networks: true))
                            }.disabled(loading || failed)
                        }
                        NavigationLink(value: PickerDestination.assets) {
                            OathSettingsRow(title: strings.text(.assets), icon: "circle.grid.2x2",
                                value: selectionText(draft.values.assetIDs, networks: false))
                        }.disabled(loading || failed)
                        if loading { ProgressView().frame(maxWidth: .infinity).padding(12) }
                        if failed { OathButton(strings.text(.tryAgain)) { attempt += 1 }.oathNeutralControl().padding(.horizontal, 20) }
                        OathSettingsSectionRule()
                    }
                    filterGroup(.historyType) {
                        choices(HistoryFilter.Direction.allCases, selection: $draft.values.directions) {
                            $0 == .swap ? strings.text(.historySwap) + " / " + strings.text(.historyBridge) : strings.text($0.title)
                        }
                    }
                    OathSettingsSectionRule()
                    filterGroup(.transactionStatus) {
                        choices(HistoryFilter.Status.allCases, selection: $draft.values.statuses) { strings.text($0.title) }
                    }
                    OathSettingsSectionRule()
                    filterGroup(.historyDate) {
                        Picker(strings.text(.historyDate), selection: $draft.period) {
                            ForEach(OathHistoryFilterSelection.Period.allCases, id: \.self) { period in
                                Text(strings.text(period.title)).tag(period)
                            }
                        }.pickerStyle(.menu).labelsHidden().oathNeutralControl()
                        if draft.period == .custom {
                            DatePicker(strings.text(.historyStartDate), selection: $draft.customStart,
                                       in: ...Date(), displayedComponents: .date)
                            DatePicker(strings.text(.historyEndDate), selection: $draft.customEnd,
                                       in: ...Date(), displayedComponents: .date)
                        }
                    }
                    OathSettingsSectionRule()
                    filterGroup(.historyAmount) {
                        OathInputGroup {
                            amountField(.historyMinimum, text: $minimum, identifier: "history.filter.minimum")
                            OathInputSeparator()
                            amountField(.historyMaximum, text: $maximum, identifier: "history.filter.maximum")
                        }
                        Text(strings.text(.historyAmountDetail)).oathFont(.footnote).foregroundStyle(.secondary)
                        if validDraft == nil {
                            Text(strings.text(.historyInvalidRange)).oathFont(.footnote).foregroundStyle(.red)
                                .accessibilityIdentifier("history.filter.invalid")
                        }
                    }
                    OathSettingsSectionRule()
                    OathButton(strings.text(.historyResetFilters)) {
                        draft = .init(); minimum = ""; maximum = ""
                    }
                    .oathFont(.body, weight: .semibold)
                    .oathNeutralControl()
                    .frame(maxWidth: .infinity, minHeight: 48).padding(.bottom, 20)
                    .accessibilityIdentifier("history.filter.reset")
                }.frame(maxWidth: 700).frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color(uiColor: OathSurfaceColors.canvas).ignoresSafeArea())
            .oathHapticFeedback(.error, trigger: failed, when: failed)
            .navigationTitle(strings.text(.historyFilters)).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    OathCloseButton { dismiss() }
                        .accessibilityIdentifier("history.filter.close")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    OathDoneButton(label: .apply) {
                        guard let selection = changedDraft else { return }
                        onApply(selection); OathHaptics.shared.play(.selection); dismiss()
                    }.disabled(changedDraft == nil).accessibilityIdentifier("history.filter.apply")
                }
            }
            .oathNativeLocalization()
            .navigationDestination(for: PickerDestination.self) { destination in
                OathHistoryFilterPicker(options: options, networks: destination == .networks,
                    networkIDs: $draft.values.networkIDs, assetIDs: $draft.values.assetIDs)
            }
            .task(id: attempt) {
                guard assetID == nil else { loading = false; return }
                loading = true; failed = false
                do {
                    let db = try await OathDataEnvironment.shared.database()
                    let result = try await db.historyFilterAssets(walletID: walletID, networkID: networkID,
                                                                  accountID: accountID, assetID: assetID)
                    try Task.checkCancellation()
                    options = result; loading = false
                } catch { OathDiagnostics.record(error); if !Task.isCancelled { failed = true; loading = false } }
            }
        }
        .oathHapticFeedback(.navigate, trigger: pickerPath)
        .presentationDetents([.large]).presentationDragIndicator(.visible)
        .oathLanguage(strings.language)
    }

    private func selectionText(_ selected: Set<String>, networks: Bool) -> String {
        if selected.isEmpty { return strings.text(.historyAny) }
        if selected.count == 1, let item = options.first(where: { selected.contains(networks ? $0.networkID : $0.id) }) {
            return strings.invariant(networks ? item.networkName : item.symbol)
        }
        return strings.format(.historySelectedCount, strings.number(selected.count))
    }

    private func filterGroup<Content: View>(_ key: OathStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(strings.text(key)).oathFont(.headline).accessibilityAddTraits(.isHeader)
            content()
        }.padding(.horizontal, 20).padding(.vertical, 12)
    }

    private func choices<T: Hashable>(_ values: [T], selection: Binding<Set<T>>, title: @escaping (T) -> String) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 10)], alignment: .leading, spacing: 10) {
            ForEach(values, id: \.self) { value in
                let selected = selection.wrappedValue.contains(value)
                OathButton(feedback: .selection) {
                    if selected { selection.wrappedValue.remove(value) } else { selection.wrappedValue.insert(value) }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selected ? OathOnboardingColors.blue : Color(uiColor: .label))
                        Text(title(value)).multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .oathFont(.subheadline, weight: selected ? .semibold : .regular)
                    .padding(14).frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                    .foregroundStyle(Color(uiColor: .label))
                    .background(selected ? OathOnboardingColors.blue.opacity(0.10) : Color(uiColor: OathSurfaceColors.field), in: .rect(cornerRadius: 18))
                }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    private func amountField(_ key: OathStringKey, text: Binding<String>, identifier: String) -> some View {
        TextField(strings.text(key), text: text)
            .textFieldStyle(.plain)
            .keyboardType(.decimalPad)
            .frame(minHeight: OathInputMetrics.minimumContentHeight)
            .oathInputRow()
            .accessibilityLabel(strings.text(key))
            .accessibilityHint(strings.text(.historyNoLimit))
            .accessibilityIdentifier(identifier)
    }
}

private struct OathHistoryFilterPicker: View {
    let options: [HistoryFilterAsset]
    let networks: Bool
    @Binding var networkIDs: Set<String>
    @Binding var assetIDs: Set<String>
    @State private var query = ""
    @Environment(\.oathLocalizer) private var strings

    private var available: [HistoryFilterAsset] {
        var seen = Set<String>()
        return options.filter { item in
            let inNetwork = networks || networkIDs.isEmpty || networkIDs.contains(item.networkID)
            let unique = !networks || seen.insert(item.networkID).inserted
            let text = networks ? item.networkName : item.name + " " + item.symbol + " " + item.reference + " " + item.networkName
            return inNetwork && unique && (query.isEmpty || text.localizedStandardContains(query))
        }
    }
    var body: some View {
        OathEmptyStateScrollView(centersContent: available.isEmpty) {
            VStack(spacing: 0) {
                OathButton(feedback: .selection) {
                    if networks { networkIDs.removeAll() } else { assetIDs.removeAll() }
                } label: {
                    OathSettingsRow(title: strings.text(.historyAny),
                        accessory: .selection(networks ? networkIDs.isEmpty : assetIDs.isEmpty))
                }.buttonStyle(OathSettingsRowButtonStyle())
                OathSettingsSectionRule()
            }.padding(.top, 12)
        } content: {
            LazyVStack(spacing: 0) {
                ForEach(available) { item in
                    let selected = networks ? networkIDs.contains(item.networkID) : assetIDs.contains(item.id)
                    OathButton(feedback: .selection) {
                        if networks {
                            if selected { networkIDs.remove(item.networkID) } else { networkIDs.insert(item.networkID) }
                            if !networkIDs.isEmpty {
                                let allowed = Set(options.filter { networkIDs.contains($0.networkID) }.map(\.id))
                                assetIDs.formIntersection(allowed)
                            }
                        } else {
                            if selected { assetIDs.remove(item.id) } else { assetIDs.insert(item.id) }
                        }
                    } label: {
                        OathSettingsRow(title: strings.invariant(networks ? item.networkName : item.name + " (" + item.symbol + ")"),
                            accessory: .selection(selected),
                            subtitle: networks ? nil : strings.invariant(item.networkName + (item.reference == "native" ? "" : " · " + shortAddress(item.reference))),
                            networkLogo: OathImportChain(rawValue: item.networkID)?.logoAsset,
                            tokenLogo: networks || item.reference == "native" ? nil : item.logo,
                            tokenSymbol: networks || item.reference == "native" ? nil : item.symbol,
                            tokenIdentity: networks ? nil : .init(networkID: item.networkID, reference: item.reference, decimals: item.decimals))
                    }.buttonStyle(OathSettingsRowButtonStyle()).accessibilityAddTraits(selected ? .isSelected : [])
                }
                if available.isEmpty {
                    OathEmptyState(strings.text(.noSearchResults), systemImage: "magnifyingglass",
                                   description: strings.format(.noSearchResultsDetail, query))
                }
            }.padding(.vertical, 12).frame(maxWidth: 700).frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: OathSurfaceColors.canvas).ignoresSafeArea())
        .navigationTitle(strings.text(networks ? .historyNetworks : .assets))
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: Text(strings.text(.searchTitle)))
        .oathNativeLocalization()
    }

    private func shortAddress(_ value: String) -> String {
        value.count > 22 ? String(value.prefix(10)) + "…" + String(value.suffix(8)) : value
    }
}
