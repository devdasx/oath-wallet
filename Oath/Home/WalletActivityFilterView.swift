import SwiftUI

struct WalletActivityFilterView: View {
    let availableNetworks: [WalletActivityNetworkOption]
    let availableDateRange: ClosedRange<Date>?
    let onApply: (WalletActivityFilter) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.walletCurrencyContext) private var currencyContext
    @FocusState private var focusedAmountField: AmountField?
    @State private var draftFilter: WalletActivityFilter
    @State private var minimumValueText: String
    @State private var maximumValueText: String

    private enum AmountField: Hashable {
        case minimum
        case maximum
    }

    init(
        filter: WalletActivityFilter,
        availableNetworks: [WalletActivityNetworkOption],
        availableDateRange: ClosedRange<Date>?,
        onApply: @escaping (WalletActivityFilter) -> Void
    ) {
        self.availableNetworks = availableNetworks
        self.availableDateRange = availableDateRange
        self.onApply = onApply
        _draftFilter = State(initialValue: filter)

        let selectedCurrency = WalletCurrencyContext.selected
        _minimumValueText = State(
            initialValue: Self.amountText(
                for: filter.minimumUSDValue,
                currencyContext: selectedCurrency
            )
        )
        _maximumValueText = State(
            initialValue: Self.amountText(
                for: filter.maximumUSDValue,
                currencyContext: selectedCurrency
            )
        )
    }

    var body: some View {
        NavigationStack {
            Group {
                List {
                    Group {
                        Section("wallet.activity.filter.network.section") {
                            NavigationLink {
                                Group {
                                    WalletActivityNetworkFilterView(
                                        networks: availableNetworks,
                                        selectedNetworkIDs: $draftFilter.networkIDs
                                    )
                                }

                            } label: {
                                LabeledContent(
                                    "wallet.activity.filter.network.label",
                                    value: networkSummary
                                )
                            }
                        }

                        Section("wallet.activity.filter.activity.section") {
                            Picker(
                                "wallet.activity.filter.type.label",
                                selection: $draftFilter.kind
                            ) {
                                ForEach(WalletActivityKindFilter.allCases) { kind in
                                    Text(kind.localizedKey)
                                        .tag(kind)
                                }
                            }
                            .pickerStyle(.navigationLink)

                            Picker(
                                "wallet.activity.filter.status.label",
                                selection: $draftFilter.status
                            ) {
                                ForEach(WalletActivityStatusFilter.allCases) { status in
                                    Text(status.localizedKey)
                                        .tag(status)
                                }
                            }
                            .pickerStyle(.navigationLink)
                        }

                        Section {
                            LabeledContent {
                                TextField(
                                    "wallet.activity.filter.amount.placeholder",
                                    text: $minimumValueText
                                )
                                .walletTextInputDirection()
                                .keyboardType(.asciiCapableNumberPad)
                                .walletTextInputSubmitAction(identifier: "activityMinimumAmount", returnKeyType: .done,
                                                            showsKeyboardDecimalKey: true) {
                                    focusedAmountField = nil
                                }
                                .focused($focusedAmountField, equals: .minimum)
                                .onChange(of: minimumValueText) {
                                    minimumValueText = sanitizedAmount(
                                        minimumValueText
                                    )
                                }
                            } label: {
                                Text("wallet.activity.filter.amount.minimum")
                            }

                            LabeledContent {
                                TextField(
                                    "wallet.activity.filter.amount.placeholder",
                                    text: $maximumValueText
                                )
                                .walletTextInputDirection()
                                .keyboardType(.asciiCapableNumberPad)
                                .walletTextInputSubmitAction(identifier: "activityMaximumAmount", returnKeyType: .done,
                                                            showsKeyboardDecimalKey: true) {
                                    focusedAmountField = nil
                                }
                                .focused($focusedAmountField, equals: .maximum)
                                .onChange(of: maximumValueText) {
                                    maximumValueText = sanitizedAmount(
                                        maximumValueText
                                    )
                                }
                            } label: {
                                Text("wallet.activity.filter.amount.maximum")
                            }
                        } header: {
                            Text(
                                EnglishNumbers.localized(
                                    "wallet.activity.filter.amount.section",
                                    currencyContext.code
                                )
                            )
                        } footer: {
                            Text("wallet.activity.filter.amount.footer")
                        }

                        Section("wallet.activity.filter.date.section") {
                            Toggle(
                                "wallet.activity.filter.date.start.toggle",
                                isOn: startDateEnabled
                            )

                            if draftFilter.startDate != nil {
                                DatePicker(
                                    "wallet.activity.filter.date.start",
                                    selection: startDateBinding,
                                    displayedComponents: [.date, .hourAndMinute]
                                )
                            }

                            Toggle(
                                "wallet.activity.filter.date.end.toggle",
                                isOn: endDateEnabled
                            )

                            if draftFilter.endDate != nil {
                                DatePicker(
                                    "wallet.activity.filter.date.end",
                                    selection: endDateBinding,
                                    displayedComponents: [.date, .hourAndMinute]
                                )
                            }
                        }

                        if draftFilter.isActive
                            || !minimumValueText.isEmpty
                            || !maximumValueText.isEmpty {
                            Section {
                                Button("wallet.activity.filter.reset", action: UniHaptic.action {
                                    resetDraft()
                                })
                            }
                        }
                    }
                    .walletListRowSurface()
                }
                .walletListAppearance()
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .background(WalletTheme.groupedBackground)
                .navigationTitle("wallet.activity.filter.title")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        WalletCloseButton {
                            dismiss()
                        }
                    }

                    ToolbarItem(placement: .confirmationAction) {
                        WalletConfirmationButton {
                            applyFilter()
                        }
                    }

                }
            }

        }
    }

    private var networkSummary: String {
        if draftFilter.networkIDs.isEmpty {
            return WalletLocalization.string(
                "wallet.activity.filter.network.all"
            )
        }

        if draftFilter.networkIDs.count == 1,
           let selectedID = draftFilter.networkIDs.first,
           let selectedNetwork = availableNetworks.first(where: {
               $0.id == selectedID
           }) {
            return selectedNetwork.name
        }

        return EnglishNumbers.localized(
            "wallet.activity.filter.network.selected_count",
            EnglishNumbers.integer(
                Int64(draftFilter.networkIDs.count)
            )
        )
    }

    private var defaultStartDate: Date {
        availableDateRange?.lowerBound ?? Date()
    }

    private var defaultEndDate: Date {
        availableDateRange?.upperBound ?? Date()
    }

    private var startDateEnabled: Binding<Bool> {
        Binding(
            get: { draftFilter.startDate != nil },
            set: { isEnabled in
                draftFilter.startDate = isEnabled ? defaultStartDate : nil
            }
        )
    }

    private var endDateEnabled: Binding<Bool> {
        Binding(
            get: { draftFilter.endDate != nil },
            set: { isEnabled in
                draftFilter.endDate = isEnabled ? defaultEndDate : nil
            }
        )
    }

    private var startDateBinding: Binding<Date> {
        Binding(
            get: { draftFilter.startDate ?? defaultStartDate },
            set: { draftFilter.startDate = $0 }
        )
    }

    private var endDateBinding: Binding<Date> {
        Binding(
            get: { draftFilter.endDate ?? defaultEndDate },
            set: { draftFilter.endDate = $0 }
        )
    }

    private func resetDraft() {
        draftFilter = WalletActivityFilter()
        minimumValueText = ""
        maximumValueText = ""
        focusedAmountField = nil
    }

    private func applyFilter() {
        var resolvedFilter = draftFilter
        resolvedFilter.minimumUSDValue = usdValue(from: minimumValueText)
        resolvedFilter.maximumUSDValue = usdValue(from: maximumValueText)

        if let minimum = resolvedFilter.minimumUSDValue,
           let maximum = resolvedFilter.maximumUSDValue,
           minimum > maximum {
            resolvedFilter.minimumUSDValue = maximum
            resolvedFilter.maximumUSDValue = minimum
        }

        if let startDate = resolvedFilter.startDate,
           let endDate = resolvedFilter.endDate,
           startDate > endDate {
            resolvedFilter.startDate = endDate
            resolvedFilter.endDate = startDate
        }

        onApply(resolvedFilter)
        dismiss()
    }

    private func usdValue(from amountText: String) -> Decimal? {
        guard !amountText.isEmpty,
              let localValue = Decimal(
                  string: amountText,
                  locale: Locale(identifier: "en_US_POSIX")
              ) else {
            return nil
        }
        return localValue / currencyContext.ratePerUSD
    }

    private func sanitizedAmount(_ input: String) -> String {
        var result = ""
        var hasDecimalPoint = false
        var fractionalDigits = 0

        for character in input {
            if character >= "0", character <= "9" {
                if hasDecimalPoint {
                    guard fractionalDigits < 2 else { continue }
                    fractionalDigits += 1
                }
                result.append(character)
            } else if character == ".", !hasDecimalPoint {
                result += result.isEmpty ? "0." : "."
                hasDecimalPoint = true
            }

            if result.count >= 24 {
                break
            }
        }

        return result
    }

    private static func amountText(
        for usdValue: Decimal?,
        currencyContext: WalletCurrencyContext
    ) -> String {
        guard let usdValue else { return "" }
        return NSDecimalNumber(
            decimal: usdValue * currencyContext.ratePerUSD
        ).stringValue
    }
}
