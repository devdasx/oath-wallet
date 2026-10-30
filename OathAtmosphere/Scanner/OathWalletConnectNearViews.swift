import SwiftUI
import OathAnkr
import OathDatabase

struct OathWCNearReview: View {
    let request:WalletConnectNearRequest
    let review:WalletConnectNearReview
    @Environment(\.oathLocalizer) private var strings
    var body:some View {
        VStack(spacing:0) {
            OathSettingsRow(title:request.network.walletConnectName,accessory:.none,networkLogo:"network-near")
            OathWCValue(title:strings.text(.scannerWCAccount),value:request.account,leftToRight:true)
            OathWCValue(title:strings.text(.wcMaximumFee),value:(OathSendAmount.units(review.fee,decimals:24) ?? "—") + " NEAR",leftToRight:true)
            ForEach(Array(review.transactions.enumerated()),id:\.offset) { index, tx in
                Divider()
                OathWCValue(title:strings.text(.sendRecipient),value:tx.receiver,leftToRight:true)
                ForEach(Array(tx.actions.enumerated()),id:\.offset) { _, action in
                    Text(actionText(action)).oathFont(.body).textSelection(.enabled)
                        .frame(maxWidth:.infinity,alignment:.leading).padding(20)
                }
            }
            OathSettingsFooter { Text(strings.text(.wcCallWarning)) }
        }.environment(\.layoutDirection,.leftToRight)
    }
    private func actionText(_ action:WalletConnectNearTransaction.Action) -> String {
        var value = action.description.components(separatedBy:"\n").map { line in
            guard ["Transfer ","Stake ","Deposit: ","Gas allowance (yoctoNEAR): "].contains(where:line.hasPrefix),
                  let amount = line.split(separator:" ").first(where:{!$0.isEmpty && $0.allSatisfy(\.isNumber)}),
                  let units = OathSendAmount.units(String(amount),decimals:24) else { return line }
            return line.replacingOccurrences(of:String(amount),with:units).replacingOccurrences(of:"yoctoNEAR",with:"NEAR")
        }.joined(separator:"\n")
        if let range = value.range(of:"Arguments (base64): "),
           let data = Data(base64Encoded:String(value[range.upperBound...])), let text = String(data:data,encoding:.utf8),
           !text.unicodeScalars.contains(where:{$0.properties.isBidiControl || ($0.value < 32 && $0.value != 10 && $0.value != 9 && $0.value != 13)}) {
            value = String(value[..<range.lowerBound]) + "Arguments: " + text
        }
        return value
    }
}

struct OathWCNearCompletion: View {
    let submission: WalletConnectNearSubmission
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
                Text(NearSendNetwork(walletConnectChain: submission.chain)?.walletConnectName ?? submission.chain)
                    .oathFont(.subheadline).foregroundStyle(.secondary)
            }.multilineTextAlignment(.center).frame(maxWidth: .infinity)
        }.toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                OathDoneButton(action: close).accessibilityIdentifier("walletconnect.near.done")
            }
        }.toolbar(.hidden, for: .bottomBar)
    }
}
