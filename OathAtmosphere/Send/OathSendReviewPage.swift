import SwiftUI
import LocalAuthentication
import OathDatabase
import OathBitcoin
import OathAnkr
import OathDiagnostics

struct OathSendReviewPage: View {
    @Bindable var model: OathSendModel
    let session: OathWalletSession
    @Bindable var bitcoin: OathBitcoinSendModel
    @Bindable var sui: OathSuiSendModel
    @Bindable var xrpl: OathXrplSendModel
    @Bindable var stellar: OathStellarSendModel
    @Bindable var tron: OathTronSendModel
    @Bindable var ton: OathTonSendModel
    @Bindable var solana: OathSolanaSendModel
    @Bindable var aptos: OathAptosSendModel
    @Bindable var thorchain: OathThorchainSendModel
    @Bindable var evm: OathEVMSendModel
    @Bindable var arc: OathArcSendModel
    @Bindable var polkadot: OathPolkadotSendModel
    @Bindable var near: OathNearSendModel
    let onClose: @MainActor () -> Void
    @Environment(\.oathLocalizer) private var strings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var accountHelp: SendAccountGuidance?
    @State private var pendingAccountAction: SendAccountGuidance.Action?
    @State private var showsAddress = false
    @State private var biometricSymbol: String?
    @State private var showsMessage = false
    @State private var showsAddContact = false
    @State private var savedRecipient: Bool?
    @State private var contactLookupFailed = false
    @State private var contactLookupRetry = UUID()
    @State private var receiptState: SendSubmissionState?
    @State private var receiptHash: String?
    @State private var receiptObservationFailed = false
    @State private var receiptRetry = UUID()
    @State private var receiptFeedbackStates = Set<String>()
    @State private var feeReceiveAddress: OathWalletAddress?
    @State private var recoveringFeeIntent: [String]?

    private struct FeeRecoveryObservation: Equatable {
        let intent: [String]
        let busy: Bool
        let needsRefresh: Bool
        let hasQuote: Bool
        let failure: OathStringKey
    }

    // Keep the retry bound to the frozen transfer, not a balance/price snapshot.
    // These identifiers stay local and are never attached to diagnostics.
    private var feeIntent: [String] {
        [model.walletID, model.holding?.id ?? "", model.holding?.address ?? "",
         model.address, model.reviewAtomic ?? "", model.memo,
         String(model.maximumAmount != nil)] + model.solanaReferences
    }
    private var feeRecoveryObservation: FeeRecoveryObservation {
        .init(intent: feeIntent, busy: busy, needsRefresh: needsRefresh, hasQuote: hasQuote,
              failure: reviewFailureKey)
    }
    private var feeRecoveryAllowed: Bool {
        session.isUnlocked && !session.resetting && !session.changingWallet && scenePhase == .active
            && session.displayedProfile?.id.uuidString == model.walletID
            && model.path.last == .review && !model.reviewNeedsUpdate && submission == nil && !passcode
    }
    private var feeRecoveryTaskID: [String]? {
        guard feeRecoveryAllowed, recoveringFeeIntent == feeIntent, feeReceiveAddress == nil else { return nil }
        return feeIntent
    }
    private var feeFundingAddress: OathWalletAddress? {
        guard let holding = model.holding, let snapshot = model.snapshot,
              snapshot.wallet.id == model.walletID else { return nil }
        return OathReceiveAsset.feeAddress(for: holding, in: snapshot)
    }
    private var showsFeeFunding: Bool {
        (needsRefresh && reviewFailureKey == .sendNativeFeeRequired)
            || (busy && recoveringFeeIntent == feeIntent)
    }
    private func refreshFeeFunding() {
        guard feeRecoveryAllowed, recoveringFeeIntent == feeIntent, !busy, !hasQuote else { return }
        prepare()
    }

    private var feeFundingNotice: some View {
        Group {
            if let chain = model.chain {
                OathReceiveNetworkNotice(key: .sendNativeFeeShort, symbol: chain.ticker, chain: chain,
                                         isError: true, inlineLink: feeFundingLink(for: chain))
                    .multilineTextAlignment(.leading)
                    .tint(.primary)
                    .environment(\.openURL, OpenURLAction { url in
                        guard url.absoluteString == "oath-receive://network-fee", feeRecoveryAllowed,
                              feeFundingAddress != nil else { return .discarded }
                        presentFeeFunding()
                        return .handled
                    })
                    .accessibilityActions {
                        if feeFundingAddress != nil {
                            Button(strings.format(.sendReceiveFeeAsset, strings.invariant(chain.ticker), strings.invariant(chain.name))) {
                                presentFeeFunding()
                            }
                        }
                    }
                    .accessibilityIdentifier("send.receiveFeeAsset")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func feeFundingLink(for chain: OathImportChain) -> AttributedString? {
        guard feeFundingAddress != nil else { return nil }
        var link = AttributedString(strings.format(.sendReceiveFeeAsset, strings.invariant(chain.ticker), strings.invariant(chain.name)))
        link.link = URL(string: "oath-receive://network-fee")
        link.foregroundColor = .primary
        link.underlineStyle = Text.LineStyle(pattern: .dot, color: .gray.opacity(0.65))
        return link
    }

    private func presentFeeFunding() {
        guard feeRecoveryAllowed, let address = feeFundingAddress else { return }
        OathHaptics.shared.play(.navigate)
        feeReceiveAddress = address
    }

    private var receiptOutcome: SendSubmissionState.Outcome {
        if receiptHash == submission?.txid, let receiptState {
            return receiptState.presentationOutcome(broadcastAcknowledged: submission?.accepted == true)
        }
        return submission?.accepted == true ? .submitted : .checking
    }
    private var receiptTitle: OathStringKey {
        switch receiptOutcome {
        case .checking: .sendChecking
        case .submitted: .sendSubmitted
        case .confirmed: .wcTransactionConfirmed
        case .failed: .wcTransactionFailed
        case .cancelled: .wcTransactionCancelled
        case .replaced: .wcTransactionReplaced
        case .expired: .permissionExpired
        case .awaitingConfirmation: .assetReorged
        }
    }
    private var receiptDetail: OathStringKey? {
        switch receiptOutcome {
        case .checking: .sendCheckingDetail
        case .confirmed: .wcTransactionConfirmedDetail
        case .failed: .wcTransactionFailedDetail
        case .cancelled: .wcTransactionCancelledDetail
        case .awaitingConfirmation: .wcTransactionPendingDetail
        // The existing replacement prose is nonce-specific. UTXO replacements
        // have no nonce, so show the actual replacement link instead.
        case .submitted, .replaced, .expired: nil
        }
    }
    private var receiptTransition: AnyTransition {
        reduceMotion ? .opacity : AnyTransition(.blurReplace)
    }
    private var receiptAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.12) : .smooth(duration: 0.35)
    }
    private var showsRecipientReceipt: Bool {
        receiptOutcome == .submitted || receiptOutcome == .confirmed
    }
    private var recipientReceiptKey: OathStringKey {
        receiptOutcome == .confirmed ? .sendConfirmedRecipient : .sendSubmittedRecipient
    }
    private var receiptObservationID: String? {
        guard let submission, scenePhase == .active, session.isUnlocked else { return nil }
        return model.walletID + ":" + (model.chain?.rawValue ?? "") + ":" + submission.txid + ":" + receiptRetry.uuidString
    }

    private func observeReceipt(_ sent: OathBitcoinSubmission) async {
        guard let network = model.chain?.rawValue else { return }
        if receiptHash != sent.txid { receiptState = nil; receiptHash = sent.txid }
        receiptObservationFailed = false
        await OathDiagnostics.$chain.withValue(network) {
            await OathDiagnostics.$operationID.withValue(UUID()) {
                while !Task.isCancelled, session.isUnlocked {
                    do {
                        let db = try await session.vault.database()
                        for try await progress in db.observeSendSubmission(walletID: model.walletID, networkID: network, hash: sent.txid) {
                            guard !Task.isCancelled, session.isUnlocked, submission?.txid == sent.txid else { return }
                            guard let progress else { return } // Removed wallet/reset; no invented outcome.
                            receiptState = progress
                            receiptObservationFailed = false
                            // Keep observing even a final state: a reorg can return
                            // the journal to pending and restart its existing worker.
                        }
                    } catch {
                        if error is CancellationError || Task.isCancelled { return }
                        OathDiagnostics.record(error, component: "send", operation: "observe_receipt", context: ["chain": network])
                        receiptObservationFailed = true
                    }
                    do { try await Task.sleep(for: .seconds(15)) }
                    catch { return } // Observation/lifecycle cancellation, not a transaction failure.
                }
            }
        }
    }

    private var accountGuidance: SendAccountGuidance? {
        if needsRefresh {
            if model.supportsXrplSend { return xrpl.accountGuidance }
            if model.supportsStellarSend { return stellar.accountGuidance }
            if model.supportsTronSend { return tron.accountGuidance }
            if model.supportsPolkadotSend { return polkadot.accountGuidance }
            if model.supportsNearSend { return near.accountGuidance }
            if model.supportsSolanaSend { return solana.accountGuidance }
            return nil
        }
        // Priced account requirements have one row beside fees, not a second
        // general reserve warning that also appears for activated recipients.
        if model.supportsTronSend, let plan = tron.quote?.plan,
           plan.isContract, plan.recipientNeedsActivation == true {
            return .init(.tronTokenActivation, isBlocking: false)
        }
        return nil
    }

    private var accountCost: SendAccountCost? {
        guard !needsRefresh, !model.reviewNeedsUpdate else { return nil }
        if model.supportsXrplSend { return xrpl.quote?.plan.accountCost }
        if model.supportsStellarSend { return stellar.quote?.plan.accountCost }
        if model.supportsTronSend { return tron.quote?.plan.accountCost }
        if model.supportsSolanaSend { return solana.quote?.plan.accountCost }
        if model.supportsNearSend { return near.quote?.plan.accountCost }
        return nil
    }

    private func accountCostValue(_ cost: SendAccountCost) -> String {
        if cost.kind == .nearStorage { return nearMoney(cost.atomic) }
        let price: Decimal?
        switch cost.kind {
        case .xrpReserve: price = xrpl.gasPrice
        case .stellarReserve: price = stellar.gasPrice
        case .tronCreation: price = tron.gasPrice
        case .solanaReserve, .solanaTokenDeposit: price = solana.gasPrice
        case .nearStorage: price = near.gasPrice
        }
        guard let amount = UInt64(cost.atomic) else { return "—" }
        return suiMoney(amount, decimals: cost.decimals, symbol: cost.symbol, price: price)
    }

    private func accountCostRow(_ cost: SendAccountCost) -> some View {
        OathButton(feedback: .navigate) { accountHelp = cost.guidance } label: {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 24) {
                    accountCostLabel(cost)
                    Spacer(minLength: 0)
                    Text(accountCostValue(cost)).foregroundStyle(.primary).multilineTextAlignment(.trailing)
                }.fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 6) {
                    accountCostLabel(cost)
                    Text(accountCostValue(cost)).foregroundStyle(.primary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.oathFont(.body).contentShape(Rectangle())
        }.buttonStyle(.plain).oathNeutralControl()
            .accessibilityHint(strings.text(.accountLearnMore))
            .accessibilityIdentifier("send.accountCost")
    }

    private func accountCostLabel(_ cost: SendAccountCost) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(strings.text(cost.titleKey))
                Image(systemName: "info.circle").accessibilityHidden(true)
            }.foregroundStyle(.secondary)
            if cost.inclusion == .payment {
                Text(strings.text(.accountCostIncluded)).oathFont(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func accountNotice(_ guidance: SendAccountGuidance) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(guidance.summary(strings: strings)).oathFont(.footnote)
                .foregroundStyle(guidance.isBlocking ? Color.red : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
            OathButton(strings.text(.accountLearnMore), feedback: .navigate) { accountHelp = guidance }
                .oathFont(.footnote, weight: .semibold).oathNeutralControl()
                .accessibilityIdentifier("send.accountHelp.open")
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func performAccountAction(_ action: SendAccountGuidance.Action) {
        guard session.isUnlocked, !session.resetting, !busy, submission == nil else { return }
        switch action {
        case .editAmount: model.path = [.recipient, .amount]
        case .editRecipient: model.path = [.recipient]
        case .refresh: prepare()
        }
    }

    private var reviewFailureKey: OathStringKey {
        evm.failureMessage ?? arc.failureMessage ?? ton.failureMessage ?? solana.failureMessage ?? aptos.failureMessage ?? thorchain.failureMessage ?? polkadot.failureMessage ?? near.failureMessage ?? tron.failureMessage ?? stellar.failureMessage ?? xrpl.failureMessage ?? sui.failureMessage ?? (bitcoin.needsMessageChange ? .sendMessageDoesNotFit : needsAmountChange ? .sendAdjustAmount : .sendRefreshNeeded)
    }
    private var reviewFailureMessage: String {
        let key = reviewFailureKey
        if key == .sendNativeFeeRequired {
            // Use network metadata, never the transferred token's symbol or a
            // cached balance. Fee shortages are identified by the send client.
            return strings.format(key, strings.invariant(model.chain?.ticker ?? ""))
        }
        return strings.text(key)
    }

    private var busy: Bool { model.supportsEVMSend ? evm.busy : model.supportsArcSend ? arc.busy : model.supportsTonSend ? ton.busy : model.supportsSolanaSend ? solana.busy : model.supportsAptosSend ? aptos.busy : model.supportsThorchainSend ? thorchain.busy : model.supportsPolkadotSend ? polkadot.busy : model.supportsNearSend ? near.busy : model.supportsTronSend ? tron.busy : model.supportsStellarSend ? stellar.busy : model.supportsXrplSend ? xrpl.busy : model.supportsSuiSend ? sui.busy : bitcoin.busy }
    private var needsRefresh: Bool { model.supportsEVMSend ? evm.needsRefresh : model.supportsArcSend ? arc.needsRefresh : model.supportsTonSend ? ton.needsRefresh : model.supportsSolanaSend ? solana.needsRefresh : model.supportsAptosSend ? aptos.needsRefresh : model.supportsThorchainSend ? thorchain.needsRefresh : model.supportsPolkadotSend ? polkadot.needsRefresh : model.supportsNearSend ? near.needsRefresh : model.supportsTronSend ? tron.needsRefresh : model.supportsStellarSend ? stellar.needsRefresh : model.supportsXrplSend ? xrpl.needsRefresh : model.supportsSuiSend ? sui.needsRefresh : bitcoin.needsRefresh }
    private var needsAmountChange: Bool { model.supportsEVMSend ? evm.needsAmountChange : model.supportsArcSend ? arc.needsAmountChange : model.supportsTonSend ? ton.needsAmountChange : model.supportsSolanaSend ? solana.needsAmountChange : model.supportsAptosSend ? aptos.needsAmountChange : model.supportsThorchainSend ? thorchain.needsAmountChange : model.supportsPolkadotSend ? polkadot.needsAmountChange : model.supportsNearSend ? near.needsAmountChange : model.supportsTronSend ? tron.needsAmountChange : model.supportsStellarSend ? stellar.needsAmountChange : model.supportsXrplSend ? xrpl.needsAmountChange : model.supportsSuiSend ? sui.needsAmountChange : bitcoin.needsAmountChange }
    private var passcode: Bool { model.supportsEVMSend ? evm.passcode : model.supportsArcSend ? arc.passcode : model.supportsTonSend ? ton.passcode : model.supportsSolanaSend ? solana.passcode : model.supportsAptosSend ? aptos.passcode : model.supportsThorchainSend ? thorchain.passcode : model.supportsPolkadotSend ? polkadot.passcode : model.supportsNearSend ? near.passcode : model.supportsTronSend ? tron.passcode : model.supportsStellarSend ? stellar.passcode : model.supportsXrplSend ? xrpl.passcode : model.supportsSuiSend ? sui.passcode : bitcoin.passcode }
    private var submission: OathBitcoinSubmission? { model.supportsEVMSend ? evm.submission : model.supportsArcSend ? arc.submission : model.supportsTonSend ? ton.submission : model.supportsSolanaSend ? solana.submission : model.supportsAptosSend ? aptos.submission : model.supportsThorchainSend ? thorchain.submission : model.supportsPolkadotSend ? polkadot.submission : model.supportsNearSend ? near.submission : model.supportsTronSend ? tron.submission : model.supportsStellarSend ? stellar.submission : model.supportsXrplSend ? xrpl.submission : model.supportsSuiSend ? sui.submission : bitcoin.submission }
    private var hasQuote: Bool { model.supportsEVMSend ? evm.quote != nil : model.supportsArcSend ? arc.quote != nil : model.supportsTonSend ? ton.quote != nil : model.supportsSolanaSend ? solana.quote != nil : model.supportsAptosSend ? aptos.quote != nil : model.supportsThorchainSend ? thorchain.quote != nil : model.supportsPolkadotSend ? polkadot.quote != nil : model.supportsNearSend ? near.quote != nil : model.supportsTronSend ? tron.quote != nil : model.supportsStellarSend ? stellar.quote != nil : model.supportsXrplSend ? xrpl.quote != nil : model.supportsSuiSend ? sui.quote != nil : bitcoin.quote != nil }
    private var noticeBinding: Binding<OathStringKey?> { model.supportsEVMSend ? $evm.notice : model.supportsArcSend ? $arc.notice : model.supportsTonSend ? $ton.notice : model.supportsSolanaSend ? $solana.notice : model.supportsAptosSend ? $aptos.notice : model.supportsThorchainSend ? $thorchain.notice : model.supportsPolkadotSend ? $polkadot.notice : model.supportsNearSend ? $near.notice : model.supportsTronSend ? $tron.notice : model.supportsStellarSend ? $stellar.notice : model.supportsXrplSend ? $xrpl.notice : model.supportsSuiSend ? $sui.notice : $bitcoin.notice }
    private func send(digits: [UInt8]? = nil) {
        if model.supportsEVMSend { evm.send(session:session,digits:digits,reason:strings.text(.sendAuthorize)) }
        else if model.supportsArcSend { arc.send(session:session,digits:digits,reason:strings.text(.sendAuthorize)) }
        else if model.supportsTonSend { ton.send(session:session,digits:digits,reason:strings.text(.sendAuthorize)) }
        else if model.supportsSolanaSend { solana.send(session:session,digits:digits,reason:strings.text(.sendAuthorize)) }
        else if model.supportsThorchainSend { thorchain.send(session:session,digits:digits,reason:strings.text(.sendAuthorize)) }
        else if model.supportsAptosSend { aptos.send(session:session,digits:digits,reason:strings.text(.sendAuthorize)) }
        else if model.supportsPolkadotSend { polkadot.send(session:session,digits:digits,reason:strings.text(.sendAuthorize)) }
        else if model.supportsNearSend { near.send(session:session,digits:digits,reason:strings.text(.sendAuthorize)) }
        else if model.supportsTronSend { tron.send(session:session,digits:digits,reason:strings.text(.sendAuthorize)) }
        else if model.supportsStellarSend { stellar.send(session:session,digits:digits,reason:strings.text(.sendAuthorize)) }
        else if model.supportsXrplSend { xrpl.send(session:session,digits:digits,reason:strings.text(.sendAuthorize)) }
        else if model.supportsSuiSend { sui.send(session:session,digits:digits,reason:strings.text(.sendAuthorize)) }
        else { bitcoin.send(session:session,digits:digits,reason:strings.text(.sendAuthorize)) }
    }
    private func prepare() {
        if model.supportsEVMSend { evm.prepare(model:model,session:session) }
        else if model.supportsArcSend { arc.prepare(model:model,session:session) }
        else if model.supportsTonSend { ton.prepare(model:model,session:session) }
        else if model.supportsSolanaSend { solana.prepare(model:model,session:session) }
        else if model.supportsThorchainSend { thorchain.prepare(model:model,session:session) }
        else if model.supportsAptosSend { aptos.prepare(model:model,session:session) }
        else if model.supportsPolkadotSend { polkadot.prepare(model:model,session:session) }
        else if model.supportsNearSend { near.prepare(model:model,session:session) }
        else if model.supportsTronSend { tron.prepare(model:model,session:session) }
        else if model.supportsStellarSend { stellar.prepare(model:model,session:session) }
        else if model.supportsXrplSend { xrpl.prepare(model:model,session:session) }
        else if model.supportsSuiSend { sui.prepare(model:model,session:session) }
        else { bitcoin.prepare(model:model,session:session,forceRefresh:true) }
    }
    private func suiMoney(_ atomic: UInt64, decimals: Int, symbol: String, price: Decimal?) -> String {
        let units = OathSendAmount.units(String(atomic),decimals:decimals) ?? "0"
        if let price, price > 0, let value = Decimal(string:units,locale:Locale(identifier:"en_US_POSIX")) {
            return OathAssetAmountFormat(locale: strings.language.locale, selectedCurrencyCode: model.reviewCurrency ?? model.currency).money((value*price))
        }
        return strings.invariant(units+" "+symbol)
    }
    private func suiAssetMoney(_ atomic: UInt64) -> String {
        suiMoney(atomic,decimals:model.holding?.decimals ?? 9,symbol:model.holding?.symbol ?? "SUI",price:model.reviewPrice)
    }
    private var feeValue: String? {
        if model.supportsEVMSend { return evm.quote.map { suiMoney($0.plan.fee,decimals:18,symbol:$0.plan.network.symbol,price:evm.gasPrice) } }
        if model.supportsArcSend { return arc.quote.map { suiMoney($0.plan.fee,decimals:18,symbol:"USDC",price:arc.gasPrice) } }
        if model.supportsTonSend { return ton.quote.map { suiMoney($0.plan.fee,decimals:9,symbol:"GRAM",price:ton.gasPrice) } }
        if model.supportsSolanaSend { return solana.quote.map { suiMoney($0.plan.transactionFee,decimals:9,symbol:"SOL",price:solana.gasPrice) } }
        if model.supportsThorchainSend { return thorchain.quote.map { suiMoney($0.plan.fee,decimals:8,symbol:"RUNE",price:thorchain.gasPrice) } }
        if model.supportsAptosSend { return aptos.quote.map { suiMoney($0.plan.fee,decimals:8,symbol:"APT",price:aptos.gasPrice) } }
        if model.supportsPolkadotSend { return polkadot.quote.map { polkadotMoney($0.plan.fee) } }
        if model.supportsNearSend { return near.quote.map { nearMoney($0.plan.fee) } }
        if model.supportsTronSend { return tron.quote.map { suiMoney($0.plan.feeExcludingAccountCreation,decimals:6,symbol:"TRX",price:tron.gasPrice) } }
        if model.supportsStellarSend { return stellar.quote.map { suiMoney(UInt64($0.plan.fee),decimals:7,symbol:"XLM",price:stellar.gasPrice) } }
        if model.supportsXrplSend { return xrpl.quote.map { suiMoney($0.plan.fee,decimals:6,symbol:"XRP",price:xrpl.gasPrice) } }
        if model.supportsSuiSend { return sui.quote.map { suiMoney($0.plan.estimatedFee,decimals:9,symbol:"SUI",price:sui.gasPrice) } }
        return bitcoin.quote.map { money($0.plan.fee) }
    }
    private var totalValue: String? {
        if model.supportsEVMSend { return evmTotal }
        if model.supportsArcSend { return arcTotal }
        if model.supportsTonSend { return tonTotal }
        if model.supportsSolanaSend { return solanaTotal }
        if model.supportsThorchainSend { return thorchainTotal }
        if model.supportsAptosSend { return aptosTotal }
        if model.supportsPolkadotSend { return polkadotTotal }
        if model.supportsNearSend { return nearTotal }
        if model.supportsTronSend { return tronTotal }
        if model.supportsStellarSend { return stellarTotal }
        if model.supportsXrplSend { return xrplTotal }
        guard model.supportsSuiSend else { return bitcoin.quote.map { money($0.plan.total) } }
        guard let plan = sui.quote?.plan else { return nil }
        if plan.reference == "native" { return suiAssetMoney(plan.amount+plan.estimatedFee) }
        // Token quantity and SUI gas have different units and prices. Never
        // subtract SUI gas from a token balance or value it at the token price.
        if let price = model.reviewPrice, let gasPrice = sui.gasPrice,
           let units, let value = Decimal(string:units,locale:Locale(identifier:"en_US_POSIX")) {
            return OathAssetAmountFormat(locale: strings.language.locale, selectedCurrencyCode: model.reviewCurrency ?? model.currency).money((value*price+Decimal(plan.estimatedFee)/1_000_000_000*gasPrice))
        }
        return suiAssetMoney(plan.amount)+" + "+(feeValue ?? "—")
    }

    private func xrplAssetMoney(_ atomic: String) -> String {
        let units = OathSendAmount.units(atomic,decimals:model.holding?.decimals ?? 6) ?? "—"
        if let price = model.reviewPrice, let value = Decimal(string:units,locale:Locale(identifier:"en_US_POSIX")), !(value*price).isNaN {
            return OathAssetAmountFormat(locale: strings.language.locale, selectedCurrencyCode: model.reviewCurrency ?? model.currency).money((value*price))
        }
        return strings.invariant(units+" "+(model.holding?.symbol ?? "XRP"))
    }
    private var xrplTotal: String? {
        guard let plan = xrpl.quote?.plan else { return nil }
        if plan.reference == "native", let drops = UInt64(plan.assetDebit) { return xrplAssetMoney(String(drops+plan.fee)) }
        if let raw = OathSendAmount.units(plan.assetDebit,decimals:model.holding?.decimals ?? 96),
           let value = Decimal(string:raw,locale:Locale(identifier:"en_US_POSIX")),
           let price = model.reviewPrice, let gasPrice = xrpl.gasPrice {
            let total = value*price+Decimal(plan.fee)/1_000_000*gasPrice
            if !total.isNaN { return OathAssetAmountFormat(locale: strings.language.locale, selectedCurrencyCode: model.reviewCurrency ?? model.currency).money(total) }
        }
        return xrplAssetMoney(plan.assetDebit)+" + "+(feeValue ?? "—")
    }

    private var stellarTotal: String? {
        guard let plan = stellar.quote?.plan else { return nil }
        if plan.reference == "native" { return xrplAssetMoney(StellarIdentity.sum(plan.amount,String(plan.fee))) }
        if let raw = OathSendAmount.units(plan.amount,decimals:plan.decimals),
           let value = Decimal(string:raw,locale:Locale(identifier:"en_US_POSIX")),
           let price = model.reviewPrice, let gasPrice = stellar.gasPrice {
            let total = value*price+Decimal(plan.fee)/10_000_000*gasPrice
            if !total.isNaN { return OathAssetAmountFormat(locale: strings.language.locale, selectedCurrencyCode: model.reviewCurrency ?? model.currency).money(total) }
        }
        return xrplAssetMoney(plan.amount)+" + "+(feeValue ?? "—")
    }
    private var tronTotal: String? {
        guard let plan = tron.quote?.plan else { return nil }
        if plan.reference == "native" { return xrplAssetMoney(StellarIdentity.sum(plan.amount,String(plan.fee))) }
        if let raw = OathSendAmount.units(plan.amount,decimals:plan.decimals),
           let value = Decimal(string:raw,locale:Locale(identifier:"en_US_POSIX")),
           let price = model.reviewPrice, let gasPrice = tron.gasPrice {
            let total = value*price+Decimal(plan.fee)/1_000_000*gasPrice
            if !total.isNaN { return OathAssetAmountFormat(locale: strings.language.locale, selectedCurrencyCode: model.reviewCurrency ?? model.currency).money(total) }
        }
        return xrplAssetMoney(plan.amount)+" + "+suiMoney(plan.fee,decimals:6,symbol:"TRX",price:tron.gasPrice)
    }

    private var solanaTotal: String? {
        guard let plan=solana.quote?.plan else { return nil }
        if plan.reference=="native" { return xrplAssetMoney(String(plan.amount+plan.fee)) }
        if let raw=OathSendAmount.units(String(plan.amount),decimals:plan.decimals),
           let value=Decimal(string:raw,locale:Locale(identifier:"en_US_POSIX")),let price=model.reviewPrice,let gasPrice=solana.gasPrice {
            return OathAssetAmountFormat(locale: strings.language.locale, selectedCurrencyCode: model.reviewCurrency ?? model.currency).money((value*price+Decimal(plan.fee)/1_000_000_000*gasPrice))
        }
        return xrplAssetMoney(String(plan.amount))+" + "+suiMoney(plan.fee,decimals:9,symbol:"SOL",price:solana.gasPrice)
    }

    private var arcTotal: String? {
        guard let plan=arc.quote?.plan else { return nil }
        if plan.reference=="native" { return xrplAssetMoney(StellarIdentity.sum(plan.amount,String(plan.fee))) }
        if let raw=OathSendAmount.units(plan.amount,decimals:plan.decimals),
           let value=Decimal(string:raw,locale:Locale(identifier:"en_US_POSIX")),let price=model.reviewPrice,let gasPrice=arc.gasPrice {
            return OathAssetAmountFormat(locale: strings.language.locale, selectedCurrencyCode: model.reviewCurrency ?? model.currency).money((value*price+Decimal(plan.fee)/1_000_000_000_000_000_000*gasPrice))
        }
        return xrplAssetMoney(plan.amount)+" + "+(feeValue ?? "—")
    }

    private var evmTotal: String? {
        guard let plan=evm.quote?.plan else { return nil }
        if plan.reference=="native" { return xrplAssetMoney(StellarIdentity.sum(plan.amount,String(plan.fee))) }
        if let raw=OathSendAmount.units(plan.amount,decimals:plan.decimals),
           let value=Decimal(string:raw,locale:Locale(identifier:"en_US_POSIX")),let price=model.reviewPrice,let gasPrice=evm.gasPrice {
            return OathAssetAmountFormat(locale: strings.language.locale, selectedCurrencyCode: model.reviewCurrency ?? model.currency).money((value*price+Decimal(plan.fee)/1_000_000_000_000_000_000*gasPrice))
        }
        return xrplAssetMoney(plan.amount)+" + "+(feeValue ?? "—")
    }

    private var aptosTotal: String? {
        guard let plan=aptos.quote?.plan else { return nil }
        if plan.reference=="native" { return xrplAssetMoney(String(plan.amount+plan.fee)) }
        if let raw=OathSendAmount.units(String(plan.amount),decimals:plan.decimals),
           let value=Decimal(string:raw,locale:Locale(identifier:"en_US_POSIX")),let price=model.reviewPrice,let gasPrice=aptos.gasPrice {
            return OathAssetAmountFormat(locale: strings.language.locale, selectedCurrencyCode: model.reviewCurrency ?? model.currency).money((value*price+Decimal(plan.fee)/100_000_000*gasPrice))
        }
        return xrplAssetMoney(String(plan.amount))+" + "+(feeValue ?? "—")
    }

    private var thorchainTotal: String? {
        guard let plan=thorchain.quote?.plan else { return nil }
        if plan.reference=="native" { return xrplAssetMoney(StellarIdentity.sum(plan.amount,String(plan.fee))) }
        if let raw=OathSendAmount.units(String(plan.amount),decimals:plan.decimals),
           let value=Decimal(string:raw,locale:Locale(identifier:"en_US_POSIX")),let price=model.reviewPrice,let gasPrice=thorchain.gasPrice {
            return OathAssetAmountFormat(locale: strings.language.locale, selectedCurrencyCode: model.reviewCurrency ?? model.currency).money((value*price+Decimal(plan.fee)/100_000_000*gasPrice))
        }
        return xrplAssetMoney(String(plan.amount))+" + "+(feeValue ?? "—")
    }

    private var tonTotal: String? {
        guard let plan=ton.quote?.plan else { return nil }
        if plan.reference=="native" { return xrplAssetMoney(String(plan.amount+plan.fee)) }
        if let raw=OathSendAmount.units(String(plan.amount),decimals:plan.decimals),
           let value=Decimal(string:raw,locale:Locale(identifier:"en_US_POSIX")),let price=model.reviewPrice,let gasPrice=ton.gasPrice {
            return OathAssetAmountFormat(locale: strings.language.locale, selectedCurrencyCode: model.reviewCurrency ?? model.currency).money((value*price+Decimal(plan.fee)/1_000_000_000*gasPrice))
        }
        return xrplAssetMoney(String(plan.amount))+" + "+(feeValue ?? "—")
    }

    private func nearMoney(_ atomic:String) -> String {
        let units=OathSendAmount.units(atomic,decimals:24) ?? "—"
        if let price=near.gasPrice,let value=Decimal(string:units,locale:Locale(identifier:"en_US_POSIX")),!(value*price).isNaN {
            return OathAssetAmountFormat(locale: strings.language.locale, selectedCurrencyCode: model.reviewCurrency ?? model.currency).money((value*price))
        }
        return strings.invariant(units+" NEAR")
    }
    private var nearTotal:String? {
        guard let plan=near.quote?.plan else { return nil }
        if plan.reference=="native" { return nearMoney(plan.nativeDebit) }
        if let raw=OathSendAmount.units(plan.amount,decimals:plan.decimals),let value=Decimal(string:raw,locale:Locale(identifier:"en_US_POSIX")),
           let gasUnits=OathSendAmount.units(plan.nativeDebit,decimals:24),let gas=Decimal(string:gasUnits,locale:Locale(identifier:"en_US_POSIX")),
           let price=model.reviewPrice,let gasPrice=near.gasPrice {
            let total=value*price+gas*gasPrice
            if !total.isNaN { return OathAssetAmountFormat(locale: strings.language.locale, selectedCurrencyCode: model.reviewCurrency ?? model.currency).money(total) }
        }
        return xrplAssetMoney(plan.amount)+" + "+nearMoney(plan.nativeDebit)
    }

    private func polkadotMoney(_ atomic:String) -> String {
        let units=OathSendAmount.units(atomic,decimals:10) ?? "—"
        if let price=polkadot.gasPrice,let value=Decimal(string:units,locale:Locale(identifier:"en_US_POSIX")),!(value*price).isNaN {
            return OathAssetAmountFormat(locale: strings.language.locale, selectedCurrencyCode: model.reviewCurrency ?? model.currency).money((value*price))
        }
        return strings.invariant(units+" DOT")
    }
    private var polkadotTotal:String? {
        guard let plan=polkadot.quote?.plan else { return nil }
        if plan.reference=="native" { return polkadotMoney(plan.nativeDebit) }
        if let raw=OathSendAmount.units(plan.amount,decimals:plan.decimals),let value=Decimal(string:raw,locale:Locale(identifier:"en_US_POSIX")),
           let gasUnits=OathSendAmount.units(plan.nativeDebit,decimals:10),let gas=Decimal(string:gasUnits,locale:Locale(identifier:"en_US_POSIX")),
           let price=model.reviewPrice,let gasPrice=polkadot.gasPrice {
            let total=value*price+gas*gasPrice
            if !total.isNaN { return OathAssetAmountFormat(locale: strings.language.locale, selectedCurrencyCode: model.reviewCurrency ?? model.currency).money(total) }
        }
        return xrplAssetMoney(plan.amount)+" + "+polkadotMoney(plan.nativeDebit)
    }

    private var canSend: Bool {
        model.supportsSend && session.isUnlocked && !session.resetting && hasQuote &&
            !busy && !needsRefresh && !model.reviewNeedsUpdate && !passcode && submission == nil
    }
    private var isSubmitting: Bool { busy && hasQuote }
    private var isQuotePending: Bool {
        model.supportsSend && !hasQuote &&
            (busy || (!needsRefresh && !model.reviewNeedsUpdate))
    }
    private var sendIcon: String? {
        session.security.biometricsEnabled && !session.biometricRepairNeeded ? biometricSymbol : nil
    }
    private var recipientAddress: String { (model.supportsEVMSend ? evm.quote?.plan.recipient : model.supportsArcSend ? arc.quote?.plan.recipient : model.supportsTonSend ? ton.quote?.plan.recipient : model.supportsSolanaSend ? solana.quote?.plan.recipient : model.supportsAptosSend ? aptos.quote?.plan.recipient : model.supportsThorchainSend ? thorchain.quote?.plan.recipient : model.supportsPolkadotSend ? polkadot.quote?.plan.recipient : model.supportsNearSend ? near.quote?.plan.recipient : model.supportsTronSend ? tron.quote?.plan.recipient : model.supportsStellarSend ? stellar.quote?.plan.recipient : model.supportsXrplSend ? xrpl.quote?.plan.recipient : model.supportsSuiSend ? sui.quote?.plan.recipient : bitcoin.quote?.plan.recipient) ?? model.address }

    private var units: String? {
        guard let holding = model.holding, let raw = (model.supportsEVMSend ? evm.quote?.plan.amount : model.supportsArcSend ? arc.quote?.plan.amount : model.supportsTonSend ? ton.quote.map({ String($0.plan.amount) }) : model.supportsSolanaSend ? solana.quote.map({ String($0.plan.amount) }) : model.supportsAptosSend ? aptos.quote.map({ String($0.plan.amount) }) : model.supportsThorchainSend ? thorchain.quote.map({ String($0.plan.amount) }) : model.supportsPolkadotSend ? polkadot.quote?.plan.amount : model.supportsNearSend ? near.quote?.plan.amount : model.supportsTronSend ? tron.quote?.plan.amount : model.supportsStellarSend ? stellar.quote?.plan.amount : model.supportsXrplSend ? xrpl.quote?.plan.amount : model.supportsSuiSend ? sui.quote.map({ String($0.plan.amount) }) : bitcoin.quote.map({ String($0.plan.recipientAmount) })) ?? model.reviewAtomic else { return nil }
        return OathSendAmount.units(raw, decimals: holding.decimals)
    }
    private var native: String { strings.invariant((units ?? "—") + " " + (model.holding?.symbol ?? "")) }
    private var fiat: String? {
        guard let units, let value = Decimal(string: units, locale: Locale(identifier: "en_US_POSIX")),
              let price = model.reviewPrice, !(value * price).isNaN else { return nil }
        return OathAssetAmountFormat(locale: strings.language.locale, selectedCurrencyCode: model.reviewCurrency ?? model.currency).money((value * price))
    }

    private var confirmTitle: OathStringKey { model.xrplAccountClosure != nil ? .xrplCloseConfirm : .sendConfirmAndSend }

    var body: some View {
        Group {
            if let submission = submission { result(submission) }
            else if passcode {
                OathSecretPasscodePage(session: session, busy: busy, notice: noticeBinding,
                    title: confirmTitle, identifier: "send.passcode") { digits in
                    send(digits: digits)
                }
            } else { review }
        }
        .navigationTitle(submission == nil ? strings.text(.sendReview) : "")
        .task(id: receiptObservationID) {
            guard receiptObservationID != nil, let submission else { return }
            await observeReceipt(submission)
        }
        .onChange(of: feeRecoveryObservation, initial: true) { _, state in
            if state.intent != recoveringFeeIntent { recoveringFeeIntent = nil }
            if !state.busy {
                if state.needsRefresh && state.failure == .sendNativeFeeRequired {
                    recoveringFeeIntent = state.intent
                } else if state.hasQuote || (state.needsRefresh && state.failure != .sendRefreshNeeded) {
                    recoveringFeeIntent = nil
                }
            }
        }
        .task(id: feeRecoveryTaskID) {
            guard let intent = feeRecoveryTaskID else { return }
            await OathDiagnostics.$chain.withValue(model.chain?.id) {
                await OathDiagnostics.$operationID.withValue(UUID()) {
                    await SendFeeFundingRecovery.run(state: {
                        guard feeRecoveryTaskID == intent, !hasQuote else { return .stopped }
                        return busy ? .preparing : .waiting
                    }, refresh: { refreshFeeFunding() })
                }
            }
        }
        .sheet(item: $feeReceiveAddress, onDismiss: { refreshFeeFunding() }) { address in
            OathReceiveSheet(address: address, session: session, allowsAddressChoice: false)
                .oathLanguage(strings.language)
        }
        .onChange(of: feeRecoveryAllowed) { _, allowed in
            if !allowed { feeReceiveAddress = nil }
        }
        .toolbar {
            if submission != nil {
                OathToolbarAction(title: .done, kind: .navigation,
                                  isEnabled: true, isWorking: false,
                                  identifier: "send.result.done", action: onClose)
            } else if !passcode {
                OathToolbarAction(title: confirmTitle, icon: sendIcon, kind: .transaction,
                                      progressLabel: isQuotePending ? .sendLoadingFee : .sendSending,
                                      isEnabled: canSend, isWorking: isQuotePending || isSubmitting,
                                      identifier: "send.submit") {
                    send()
                }
            }
        }
        .task {
            // Capability probing does not prompt for authentication. Unavailable
            // or locked-out biometrics are expected; submit owns passcode fallback.
            let context = LAContext()
            _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
            switch context.biometryType {
            case .faceID: biometricSymbol = "faceid"
            case .touchID: biometricSymbol = "touchid"
            default: biometricSymbol = nil
            }
            context.invalidate()
        }
        .sheet(item: $accountHelp, onDismiss: {
            let action = pendingAccountAction
            pendingAccountAction = nil
            if let action { performAccountAction(action) }
        }) { guidance in
            OathSendAccountHelp(guidance: guidance) { action in
                pendingAccountAction = action
                accountHelp = nil
            }.oathLanguage(strings.language)
        }
        .onChange(of: session.isUnlocked) { _, unlocked in
            if !unlocked { pendingAccountAction = nil; accountHelp = nil }
        }
        .sheet(isPresented: $showsAddress) {
            OathWalletSheet(title: .contactAddress) {
                OathAddressText(address: recipientAddress, identifier: "send.recipient.fullAddress")
                    .padding(.vertical, 16)
            }.oathLanguage(strings.language)
        }
        .sheet(isPresented: $showsAddContact) {
            if let networkID = model.holding?.networkID {
                OathSendContactSheet(networkID: networkID, address: recipientAddress,
                                     isAllowed: session.isUnlocked && !session.resetting) {
                    savedRecipient = true
                    showsAddContact = false
                }
            }
        }
        .sheet(isPresented: $showsMessage) {
            NavigationStack {
                ScrollView {
                    Text(String(decoding: model.reviewOptions.message, as: UTF8.self))
                        .oathFont(.body).textSelection(.enabled).padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .navigationTitle(strings.text(.sendOnChainMessage)).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { OathDoneButton { showsMessage = false } } }
            }.oathNativeLocalization()
        }
        .navigationBarBackButtonHidden(submission != nil)
    }

    private var review: some View {
        ScrollView {
            VStack(spacing: 28) {
                hero
                VStack(spacing: 20) {
                    detail(.transactionFrom, value: session.walletName(model.snapshot?.wallet, strings: strings))
                    recipient
                    detail(.tokenNetwork, value: model.chain?.name ?? "")
                    if let note = model.paymentNote {
                        Text(note).oathFont(.footnote).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let memo = model.memoKind, !model.memo.isEmpty { detail(model.supportsStellarSend ? model.stellarMemoLabel : memo, value: model.memo) }
                    if model.supportsBitcoinSend {
                        if let chain = model.chain.flatMap({ UTXONetwork(rawValue: $0.rawValue) }), BitcoinSendOptions.supportsRBF(chain) {
                            detail(.sendRBF, value: strings.text(model.reviewOptions.replaceable ? .sendOptionOn : .sendOptionOff))
                        }
                        if !model.reviewOptions.message.isEmpty {
                            OathButton(feedback: .navigate) { showsMessage = true } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text(strings.text(.sendOnChainMessage)).foregroundStyle(.secondary)
                                        Spacer()
                                        Image(systemName: "chevron.forward").font(.footnote)
                                    }
                                    Text(String(decoding: model.reviewOptions.message, as: UTF8.self))
                                        .lineLimit(3).multilineTextAlignment(.leading)
                                }.oathFont(.body).frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain).oathNeutralControl()
                        }
                    }
                    OathHairline()
                    feeDetail(.transactionNetworkFee, value: feeValue)
                    if let cost = accountCost { accountCostRow(cost) }
                    if model.supportsSolanaSend, let storage = solana.quote?.plan.multisig?.storageRent {
                        feeDetail(.multisigSolanaStorage, value: suiMoney(storage, decimals: 9, symbol: "SOL", price: solana.gasPrice))
                        Text(strings.text(.multisigSolanaTransferFeeDetail)).oathFont(.footnote).foregroundStyle(.secondary)
                    }
                    feeDetail(.sendTotal, value: totalValue)
                    if model.supportsTonSend, let plan = ton.quote?.plan {
                        detail(.sendRemaining, value: xrplAssetMoney(String(plan.remaining)))
                        if plan.amount < plan.requestedAmount { Text(strings.text(.sendFeeAdjusted)).oathFont(.footnote).foregroundStyle(.secondary) }
                    }

                    if model.supportsSolanaSend, let plan = solana.quote?.plan {
                        if plan.receivedAmount<plan.amount { detail(.solanaRecipientReceives,value:xrplAssetMoney(String(plan.receivedAmount))) }
                        detail(.sendRemaining, value: xrplAssetMoney(String(plan.remaining)))
                        if plan.amount < plan.requestedAmount { Text(strings.text(.sendFeeAdjusted)).oathFont(.footnote).foregroundStyle(.secondary) }
                    }
                    if model.supportsEVMSend, let plan=evm.quote?.plan {
                        detail(.sendRemaining,value:xrplAssetMoney(plan.remaining))
                        if EVMSendAmount.less(plan.amount,plan.requestedAmount) { Text(strings.text(.sendFeeAdjusted)).oathFont(.footnote).foregroundStyle(.secondary) }
                    }
                    if model.supportsArcSend, let plan = arc.quote?.plan {
                        detail(.sendRemaining,value:xrplAssetMoney(plan.remaining))
                        Text(strings.text(.arcFeeMaximum)).oathFont(.footnote).foregroundStyle(.secondary)
                        if ArcSendAmount.less(plan.amount,plan.requestedAmount) { Text(strings.text(.sendFeeAdjusted)).oathFont(.footnote).foregroundStyle(.secondary) }
                    }
                    if model.supportsAptosSend, let plan = aptos.quote?.plan {
                        detail(.sendRemaining, value: xrplAssetMoney(String(plan.remaining)))
                        if plan.amount < plan.requestedAmount { Text(strings.text(.sendFeeAdjusted)).oathFont(.footnote).foregroundStyle(.secondary) }
                    }
                    if model.supportsThorchainSend, let plan = thorchain.quote?.plan {
                        detail(.sendRemaining, value: xrplAssetMoney(String(plan.remaining)))
                        if ThorchainSendAmount.less(plan.amount,plan.requestedAmount) { Text(strings.text(.sendFeeAdjusted)).oathFont(.footnote).foregroundStyle(.secondary) }
                    }
                    if model.supportsPolkadotSend, let plan = polkadot.quote?.plan {
                        detail(.sendRemaining, value: xrplAssetMoney(plan.remaining))
                        if let minimum = plan.minimumNativeBalance {
                            Text(strings.format(.receiveAccountReserve, strings.invariant("Polkadot"), strings.invariant((OathSendAmount.units(minimum,decimals:10) ?? "—")+" DOT"))).oathFont(.footnote).foregroundStyle(.secondary)
                        }
                        if EVMSendAmount.less(plan.amount,plan.requestedAmount) { Text(strings.text(.sendFeeAdjusted)).oathFont(.footnote).foregroundStyle(.secondary) }
                    }
                    if model.supportsNearSend, let plan = near.quote?.plan {
                        detail(.sendRemaining, value: xrplAssetMoney(plan.remaining))
                        if plan.storageDeposit == "0" { Text(strings.text(.nearFeeNotice)).oathFont(.footnote).foregroundStyle(.secondary) }
                    }
                    if model.supportsTronSend, let plan = tron.quote?.plan {
                        detail(.sendRemaining, value: xrplAssetMoney(plan.remaining))
                    }
                    if model.supportsStellarSend, let plan = stellar.quote?.plan {
                        detail(.sendRemaining, value: xrplAssetMoney(plan.remaining))
                        if plan.kind == .contract { Text(strings.text(.stellarFeeMaximum)).oathFont(.footnote).foregroundStyle(.secondary) }
                    }
                    if model.supportsXrplSend, let plan = xrpl.quote?.plan {
                        detail(.sendRemaining, value: xrplAssetMoney(plan.remaining))
                        if plan.tokenFee != "0" { detail(.xrplTokenFee, value: xrplAssetMoney(plan.tokenFee)) }
                        if plan.closesAccount {
                            Text(strings.text(.xrplCloseWarning)).oathFont(.footnote).foregroundStyle(.red)
                                .fixedSize(horizontal:false,vertical:true)
                        }
                    }
                    if model.supportsSuiSend, let plan = sui.quote?.plan {
                        detail(.sendRemaining, value: suiAssetMoney(plan.remaining))
                        if plan.deductedFromAmount > 0 {
                            Text(strings.text(.suiGasReserved)).oathFont(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    if model.supportsBitcoinSend, let plan = bitcoin.quote?.plan {
                        detail(.sendRemaining, value: money(plan.remainingBalance))
                        if plan.deductedFromAmount > 0 {
                            Text(strings.text(.sendFeeAdjusted)).oathFont(.footnote).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if !busy, let guidance = accountGuidance, !guidance.isBlocking {
                    accountNotice(guidance)
                }
                if model.reviewNeedsUpdate {
                    Label(strings.text(.sendReviewChanged), systemImage: "exclamationmark.circle")
                        .oathFont(.footnote).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(spacing: 16) {
                    if model.supportsSend {
                        if showsFeeFunding {
                            feeFundingNotice
                        } else if !busy && needsRefresh {
                            if let guidance = accountGuidance {
                                accountNotice(guidance)
                                OathActionButton(title: strings.text(guidance.actionTitle), appearance: .secondary) {
                                    performAccountAction(guidance.action)
                                }
                                if guidance.action == .editRecipient {
                                    OathButton(strings.text(.sendRefreshQuote)) { prepare() }.oathNeutralControl()
                                }
                            } else {
                                Text(reviewFailureMessage).oathFont(.footnote).foregroundStyle(.red)
                                    .fixedSize(horizontal: false, vertical: true)
                                OathActionButton(title: strings.text((thorchain.needsRecipientChange || aptos.needsRecipientChange || xrpl.needsRecipientChange) ? .sendChangeAddress : needsAmountChange ? .sendEditAmount : .sendRefreshQuote), appearance: .secondary) {
                                    if thorchain.needsRecipientChange || aptos.needsRecipientChange || xrpl.needsRecipientChange { model.path = [.recipient] }
                                    else if needsAmountChange { model.path = [.recipient, .amount] }
                                    else { prepare() }
                                }
                            }
                        }
                    } else {
                        Text(strings.text(.sendNotAvailable)).oathFont(.footnote).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }.oathActionArea(existingInset: 20)

            }.padding(.horizontal, 20).padding(.vertical, 28)
                .frame(maxWidth: 600).frame(maxWidth: .infinity)
        }
        .oathInteractionBlocked(isSubmitting)
        .accessibilityIdentifier("send.review")
    }

    private func money(_ sats: Int64) -> String {
        let amount = Decimal(sats) / 100_000_000
        if let price = model.reviewPrice {
            return OathAssetAmountFormat(locale: strings.language.locale, selectedCurrencyCode: model.reviewCurrency ?? model.currency).money((amount * price))
        }
        return strings.invariant((OathSendAmount.units(String(sats), decimals: 8) ?? "—") + (model.chain == .dogecoin ? " DOGE" : model.chain == .litecoin ? " LTC" : model.chain == .bitcoincash ? " BCH" : " BTC"))
    }

    private func result(_ submission: OathBitcoinSubmission) -> some View {
        let recipient = recipientAddress
        // CashAddr's network prefix stays in the transfer; omit it only from
        // this receipt's visible and spoken address before shortening it.
        let cashPrefix = "bitcoincash:"
        let address = model.chain == .bitcoincash && recipient.lowercased().hasPrefix(cashPrefix)
            ? String(recipient.dropFirst(cashPrefix.count)) : recipient
        let compactAddress = address.count > 24 ? String(address.prefix(12)) + "…" + String(address.suffix(8)) : address
        return OathEmptyStateScrollView(maximumWidth: 600) {
            VStack(spacing: 24) {
                resultSymbol(outcome: receiptOutcome)
                    .frame(width: 72, height: 72)
                    .accessibilityHidden(true)
                ZStack {
                    Text(strings.text(receiptTitle))
                        .oathFont(.largeTitle, weight: .bold).multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                        .id(receiptTitle).transition(receiptTransition)
                }
                Text(fiat ?? native).oathFont(.largeTitle, weight: .semibold).multilineTextAlignment(.center)
                ZStack {
                    if showsRecipientReceipt {
                        Text(receiptMessage(compactAddress: compactAddress))
                            .oathFont(.title3).tint(.primary).multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel(strings.format(recipientReceiptKey, strings.invariant(address)))
                            .accessibilityIdentifier("send.result.message")
                            .accessibilityActions {
                                if savedRecipient == false {
                                    OathButton(strings.text(.addContact), feedback: .navigate, action: presentContactEditor)
                                }
                            }
                            .environment(\.openURL, OpenURLAction { url in
                                guard url.absoluteString == "oath-contact://add-recipient", savedRecipient == false,
                                      session.isUnlocked, !session.resetting else { return .discarded }
                                presentContactEditor()
                                return .handled
                            })
                            .id(receiptOutcome).transition(receiptTransition)
                    } else if let receiptDetail {
                        Text(strings.text(receiptDetail))
                            .oathFont(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .id(receiptOutcome).transition(receiptTransition)
                    }
                }
                if receiptOutcome == .failed {
                    OathButton(strings.text(.sendContactSupport), feedback: .navigate) {
                        openURL(OathSupportLinks.contact)
                    }
                    .oathActionStyle(.secondary)
                    .accessibilityIdentifier("send.result.contactSupport")
                    .transition(receiptTransition)
                }
                if showsRecipientReceipt, contactLookupFailed {
                    Text(strings.text(.contactsLoadFailed)).oathFont(.footnote).foregroundStyle(.red)
                    OathButton(strings.text(.tryAgain)) { contactLookupRetry = UUID() }
                        .oathNeutralControl()
                }
                if receiptObservationFailed {
                    Text(strings.text(.refreshFailed)).oathFont(.footnote).foregroundStyle(.secondary)
                    OathButton(strings.text(.tryAgain)) { receiptRetry = UUID() }.oathNeutralControl()
                }
            }.padding(24).frame(maxWidth: 600).frame(maxWidth: .infinity)
                .animation(receiptAnimation, value: receiptOutcome)
        }
        .scrollBounceBehavior(.basedOnSize)
        .oathBottomActions(isPresented: model.chain?.transactionExplorerURL(hash: submission.txid) != nil) {
            VStack(spacing: 12) {
                if receiptHash == submission.txid, let replacement = receiptState?.replacementHash,
                   [.cancelled, .replaced].contains(receiptOutcome),
                   let url = model.chain?.transactionExplorerURL(hash: replacement) {
                    OathBottomAction(title: strings.text(.transactionReplacement), identifier: "send.result.replacement",
                                     appearance: .secondary) { openURL(url) }
                        .transition(receiptTransition)
                }
                if let url = model.chain?.transactionExplorerURL(hash: submission.txid) {
                    OathBottomAction(title: strings.text(.transactionViewExplorer), identifier: "send.result.explorer",
                                     appearance: .secondary) { openURL(url) }
                }
            }
            .animation(receiptAnimation, value: receiptOutcome)
        }
        // Keep address-book observation alive across submitted -> confirmed so
        // an unsaved address does not briefly lose its dotted link.
        .task(id: "\(submission.txid)-\(showsRecipientReceipt)-\(contactLookupRetry)") {
            if showsRecipientReceipt { await observeRecipientContact() }
        }
        .task(id: "\(submission.txid)-\(receiptOutcome)-\(scenePhase == .active)") {
            let outcome = receiptOutcome
            guard scenePhase == .active, outcome != .checking, outcome != .awaitingConfirmation else { return }
            let key = submission.txid + ":" + outcome.rawValue
            guard !receiptFeedbackStates.contains(key) else { return }
            await Task.yield()
            guard !Task.isCancelled else { return }
            receiptFeedbackStates.insert(key)
            OathHaptics.shared.play(outcome == .submitted || outcome == .confirmed ? .success : .warning)
        }
        .accessibilityIdentifier("send.result")
    }

    private func resultSymbol(outcome: SendSubmissionState.Outcome) -> some View {
        let symbol: String = switch outcome {
        case .submitted: "checkmark.circle.dotted"
        case .confirmed: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle"
        case .cancelled: "xmark.circle"
        case .expired: "clock.badge.exclamationmark"
        case .replaced: "arrow.triangle.2.circlepath"
        case .checking, .awaitingConfirmation: "clock.arrow.circlepath"
        }
        let color: Color = switch outcome {
        case .submitted, .confirmed, .checking, .awaitingConfirmation: OathOnboardingColors.blue
        case .failed: .red
        case .cancelled, .replaced, .expired: .orange
        }
        // Keep one Image identity across states so SF Symbols can replace the
        // whole symbol instead of removing/reinserting it with the text blur.
        return Image(systemName: symbol)
            .font(.system(size: 64))
            .foregroundStyle(color)
            .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace.downUp.wholeSymbol, options: .nonRepeating))
            .symbolEffectsRemoved(reduceMotion)
    }

    private func presentContactEditor() {
        guard savedRecipient == false, session.isUnlocked, !session.resetting else { return }
        OathHaptics.shared.play(.navigate)
        showsAddContact = true
    }

    private func receiptMessage(compactAddress: String) -> AttributedString {
        let address = strings.invariant(compactAddress)
        var message = AttributedString(strings.format(recipientReceiptKey, address))
        message.foregroundColor = .secondary
        if let range = message.range(of: address) {
            message[range].foregroundColor = .primary
            if savedRecipient == false {
                message[range].link = URL(string: "oath-contact://add-recipient")
                message[range].underlineStyle = Text.LineStyle(pattern: .dot, color: .gray.opacity(0.65))
            }
        }
        return message
    }

    private func observeRecipientContact() async {
        #if DEBUG && targetEnvironment(simulator)
        if OathSendResultVisualFixture.enabled { savedRecipient = true; return }
        #endif
        savedRecipient = nil; contactLookupFailed = false
        guard let networkID = model.holding?.networkID else { return }
        await OathDiagnostics.$chain.withValue(networkID) {
            await OathDiagnostics.$operationID.withValue(UUID()) {
                do {
                    let database = try await OathDataEnvironment.shared.database()
                    for try await saved in database.observeContactAddress(networkID: networkID, address: recipientAddress) {
                        try Task.checkCancellation()
                        savedRecipient = saved
                    }
                } catch is CancellationError { }
                catch {
                    OathDiagnostics.record(error, component: "contacts", operation: "observe_sent_recipient")
                    if !Task.isCancelled { savedRecipient = nil; contactLookupFailed = true }
                }
            }
        }
    }

    private var hero: some View {
        VStack(spacing: 14) {
            if let holding = model.holding { OathSendLogo(holding: holding, size: 40) }
            Text(strings.text(.sendYoureSending)).oathFont(.body).foregroundStyle(.secondary)
            Text(fiat ?? native).oathFont(.largeTitle, weight: .semibold, size: 46)
                .lineLimit(2).minimumScaleFactor(0.5).multilineTextAlignment(.center)
            Text(fiat == nil ? strings.text(.assetPriceUnavailable) : native)
                .oathFont(.title3).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity)
    }

    private var recipient: some View {
        HStack(alignment: .firstTextBaseline, spacing: 24) {
            Text(strings.text(.transactionTo)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            OathButton(feedback: .navigate) { showsAddress = true } label: {
                Text(recipientAddress)
                    .underline(pattern: .dot, color: .gray.opacity(0.65))
                    .lineLimit(1).truncationMode(.middle)
                    .environment(\.layoutDirection, .leftToRight)
                    .padding(.vertical, 8).frame(minHeight: 44).contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(.primary)
                .accessibilityLabel(strings.text(.transactionTo))
                .accessibilityValue(recipientAddress)
                .accessibilityHint(strings.text(.sendShowAddress))
                .accessibilityIdentifier("send.recipient.showAddress")
        }.oathFont(.body)
    }

    @ViewBuilder private func feeDetail(_ key: OathStringKey, value: String?) -> some View {
        if isQuotePending {
            HStack(alignment: .firstTextBaseline, spacing: 24) {
                Text(strings.text(key)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                OathSendFeePlaceholder()
            }.oathFont(.body)
        } else {
            detail(key, value: value ?? "—")
        }
    }

    private func detail(_ key: OathStringKey, value: String) -> some View {
        OathSendReviewDetail(title: strings.text(key)) { Text(value) }
    }
}

/// Shared review rows keep labels, values and larger-text wrapping consistent
/// across transfers and swap requests. The containing list owns row spacing.
struct OathSendReviewDetail<Value: View>: View {
    let title: String
    let value: Value
    let fitsSingleLine: Bool

    init(title: String, fitsSingleLine: Bool = false, @ViewBuilder value: () -> Value) {
        self.title = title
        self.value = value()
        self.fitsSingleLine = fitsSingleLine
    }

    var body: some View {
        Group {
            if fitsSingleLine {
                horizontal
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            } else {
                ViewThatFits(in: .horizontal) {
                    horizontal.fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(title).foregroundStyle(.secondary)
                        value.multilineTextAlignment(.leading)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }.oathFont(.body)
    }

    private var horizontal: some View {
        HStack(alignment: .firstTextBaseline, spacing: 24) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            value.multilineTextAlignment(.trailing)
        }
    }
}

/// A native SwiftUI placeholder exists only while a quote is pending. Motion
/// pauses with the scene and respects Reduce Motion; a failed quote never keeps
/// animating indefinitely instead of offering the existing retry action.
private struct OathSendFeePlaceholder: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.oathLocalizer) private var strings
    @ScaledMetric(relativeTo: .body) private var height = 20.0

    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color(uiColor: .tertiarySystemFill))
            .overlay {
                if !reduceMotion && scenePhase == .active {
                    GeometryReader { geometry in
                        LinearGradient(colors: [.clear, Color.primary.opacity(0.08), .clear],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: geometry.size.width * 0.6)
                            .phaseAnimator([false, true]) { content, across in
                                content.offset(x: across ? geometry.size.width : -geometry.size.width * 0.6)
                            } animation: { across in
                                .linear(duration: across ? 1.2 : 0)
                            }
                    }
                }
            }
            .frame(width: 110, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(strings.text(.sendLoadingFee))
    }
}

#if DEBUG && targetEnvironment(simulator)
/// Renders the production receipt with synthetic journal states. No transfer is prepared or sent.
struct OathSendResultVisualFixture: View {
    static var state: String { UserDefaults.standard.string(forKey: "oath.sendResultFixture") ?? "" }
    static var enabled: Bool { ["submitted", "confirmed", "failed", "canceled", "replaced", "expired"].contains(state) }
    let session: OathWalletSession
    @State private var presented = false

    var body: some View {
        OathBackground().ignoresSafeArea()
            .preferredColorScheme(.light)
            .task { presented = true }
            .sheet(isPresented: $presented) {
                NavigationStack {
                    OathSendReviewPage.visualFixture(session: session, state: Self.state) { presented = false }
                        .navigationBarTitleDisplayMode(.inline)
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(Color(uiColor: OathSurfaceColors.canvas))
                .oathLanguage(.english)
            }
    }
}

private extension OathSendReviewPage {
    static func visualFixture(session: OathWalletSession, state: String, onClose: @escaping @MainActor () -> Void) -> Self {
        let hash = "0x" + String(repeating: "1", count: 64)
        let replacement = "0x" + String(repeating: "2", count: 64)
        let progress: SendSubmissionState = switch state {
        case "confirmed": .init(state: "confirmed", accepted: true)
        case "failed": .init(state: "failed", accepted: true, failureCode: "execution_failed")
        case "canceled": .init(state: "cancelled", accepted: true, replacementHash: replacement)
        case "replaced": .init(state: "failed", accepted: true, failureCode: "replaced", replacementHash: replacement)
        case "expired": .init(state: "failed", accepted: true, failureCode: "expired")
        default: .init(state: "broadcast", accepted: true)
        }
        var page = Self(model: .resultVisualFixture(), session: session,
                        bitcoin: .init(), sui: .init(), xrpl: .init(), stellar: .init(), tron: .init(),
                        ton: .init(), solana: .init(), aptos: .init(), thorchain: .init(),
                        evm: .resultVisualFixture(hash: hash), arc: .init(), polkadot: .init(), near: .init(), onClose: onClose)
        page._receiptHash = State(initialValue: hash)
        page._receiptState = State(initialValue: progress)
        page._savedRecipient = State(initialValue: true)
        return page
    }
}
#endif
