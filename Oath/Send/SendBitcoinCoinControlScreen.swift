import SwiftUI

private enum SendBitcoinCoinControlMode: String, CaseIterable {
    case automatic
    case manual

    var titleKey: String {
        "send.coin_control.mode.\(rawValue)"
    }
}

struct SendBitcoinCoinControlScreen: View {
    let database: WalletDatabase
    let draft: SendDraft
    private var asset: SendAssetChoice { draft.asset }
    let chain: BitcoinFamilyChain
    let nativeUnitUSDPrice: Decimal?
    private var initialOptions: SendBitcoinFamilyOptions { draft.bitcoinFamilyOptions }
    let onApply: (SendBitcoinFamilyOptions) -> Void
    private let inputLoader: @Sendable (SendDraft) async throws -> SendBitcoinPlanningInputs
    private let planLoader: @Sendable (SendDraft, SendBitcoinPlanningInputs) async throws -> SendBitcoinSelectionPlan

    @Environment(\.dismiss) private var dismiss
    @Environment(\.walletCurrencyContext) private var currencyContext
    @State private var mode: SendBitcoinCoinControlMode
    @State private var loadState: LoadState = .loading
    @State private var selectedIDs: Set<String>
    @State private var validationMessage: String?
    @State private var staleSelectionMessage: String?

    private let requestedAtomic: String?

    private enum LoadState {
        case loading
        case loaded(LoadedOutputs)
        case failed(String)
    }

    private struct LoadedOutputs {
        let outputs: [SendBitcoinUTXO]
        let rows: [SendBitcoinCoinControlOutputPresentation]
        let automatic: AutomaticSelection
    }

    private enum AutomaticSelection {
        case loading
        case amountRequired
        case selected(SendBitcoinSelectionPlan)
        case failed(String)
    }

    private struct ManualSelectionSnapshot {
        let outputs: [SendBitcoinUTXO]
        let totalAtomic: String
        let requestedAtomic: String?

        var canApply: Bool {
            guard !outputs.isEmpty else { return false }
            guard let requestedAtomic else { return true }
            return SendBitcoinAtomicAmount.compare(
                totalAtomic,
                requestedAtomic
            ) != .orderedAscending
        }
    }

    init(
        database: WalletDatabase,
        draft: SendDraft,
        chain: BitcoinFamilyChain,
        nativeUnitUSDPrice: Decimal?,
        inputLoader: (@Sendable (SendDraft) async throws -> SendBitcoinPlanningInputs)? = nil,
        planLoader: (@Sendable (SendDraft, SendBitcoinPlanningInputs) async throws -> SendBitcoinSelectionPlan)? = nil,
        onApply: @escaping (SendBitcoinFamilyOptions) -> Void
    ) {
        self.database = database
        self.draft = draft
        self.chain = chain
        self.nativeUnitUSDPrice = nativeUnitUSDPrice
        self.onApply = onApply
        let estimator = SendNetworkFeeEstimator(database: database)
        self.inputLoader = inputLoader ?? { try await estimator.bitcoinPlanningInputs(draft: $0) }
        self.planLoader = planLoader ?? { draft, inputs in
            let quote = try await SendNetworkFeeQuoteRepository.shared.quote(for: draft.asset.networkID, database: database)
            let fee = try SendResolvedNetworkFee.resolve(policy: draft.feePolicy, quote: quote)
            return try await estimator.bitcoinFamilyPlan(draft: draft, fee: fee, loadedInputs: inputs)
        }
        requestedAtomic = draft.amount.flatMap {
            try? SendNetworkFeeBaseUnitConverter.baseUnits(
                from: $0,
                decimals: draft.asset.decimals,
                permitsZero: false
            )
        }
        let selected = draft.bitcoinFamilyOptions.coinSelection.selectedUTXOs
        _mode = State(
            initialValue: selected.isEmpty ? .automatic : .manual
        )
        _selectedIDs = State(
            initialValue: Set(selected.map(\.id))
        )
    }

    var body: some View {
        let selection = manualSelectionSnapshot

        List {
            Group {
                Section {
                    Picker(
                        "send.coin_control.mode.label",
                        selection: $mode
                    ) {
                        ForEach(
                            SendBitcoinCoinControlMode.allCases,
                            id: \.self
                        ) { option in
                            Text(LocalizedStringKey(option.titleKey))
                                .tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("sendCoinControlMode")
                } footer: {
                    Text(
                        mode == .automatic
                            ? "send.coin_control.automatic.footer"
                            : "send.coin_control.manual.footer"
                    )
                }

                if mode == .manual {
                    manualOutputContent(selection: selection)
                } else {
                    automaticOutputContent
                }

                if let staleSelectionMessage {
                    Section {
                        Text(verbatim: staleSelectionMessage)
                            .foregroundStyle(WalletTheme.warning)
                    }
                }

                if let validationMessage {
                    Section {
                        Text(verbatim: validationMessage)
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
        .navigationTitle("send.coin_control.title")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                WalletCloseButton { dismiss() }
                    .accessibilityIdentifier("sendCoinControlClose")
            }
            ToolbarItem(placement: .confirmationAction) {
                WalletConfirmationButton("send.coin_control.apply", action: apply)
                    .disabled(mode == .manual && !selection.canApply)
                    .accessibilityIdentifier("sendCoinControlConfirm")
            }
        }
        .task(id: chain.networkID) {
            await loadOutputs()
        }
        .onChange(of: mode) {
            validationMessage = nil
            UniHaptic.play(.selection)
        }
    }

    @ViewBuilder
    private func manualOutputContent(
        selection: ManualSelectionSnapshot
    ) -> some View {
        switch loadState {
        case .loading:
            loadingOutputs(titleKey: "send.coin_control.outputs.section")
        case let .loaded(loaded):
            if loaded.outputs.isEmpty {
                Section {
                    WalletEmptyStateView("send.coin_control.empty")
                        .frame(maxWidth: .infinity)
                        .listRowSeparator(.hidden)
                } header: {
                    Text("send.coin_control.outputs.section")
                }
            } else {
                Section {
                    ForEach(loaded.rows) { row in
                        outputRow(row)
                    }
                } header: {
                    Text("send.coin_control.outputs.section")
                } footer: {
                    Text(
                        verbatim: selectionSummary(
                            selection: selection
                        )
                    )
                }
            }
        case let .failed(message):
            Section {
                Text(verbatim: message)
                    .foregroundStyle(WalletTheme.danger)
                Button("common.retry", action: UniHaptic.action {
                    Task { await loadOutputs() }
                })
                .foregroundStyle(WalletTheme.accent)
            } header: {
                Text("send.coin_control.outputs.section")
            }
        }
    }

    private func loadingOutputs(titleKey: String) -> some View {
            Section {
                ForEach(0..<4, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 8) {
                        Capsule()
                            .fill(WalletTheme.tertiaryFill)
                            .frame(maxWidth: 150)
                            .frame(height: 16)
                        Capsule()
                            .fill(WalletTheme.tertiaryFill)
                            .frame(maxWidth: 260)
                            .frame(height: 13)
                    }
                    .sendSkeletonPulse()
                    .accessibilityHidden(true)
                }
            } header: {
                Text(LocalizedStringKey(titleKey))
            }
    }

    @ViewBuilder
    private var automaticOutputContent: some View {
        if requestedAtomic == nil {
            Section {
                Text("send.coin_control.automatic.amount_required")
                    .foregroundStyle(WalletTheme.secondaryLabel)
                    .accessibilityIdentifier("sendCoinControlAmountRequired")
            }
        } else {
            switch loadState {
            case .loading, .failed:
                manualOutputContent(selection: manualSelectionSnapshot)
            case let .loaded(loaded):
                switch loaded.automatic {
                case .loading:
                    loadingOutputs(titleKey: "send.coin_control.automatic.outputs.section")
                case .amountRequired:
                    EmptyView()
                case let .failed(message):
                    Section {
                        Text(verbatim: message).foregroundStyle(WalletTheme.danger)
                        Button("common.retry", action: UniHaptic.action {
                            Task { await loadOutputs() }
                        })
                    }
                case let .selected(plan):
                    let selected = Set(plan.outputs.map(\.id))
                    Section {
                        ForEach(loaded.rows.filter { selected.contains($0.id) }) { row in
                            outputContent(row, selected: true)
                                .accessibilityElement(children: .combine)
                                .accessibilityIdentifier("sendAutomaticOutput.\(row.id)")
                        }
                    } header: {
                        Text("send.coin_control.automatic.outputs.section")
                    } footer: {
                        Text(verbatim: EnglishNumbers.localized(
                            "send.coin_control.selected_summary", plan.outputs.count,
                            formattedAtomicAmount(SendBitcoinAtomicAmount.sum(plan.outputs.map(\.valueAtomic)))
                        ))
                    }
                }
            }
        }
    }

    private func outputRow(
        _ row: SendBitcoinCoinControlOutputPresentation
    ) -> some View {
        let selected = selectedIDs.contains(row.id)
        return Button(action: UniHaptic.action {
            validationMessage = nil
            if selected {
                selectedIDs.remove(row.id)
            } else {
                selectedIDs.insert(row.id)
            }
            UniHaptic.play(.selection)
        }) {
            outputContent(row, selected: selected)
        }
        .buttonStyle(.automatic)
        .accessibilityIdentifier("sendManualOutput.\(row.id)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityValue(
            Text(
                selected
                    ? "selection.selected"
                    : "selection.not_selected"
            )
        )
    }

    private func outputContent(
        _ row: SendBitcoinCoinControlOutputPresentation, selected: Bool
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: row.localAmount)
                    .foregroundStyle(WalletTheme.secondaryLabel)
                Text(verbatim: row.nativeAmount)
                    .font(.subheadline)
                    .foregroundStyle(WalletTheme.secondaryLabel)
                if let addressType = row.addressType {
                    Text(verbatim: addressType)
                        .font(.caption)
                        .foregroundStyle(WalletTheme.secondaryLabel)
                }
                Text(verbatim: row.confirmation)
                    .font(.caption)
                    .foregroundStyle(WalletTheme.secondaryLabel)
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            SendBitcoinCoinControlSelectionCheck(
                isSelected: selected
            )
        }
        .contentShape(Rectangle())
    }

    private var loadedOutputs: [SendBitcoinUTXO] {
        if case let .loaded(loaded) = loadState {
            return loaded.outputs
        }
        return []
    }

    private var manualSelectionSnapshot: ManualSelectionSnapshot {
        let outputs = loadedOutputs.filter {
            selectedIDs.contains($0.id)
        }
        let totalAtomic = SendBitcoinAtomicAmount.sum(
            outputs.map(\.valueAtomic)
        )
        return ManualSelectionSnapshot(
            outputs: outputs,
            totalAtomic: totalAtomic,
            requestedAtomic: requestedAtomic
        )
    }

    private func selectionSummary(
        selection: ManualSelectionSnapshot
    ) -> String {
        EnglishNumbers.localized(
            "send.coin_control.selected_summary",
            selection.outputs.count,
            formattedAtomicAmount(selection.totalAtomic)
        )
    }

    @MainActor
    private func loadOutputs() async {
        loadState = .loading
        staleSelectionMessage = nil
        validationMessage = nil
        do {
            let automaticDraft = draft.replacingBitcoinFamilyOptions(
                initialOptions.replacingCoinSelection(.automatic)
            )
            async let inputRequest = inputLoader(automaticDraft)
            let unitUSDPrice = await resolvedUnitUSDPrice()
            let inputs = try await inputRequest
            try Task.checkCancellation()
            let outputs = inputs.outputs
            let availableIDs = Set(outputs.map(\.id))
            let staleCount = selectedIDs.subtracting(availableIDs).count
            selectedIDs.formIntersection(availableIDs)
            if staleCount > 0 {
                staleSelectionMessage = EnglishNumbers.localized(
                    "send.coin_control.stale_selection",
                    staleCount
                )
            }
            let rows = outputs.map {
                SendBitcoinCoinControlOutputPresentation(output: $0, asset: asset,
                    unitUSDPrice: unitUSDPrice, currency: currencyContext,
                    accountAddress: inputs.account.address)
            }
            // Manual rows depend only on the fresh outputs. Fee loading and
            // automatic planning must not delay their presentation.
            loadState = .loaded(LoadedOutputs(outputs: outputs, rows: rows,
                automatic: requestedAtomic == nil ? .amountRequired : .loading))
            guard requestedAtomic != nil else { return }
            let automatic: AutomaticSelection
            do {
                automatic = .selected(try await planLoader(automaticDraft, inputs))
            } catch is CancellationError { return }
            catch { automatic = .failed(Self.message(for: error)) }
            try Task.checkCancellation()
            loadState = .loaded(LoadedOutputs(outputs: outputs, rows: rows, automatic: automatic))
        } catch is CancellationError {
            return
        } catch let error as SendBitcoinUTXORepositoryError {
            loadState = .failed(error.localizedMessage)
        } catch {
            loadState = .failed(Self.message(for: error))
        }
    }

    private static func message(for error: Error) -> String {
        if let error = error as? SendNetworkFeeAPIError { return error.localizedMessage }
        if let error = error as? SendTransactionSubmissionError { return error.localizedMessage }
        if let error = error as? SendBitcoinUTXORepositoryError { return error.localizedMessage }
        if let error = error as? SendBitcoinFamilyOptionsError { return error.localizedMessage }
        return EnglishNumbers.localized("send.network_fee.error.unexpected",
            SendTransactionSubmissionError.sanitizedErrorType(error))
    }

    @MainActor
    private func apply() {
        validationMessage = nil
        let selection = manualSelectionSnapshot
        let nextSelection: SendBitcoinCoinSelection
        switch mode {
        case .automatic:
            nextSelection = .automatic
        case .manual:
            guard !selection.outputs.isEmpty else {
                validationMessage =
                    SendBitcoinFamilyOptionsError.emptySelection
                        .localizedMessage
                UniHaptic.play(.error)
                return
            }
            guard selection.canApply else {
                validationMessage =
                    SendBitcoinFamilyOptionsError
                        .insufficientSelectedValue.localizedMessage
                UniHaptic.play(.error)
                return
            }
            nextSelection = .manual(selection.outputs)
        }
        do {
            let options = try initialOptions
                .replacingCoinSelection(nextSelection)
                .normalized(for: chain)
            onApply(options)
            UniHaptic.play(.selection)
            dismiss()
        } catch let error as SendBitcoinFamilyOptionsError {
            validationMessage = error.localizedMessage
            UniHaptic.play(.error)
        } catch {
            validationMessage = WalletLocalization.string(
                "send.coin_control.error.unexpected"
            )
            UniHaptic.play(.error)
        }
    }

    private func formattedAtomicAmount(_ value: String) -> String {
        let userUnits = SendDecimalAmount.userUnits(
            fromAtomicUnits: value,
            decimals: asset.decimals
        )
        return EnglishNumbers.localized(
            "wallet.format.asset_amount",
            userUnits,
            asset.symbol
        )
    }

    private func resolvedUnitUSDPrice() async -> Decimal? {
        if let unitUSDPrice = SendAmountPresentation.unitUSDPrice(
            for: asset,
            nativeUnitUSDPrice: nativeUnitUSDPrice
        ), unitUSDPrice > 0 {
            return unitUSDPrice
        }
        let assetID = AssetIdentityKey.make(
            networkID: chain.networkID,
            contractAddress: nil
        )
        let cachedPrice = (try? await database.cachedAssetUSDPrice(
            assetID: assetID
        ))?.price
        guard let cachedPrice, cachedPrice > 0 else { return nil }
        return cachedPrice
    }
}
