import SwiftUI

struct SendAmountScreen: View {
    let database: WalletDatabase
    let feePreferences: SendNetworkFeePreferenceRepository
    let draft: SendDraft
    let nativeUnitUSDPrice: Decimal?
    let initialValidationFailure: SendDraftValidationFailure?
    let onStateChange: (SendAmountEntryState) -> Void
    let onReview: (SendDraft) -> Void

    @Environment(WalletSettingsStore.self) private var applicationSettings
    @Environment(\.walletCurrencyContext) private var currencyContext
    @State private var entry: SendAmountEntryState
    @State private var amountTypingRevision = 0
    @State private var cachedAssetUnitUSDPrice: Decimal?
    @State private var isNetworkFeePresented = false
    @State private var isCoinControlPresented = false
    @State private var isOPReturnPresented = false
    @State private var hasAttemptedReview = false
    @State private var requirementModel = SendRecipientRequirementModel()
    @ScaledMetric(relativeTo: .body)
    private var amountControlDiameter = 52
    private let amountControlSpacing: CGFloat = 12

    init(
        database: WalletDatabase,
        feePreferences: SendNetworkFeePreferenceRepository? = nil,
        draft: SendDraft,
        nativeUnitUSDPrice: Decimal? = nil,
        initialValidationFailure: SendDraftValidationFailure? = nil,
        initialState: SendAmountEntryState? = nil,
        onStateChange: @escaping (SendAmountEntryState) -> Void = { _ in },
        onReview: @escaping (SendDraft) -> Void
    ) {
        self.database = database
        self.feePreferences = feePreferences
            ?? SendNetworkFeePreferenceRepository(database: database)
        self.draft = draft
        self.nativeUnitUSDPrice = nativeUnitUSDPrice
        self.initialValidationFailure = initialValidationFailure
        self.onStateChange = onStateChange
        self.onReview = onReview
        _entry = State(initialValue: initialState ?? SendAmountEntryState(draft: draft))
    }

    var body: some View {
        GeometryReader { geometry in
            // A short, wide window needs room for the form beside the controls.
            // Both arrangements keep the keypad at the bottom, outside the List.
            if geometry.size.width >= 600 && geometry.size.height < 500 {
                HStack(spacing: 0) {
                    amountList
                    compactControls
                        .frame(width: min(440, geometry.size.width / 2))
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
            } else {
                VStack(spacing: 0) {
                    amountList
                    bottomControls(keyHeight: max(44, min(80, geometry.size.height * 0.1)))
                }
            }
        }
        .background(WalletTheme.groupedBackground)
        .navigationTitle("send.amount.section")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("send.network_fee.action", action: UniHaptic.action(nil) {
                        isNetworkFeePresented = true
                    })
                    .accessibilityIdentifier("sendAmountNetworkFee")

                    if bitcoinFamilyChain != nil {
                        Button("send.coin_control.option", action: UniHaptic.action(nil) {
                            isCoinControlPresented = true
                        })
                        .accessibilityIdentifier("sendAmountCoinControl")
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
                            "sendAmountReplaceByFee"
                        )
                    }

                    if bitcoinFamilyChain?.supportsOPReturn == true {
                        Button("send.bitcoin.op_return.insert", action: UniHaptic.action(nil) {
                            isOPReturnPresented = true
                        })
                        .accessibilityIdentifier(
                            "sendAmountOPReturn"
                        )
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel(Text("send.transaction_options.action"))
                .accessibilityIdentifier("sendAmountOptions")
            }
        }
        .task {
            requirementModel.schedule(
                input: SendRecipientRequirementInput(
                    asset: draft.asset,
                    sourceRecipient: draft.recipient,
                    checkedRecipient: draft.recipient
                ),
                asset: draft.asset,
                debounce: .zero
            )
            if amountUnitUSDPrice == nil {
                await loadAmountPrice()
            }
            guard !Task.isCancelled else { return }
            if !entry.hasEditedAmount {
                entry.applyPreferredMode(
                    applicationSettings.sendAmountEntryMode,
                    asset: draft.asset, currency: currencyContext, unitUSDPrice: amountUnitUSDPrice
                )
            }

        }
        .onDisappear {
            requirementModel.cancelScheduledRefresh()
            onStateChange(entry)
        }
        .sheet(isPresented: $isNetworkFeePresented) {
            SendNetworkFeeFlowScreen(
                database: database,
                feePreferences: feePreferences,
                draft: networkFeeDraft,
                nativeUnitUSDPrice: nativeUnitUSDPrice,
                initialPolicy: entry.feePolicy,
                onPolicyChanged: { entry.feePolicy = $0 }
            )
            .walletLocalePresentation()
            .presentationDragIndicator(.visible)
            .walletSheetPresentation(nativeGlass: false)
        }
        .sheet(isPresented: $isCoinControlPresented) {
            if let bitcoinFamilyChain {
                NavigationStack {
                    SendBitcoinCoinControlScreen(
                        database: database,
                        draft: networkFeeDraft,
                        chain: bitcoinFamilyChain,
                        nativeUnitUSDPrice: nativeUnitUSDPrice,
                        onApply: { entry.bitcoinFamilyOptions = $0 }
                    )
                }
                .walletLocalePresentation()
                .presentationDragIndicator(.visible)
                .walletSheetPresentation(nativeGlass: false)
            }
        }
        .sheet(isPresented: $isOPReturnPresented) {
            SendBitcoinOPReturnScreen(
                initialMessage:
                    entry.bitcoinFamilyOptions.opReturnMessage,
                onSave: { message in
                    entry.bitcoinFamilyOptions = entry
                        .bitcoinFamilyOptions
                        .replacingOPReturnMessage(message)
                }
            )
            .walletLocalePresentation()
            .presentationDragIndicator(.visible)
            .presentationBackground(WalletTheme.groupedBackground)
        }
    }

    private var amountList: some View {
        List {
            Group {
                Section {
                    UnifiedAssetSelectionRow(
                        name: draft.asset.name,
                        symbol: draft.asset.symbol,
                        logoSource: draft.asset.logoSource,
                        networkLogoSource: draft.asset.networkLogoSource,
                        familyLogoSource: draft.asset.familyLogoSource,
                        balance: draft.asset.balance,
                        fiatValue: draft.asset.fiatValue,
                        isBalanceHidden: applicationSettings.balancePrivacyEnabled,
                        logoDiagnosticIdentity: draft.asset.id
                    )
                    .accessibilityIdentifier("sendAmountBalance")
                } header: {
                    Text("send.selected_asset.section")
                }

                Section {
                    let presentation = amountPresentation
                    VStack(spacing: 8) {
                        ZStack {
                            SendAmountValue(
                                value: entry.input,
                                unit: presentation.unit,
                                typingRevision: amountTypingRevision,
                                currencyPrefix: presentation.currencyPrefix,
                                isInvalid: amountExceedsBalance
                            )
                            // Reserve space for Max only on its side. Let long
                            // amounts use the trailing space before scaling down.
                            .padding(
                                .leading,
                                amountControlDiameter + amountControlSpacing
                            )
                            .padding(.trailing, 20)

                            HStack(spacing: 0) {
                                amountMaximumControl
                                Spacer(minLength: 0)
                            }
                        }

                        if let counterpart = presentation.counterpart {
                            amountModeControl(counterpart: counterpart)
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } footer: {
                    amountFeedback
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
        // Measure the real button height, including its current Dynamic Type
        // size, instead of estimating how much space it leaves for the keys.
        ViewThatFits(in: .vertical) {
            bottomControls(keyHeight: 64, compact: true)
                .fixedSize(horizontal: false, vertical: true)
            bottomControls(keyHeight: 52, compact: true)
                .fixedSize(horizontal: false, vertical: true)
            bottomControls(keyHeight: 44, compact: true)
                .fixedSize(horizontal: false, vertical: true)
            // Very short accessibility-size windows can scroll the controls
            // independently without shrinking targets below 44 points.
            ScrollView {
                bottomControls(keyHeight: 44, compact: true)
            }
        }
    }

    private func bottomControls(keyHeight: CGFloat, compact: Bool = false) -> some View {
        VStack(spacing: compact ? 4 : 12) {
            PrimaryWalletButton(title: "send.review.action", hapticPolicy: .silent, action: review)
                .disabled(!canReview)
                .accessibilityIdentifier("sendAmountReview")
                .walletActionScreenMargins()

            SendAmountKeypad(
                input: entry.input,
                maximumFractionDigits: entry.maximumFractionDigits(for: draft.asset),
                keyHeight: keyHeight,
                verticalSpacing: compact ? 0 : 8
            ) { key in
                let previouslyExceededBalance = amountExceedsBalance
                if entry.press(key, asset: draft.asset) {
                    amountTypingRevision &+= 1
                    if !previouslyExceededBalance
                        && amountExceedsBalance {
                        UniHaptic.play(.error)
                    } else {
                        UniHaptic.play(.selection)
                    }
                }
            }
            .frame(maxWidth: 560)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity)
        }
        .padding(.top, compact ? 0 : 8)
        .padding(.bottom, compact ? 4 : 8)
        .frame(maxWidth: .infinity)
    }

    private var amountFeedback: some View {
        VStack(alignment: .leading, spacing: 6) {
            if entry.hasEditedAmount || hasAttemptedReview || initialValidationFailure?.amountIssue != nil,
               let issue = entry.amountIssue(asset: draft.asset, currency: currencyContext, unitUSDPrice: amountUnitUSDPrice) {
                Text(verbatim: issue.localizedMessage).foregroundStyle(WalletTheme.danger)
            }
            if let issue = entry.coinControlIssue(asset: draft.asset, currency: currencyContext, unitUSDPrice: amountUnitUSDPrice) {
                Text(verbatim: issue.localizedMessage).foregroundStyle(WalletTheme.danger)
            }
            if let requirement = requirementModel.presentation(
                asset: draft.asset, sourceRecipient: draft.recipient, assetAmount: assetAmount
            ) {
                Text(verbatim: requirement.message)
                    .foregroundStyle(requirement.isBlocking ? WalletTheme.danger : WalletTheme.warning)
            }
            if requirementModel.canRetry(asset: draft.asset, sourceRecipient: draft.recipient) {
                Button("common.retry", action: UniHaptic.action {
                    Task { await requirementModel.retry(asset: draft.asset) }
                })
            }
        }
    }

    private var amountUnitUSDPrice: Decimal? {
        SendAmountPresentation.unitUSDPrice(
            for: draft.asset,
            nativeUnitUSDPrice: nativeUnitUSDPrice,
            cachedAssetUnitUSDPrice: cachedAssetUnitUSDPrice
        )
    }

    private func loadAmountPrice() async {
        guard amountUnitUSDPrice == nil else { return }
        let price = await SendAmountPresentation.unitUSDPrice(
            for: draft.asset, nativeUnitUSDPrice: nativeUnitUSDPrice, database: database
        )
        guard !Task.isCancelled else { return }
        cachedAssetUnitUSDPrice = price
    }

    private var amountPresentation: SendAmountInputPresentation {
        SendAmountInputPresentation(entry: entry, asset: draft.asset, currency: currencyContext, unitUSDPrice: amountUnitUSDPrice)
    }

    private var assetAmount: String? {
        entry.assetAmount(asset: draft.asset, currency: currencyContext, unitUSDPrice: amountUnitUSDPrice)
    }

    private var bitcoinFamilyChain: BitcoinFamilyChain? {
        BitcoinFamilyChain(rawValue: draft.asset.networkID)
    }

    private func replaceByFeeBinding(
        chain: BitcoinFamilyChain
    ) -> Binding<Bool> {
        Binding(
            get: { entry.bitcoinFamilyOptions.replaceByFee },
            set: { isEnabled in
                entry.bitcoinFamilyOptions = entry
                    .bitcoinFamilyOptions
                    .replacingReplaceByFee(
                        isEnabled,
                        chain: chain
                    )
                UniHaptic.play(.selection)
            }
        )
    }

    private var amountExceedsBalance: Bool {
        entry.amountIssue(
            asset: draft.asset,
            currency: currencyContext, unitUSDPrice: amountUnitUSDPrice
        ) == .exceedsBalance
    }

    private var networkFeeDraft: SendDraft {
        SendDraft(
            request: draft.request,
            asset: draft.asset,
            recipient: draft.recipient,
            amount: assetAmount,
            note: nil,
            feePolicy: entry.feePolicy,
            bitcoinFamilyOptions: entry.bitcoinFamilyOptions,
            usesMaximumBalance: entry.usesMaximumBalance
        )
    }

    private var canReview: Bool {
        requirementModel.allowsReview(
            asset: draft.asset,
            sourceRecipient: draft.recipient,
            assetAmount: assetAmount,
            baseFormIsValid: entry.reviewDraft(from: draft, currency: currencyContext, unitUSDPrice: amountUnitUSDPrice) != nil
        )
    }

    private var amountMaximumControl: some View {
        Button(action: UniHaptic.action(applyMaximum)) {
            amountControlLabel(Text("send.amount.max_action"))
        }
        .buttonStyle(.plain)
        .disabled(draft.asset.balance <= 0)
        .accessibilityIdentifier("sendAmountMax")
    }

    private func amountModeControl(counterpart: String) -> some View {
        Button(action: UniHaptic.action(toggleAmountMode)) {
            Label {
                Text(verbatim: counterpart)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.1)
            } icon: {
                Image(systemName: "arrow.up.arrow.down")
                    .accessibilityHidden(true)
            }
            .labelStyle(.titleAndIcon)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(WalletTheme.primaryLabel)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(minHeight: 44)
            .background(WalletTheme.mutedSecondaryFill, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("send.amount.entry_mode"))
        .accessibilityValue(Text(verbatim: counterpart))
        .accessibilityIdentifier("sendAmountMode")
    }

    private func amountControlLabel(_ text: Text) -> some View {
        text
            .font(.caption.weight(.semibold))
            .foregroundStyle(WalletTheme.primaryLabel)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .frame(
                width: amountControlDiameter,
                height: amountControlDiameter
            )
            .background(
                WalletTheme.mutedSecondaryFill,
                in: Circle()
            )
            .contentShape(Circle())
    }

    private func toggleAmountMode() {
        let mode: SendAmountEntryMode = entry.mode == .asset
            ? .localCurrency
            : .asset
        do {
            try entry.changeMode(
                to: mode,
                asset: draft.asset,
                currency: currencyContext, unitUSDPrice: amountUnitUSDPrice
            )
            applicationSettings.setSendAmountEntryMode(mode)
            UniHaptic.play(.selection)
        } catch {
            UniHaptic.play(.error)
        }
    }

    private func applyMaximum() {
        do {
            try entry.applyMaximum(asset: draft.asset, currency: currencyContext, unitUSDPrice: amountUnitUSDPrice)
            UniHaptic.play(.selection)
        } catch { UniHaptic.play(.error) }
    }

    private func review() {
        hasAttemptedReview = true
        guard canReview, let reviewed = entry.reviewDraft(from: draft, currency: currencyContext, unitUSDPrice: amountUnitUSDPrice) else {
            UniHaptic.play(.error)
            return
        }
        onStateChange(entry)
        onReview(reviewed)
    }
}
