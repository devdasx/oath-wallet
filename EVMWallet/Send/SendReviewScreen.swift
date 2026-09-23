import SwiftUI

struct SendReviewScreen: View {
    let database: WalletDatabase
    let feePreferences: SendNetworkFeePreferenceRepository
    let draft: SendDraft
    let nativeUnitUSDPrice: Decimal?
    let isAuthorizing: Bool
    let slideResetID: UUID?
    let onContinue: (SendDraft) -> Void

    @Environment(\.walletCurrencyContext) private var currencyContext
    @State private var feePolicy: SendNetworkFeePolicy
    @State private var feeState: SendReviewFeeState
    @State private var bitcoinFamilyOptions:
        SendBitcoinFamilyOptions
    @State private var cachedAssetUnitUSDPrice: Decimal?
    @State private var transferAmountPriceIsLoading: Bool
    @State private var isNetworkFeePresented = false
    @State private var depositFunding: SendReviewFunding?
    @State private var hasLoadedFeePreferences = false
    @State private var feeLoadRevision = UUID()
    @Environment(\.scenePhase) private var scenePhase
    @State private var opReturnDetail: SendOPReturnMessageDetailScreen.Content?

    init(
        database: WalletDatabase,
        feePreferences: SendNetworkFeePreferenceRepository? = nil,
        draft: SendDraft,
        nativeUnitUSDPrice: Decimal? = nil,
        isAuthorizing: Bool = false,
        slideResetID: UUID? = nil,
        onContinue: @escaping (SendDraft) -> Void = { _ in }
    ) {
        self.database = database
        self.feePreferences = feePreferences
            ?? SendNetworkFeePreferenceRepository(database: database)
        self.draft = draft
        self.nativeUnitUSDPrice = nativeUnitUSDPrice
        self.isAuthorizing = isAuthorizing
        self.slideResetID = slideResetID
        self.onContinue = onContinue
        _feePolicy = State(initialValue: draft.feePolicy)
        _feeState = State(initialValue: SendReviewFeeState(
            draft: draft,
            nativeUnitUSDPrice: nativeUnitUSDPrice
        ))
        _bitcoinFamilyOptions = State(
            initialValue: draft.bitcoinFamilyOptions
        )
        _transferAmountPriceIsLoading = State(
            initialValue: SendAmountPresentation.unitUSDPrice(
                for: draft.asset,
                nativeUnitUSDPrice: nativeUnitUSDPrice
            ) == nil
        )
    }

    var body: some View {
        List {
            Group {
                Section {
                    HStack(spacing: 14) {
                        AssetLogoView(
                            source: draft.asset.logoSource,
                            size: 44,
                            animatesChanges: false,
                            diagnosticAssetIdentity: draft.asset.id
                        )

                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: draft.asset.name)
                                .font(WalletTypography.listRowTitle)
                            HStack(spacing: 6) {
                                AssetLogoView(
                                    source: draft.asset.networkLogoSource,
                                    size: 18,
                                    animatesChanges: false,
                                    diagnosticAssetIdentity:
                                        draft.asset.networkID
                                )
                                Text(verbatim: draft.asset.networkName)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)

                } header: {
                    Text("send.review.asset.section")
                }

                Section {
                    WalletExactText(draft.recipient)
                        .fixedSize(horizontal: false, vertical: true)
                } header: {
                    Text("send.recipient.section")
                }

                Section {
                    LabeledContent("wallet.transaction.details.amount") {
                        transferAmountValue
                    }

                    LabeledContent("wallet.transaction.details.network_fee") {
                        networkFeeValue
                    }

                    if let feeQuoteErrorMessage {
                        Text(verbatim: feeQuoteErrorMessage)
                            .foregroundStyle(WalletTheme.danger)
                        if let funding = feeState.funding {
                            Button(funding.actionTitle) { depositFunding = funding }
                                .foregroundStyle(WalletTheme.accent)
                        }
                        Button("common.retry", action: UniHaptic.action {
                            restartFeeLoading()
                        })
                        .foregroundStyle(WalletTheme.accent)
                    } else if feeState.isCheckingFunds && !feeState.canContinue {
                        Text("send.network_fee.loading")
                            .foregroundStyle(WalletTheme.secondaryLabel)
                    }
                }

                if let bitcoinFamilyChain {
                    Section {
                        LabeledContent("send.coin_control.option") {
                            Text(verbatim: coinSelectionDescription)
                                .multilineTextAlignment(.trailing)
                        }
                    } header: {
                        Text(
                            verbatim: bitcoinFamilyChain
                                .transactionControlsTitle
                        )
                    }
                }

                if let opReturnMessage =
                    bitcoinFamilyOptions.opReturnMessage {
                    Section {
                        SendOPReturnMessagePreview(message: opReturnMessage) {
                            opReturnDetail = .init(message: opReturnMessage)
                        }
                    } header: {
                        Text("send.bitcoin.op_return.title")
                    } footer: {
                        Text(verbatim: opReturnByteCountDescription)
                    }
                }

                if hasPaymentMetadata {
                    Section {
                        if let label = draft.request.label {
                            LabeledContent("send.review.label") {
                                Text(verbatim: label)
                            }
                        }
                        if let message = draft.request.message {
                            LabeledContent("send.review.message") {
                                Text(verbatim: message)
                            }
                        }
                        if let memo = draft.request.memo {
                            LabeledContent("send.review.memo") {
                                Text(verbatim: memo)
                            }
                        }
                        if !draft.request.references.isEmpty {
                            LabeledContent("send.review.references") {
                                Text(
                                    verbatim: EnglishNumbers.decimal(
                                        Decimal(
                                            draft.request.references.count
                                        ),
                                        maximumFractionDigits: 0
                                    )
                                )
                            }
                        }
                    } header: {
                        Text("send.review.request_details.section")
                    }
                }
            }
            .walletListRowSurface()
        }
        .walletListAppearance()
        .listStyle(.insetGrouped)
        .walletCallSafetyWarning(.sending)
        .listSectionSpacing(12)
        .contentMargins(.top, 12, for: .scrollContent)
        .scrollContentBackground(.hidden)
        .background(WalletTheme.groupedBackground)
        .navigationTitle("send.review.title")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(action: UniHaptic.action(nil) {
                        isNetworkFeePresented = true
                    }) {
                        Text("send.network_fee.action")
                    }

                    if let bitcoinFamilyChain,
                       bitcoinFamilyChain.supportsReplaceByFee {
                        Toggle(
                            "send.rbf.section",
                            isOn: replaceByFeeBinding(
                                chain: bitcoinFamilyChain
                            )
                        )
                        .accessibilityIdentifier(
                            "sendReviewReplaceByFee"
                        )
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel(
                    Text("send.transaction_options.action")
                )
                .accessibilityIdentifier("sendReviewOptions")
            }
        }
        .walletSafeAreaBar(edge: .bottom, spacing: 0) {
            SendSlideControl(
                isEnabled: !isAuthorizing && !isNetworkFeePresented
                    && opReturnDetail == nil && depositFunding == nil && feeState.canContinue,
                isLoadingFee: !isAuthorizing && feeState.isCheckingFunds && !feeState.canContinue,
                resetID: slideResetID,
                onSend: continueWithOptions
            )
            .frame(maxWidth: 560)
            .padding(.horizontal, 28)
            .padding(.top, 12)
            .padding(.bottom, 8)
        }
        .onDisappear { feeState.invalidatePendingUpdates() }
        .sheet(item: $depositFunding) { funding in
            SendFeeDepositScreen(funding: funding)
                .walletLocalePresentation()
                .presentationDragIndicator(.visible)
        }
        .task(id: feeLoadID) {
            // Each lifecycle task owns its publishers; a rapid scene change
            // cannot leave a cancelled predecessor occupying the request slot.
            feeState.invalidatePendingUpdates()
            guard feeLoadID.draft != nil else { return }
            await loadFeeState()
        }
        .task(id: draft.asset.id) {
            await loadTransferAmountPrice()
        }
        .sheet(item: $opReturnDetail) { content in
            SendOPReturnMessageDetailScreen(content: content)
                .walletSheetPresentation()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $isNetworkFeePresented) {
            SendNetworkFeeFlowScreen(
                database: database,
                feePreferences: feePreferences,
                draft: draft
                    .replacingFeePolicy(feePolicy)
                    .replacingBitcoinFamilyOptions(
                        bitcoinFamilyOptions
                    ),
                nativeUnitUSDPrice: nativeUnitUSDPrice,
                initialPolicy: feePolicy,
                onPolicyChanged: { nextPolicy in
                    feePolicy = nextPolicy
                    feeState.reset(draft: currentFeeDraft)
                }
            )
            .walletLocalePresentation()
            .presentationDragIndicator(.visible)
            .presentationBackground(WalletTheme.groupedBackground)
        }
    }

    private var formattedAmount: String {
        SendAmountPresentation.formatted(
            amount: feeState.estimate?.applyingNativeAmount(to: draft).amount ?? draft.amount ?? "0",
            asset: draft.asset,
            currency: currencyContext,
            nativeUnitUSDPrice: nativeUnitUSDPrice,
            cachedAssetUnitUSDPrice: cachedAssetUnitUSDPrice
        )
    }

    @ViewBuilder
    private var transferAmountValue: some View {
        if draft.asset.isNative, let amount = feeState.estimate?.nativeTransferAmountAtomic {
            VStack(alignment: .trailing, spacing: 2) {
                Text(verbatim: EnglishNumbers.localized("wallet.format.asset_amount",
                    SendDecimalAmount.userUnits(fromAtomicUnits: amount, decimals: draft.asset.decimals),
                    draft.asset.symbol))
                if SendAmountPresentation.unitUSDPrice(for: draft.asset,
                    nativeUnitUSDPrice: nativeUnitUSDPrice, cachedAssetUnitUSDPrice: cachedAssetUnitUSDPrice) != nil {
                    Text(verbatim: formattedAmount).font(.caption).foregroundStyle(.secondary)
                }
            }
            .multilineTextAlignment(.trailing)
        } else if transferAmountPriceIsLoading {
            Capsule()
                .fill(WalletTheme.tertiaryFill)
                .frame(maxWidth: 112)
                .frame(height: 14)
                .sendSkeletonPulse()
                .accessibilityHidden(true)
        } else {
            Text(verbatim: formattedAmount)
                .multilineTextAlignment(.trailing)
        }
    }

    @ViewBuilder
    private var networkFeeValue: some View {
        if let networkFeeNativeText {
            VStack(alignment: .trailing, spacing: 2) {
                Text(verbatim: networkFeeNativeText)
                if let networkFeeUSDValue {
                    Text(
                        verbatim: EnglishNumbers.networkFeeCurrency(
                            networkFeeUSDValue,
                            using: currencyContext
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .multilineTextAlignment(.trailing)
        } else {
            Text(verbatim: "—")
                .foregroundStyle(.secondary)
        }
    }

    private var hasPaymentMetadata: Bool {
        draft.request.label != nil
            || draft.request.message != nil
            || draft.request.memo != nil
            || !draft.request.references.isEmpty
    }

    private var bitcoinFamilyChain: BitcoinFamilyChain? {
        BitcoinFamilyChain(rawValue: draft.asset.networkID)
    }

    private var coinSelectionDescription: String {
        switch bitcoinFamilyOptions.coinSelection {
        case .automatic:
            WalletLocalization.string(
                "send.coin_control.mode.automatic"
            )
        case let .manual(outputs):
            EnglishNumbers.localized(
                "send.coin_control.selected_count",
                outputs.count
            )
        }
    }

    private var opReturnByteCountDescription: String {
        let message = bitcoinFamilyOptions.opReturnMessage ?? ""
        return EnglishNumbers.localized(
            "send.bitcoin.op_return.byte_count",
            SendBitcoinOPReturn.byteCount(message),
            SendBitcoinOPReturn.maximumPayloadBytes,
            SendBitcoinOPReturn.remainingByteCount(message)
        )
    }

    private func replaceByFeeBinding(
        chain: BitcoinFamilyChain
    ) -> Binding<Bool> {
        Binding(
            get: { bitcoinFamilyOptions.replaceByFee },
            set: { isEnabled in
                bitcoinFamilyOptions = bitcoinFamilyOptions
                    .replacingReplaceByFee(
                        isEnabled,
                        chain: chain
                    )
                feeState.reset(draft: currentFeeDraft)
                UniHaptic.play(.selection)
            }
        )
    }

    private func continueWithOptions() {
        guard let preparedNetworkFee = feeState.feeForAuthorization() else {
            UniHaptic.play(.error)
            return
        }
        let reviewedDraft = draft
            .replacingFeePolicy(feePolicy)
            .replacingBitcoinFamilyOptions(
                bitcoinFamilyOptions
            )
        let amountAdjustedDraft = feeState.estimate?.applyingNativeAmount(to: reviewedDraft) ?? reviewedDraft
        onContinue(
            amountAdjustedDraft.replacingPreparedNetworkFee(
                preparedNetworkFee
            )
        )
    }

    @MainActor
    private func loadTransferAmountPrice() async {
        guard SendAmountPresentation.unitUSDPrice(
            for: draft.asset,
            nativeUnitUSDPrice: nativeUnitUSDPrice,
            cachedAssetUnitUSDPrice: cachedAssetUnitUSDPrice
        ) == nil else {
            transferAmountPriceIsLoading = false
            return
        }

        transferAmountPriceIsLoading = true
        let assetID = AssetIdentityKey.canonical(draft.asset.id)
        let cachedPrice = (try? await database.cachedAssetUSDPrice(
            assetID: assetID
        ))?.price
        guard !Task.isCancelled else { return }
        cachedAssetUnitUSDPrice = cachedPrice
        transferAmountPriceIsLoading = false
    }

    private var currentFeeDraft: SendDraft {
        draft.replacingFeePolicy(feePolicy)
            .replacingBitcoinFamilyOptions(bitcoinFamilyOptions)
    }

    private struct FeeLoadID: Hashable {
        let draft: SendDraft?
        let retry: UUID
    }

    private var feeLoadID: FeeLoadID {
        FeeLoadID(
            draft: scenePhase == .active && !isAuthorizing && depositFunding == nil ? currentFeeDraft : nil,
            retry: feeLoadRevision
        )
    }

    private func restartFeeLoading() {
        feeState.invalidatePendingUpdates()
        feeLoadRevision = UUID()
    }

    private var feeQuoteErrorMessage: String? { feeState.errorMessage }
    private var networkFeeUSDValue: Decimal? { feeState.usdValue }
    private var networkFeeNativeText: String? {
        feeState.estimate.map { estimate in
            EnglishNumbers.localized(
                "wallet.format.asset_amount",
                SendDecimalAmount.userUnits(
                    fromAtomicUnits: estimate.atomicAmount,
                    decimals: estimate.nativeDecimals
                ),
                Self.nativeFeeSymbol(for: draft.asset.networkID)
            )
        }
    }

    @MainActor
    private func loadFeeState() async {
        guard !Task.isCancelled, !isAuthorizing else { return }
        feeState.reset(draft: currentFeeDraft)
        guard !feeState.canContinue else { return }
        if !hasLoadedFeePreferences {
            let revision = feeState.revision
            let savedPolicy = try? await feePreferences.policy(for: draft.asset.networkID)
            guard feeState.revision == revision, !Task.isCancelled else { return }
            hasLoadedFeePreferences = true
            if let savedPolicy, savedPolicy != feePolicy {
                feePolicy = savedPolicy
                feeState.reset(draft: currentFeeDraft)
                // The changed draft starts the single lifecycle-owned task again.
                return
            }
        }
        guard !Task.isCancelled, !isAuthorizing else { return }
        await loadFeePresentation()
    }

    @MainActor
    private func loadFeePresentation() async {
        let estimator = SendNetworkFeeEstimator(database: database)
        let networkID = draft.asset.networkID
        let preferredPrice = nativeUnitUSDPrice
        await feeState.refresh(
            draft: currentFeeDraft,
            quoteLoader: { try await SendNetworkFeeQuoteRepository.shared.quote(for: $0, database: database) },
            estimateLoader: { try await SendReviewFundsValidator(database: database).estimate(draft: $0, fee: $1) },
            priceLoader: {
                await estimator.resolvedNativeUnitUSDPrice(
                    networkID: networkID, preferredPrice: preferredPrice
                )
            }
        )
    }

    private static func nativeFeeSymbol(for networkID: String) -> String {
        if let chain = BitcoinFamilyChain(rawValue: networkID) {
            return chain.symbol
        }
        return ReceiveNetworkCatalog.catalogNetwork(
            for: networkID
        )?.symbol ?? networkID.uppercased()
    }
}
