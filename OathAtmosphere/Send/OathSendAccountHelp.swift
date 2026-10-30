import SwiftUI
import OathAnkr

extension SendAccountCost {
    var titleKey: OathStringKey {
        switch kind {
        case .xrpReserve, .stellarReserve, .solanaReserve: .accountCostReserve
        case .tronCreation: .accountCostCreation
        case .solanaTokenDeposit: .accountCostTokenDeposit
        case .nearStorage: .nearStorageDeposit
        }
    }
    var detailKey: OathStringKey {
        switch kind {
        case .xrpReserve: .accountCostXrpDetail
        case .stellarReserve: .accountCostStellarDetail
        case .solanaReserve: .accountCostSolanaDetail
        case .tronCreation: .accountCostTronDetail
        case .solanaTokenDeposit: .accountCostSolanaTokenDetail
        case .nearStorage: .accountCostNearDetail
        }
    }
    func amountText(strings: OathLocalizer) -> String {
        let units = OathSendAmount.units(atomic, decimals: decimals) ?? "—"
        return strings.invariant(units + " " + symbol)
    }
}

extension SendAccountGuidance {
    var actionTitle: OathStringKey {
        switch action {
        case .editAmount: .sendEditAmount
        case .editRecipient: .sendChangeAddress
        case .refresh: .sendRefreshQuote
        }
    }

    func minimumText(strings: OathLocalizer) -> String? {
        guard let minimumAtomic else { return nil }
        let decimals: Int, symbol: String
        switch topic {
        case .xrpActivation: decimals = 6; symbol = "XRP"
        case .stellarActivation: decimals = 7; symbol = "XLM"
        case .solanaActivation: decimals = 9; symbol = "SOL"
        case .tronActivation: decimals = 6; symbol = "TRX"
        default: return nil
        }
        guard let units = OathSendAmount.units(String(minimumAtomic), decimals: decimals) else { return nil }
        return strings.invariant(units + " " + symbol)
    }

    func summary(strings: OathLocalizer) -> String {
        let key: OathStringKey
        switch topic {
        case .xrpActivation, .stellarActivation, .solanaActivation:
            if isBlocking, let amount = minimumText(strings: strings) {
                return strings.format(.accountMinimumMessage, amount)
            }
            key = .accountActivationIncluded
        case .xrpTokenActivation, .stellarTokenActivation, .nearTokenActivation: key = .accountTokenActivation
        case .xrpReserve, .stellarReserve:
            if isBlocking {
                let symbol = topic == .xrpReserve ? "XRP" : "XLM"
                return strings.invariant(symbol) + ": " + strings.text(.accountReserveShort)
            }
            key = .accountReserveInfo
        case .stellarTrustline: key = .accountTrustlineShort
        case .tronActivation: key = isBlocking ? .accountTronActivationShort : .accountTronActivationInfo
        case .tronTokenActivation: key = .accountTronTokenInfo
        case .tronResources: key = isBlocking ? .accountTronResourcesShort : .accountTronResourcesInfo
        case .tronSenderActivation: key = .accountTronSenderShort
        case .nearAccount: key = .accountNearMissingShort
        case .nearStorage: key = isBlocking ? .accountNearStorageFunds : .accountNearStorageInfo
        case .nearStorageUnsupported: key = .accountNearStorageShort
        case .solanaRent: key = isBlocking ? .accountSolanaRentShort : .accountSolanaRentInfo
        case .solanaStorage: key = .accountSolanaStorageShort
        }
        return strings.text(key)
    }

    var detailKey: OathStringKey {
        switch topic {
        case .xrpActivation: .accountXrpActivationDetail
        case .stellarActivation: .accountStellarActivationDetail
        case .solanaActivation: .accountSolanaActivationDetail
        case .xrpTokenActivation: .accountXrpTokenDetail
        case .stellarTokenActivation: .accountStellarTokenDetail
        case .stellarTrustline: .accountStellarTrustlineDetail
        case .xrpReserve: .accountXrpReserveDetail
        case .stellarReserve: .accountStellarReserveDetail
        case .tronActivation: .accountTronActivationDetail
        case .tronTokenActivation: .accountTronTokenDetail
        case .tronResources: .accountTronResourcesDetail
        case .tronSenderActivation: .accountTronSenderDetail
        case .nearAccount: .accountNearMissingDetail
        case .nearTokenActivation: .accountNearTokenDetail
        case .nearStorage: .accountNearStorageDetail
        case .nearStorageUnsupported: .accountNearStorageUnsupportedDetail
        case .solanaRent: .accountSolanaRentDetail
        case .solanaStorage: .accountSolanaStorageDetail
        }
    }
}

/// Shared, local-only explanation. Opening help performs no network work and
/// records no telemetry; the original failure is reported by the send model.
struct OathSendAccountHelp: View {
    let guidance: SendAccountGuidance
    let onAction: (SendAccountGuidance.Action) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.oathLocalizer) private var strings

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text(guidance.cost.map { $0.amountText(strings: strings) } ?? guidance.summary(strings: strings))
                        .oathFont(.title3, weight: .semibold)
                        .foregroundStyle(guidance.isBlocking ? Color.red : Color.primary)
                    if let cost = guidance.cost {
                        Text(strings.text(cost.inclusion == .payment ? .accountCostPaymentExplanation : .accountCostExtraExplanation))
                            .oathFont(.body).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let minimum = guidance.minimumText(strings: strings) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(strings.text(guidance.topic == .tronActivation ? .accountRequiredFees : .accountMinimumPayment))
                                .oathFont(.footnote).foregroundStyle(.secondary)
                            Text(minimum).oathFont(.title2, weight: .semibold)
                        }
                    }
                    Text(strings.text(guidance.cost?.detailKey ?? guidance.detailKey)).oathFont(.body)
                        .fixedSize(horizontal: false, vertical: true)
                }.padding(24).frame(maxWidth: 600).frame(maxWidth: .infinity, alignment: .center)
            }
            .background(Color(uiColor: OathSurfaceColors.canvas))
            .navigationTitle(strings.text(guidance.cost?.titleKey ?? .accountHelpTitle)).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { OathCloseButton { dismiss() } }
            }
            .oathBottomActions(isPresented: guidance.isBlocking) {
                OathBottomAction(title: strings.text(guidance.actionTitle), identifier: "send.accountHelp.action") {
                    onAction(guidance.action)
                }
            }
        }
        .oathNativeLocalization()
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color(uiColor: OathSurfaceColors.canvas))
        .accessibilityIdentifier("send.accountHelp")
    }
}
