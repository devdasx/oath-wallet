import SwiftUI

struct CurrencyConverterView: View {
    @Environment(\.locale) private var locale
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.walletCurrencyContext) private var localCurrency
    @Environment(WalletSettingsStore.self) private var applicationSettings

    let database: WalletDatabase

    @State private var editMode: EditMode = .inactive
    @State private var units: [CurrencyConverterUnit] = []
    @State private var selectedUnitIDs: [String] = []
    @State private var amountTexts: [String: String] = [:]
    @State private var referenceUnitID = ""
    @State private var isLoading = true
    @State private var hasFailed = false
    @State private var lastUsedUnitID = ""
    @State private var didRequestInitialFocus = false
    @State private var hasFinishedPresentation = false
    @State private var isVisible = false
    @State private var pendingFocusedUnitID: String?
    @FocusState private var focusedUnitID: String?

    var body: some View {
        ScrollViewReader { scrollProxy in
            List {
                Group {
                    Section {
                        Toggle(
                            "settings.converter.show_on_home",
                            isOn: homeShortcutBinding
                        )
                    }

                    if isLoading && units.isEmpty {
                        Section {
                            Text("settings.currency.loading")
                                .foregroundStyle(WalletTheme.secondaryLabel)
                        }
                    } else if hasFailed && usableUnits.count < 2 {
                        Section {
                            CurrencyConverterFailureView {
                                Task { await load(forceRefresh: true) }
                            }
                        }
                    } else {
                        converterSections
                    }
                }
                .walletListRowSurface()
            }
            .walletListAppearance()
            .onChange(of: requestedFocusID, initial: true) {
                if let requestedFocusID {
                    scrollProxy.scrollTo(requestedFocusID)
                }
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(24)
        .navigationTitle("settings.converter.title")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            if selectedUnitIDs.count > 1 {
                ToolbarItem(placement: .primaryAction) {
                    EditButton()
                }
            }
        }
        // Both the toolbar's EditButton and the List must share this binding.
        .environment(\.editMode, $editMode.hapticSelection())
        .onChange(of: editMode) {
            if editMode.isEditing {
                pendingFocusedUnitID = nil
                focusedUnitID = nil
            }
        }
        .task {
            await load()
        }
        .onChange(of: localCurrency.code) {
            Task { await load() }
        }
        .walletFocusOnPresentation { hasFinishedPresentation = true }
        .onAppear {
            isVisible = true
        }
        .onDisappear {
            isVisible = false
            focusedUnitID = nil
        }
        .onChange(of: focusedUnitID) {
            guard let focusedUnitID,
                  selectedUnitIDs.contains(focusedUnitID),
                  lastUsedUnitID != focusedUnitID else { return }
            lastUsedUnitID = focusedUnitID
            persistSelection()
        }
    }

    @ViewBuilder
    private var converterSections: some View {
        Section {
            ForEach(selectedUnits) { unit in
                converterRow(unit: unit)
                    .deleteDisabled(selectedUnitIDs.count <= 2)
            }
            .onDelete(perform: removeUnits)
            .onMove(perform: moveUnits)

            if canAddUnit {
                NavigationLink {
                    Group {
                        CurrencyConverterUnitSelectionView(
                            units: units,
                            selectedID: "",
                            excludedIDs: Set(selectedUnitIDs),
                            onSelect: addUnit
                        )
                    }

                } label: {
                    Text("settings.converter.add")
                }
            }
        }
    }

    private func converterRow(
        unit: CurrencyConverterUnit
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                amountField(unit: unit)

                if unit.id != referenceUnitID,
                   let referenceUnit = self.unit(for: referenceUnitID),
                   let rateText = rateSummary(
                       source: referenceUnit,
                       target: unit
                   ) {
                    Text(verbatim: rateText)
                        .font(.caption)
                        .foregroundStyle(WalletTheme.secondaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            NavigationLink {
                Group {
                    CurrencyConverterUnitSelectionView(
                        units: units,
                        selectedID: unit.id,
                        excludedIDs: Set(
                            selectedUnitIDs.filter { $0 != unit.id }
                        ),
                        onSelect: { replacement in
                            replaceUnit(unit.id, with: replacement)
                        }
                    )
                    .environment(\.layoutDirection, layoutDirection)
                }

            } label: {
                Text(verbatim: unit.code)
                    .font(.subheadline.bold())
                    .foregroundStyle(WalletTheme.primaryLabel)
                    .lineLimit(1)
            }
            .fixedSize(horizontal: true, vertical: false)
            .disabled(editMode.isEditing)
            .accessibilityLabel(unit.localizedName(locale: locale))
        }
        .padding(.vertical, 4)
        // Keep flags, amounts, and currency codes in a stable physical order,
        // including the native text field's leading alignment while editing.
        .environment(\.layoutDirection, .leftToRight)
    }

    private func amountField(
        unit: CurrencyConverterUnit
    ) -> some View {
        HStack(spacing: 12) {
            CurrencyConverterAmountLogo(unit: unit)

            TextField(
                "settings.converter.amount",
                text: amountBinding(for: unit.id),
                prompt: Text(verbatim: "0.00")
            )
            .font(
                .system(.title2, design: .rounded, weight: .medium)
                    .monospacedDigit()
            )
            .foregroundStyle(WalletTheme.primaryLabel)
            .walletTextInputDirection()
            .keyboardType(.decimalPad)
            .disabled(editMode.isEditing)
            .focused($focusedUnitID, equals: unit.id)
            .accessibilityIdentifier("converter.amount.\(unit.id)")
            .task(id: requestedFocusID) {
                // Focus only after the requested native list row is mounted.
                guard requestedFocusID == unit.id else { return }
                pendingFocusedUnitID = nil
                focusedUnitID = unit.id
            }
            .accessibilityLabel(unit.localizedName(locale: locale))
        }
    }

    private var service: CurrencyConverterDataService {
        CurrencyConverterDataService(database: database)
    }

    private var homeShortcutBinding: Binding<Bool> {
        Binding(
            get: {
                applicationSettings
                    .currencyConverterHomeShortcutEnabled
            },
            set: {
                applicationSettings
                    .setCurrencyConverterHomeShortcutEnabled($0)
            }
        )
    }

    private var usableUnits: [CurrencyConverterUnit] {
        units.filter(\.hasUsableRate)
    }

    private var selectedUnits: [CurrencyConverterUnit] {
        selectedUnitIDs.compactMap { unit(for: $0) }
    }

    private var canAddUnit: Bool {
        usableUnits.contains { !selectedUnitIDs.contains($0.id) }
    }

    private func unit(for id: String) -> CurrencyConverterUnit? {
        units.first { $0.id == id && $0.hasUsableRate }
    }

    @MainActor
    private func load(forceRefresh: Bool = false) async {
        let stored = await service.savedSelection()

        if units.isEmpty {
            let cached = await service.cachedDataset(
                localCurrency: localCurrency
            )
            apply(cached, storedSelection: stored)
            isLoading = cached.units.filter(\.hasUsableRate).count < 2
        }

        hasFailed = false
        let refreshed = await service.refreshedDataset(
            localCurrency: localCurrency
        )
        guard !Task.isCancelled else { return }
        apply(
            refreshed,
            storedSelection: currentSelection ?? stored
        )
        isLoading = false
        hasFailed = usableUnits.count < 2

        if forceRefresh, hasFailed {
            UniHaptic.play(.error)
        }
    }

    @MainActor
    private func apply(
        _ dataset: CurrencyConverterDataset,
        storedSelection: CurrencyConverterSelection?
    ) {
        units = dataset.units
        guard let resolved = CurrencyConverterSelectionResolver.resolve(
            stored: storedSelection,
            localCurrencyCode: localCurrency.code,
            units: dataset.units
        ) else {
            selectedUnitIDs = []
            referenceUnitID = ""
            return
        }

        selectedUnitIDs = resolved.unitIDs
        lastUsedUnitID = resolved.lastUsedUnitID
        if !selectedUnitIDs.contains(referenceUnitID) {
            referenceUnitID = resolved.lastUsedUnitID
        }
        if amountTexts[referenceUnitID] == nil {
            amountTexts[referenceUnitID] = CurrencyConverterEngine
                .defaultAmountText
        }
        synchronizeAmounts(from: referenceUnitID)
        if !didRequestInitialFocus {
            didRequestInitialFocus = true
            pendingFocusedUnitID = lastUsedUnitID
        }
        Task { await service.saveSelection(resolved) }
    }

    private var currentSelection: CurrencyConverterSelection? {
        guard selectedUnitIDs.count >= 2 else { return nil }
        return CurrencyConverterSelection(
            unitIDs: selectedUnitIDs,
            lastUsedUnitID: lastUsedUnitID
        )
    }

    private func amountBinding(for unitID: String) -> Binding<String> {
        Binding(
            get: { amountTexts[unitID] ?? "" },
            set: { input in updateAmount(input, for: unitID) }
        )
    }

    private func updateAmount(_ input: String, for unitID: String) {
        amountTexts[unitID] = CurrencyConverterEngine
            .sanitizedAmount(input)
        referenceUnitID = unitID
        synchronizeAmounts(from: unitID)
    }

    private func synchronizeAmounts(from referenceID: String) {
        guard let referenceUnit = unit(for: referenceID) else { return }
        let referenceText = amountTexts[referenceID] ?? ""
        var updatedAmounts = amountTexts

        let targetUnits = selectedUnitIDs
            .filter { $0 != referenceID }
            .compactMap { unit(for: $0) }
        let conversions = CurrencyConverterEngine.convertedAmountTexts(
            amountText: referenceText,
            from: referenceUnit,
            to: targetUnits
        )
        for targetUnit in targetUnits {
            updatedAmounts[targetUnit.id] = conversions[targetUnit.id] ?? ""
        }

        amountTexts = updatedAmounts
    }

    private func replaceUnit(
        _ replacedID: String,
        with replacement: CurrencyConverterUnit
    ) {
        guard replacement.hasUsableRate,
              !selectedUnitIDs.contains(replacement.id),
              let index = selectedUnitIDs.firstIndex(of: replacedID)
        else {
            return
        }

        let retainedAmount = amountTexts[replacedID]
            ?? CurrencyConverterEngine.defaultAmountText
        selectedUnitIDs[index] = replacement.id
        amountTexts.removeValue(forKey: replacedID)
        amountTexts[replacement.id] = retainedAmount
        if referenceUnitID == replacedID {
            referenceUnitID = replacement.id
        }
        if lastUsedUnitID == replacedID {
            lastUsedUnitID = replacement.id
        }
        focusedUnitID = nil
        synchronizeAmounts(from: referenceUnitID)
        persistSelection()
    }

    private func addUnit(_ unit: CurrencyConverterUnit) {
        guard unit.hasUsableRate,
              !selectedUnitIDs.contains(unit.id) else {
            return
        }
        selectedUnitIDs.append(unit.id)
        synchronizeAmounts(from: referenceUnitID)
        persistSelection()
        pendingFocusedUnitID = unit.id
    }

    private var requestedFocusID: String? {
        isVisible && hasFinishedPresentation && !editMode.isEditing
            ? pendingFocusedUnitID : nil
    }

    private func removeUnits(at offsets: IndexSet) {
        guard !offsets.isEmpty, selectedUnitIDs.count - offsets.count >= 2 else { return }
        UniHaptic.play(.selectionDeselect)

        var retainedUnitIDs = selectedUnitIDs
        let removedIDs = offsets.compactMap {
            retainedUnitIDs.indices.contains($0)
                ? retainedUnitIDs[$0]
                : nil
        }
        for index in offsets.sorted(by: >) {
            guard retainedUnitIDs.indices.contains(index) else { continue }
            retainedUnitIDs.remove(at: index)
        }
        selectedUnitIDs = retainedUnitIDs
        if !selectedUnitIDs.contains(lastUsedUnitID) {
            lastUsedUnitID = selectedUnitIDs.first ?? ""
        }
        for removedID in removedIDs {
            amountTexts.removeValue(forKey: removedID)
        }
        if !selectedUnitIDs.contains(referenceUnitID) {
            guard let nextReferenceID = selectedUnitIDs.first else { return }
            referenceUnitID = nextReferenceID
            synchronizeAmounts(from: nextReferenceID)
        }
        persistSelection()
    }

    private func moveUnits(
        from source: IndexSet,
        to destination: Int
    ) {
        let previous = selectedUnitIDs
        selectedUnitIDs.move(
            fromOffsets: source,
            toOffset: destination
        )
        if selectedUnitIDs != previous { UniHaptic.play(.selection) }
        persistSelection()
    }

    private func persistSelection() {
        guard let currentSelection else { return }
        Task { await service.saveSelection(currentSelection) }
    }

    private func rateSummary(
        source: CurrencyConverterUnit,
        target: CurrencyConverterUnit
    ) -> String? {
        guard let rate = CurrencyConverterEngine.rate(
            from: source,
            to: target
        ) else {
            return nil
        }
        return "1 \(source.code) = \(CurrencyConverterEngine.formatted(rate, for: target.kind)) \(target.code)"
    }
}

private struct CurrencyConverterAmountLogo: View {
    let unit: CurrencyConverterUnit

    @ViewBuilder
    var body: some View {
        if !resolvedFlag.isEmpty {
            Text(verbatim: resolvedFlag)
                .font(.title2)
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
        } else if let logoSource = unit.logoSource {
            AssetLogoView(
                source: logoSource,
                size: 32,
                diagnosticAssetIdentity: unit.walletAssetID
            )
        }
    }

    private var resolvedFlag: String {
        let configured = unit.flag.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if !configured.isEmpty {
            return configured
        }
        guard unit.kind == .fiat else { return "" }
        return CurrencyFlagResolver.flag(for: unit.code)
    }
}

private struct CurrencyConverterFailureView: View {
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Text("settings.currency.error.title")
                .font(.headline)
        } description: {
            Text("settings.currency.error.message")
        } actions: {
            Button("settings.currency.error.retry", action: UniHaptic.action(retry))
                .walletPrimaryActionButtonStyle()
                .buttonBorderShape(.capsule)
                .controlSize(.large)
        }
    }
}
