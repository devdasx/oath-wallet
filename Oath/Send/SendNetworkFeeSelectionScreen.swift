import SwiftUI

struct SendNetworkFeeSelectionScreen: View {
    let database: WalletDatabase
    let feePreferences: SendNetworkFeePreferenceRepository
    let draft: SendDraft
    let nativeUnitUSDPrice: Decimal?
    let initialPolicy: SendNetworkFeePolicy
    let onPolicyChanged: (SendNetworkFeePolicy) -> Void
    let onCustom: (SendNetworkFeeQuote?) -> Void

    @Environment(\.walletCurrencyContext) private var currencyContext
    @State private var policy: SendNetworkFeePolicy
    @State private var quoteState: QuoteState = .loading
    @State private var localFeeValues:
        [SendNetworkFeePreset: String] = [:]
    @State private var saveError: String?
    @State private var isSaving = false
    @State private var quoteLoadGeneration = UUID()
    @State private var estimationGeneration = UUID()

    private enum QuoteState {
        case loading
        case loaded(SendNetworkFeeQuote)
        case failed(String)
    }

    init(
        database: WalletDatabase,
        feePreferences: SendNetworkFeePreferenceRepository? = nil,
        draft: SendDraft,
        nativeUnitUSDPrice: Decimal?,
        initialPolicy: SendNetworkFeePolicy,
        onPolicyChanged: @escaping (SendNetworkFeePolicy) -> Void,
        onCustom: @escaping (SendNetworkFeeQuote?) -> Void
    ) {
        self.database = database
        self.feePreferences = feePreferences
            ?? SendNetworkFeePreferenceRepository(database: database)
        self.draft = draft
        self.nativeUnitUSDPrice = nativeUnitUSDPrice
        self.initialPolicy = initialPolicy
        self.onPolicyChanged = onPolicyChanged
        self.onCustom = onCustom
        _policy = State(initialValue: initialPolicy)
    }

    private var asset: SendAssetChoice { draft.asset }

    var body: some View {
        List {
            Group {
                Section {
                    HStack(spacing: 14) {
                        AssetLogoView(
                            source: asset.networkLogoSource,
                            size: 40,
                            animatesChanges: false,
                            diagnosticAssetIdentity: asset.networkID
                        )
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: asset.networkName)
                                .font(WalletTypography.listRowTitle)
                            Text(verbatim: asset.symbol)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                } header: {
                    Text("send.network_fee.network.section")
                }

                switch quoteState {
                case .loading:
                    Section {
                        ForEach(0..<3, id: \.self) { _ in
                            VStack(alignment: .leading, spacing: 8) {
                                Capsule()
                                    .fill(WalletTheme.tertiaryFill)
                                    .frame(maxWidth: 116)
                                    .frame(height: 16)
                                Capsule()
                                    .fill(WalletTheme.tertiaryFill)
                                    .frame(maxWidth: 230)
                                    .frame(height: 13)
                            }
                            .sendSkeletonPulse()
                            .accessibilityHidden(true)
                        }
                    } header: {
                        Text("send.network_fee.options.section")
                    }
                case let .loaded(quote):
                    presetSection(quote)
                case let .failed(message):
                    Section {
                        Text(verbatim: message)
                            .foregroundStyle(WalletTheme.danger)
                        Button("common.retry", action: UniHaptic.action {
                            Task { await loadQuote() }
                        })
                        .foregroundStyle(WalletTheme.accent)
                    } header: {
                        Text("send.network_fee.options.section")
                    } footer: {
                        Text("send.network_fee.error.footer")
                    }
                }

                if SendNetworkFeeCustomModel.model(
                    for: asset.networkID
                ) != nil {
                    Section {
                        Button(action: UniHaptic.action(nil) {
                            onCustom(loadedQuote)
                        }) {
                            feeRow(
                                titleKey:
                                    SendNetworkFeePreset.custom.titleKey,
                                detail: customDetail,
                                isSelected: policy.preset == .custom
                            )
                        }
                        .buttonStyle(.automatic)
                        .disabled(isSaving)
                    } footer: {
                        Text("send.network_fee.remembered.footer")
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
        .background(WalletTheme.groupedBackground)
        .navigationTitle("send.network_fee.title")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: asset.networkID) {
            await load()
        }
        .task(id: estimationInputID) {
            guard let quote = loadedQuote else { return }
            await loadLocalFeeValues(quote: quote)
        }
    }

    @ViewBuilder
    private func presetSection(
        _ quote: SendNetworkFeeQuote
    ) -> some View {
        Section {
            ForEach(
                [
                    SendNetworkFeePreset.fastest,
                    .standard,
                    .economy
                ],
                id: \.self
            ) { preset in
                if quote.tier(for: preset) != nil {
                    Button(action: UniHaptic.action {
                        save(preset)
                    }) {
                        feeRow(
                            titleKey: preset.titleKey,
                            detail: localFeeDetail(for: preset),
                            isSelected: policy.preset == preset
                        )
                    }
                    .buttonStyle(.automatic)
                    .disabled(isSaving)
                }
            }
        } header: {
            Text("send.network_fee.options.section")
        }
    }

    private func feeRow(
        titleKey: String,
        detail: String,
        isSelected: Bool
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(LocalizedStringKey(titleKey))
                    .foregroundStyle(WalletTheme.primaryLabel)
                Text(verbatim: detail)
                    .font(.subheadline)
                    .foregroundStyle(WalletTheme.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            SendNetworkFeeSelectionCheck(isSelected: isSelected)
        }
        .contentShape(Rectangle())
        .accessibilityValue(
            isSelected ? Text("selection.selected") : Text(verbatim: "")
        )
    }

    private var loadedQuote: SendNetworkFeeQuote? {
        if case let .loaded(quote) = quoteState {
            return quote
        }
        return nil
    }

    private var customDetail: String {
        guard policy.customValue != nil else {
            return WalletLocalization.string(
                SendNetworkFeePreset.custom.detailKey
            )
        }
        return localFeeValues[.custom] ?? "—"
    }

    @MainActor
    private func load() async {
        do {
            policy = try await feePreferences.policy(
                for: asset.networkID
            )
        } catch {
            policy = initialPolicy
            saveError = EnglishNumbers.localized(
                "send.network_fee.error.preference_load",
                Self.errorTypeCode(error)
            )
        }
        if policy.requiresLiveQuote {
            await loadQuote()
        } else {
            await loadCustomState()
        }
    }

    @MainActor
    private func loadQuote() async {
        guard policy.requiresLiveQuote else {
            await loadCustomState()
            return
        }
        let generation = UUID()
        quoteLoadGeneration = generation
        quoteState = .loading
        do {
            let quote = try await SendNetworkFeeQuoteRepository.shared.quote(
                for: asset.networkID, database: database
            )
            guard quoteLoadGeneration == generation else { return }
            quoteState = .loaded(quote)
            await loadLocalFeeValues(quote: quote)
        } catch let error as SendNetworkFeeAPIError {
            guard quoteLoadGeneration == generation else { return }
            quoteState = .failed(error.localizedMessage)
        } catch {
            guard quoteLoadGeneration == generation else { return }
            let code = Self.errorTypeCode(error)
            quoteState = .failed(
                EnglishNumbers.localized(
                    "send.network_fee.error.unexpected",
                    code
                )
            )
        }
    }

    @MainActor
    private func loadCustomState() async {
        let generation = UUID()
        quoteLoadGeneration = generation
        do {
            let quote = try await SendNetworkFeeQuoteRepository.shared.quote(
                for: asset.networkID, database: database
            )
            guard quoteLoadGeneration == generation else { return }
            quoteState = .loaded(quote)
            await loadLocalFeeValues(quote: quote)
        } catch let error as SendNetworkFeeAPIError {
            guard quoteLoadGeneration == generation else { return }
            quoteState = .failed(error.localizedMessage)
        } catch {
            guard quoteLoadGeneration == generation else { return }
            quoteState = .failed(
                EnglishNumbers.localized(
                    "send.network_fee.error.unexpected",
                    Self.errorTypeCode(error)
                )
            )
        }
    }

    @MainActor
    private func loadLocalFeeValues(
        quote: SendNetworkFeeQuote
    ) async {
        let generation = UUID()
        estimationGeneration = generation
        let estimator = SendNetworkFeeEstimator(database: database)
        let unitPrice = await estimator.resolvedNativeUnitUSDPrice(
            networkID: asset.networkID,
            preferredPrice: nativeUnitUSDPrice
        )
        guard estimationGeneration == generation,
              let unitPrice else { return }

        let presetFees = Dictionary(
            uniqueKeysWithValues: [
                SendNetworkFeePreset.fastest,
                .standard,
                .economy
            ].compactMap { preset in
                quote.tier(for: preset).map { tier in
                    (
                        preset,
                        SendResolvedNetworkFee(
                            model: tier.model,
                            primaryValue: tier.primaryValue,
                            secondaryValue: tier.secondaryValue
                        )
                    )
                }
            }
        )
        var values = templateLocalFeeValues(
            presetFees: presetFees,
            unitPrice: unitPrice
        )
        if let custom = templateCustomLocalFeeValue(
            unitPrice: unitPrice
        ) {
            values[.custom] = custom
        }
        localFeeValues = values

        for preset in [
            SendNetworkFeePreset.fastest,
            .standard,
            .economy
        ] {
            guard estimationGeneration == generation,
                  let fee = presetFees[preset] else { continue }
            if let estimate = try? await estimator.estimateForDisplay(
                draft: draft
                    .replacingFeePolicy(.preset(preset)),
                fee: fee
            ), let usdValue = estimate.usdValue(
                unitUSDPrice: unitPrice
            ) {
                values[preset] = EnglishNumbers.networkFeeCurrency(
                    usdValue,
                    using: currencyContext
                )
            }
        }

        if let custom = await exactCustomLocalFeeValue(
            estimator: estimator,
            unitPrice: unitPrice
        ) {
            values[.custom] = custom
        }
        guard estimationGeneration == generation else { return }
        localFeeValues = values
    }

    private func templateLocalFeeValues(
        presetFees: [SendNetworkFeePreset: SendResolvedNetworkFee],
        unitPrice: Decimal
    ) -> [SendNetworkFeePreset: String] {
        var values: [SendNetworkFeePreset: String] = [:]
        for (preset, fee) in presetFees {
            guard let estimate = try? SendNetworkFeeEstimator
                .templateEstimate(draft: draft, fee: fee),
                  let usdValue = estimate.usdValue(
                      unitUSDPrice: unitPrice
                  ) else { continue }
            values[preset] = EnglishNumbers.networkFeeCurrency(
                usdValue,
                using: currencyContext
            )
        }
        return values
    }

    private func templateCustomLocalFeeValue(
        unitPrice: Decimal
    ) -> String? {
        guard !policy.requiresLiveQuote,
              let customFee = try? SendResolvedNetworkFee.resolveCustom(
                  policy: policy,
                  networkID: asset.networkID
              ), let estimate = try? SendNetworkFeeEstimator.templateEstimate(
                  draft: draft.replacingFeePolicy(policy),
                  fee: customFee
              ), let usdValue = estimate.usdValue(
                  unitUSDPrice: unitPrice
              ) else { return nil }
        return EnglishNumbers.networkFeeCurrency(
            usdValue,
            using: currencyContext
        )
    }

    private func exactCustomLocalFeeValue(
        estimator: SendNetworkFeeEstimator,
        unitPrice: Decimal
    ) async -> String? {
        guard !policy.requiresLiveQuote,
              let customFee = try? SendResolvedNetworkFee.resolveCustom(
                  policy: policy,
                  networkID: asset.networkID
              ), let estimate = try? await estimator.estimateForDisplay(
                  draft: draft.replacingFeePolicy(policy),
                  fee: customFee
              ), let usdValue = estimate.usdValue(
                  unitUSDPrice: unitPrice
              ) else { return nil }
        return EnglishNumbers.networkFeeCurrency(
            usdValue,
            using: currencyContext
        )
    }

    private func localFeeDetail(
        for preset: SendNetworkFeePreset
    ) -> String {
        localFeeValues[preset] ?? "—"
    }

    private var estimationInputID: String {
        [
            draft.amount ?? "",
            draft.recipient,
            String(draft.usesMaximumBalance),
            String(describing: draft.bitcoinFamilyOptions),
            currencyContext.code,
            NSDecimalNumber(decimal: currencyContext.ratePerUSD)
                .stringValue
        ].joined(separator: "|")
    }

    private func save(_ preset: SendNetworkFeePreset) {
        guard !isSaving else { return }
        isSaving = true
        saveError = nil
        Task {
            do {
                try await feePreferences.savePreset(preset)
                let nextPolicy = SendNetworkFeePolicy.preset(preset)
                policy = nextPolicy
                isSaving = false
                UniHaptic.play(.selection)
                onPolicyChanged(nextPolicy)
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

private struct SendNetworkFeeSelectionCheck: View {
    let isSelected: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDrawn = false

    var body: some View {
        ZStack {
            if isDrawn {
                Image(systemName: "checkmark")
                    .font(.system(size: 19, weight: WalletSFSymbol.weight))
                    .foregroundStyle(WalletTheme.accent)
                    .walletDrawOnTransition(options: .nonRepeating)
                    .symbolEffectsRemoved(reduceMotion)
            }
        }
        .frame(width: 28, height: 28, alignment: .center)
        .accessibilityHidden(true)
        .task(id: isSelected) {
            guard isSelected else {
                isDrawn = false
                return
            }
            await Task.yield()
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.32)) {
                isDrawn = true
            }
        }
    }
}
