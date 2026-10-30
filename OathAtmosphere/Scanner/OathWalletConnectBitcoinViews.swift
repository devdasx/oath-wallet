import SwiftUI
import OathBitcoin
import OathDatabase

struct OathWCBitcoinReview: View {
    let request: BitcoinConnectRequest
    let plan: BitcoinConnectPlan?
    @Environment(\.oathLocalizer) private var strings
    var body: some View {
        VStack(spacing: 0) {
            OathSettingsRow(title: request.network.name, accessory: .none, networkLogo: "network-bitcoin")
            OathWCValue(title: strings.text(.scannerWCAccount), value: request.account, leftToRight: true)
            if let plan {
                ForEach(Array(plan.outputs.enumerated()), id: \.offset) { _, output in
                    OathSettingsSectionRule()
                    if let address = output.address {
                        OathWCValue(title: strings.text(output.owned ? .sendChangeAddress : .sendRecipient), value: address, leftToRight: true)
                    } else {
                        OathWCValue(title: strings.text(.wcSignData), value: output.dataOutput?.message ?? output.script.map { String(format: "%02x", $0) }.joined(), leftToRight: true)
                    }
                    OathWCValue(title: strings.text(.sendAmount), value: btc(output.value), leftToRight: true)
                }
                OathSettingsSectionRule()
                OathWCValue(title: strings.text(.transactionNetworkFee), value: btc(plan.fee), leftToRight: true)
                OathWCValue(title: strings.text(.sendTotal), value: btc(plan.debit), leftToRight: true)
                if !request.broadcasts { OathSettingsFooter { Text(strings.text(.wcTypedWarning)) } }
                NavigationLink {
                    ScrollView {
                        Text(plan.psbt).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(20)
                    }.navigationTitle(strings.text(.wcSignData)).navigationBarTitleDisplayMode(.inline)
                } label: { OathSettingsRow(title: strings.text(.wcSignData), icon: "text.alignleft") }
                    .buttonStyle(OathSettingsRowButtonStyle())
            } else {
                if let address = request.address, address != request.account {
                    OathWCValue(title: strings.text(.scannerWCAccount), value: address, leftToRight: true)
                }
                Text(verbatim: request.message ?? "")
                    .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(20)
                NavigationLink {
                    ScrollView {
                        Text(Data((request.message ?? "").utf8).map { String(format: "%02x", $0) }.joined())
                            .font(.system(.footnote, design: .monospaced)).textSelection(.enabled).padding(20)
                    }.navigationTitle(strings.text(.wcSignData)).navigationBarTitleDisplayMode(.inline)
                } label: { OathSettingsRow(title: strings.text(.wcSignData), icon: "text.alignleft") }
                    .buttonStyle(OathSettingsRowButtonStyle())
            }
        }
    }
    private func btc(_ sats: UInt64) -> String { (OathSendAmount.units(String(sats), decimals: 8) ?? "—") + " BTC" }
}

struct OathWCBitcoinCompletion: View {
    let submission: WalletConnectBitcoinSubmission
    let identity: OathWCIdentity
    let close: @MainActor () -> Void
    @Environment(\.oathLocalizer) private var strings
    private var confirmed: Bool { submission.state == "confirmed" }
    private var checking: Bool { ["signed", "unknown"].contains(submission.state) }
    var body: some View {
        OathWCResultContent(identity: identity) {
            VStack(spacing: 18) {
                Image(systemName: confirmed ? "checkmark.circle" : "clock")
                    .font(.system(size: 52)).foregroundStyle(OathOnboardingColors.blue)
                Text(strings.text(confirmed ? .wcTransactionConfirmed : checking ? .sendChecking : .wcTransactionPending))
                    .oathFont(.title2, weight: .semibold)
                Text(strings.text(confirmed ? .wcTransactionConfirmedDetail : checking ? .sendCheckingDetail : .wcTransactionPendingDetail))
                    .oathFont(.body).foregroundStyle(.secondary)
                Text(BitcoinConnectNetwork(chain: submission.chain)?.name ?? "Bitcoin")
                    .oathFont(.subheadline).foregroundStyle(.secondary)
            }.multilineTextAlignment(.center).frame(maxWidth: .infinity)
        }.toolbar {
            ToolbarItem(placement: .topBarTrailing) { OathDoneButton(action: close) }
        }.toolbar(.hidden, for: .bottomBar)
    }
}
