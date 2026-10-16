import SwiftUI
import OathAnkr
import OathDiagnostics

/// Shows only facts decoded from the immutable Cosmos signing document. A
/// protocol deposit is not presented as a completed swap or guaranteed output.
struct OathWCThorchainReview: View {
    let request: ThorchainWalletConnectRequest
    let review: ThorchainWalletConnectReview
    let close: @MainActor () -> Void
    @Environment(\.oathLocalizer) private var strings
    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    OathNetworkLogo(asset: OathImportChain.thorchain.logoAsset, size: 20)
                    Text(verbatim: "THORChain").oathFont(.subheadline).foregroundStyle(.secondary)
                }
                Text(strings.text(review.swap != nil ? .wcCrossSwap : request.recipient == nil ? .wcProtocolDeposit : .wcReviewTransaction))
                    .oathFont(.title2, weight: .semibold)
                ForEach(request.coins, id: \.reference) { coin in
                    Text((OathSendAmount.units(coin.amount, decimals: review.decimals[coin.reference] ?? 0) ?? coin.amount)
                        + " " + ThorchainToken.fallback(coin.reference).symbol)
                        .oathFont(.largeTitle, weight: .semibold).minimumScaleFactor(0.6).lineLimit(2)
                        .environment(\.layoutDirection, .leftToRight)
                    if coin.reference != "native" {
                        Text(coin.reference).oathFont(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }.frame(maxWidth: .infinity).multilineTextAlignment(.center).padding(24)
            if let swap = review.swap {
                OathWCValue(title: strings.text(.wcReceiveNetwork),
                    value: OathImportChain(rawValue: swap.memo.networkID)?.name ?? swap.memo.asset, leftToRight: true)
                Image(systemName: "arrow.down").font(.title2).foregroundStyle(.secondary).padding(.bottom, 12)
                VStack(spacing: 8) {
                    Text(strings.text(.wcEstimatedReceive)).oathFont(.subheadline).foregroundStyle(.secondary)
                    Text((OathSendAmount.units(swap.expectedOutput, decimals: 8) ?? swap.expectedOutput) + " " + swap.memo.symbol)
                        .oathFont(.largeTitle, weight: .semibold).minimumScaleFactor(0.6).lineLimit(2)
                        .environment(\.layoutDirection, .leftToRight)
                }.frame(maxWidth: .infinity).padding(.bottom, 24)
                OathWCValue(title: strings.text(.wcMinimumOut), value: units(swap.memo.minimum, swap.memo.symbol), leftToRight: true)
                NavigationLink {
                    OathWCThorchainSwapDetails(request: request, review: review, swap: swap, close: close)
                } label: { OathSettingsRow(title: strings.text(.wcSwapDetails), icon: "arrow.triangle.swap") }
                    .buttonStyle(OathSettingsRowButtonStyle()).accessibilityIdentifier("walletconnect.thor.swapDetails")
                OathSettingsFooter { Text(strings.text(swap.memo.minimum == "0" ? .wcNoMinimum : .wcCrossSwapDetail)) }
            }
            OathWCValue(title: strings.text(.scannerWCAccount), value: request.sender, leftToRight: true)
            OathWCValue(title: strings.text(.tokenNetwork), value: "THORChain", leftToRight: true)
            if let recipient = request.recipient {
                NavigationLink {
                    OathWCAddressDetails(address: recipient, title: .sendRecipient, close: close)
                } label: { OathSettingsRow(title: strings.text(.sendRecipient), value: recipient) }
                    .buttonStyle(OathSettingsRowButtonStyle()).accessibilityIdentifier("walletconnect.thor.recipient")
            } else { OathSettingsFooter { Text(strings.text(.wcProtocolDepositDetail)) } }
            OathWCValue(title: strings.text(.wcProtocolFee), value: (OathSendAmount.units(String(review.fee), decimals: 8) ?? "—") + " RUNE", leftToRight: true)
            if !request.memo.isEmpty, review.swap == nil {
                OathWCValue(title: strings.text(.sendMemo), value: request.memo, leftToRight: true)
            }
            NavigationLink {
                OathWCThorchainDetails(request: request, review: review, close: close)
            } label: { OathSettingsRow(title: strings.text(.wcTransactionData), icon: "text.alignleft") }
                .buttonStyle(OathSettingsRowButtonStyle()).accessibilityIdentifier("walletconnect.thor.details")
            OathSettingsFooter { Text(strings.text(.wcTransactionDetail)) }
        }
    }
    private func units(_ value: String, _ symbol: String) -> String { (OathSendAmount.units(value, decimals: 8) ?? value) + " " + symbol }
}

struct OathWCThorchainSwapDetails: View {
    let request: ThorchainWalletConnectRequest
    let review: ThorchainWalletConnectReview
    let swap: ThorchainSwapQuote
    let close: @MainActor () -> Void
    @Environment(\.oathLocalizer) private var strings
    private func units(_ value: String) -> String { (OathSendAmount.units(value, decimals: 8) ?? value) + " " + swap.memo.symbol }
    var body: some View {
        OathWCContent {
            OathWCValue(title: strings.text(.tokenNetwork), value: "THORChain", leftToRight: true)
            OathWCValue(title: strings.text(.wcReceiveNetwork), value: OathImportChain(rawValue: swap.memo.networkID)?.name ?? swap.memo.asset, leftToRight: true)
            OathWCValue(title: strings.text(.sendRecipient), value: swap.memo.destination, leftToRight: true)
            OathWCValue(title: strings.text(.wcEstimatedReceive), value: units(swap.expectedOutput), leftToRight: true)
            OathWCValue(title: strings.text(.wcMinimumOut), value: units(swap.memo.minimum), leftToRight: true)
            OathSettingsSectionRule()
            OathWCValue(title: strings.text(.wcProtocolFee), value: (OathSendAmount.units(String(review.fee), decimals: 8) ?? "—") + " RUNE", leftToRight: true)
            OathWCValue(title: strings.text(.wcOutboundFee), value: units(swap.outboundFee), leftToRight: true)
            OathWCValue(title: strings.text(.wcLiquidityFee), value: units(swap.liquidityFee), leftToRight: true)
            if swap.affiliateFee != "0" {
                OathWCValue(title: strings.text(.wcAffiliateFee), value: units(swap.affiliateFee), leftToRight: true)
                if let affiliate = swap.memo.affiliate { OathWCValue(title: strings.text(.wcAffiliate), value: affiliate, leftToRight: true) }
            }
            OathSettingsFooter { Text(strings.text(.wcSwapFeesDetail)) }
            OathWCValue(title: strings.text(.sendMemo), value: request.memo, leftToRight: true)
            OathSettingsFooter { Text(strings.text(swap.memo.minimum == "0" ? .wcNoMinimum : .wcCrossSwapDetail)) }
        }.navigationTitle(strings.text(.wcSwapDetails)).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { OathCloseButton(action: close) } }
    }
}

struct OathWCThorchainDetails: View {
    let request: ThorchainWalletConnectRequest
    let review: ThorchainWalletConnectReview
    let close: @MainActor () -> Void
    @Environment(\.oathLocalizer) private var strings
    @State private var document: String?
    @State private var showsOriginal = false
    var body: some View {
        OathWCContent {
            OathWCValue(title: strings.text(.tokenNetwork), value: "THORChain", leftToRight: true)
            OathWCValue(title: strings.text(.scannerWCAccount), value: request.sender, leftToRight: true)
            if let recipient = request.recipient {
                OathWCValue(title: strings.text(.sendRecipient), value: recipient, leftToRight: true)
            } else { OathSettingsFooter { Text(strings.text(.wcProtocolDepositDetail)) } }
            ForEach(request.coins, id: \.reference) { coin in
                OathWCValue(title: strings.text(.sendAmount),
                    value: (OathSendAmount.units(coin.amount, decimals: review.decimals[coin.reference] ?? 0) ?? coin.amount)
                        + " " + ThorchainToken.fallback(coin.reference).symbol, leftToRight: true)
            }
            OathWCValue(title: strings.text(.wcProtocolFee), value: (OathSendAmount.units(String(review.fee), decimals: 8) ?? "—") + " RUNE", leftToRight: true)
            if !request.memo.isEmpty { OathWCValue(title: strings.text(.sendMemo), value: request.memo, leftToRight: true) }
            if request.transactionMemo != request.memo, !request.transactionMemo.isEmpty {
                OathWCValue(title: strings.text(.wcTransactionMemo), value: request.transactionMemo, leftToRight: true)
            }
            OathSettingsSectionRule()
            DisclosureGroup(isExpanded: $showsOriginal) {
                OathWCValue(title: strings.text(.wcCallMethod), value: request.method, leftToRight: true)
                OathWCValue(title: strings.text(.wcCosmosAccountNumber), value: String(request.accountNumber), leftToRight: true)
                OathWCValue(title: strings.text(.wcCosmosSequence), value: String(request.sequence), leftToRight: true)
                OathWCValue(title: strings.text(.wcTimeoutHeight), value: String(request.timeoutHeight), leftToRight: true)
                OathSettingsFooter { Text(strings.text(.wcCosmosDocumentDetail)) }
                if let document {
                    Text(document).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 16)
                        .environment(\.layoutDirection, .leftToRight)
                }
            } label: { Text(strings.text(.wcTransactionData)).oathFont(.body) }
                .tint(.primary).padding(20)
        }.navigationTitle(strings.text(.assetTransaction)).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { OathCloseButton(action: close) } }
            .task {
                // Bounded parser input; encoding runs away from the UI actor.
                let value = request.signedDocument
                document = await Task.detached(priority: .userInitiated) {
                    OathDiagnostics.attempt("walletconnect_document_display") {
                        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                        return String(decoding: try encoder.encode(value), as: UTF8.self)
                    }
                }.value
            }
    }
}

/// Opened from persisted Activity, so relaunch does not lose the transaction
/// being followed. Polling is bounded and stops when this screen disappears.
struct OathWCThorchainProgress: View {
    let initial: ThorchainSwapProgress
    var fixture = false
    @State private var latest: ThorchainSwapProgress?
    @State private var failed = false
    @State private var refresh = UUID()
    @Environment(\.oathLocalizer) private var strings
    private var value: ThorchainSwapProgress { latest ?? initial }
    var body: some View {
        OathWCContent {
            VStack(spacing: 18) {
                Image(systemName: value.isFinished ? "checkmark.circle.fill" : "clock")
                    .font(.system(size: 56)).foregroundStyle(OathOnboardingColors.blue)
                Text(strings.text(value.refundObserved ? .wcSwapRefunded : value.outboundHash != nil ? .wcSwapObserved : value.refundPlanned ? .wcSwapRefundPending : .wcSwapProgress))
                    .oathFont(.title2, weight: .semibold)
                Text(strings.text(.wcSwapProgressDetail)).oathFont(.body).foregroundStyle(.secondary)
            }.multilineTextAlignment(.center).padding(24)
            stage(.wcDepositStage, done: value.depositConfirmed)
            stage(.wcSwapStage, done: value.swapFinalised)
            if value.refundPlanned || value.refundObserved {
                stage(.wcRefundTransaction, done: value.refundObserved)
            } else { stage(.wcDeliveryStage, done: value.outboundHash != nil) }
            OathWCValue(title: strings.text(.wcReceiveNetwork), value: OathImportChain(rawValue: value.memo.networkID)?.name ?? value.memo.networkID)
            OathWCValue(title: strings.text(.sendRecipient), value: value.memo.destination, leftToRight: true)
            OathWCValue(title: strings.text(.assetTransactionID), value: value.hash, leftToRight: true)
            if let hash = value.outboundHash ?? value.refundHash {
                OathWCValue(title: strings.text(!value.refundObserved ? .wcOutboundTransaction : .wcRefundTransaction), value: hash, leftToRight: true)
            }
            OathSettingsFooter { Text(strings.text(.wcSwapObservationSource)) }
            if failed { OathSettingsFooter { Text(strings.text(.wcSwapProgressUnavailable)).foregroundStyle(.red) } }
            if !value.isFinished {
                OathActionButton(title: strings.text(.sendRefreshQuote), appearance: .secondary) { refresh = UUID() }
                    .padding(20).accessibilityIdentifier("walletconnect.swap.refresh")
            }
        }.navigationTitle(strings.text(.wcSwapProgress)).navigationBarTitleDisplayMode(.inline)
            .task(id: refresh) {
                guard !fixture else { return }
                for _ in 0..<18 {
                    do {
                        try Task.checkCancellation()
                        if let update = try await ThorchainClient().swapProgress(hash: initial.hash) {
                            guard !Task.isCancelled else { return }
                            guard update.memo == initial.memo else { throw ThorchainError.wrongOwner }
                            latest = update; failed = false
                            if update.isFinished { return }
                        }
                        try await Task.sleep(for: .seconds(10))
                    } catch is CancellationError { return }
                    catch {
                        OathDiagnostics.record(error, component: "walletconnect", operation: "swap_progress_display", context: ["chain": "thorchain"])
                        if !Task.isCancelled { failed = true }; return
                    }
                }
            }
    }
    private func stage(_ title: OathStringKey, done: Bool) -> some View {
        HStack(spacing: 16) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? OathOnboardingColors.blue : Color.secondary).font(.title2)
            Text(strings.text(title)).oathFont(.body)
            Spacer()
            Text(strings.text(done ? .wcStageConfirmed : .wcStageWaiting)).oathFont(.subheadline).foregroundStyle(.secondary)
        }.padding(.horizontal, 20).padding(.vertical, 18)
    }
}
