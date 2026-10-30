import SwiftUI
import OathAnkr
import OathDatabase

struct OathWCSuiReview: View {
    let request:WalletConnectSuiRequest
    let review:WalletConnectSuiReview?
    let close:@MainActor () -> Void
    @Environment(\.oathLocalizer) private var strings
    var body:some View {
        if let message = request.message {
            OathWCMessageReview(message:messageText(message),signIn:nil,account:request.account,network:request.network.walletConnectName,close:close)
        } else if let review {
            VStack(spacing:0) {
                OathSettingsRow(title:request.network.walletConnectName,accessory:.none,networkLogo:"network-sui")
                OathWCValue(title:strings.text(.scannerWCAccount),value:request.account,leftToRight:true)
                OathWCValue(title:strings.text(.wcMaximumFee),value:(OathSendAmount.units(String(review.gasBudget),decimals:9) ?? "—") + " SUI",leftToRight:true)
                if review.gasOwner != request.account {
                    OathWCValue(title:strings.text(.wcSolanaFeePayer),value:review.gasOwner,leftToRight:true)
                }
                ForEach(Array(review.changes.enumerated()),id:\.offset) { _, change in
                    Text(changeText(change,review:review)).oathFont(.body).textSelection(.enabled)
                        .frame(maxWidth:.infinity,alignment:.leading).padding(20)
                }
                NavigationLink {
                    OathWCContent {
                        ForEach(Array(review.details.enumerated()),id:\.offset) { _, detail in
                            Text(detail).font(.system(.footnote,design:.monospaced)).textSelection(.enabled)
                                .frame(maxWidth:.infinity,alignment:.leading).padding(20)
                        }
                    }.navigationTitle(strings.text(.wcSignData)).navigationBarTitleDisplayMode(.inline)
                } label: { OathSettingsRow(title:strings.text(.wcSignData),icon:"text.alignleft") }
                    .buttonStyle(OathSettingsRowButtonStyle())
                OathSettingsFooter { Text(strings.text(.wcCallWarning)) }
            }.environment(\.layoutDirection,.leftToRight)
        }
    }
    private func changeText(_ row:String,review:WalletConnectSuiReview) -> String {
        let lines = row.components(separatedBy:"\n")
        guard lines.count == 2, let range = lines[1].range(of:" atomic ") else { return row }
        let amount = String(lines[1][..<range.lowerBound]), type = String(lines[1][range.upperBound...])
        guard let reference = try? SuiIdentity.reference(type), let token = review.tokens[reference] else { return row }
        let negative = amount.hasPrefix("-")
        let magnitude = negative ? String(amount.dropFirst()) : amount
        guard let units = OathSendAmount.units(magnitude,decimals:token.decimals) else { return row }
        return (negative ? "−" : "+") + units + " " + token.symbol + "\n" + lines[0]
    }
    private func messageText(_ data:Data) -> String {
        if let text = String(data:data,encoding:.utf8), !text.unicodeScalars.contains(where: {
            $0.properties.isBidiControl || ($0.value < 32 && $0.value != 10 && $0.value != 9)
        }) { return text }
        return "0x" + data.map { String(format:"%02x",$0) }.joined()
    }
}
struct OathWCSuiCompletion: View {
    let submission: WalletConnectSuiSubmission
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
                Text(SuiSendNetwork(walletConnectChain: submission.chain)?.walletConnectName ?? submission.chain)
                    .oathFont(.subheadline).foregroundStyle(.secondary)
            }.multilineTextAlignment(.center).frame(maxWidth: .infinity)
        }.toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                OathDoneButton(action: close).accessibilityIdentifier("walletconnect.sui.done")
            }
        }.toolbar(.hidden, for: .bottomBar)
    }
}
