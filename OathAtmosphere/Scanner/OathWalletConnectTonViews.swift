import SwiftUI
import OathAnkr
import OathDatabase

struct OathWCTonReview: View {
    let request: WalletConnectTonRequest
    let plan: WalletConnectTonPlan?
    @Environment(\.oathLocalizer) private var strings
    var body: some View {
        VStack(spacing: 0) {
            OathSettingsRow(title: request.network.walletConnectName, accessory: .none, networkLogo: "network-ton")
            OathWCValue(title: strings.text(.scannerWCAccount), value: request.account, leftToRight: true)
            if request.broadcasts {
                ForEach(Array(request.messages.enumerated()), id: \.offset) { _, message in
                    OathSettingsSectionRule()
                    OathWCValue(title: strings.text(.sendRecipient), value: message.address, leftToRight: true)
                    OathWCValue(title: strings.text(.sendAmount), value: (OathSendAmount.units(String(message.amount), decimals: 9) ?? "—") + " TON", leftToRight: true)
                    if message.payload != nil || message.stateInit != nil {
                        NavigationLink {
                            OathWCContent {
                                OathSettingsFooter { Text(strings.text(.wcCallWarning)) }
                                if let payload = message.payload { raw(payload) }
                                if let stateInit = message.stateInit { raw(stateInit) }
                            }.navigationTitle(strings.text(.wcSignData)).navigationBarTitleDisplayMode(.inline)
                        } label: { OathSettingsRow(title: strings.text(.wcSignData), icon: "text.alignleft") }
                            .buttonStyle(OathSettingsRowButtonStyle())
                    }
                }
                OathSettingsSectionRule()
                if let plan {
                    OathWCValue(title: strings.text(.transactionNetworkFee), value: (OathSendAmount.units(String(plan.fee), decimals: 9) ?? "—") + " TON", leftToRight: true)
                }
                OathSettingsFooter { Text(strings.text(.wcCallWarning)) }
            } else {
                if request.params["type"].string != "text" { OathSettingsFooter { Text(strings.text(.wcTypedWarning)) } }
                Text(request.params["text"].string ?? request.params["schema"].string ?? "")
                    .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(20)
                if let value = request.params["bytes"].string ?? request.params["cell"].string,
                   let bytes = Data(base64Encoded: value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/").padding(toLength: ((value.count + 3) / 4) * 4, withPad: "=", startingAt: 0)) { raw(bytes) }
            }
        }
    }
    private func raw(_ bytes: Data) -> some View {
        Text(bytes.map { String(format: "%02x", $0) }.joined())
            .font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
            .environment(\.layoutDirection, .leftToRight)
            .frame(maxWidth: .infinity, alignment: .leading).padding(20)
    }
}

struct OathWCTonCompletion: View {
    let submission: WalletConnectTonSubmission
    let identity: OathWCIdentity
    let close: @MainActor () -> Void
    @Environment(\.oathLocalizer) private var strings
    private var checking: Bool { ["signed", "unknown"].contains(submission.state) }
    private var confirmed: Bool { submission.state == "confirmed" }
    private var failed: Bool { ["failed", "expired"].contains(submission.state) }
    var body: some View {
        OathWCResultContent(identity: identity) {
            VStack(spacing: 18) {
                Image(systemName: confirmed ? "checkmark.circle" : failed ? "exclamationmark.circle" : "clock")
                    .font(.system(size: 52)).foregroundStyle(failed ? Color.red : OathOnboardingColors.blue)
                Text(strings.text(confirmed ? .wcTransactionConfirmed : failed ? .wcTransactionFailed : checking ? .sendChecking : .wcTransactionPending))
                    .oathFont(.title2, weight: .semibold)
                Text(strings.text(confirmed ? .wcTransactionConfirmedDetail : failed ? .wcTransactionFailedDetail : checking ? .sendCheckingDetail : .wcTransactionPendingDetail))
                    .oathFont(.body).foregroundStyle(.secondary)
                Text(TonSendNetwork(walletConnectChain: submission.chain)?.walletConnectName ?? submission.chain)
                    .oathFont(.subheadline).foregroundStyle(.secondary)
            }.multilineTextAlignment(.center).frame(maxWidth: .infinity)
        }.toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                OathDoneButton(action: close).accessibilityIdentifier("walletconnect.ton.done")
            }
        }.toolbar(.hidden, for: .bottomBar)
    }
}
