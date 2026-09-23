import SwiftUI

struct SendCustomNetworkFeeScreen: View {
    let database: WalletDatabase
    let feePreferences: SendNetworkFeePreferenceRepository
    let draft: SendDraft
    let nativeUnitUSDPrice: Decimal?
    let initialPolicy: SendNetworkFeePolicy
    let quote: SendNetworkFeeQuote?
    let onPolicyChanged: (SendNetworkFeePolicy) -> Void

    init(
        database: WalletDatabase,
        feePreferences: SendNetworkFeePreferenceRepository? = nil,
        draft: SendDraft,
        nativeUnitUSDPrice: Decimal?,
        initialPolicy: SendNetworkFeePolicy,
        quote: SendNetworkFeeQuote?,
        onPolicyChanged: @escaping (SendNetworkFeePolicy) -> Void
    ) {
        self.database = database
        self.feePreferences = feePreferences
            ?? SendNetworkFeePreferenceRepository(database: database)
        self.draft = draft
        self.nativeUnitUSDPrice = nativeUnitUSDPrice
        self.initialPolicy = initialPolicy
        self.quote = quote
        self.onPolicyChanged = onPolicyChanged
    }

    @Environment(\.walletCurrencyContext) private var currencyContext
    @State private var localValue = ""
    @State private var nativePrice: Decimal?
    @State private var costBasis: SendNetworkFeeCostBasis?
    @State private var fastestLocalValue: String?
    @State private var fastestLocalAmount: Decimal?
    @State private var availableLocalBalance: Decimal?
    @State private var hasLoadedFeeBalance = false
    @State private var hasAttemptedSave = false
    @State private var saveError: String?
    @State private var isSaving = false
    @State private var typingRevision = 0

    private var asset: SendAssetChoice { draft.asset }

    private var model: SendNetworkFeeCustomModel? {
        if let custom = initialPolicy.customValue {
            return custom.model
        }
        if quote?.tier(for: .fastest)?.model == .evmLegacy {
            return .evmLegacy
        }
        return SendNetworkFeeCustomModel.model(for: asset.networkID)
    }

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width >= 600 && geometry.size.height < 500 {
                HStack(spacing: 0) {
                    feeList
                    compactControls
                        .frame(width: min(440, geometry.size.width / 2))
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
            } else {
                VStack(spacing: 0) {
                    feeList
                    bottomControls(
                        keyHeight: max(
                            44,
                            min(76, geometry.size.height * 0.09)
                        )
                    )
                }
            }
        }
        .background(WalletTheme.groupedBackground)
        .navigationTitle("send.network_fee.custom.title")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                WalletConfirmationButton("send.network_fee.custom.save", action: save)
                    .disabled(
                        isSaving
                            || model == nil
                            || nativePrice == nil
                            || costBasis == nil
                            || !hasLoadedFeeBalance
                            || availableLocalBalance == nil
                            || feeExceedsAvailableBalance
                            || feeIsBelowNetworkMinimum
                            || localValue.isEmpty
                    )
                    .accessibilityIdentifier("sendCustomFeeConfirm")
            }
        }
        .task(id: loadID) {
            await load()
        }
    }

    private var feeList: some View {
        List {
            Group {
                Section {
                    SendAmountValue(
                        value: localValue,
                        unit: currencyContext.code,
                        typingRevision: typingRevision,
                        currencyPrefix: currencyPrefix,
                        isInvalid: feeExceedsAvailableBalance
                            || feeIsBelowNetworkMinimum
                    )
                    .padding(.vertical, 14)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .accessibilityIdentifier("sendCustomFeeValue")
                } header: {
                    Text("send.network_fee.section")
                } footer: {
                    if let inputError {
                        Text(verbatim: inputError.localizedMessage)
                            .foregroundStyle(WalletTheme.danger)
                    }
                    if let highFeeWarning {
                        Text(verbatim: highFeeWarning)
                            .foregroundStyle(WalletTheme.warning)
                    }
                }

                if let fastestLocalValue {
                    Section {
                        LabeledContent(
                            "send.network_fee.custom.current_fastest"
                        ) {
                            Text(verbatim: fastestLocalValue)
                                .fontDesign(.rounded)
                                .monospacedDigit()
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }

                if let balancePercentage = entryFeedback?
                    .balancePercentage {
                    Section {
                        LabeledContent(
                            "send.network_fee.custom.balance_share"
                        ) {
                            Text(
                                verbatim: EnglishNumbers.percentage(
                                    balancePercentage
                                )
                            )
                            .fontDesign(.rounded)
                            .monospacedDigit()
                            .foregroundStyle(
                                feeExceedsAvailableBalance
                                    ? WalletTheme.danger
                                    : WalletTheme.secondaryLabel
                            )
                        }
                    }
                }

                if nativePrice == nil {
                    Section {
                        Text("send.amount.error.local_currency_unavailable")
                            .foregroundStyle(WalletTheme.danger)
                    }
                }

                if hasLoadedFeeBalance && availableLocalBalance == nil {
                    Section {
                        Text("send.network_fee.error.balance_unavailable")
                            .foregroundStyle(WalletTheme.danger)
                    }
                }

                if let saveError {
                    Section {
                        Text(verbatim: saveError)
                            .foregroundStyle(WalletTheme.danger)
                    }
                }
            }
            .walletListRowSurface()
        }
        .walletListAppearance()
        .listStyle(.insetGrouped)
        .listSectionSpacing(12)
        .contentMargins(.top, 12, for: .scrollContent)
        .scrollContentBackground(.hidden)
    }

    private var compactControls: some View {
        ViewThatFits(in: .vertical) {
            bottomControls(keyHeight: 58, compact: true)
                .fixedSize(horizontal: false, vertical: true)
            bottomControls(keyHeight: 44, compact: true)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                bottomControls(keyHeight: 44, compact: true)
            }
        }
    }

    private func bottomControls(
        keyHeight: CGFloat,
        compact: Bool = false
    ) -> some View {
        VStack(spacing: compact ? 4 : 10) {

            SendAmountKeypad(
                input: localValue,
                maximumFractionDigits:
                    SendNetworkFeeCustomLocalConverter
                        .maximumFractionDigits,
                keyHeight: keyHeight,
                verticalSpacing: compact ? 0 : 6,
                accessibilityLabelKey:
                    "send.amount.keypad.label",
                identifierPrefix: "sendCustomFee"
            ) { key in
                press(key)
            }
        }
        .frame(maxWidth: 560)
        .padding(.horizontal, 20)
        .padding(.top, compact ? 0 : 8)
        .padding(.bottom, compact ? 4 : 8)
        .frame(maxWidth: .infinity)
    }

    private var currencyPrefix: String {
        String(
            EnglishNumbers.currency(
                0,
                currencyCode: currencyContext.code
            ).prefix { !($0 >= "0" && $0 <= "9") }
        )
    }

    private var loadID: String {
        [
            asset.networkID,
            currencyContext.code,
            NSDecimalNumber(decimal: currencyContext.ratePerUSD)
                .stringValue,
            initialPolicy.customValue?.primaryValue ?? "",
            initialPolicy.customValue?.totalBudgetAtomic ?? ""
        ].joined(separator: "|")
    }

    private var inputError: SendNetworkFeeInputError? {
        if feeExceedsAvailableBalance { return .exceedsBalance }
        if feeIsBelowNetworkMinimum {
            return .belowNetworkMinimum
        }
        guard hasAttemptedSave else { return nil }
        guard !localValue.isEmpty else { return .required }
        guard hasLoadedFeeBalance,
              availableLocalBalance != nil else {
            return .balanceUnavailable
        }
        return candidateInputError
    }

    private var entryFeedback: SendCustomNetworkFeeEntryFeedback? {
        feedback(for: localValue)
    }

    private var feeExceedsAvailableBalance: Bool {
        entryFeedback?.exceedsAvailableBalance == true
    }

    private var candidateInputError: SendNetworkFeeInputError? {
        guard !localValue.isEmpty else { return nil }
        do {
            _ = try candidateCustomValue()
            return nil
        } catch let error as SendNetworkFeeInputError {
            return error
        } catch {
            return .invalid
        }
    }

    private var feeIsBelowNetworkMinimum: Bool {
        candidateInputError == .belowNetworkMinimum
    }

    private var highFeeWarning: String? {
        guard let entryFeedback,
              entryFeedback.exceedsHighFeeThreshold,
              let multiple = entryFeedback.fastestMultiple else {
            return nil
        }
        return EnglishNumbers.localized(
            "send.network_fee.custom.high_fee_warning",
            EnglishNumbers.decimal(
                multiple,
                minimumFractionDigits: 0,
                maximumFractionDigits: 2
            )
        )
    }

    private func feedback(
        for input: String
    ) -> SendCustomNetworkFeeEntryFeedback? {
        SendCustomNetworkFeeEntryFeedback(
            input: input,
            availableLocalBalance: availableLocalBalance,
            fastestLocalAmount: fastestLocalAmount
        )
    }

    private var referenceFee: SendResolvedNetworkFee? {
        guard let tier = quote?.tier(for: .fastest) else { return nil }
        return SendResolvedNetworkFee(
            model: tier.model,
            primaryValue: tier.primaryValue,
            secondaryValue: tier.secondaryValue
        )
    }

    private var minimumReferenceFee: SendResolvedNetworkFee? {
        guard let tier = quote?.tier(for: .economy) else { return nil }
        return SendResolvedNetworkFee(
            model: tier.model,
            primaryValue: tier.primaryValue,
            secondaryValue: tier.secondaryValue
        )
    }

    @MainActor
    private func load() async {
        let estimator = SendNetworkFeeEstimator(database: database)
        hasLoadedFeeBalance = false
        availableLocalBalance = nil
        nativePrice = await estimator.resolvedNativeUnitUSDPrice(
            networkID: asset.networkID,
            preferredPrice: nativeUnitUSDPrice
        )
        guard let model else { return }
        availableLocalBalance = await estimator
            .availableFeePayerLocalBalance(
                draft: draft,
                model: model,
                nativeUnitUSDPrice: nativePrice,
                currency: currencyContext
            )
        hasLoadedFeeBalance = true
        costBasis = try? await estimator.customCostBasis(
            draft: draft,
            model: model,
            referenceFee: referenceFee,
            minimumFee: minimumReferenceFee
        )
        await loadFastestLocalValue(estimator: estimator)
        await loadInitialLocalValue(estimator: estimator, model: model)
    }

    @MainActor
    private func loadFastestLocalValue(
        estimator: SendNetworkFeeEstimator
    ) async {
        guard let fee = referenceFee else {
            fastestLocalValue = nil
            fastestLocalAmount = nil
            return
        }
        guard let nativePrice,
              let estimate = try? await estimator.estimateForDisplay(
                  draft: draft.replacingFeePolicy(.fastest),
                  fee: fee
              ), let usdValue = estimate.usdValue(
                  unitUSDPrice: nativePrice
              ) else {
            fastestLocalValue = nil
            fastestLocalAmount = nil
            return
        }
        fastestLocalAmount = usdValue * currencyContext.ratePerUSD
        fastestLocalValue = EnglishNumbers.networkFeeCurrency(
            usdValue,
            using: currencyContext
        )
    }

    @MainActor
    private func loadInitialLocalValue(
        estimator: SendNetworkFeeEstimator,
        model: SendNetworkFeeCustomModel
    ) async {
        let storedPolicy: SendNetworkFeePolicy
        if let custom = initialPolicy.customValue,
           custom.model == model {
            storedPolicy = initialPolicy
        } else if let saved = try? await feePreferences.policy(
                    for: asset.networkID
                  ), let custom = saved.customValue,
                  custom.model == model {
            storedPolicy = saved
        } else {
            storedPolicy = .fastest
        }

        let fee: SendResolvedNetworkFee?
        if storedPolicy.preset == .custom {
            fee = try? SendResolvedNetworkFee.resolveCustom(
                policy: storedPolicy,
                networkID: asset.networkID
            )
        } else {
            fee = referenceFee
        }
        guard let fee, let nativePrice else { return }
        let estimate = try? await estimator.estimateForDisplay(
            draft: draft.replacingFeePolicy(storedPolicy),
            fee: fee
        )
        guard let estimate,
              let input = SendNetworkFeeCustomLocalConverter
                .editableLocalValue(
                    estimate: estimate,
                    nativeUnitUSDPrice: nativePrice,
                    currency: currencyContext
                ) else { return }
        localValue = input
    }

    private func press(_ key: SendAmountKey) {
        let previousFeedback = feedback(for: localValue)
        guard let next = SendAmountKeypadInput.applying(
            key,
            to: localValue,
            maximumFractionDigits:
                SendNetworkFeeCustomLocalConverter.maximumFractionDigits
        ), next != localValue else { return }
        let nextFeedback = feedback(for: next)
        localValue = next
        typingRevision &+= 1
        hasAttemptedSave = false
        saveError = nil
        if previousFeedback?.exceedsAvailableBalance != true,
           nextFeedback?.exceedsAvailableBalance == true {
            UniHaptic.play(.error)
        } else if previousFeedback?.exceedsHighFeeThreshold != true,
                  nextFeedback?.exceedsHighFeeThreshold == true {
            UniHaptic.play(.warning)
        } else {
            UniHaptic.play(.selection)
        }
    }

    private func candidateCustomValue() throws
        -> SendNetworkFeeCustomValue {
        guard let model, let costBasis, let nativePrice else {
            throw SendNetworkFeeInputError.invalid
        }
        guard hasLoadedFeeBalance,
              availableLocalBalance != nil else {
            throw SendNetworkFeeInputError.balanceUnavailable
        }
        if feeExceedsAvailableBalance {
            throw SendNetworkFeeInputError.exceedsBalance
        }
        let target = try SendNetworkFeeCustomLocalConverter
            .targetAtomicAmount(
                from: localValue,
                nativeDecimals: SendNetworkFeeEstimator.nativeDecimals(
                    for: model.quoteModel
                ),
                nativeUnitUSDPrice: nativePrice,
                currency: currencyContext
            )
        let value = try SendNetworkFeeCustomLocalConverter.customValue(
            targetAtomicAmount: target,
            model: model,
            basis: costBasis
        )
        guard value.isValid(for: asset.networkID) else {
            throw SendNetworkFeeInputError.invalid
        }
        return value
    }

    @MainActor
    private func save() {
        hasAttemptedSave = true
        saveError = nil
        let value: SendNetworkFeeCustomValue
        do {
            value = try candidateCustomValue()
        } catch let error as SendNetworkFeeInputError {
            saveError = error.localizedMessage
            UniHaptic.play(.error)
            return
        } catch {
            saveError = SendNetworkFeeInputError.invalid.localizedMessage
            UniHaptic.play(.error)
            return
        }

        isSaving = true
        Task {
            do {
                try await feePreferences.saveCustom(
                    value,
                    for: asset.networkID
                )
                isSaving = false
                UniHaptic.play(.selection)
                onPolicyChanged(.custom(value))
            } catch {
                isSaving = false
                saveError = EnglishNumbers.localized(
                    "send.network_fee.error.preference_save",
                    Self.errorTypeCode(error)
                )
                UniHaptic.play(.error)
            }
        }
    }

    private static func errorTypeCode(_ error: Error) -> String {
        String(reflecting: type(of: error))
            .replacingOccurrences(of: ".", with: "_")
            .prefix(80)
            .description
    }
}
