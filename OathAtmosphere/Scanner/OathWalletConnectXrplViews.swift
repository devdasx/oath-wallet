import SwiftUI
import OathAnkr
import OathDatabase

struct OathWCXrplCompletion: View {
    let submission: WalletConnectXrplSubmission
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
                Text(XrplSendNetwork(walletConnectChain: submission.chain)?.walletConnectName ?? submission.chain)
                    .oathFont(.subheadline).foregroundStyle(.secondary)
            }.multilineTextAlignment(.center).frame(maxWidth: .infinity)
        }.toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                OathDoneButton(action: close).accessibilityIdentifier("walletconnect.xrpl.done")
            }
        }.toolbar(.hidden, for: .bottomBar)
    }
}

struct OathWCXrplReview: View {
    let request: WalletConnectXrplRequest
    let review: WalletConnectXrplReview
    @Environment(\.oathLocalizer) private var strings
    var body: some View {
        VStack(spacing: 0) {
            OathSettingsRow(title: request.network.walletConnectName, accessory: .none, networkLogo: "network-xrpl")
            OathWCValue(title: strings.text(.scannerWCAccount), value: request.account, leftToRight: true)
            OathWCValue(title: strings.text(.transactionFrom), value: review.transaction["Account"].string ?? "—", leftToRight: true)
            if let destination = review.transaction["Destination"].string {
                OathWCValue(title: strings.text(.transactionTo), value: destination, leftToRight: true)
            }
            if let amount = review.transaction["Amount"].string {
                OathWCValue(title: strings.text(.sendAmount), value: (OathSendAmount.units(amount, decimals: 6) ?? amount) + " XRP", leftToRight: true)
            } else if let amount = review.transaction["Amount"]["value"].string {
                OathWCValue(title: strings.text(.sendAmount), value: amount + " " + (review.transaction["Amount"]["currency"].string ?? ""), leftToRight: true)
                OathWCValue(title: strings.text(.multisigXrplIssuer), value: review.transaction["Amount"]["issuer"].string ?? "—", leftToRight: true)
            }
            if let tag = review.transaction["DestinationTag"].integer {
                OathWCValue(title: strings.text(.sendDestinationTag), value: String(tag), leftToRight: true)
            }
            ForEach(Array((review.transaction["Memos"].array ?? []).enumerated()), id: \.offset) { _, item in
                if let hex = item["Memo"]["MemoData"].string {
                    OathWCValue(title: strings.text(.sendMemo), value: memoText(hex), leftToRight: true)
                }
            }
            OathWCValue(title: strings.text(.wcMaximumFee), value: (OathSendAmount.units(String(review.fee), decimals: 6) ?? "—") + " XRP", leftToRight: true)
            Divider()
            Text(review.transaction["TransactionType"].string ?? "").oathFont(.title2, weight: .semibold).padding(20)
            Text(transactionText).oathFont(.body).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(20)
        }.environment(\.layoutDirection, .leftToRight)
    }
    private func memoText(_ hex: String) -> String {
        // Non-text memos retain their exact hex representation.
        guard let data = try? TronIdentity.hex(hex), let text = String(data: data, encoding: .utf8),
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return hex }
        return text
    }
    private var transactionText: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(review.transaction)).flatMap { String(data: $0, encoding: .utf8) } ?? "—"
    }
}
