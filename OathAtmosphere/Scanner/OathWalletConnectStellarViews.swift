import SwiftUI
import OathAnkr
import OathDatabase

struct OathWCStellarCompletion: View {
    let submission: WalletConnectStellarSubmission
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
                Text(StellarSendNetwork(walletConnectChain: submission.chain)?.walletConnectName ?? submission.chain)
                    .oathFont(.subheadline).foregroundStyle(.secondary)
            }.multilineTextAlignment(.center).frame(maxWidth: .infinity)
        }.toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                OathDoneButton(action: close).accessibilityIdentifier("walletconnect.stellar.done")
            }
        }.toolbar(.hidden, for: .bottomBar)
    }
}

struct OathWCStellarReview: View {
    let request: WalletConnectStellarRequest
    let review: WalletConnectStellarReview
    @Environment(\.oathLocalizer) private var strings
    @Environment(\.layoutDirection) private var layoutDirection
    var body: some View {
        VStack(spacing: 0) {
            OathSettingsRow(title: request.network.walletConnectName, accessory: .none, networkLogo: "network-stellar")
            OathWCValue(title: strings.text(.scannerWCAccount), value: request.account, leftToRight: true)
            if review.details.source != request.account {
                OathWCValue(title: strings.text(.transactionFrom), value: review.details.source, leftToRight: true)
                OathWCValue(title: strings.text(.wcSolanaFeePayer), value: review.details.feePayer, leftToRight: true)
            }
            OathWCValue(title: strings.text(.wcMaximumFee), value: (OathSendAmount.units(String(review.details.fee), decimals: 7) ?? "—") + " XLM", leftToRight: true)
            ForEach(Array(review.details.operations.enumerated()), id: \.offset) { _, operation in
                Divider()
                detailsText(operation).oathFont(.body)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(20)
            }
            if review.details.memo != "\"none\"" {
                detailsText(review.details.memo).oathFont(.body).padding(20)
            }
            DisclosureGroup {
                detailsText(review.details.transaction).oathFont(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } label: { Text(strings.text(.wcTransactionData)) }.padding(20)
        }
    }
    private func detailsText(_ json: String) -> some View {
        let content = readable(json)
        return Text(content.text).textSelection(.enabled)
            .environment(\.layoutDirection, content.localized ? layoutDirection : .leftToRight)
    }
    private func readable(_ json: String) -> (text: String, localized: Bool) {
        guard let data = json.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) else { return (json, false) }
        if let operation = value as? [String: Any], let body = operation["body"] as? [String: Any],
           let payment = body["payment"] as? [String: Any], let amount = payment["amount"] as? String,
           let destination = payment["destination"] as? String {
            var asset: String?
            var issuer: String?
            if payment["asset"] as? String == "native" { asset = "XLM" }
            else if let issued = payment["asset"] as? [String: Any],
                    let credit = (issued["credit_alphanum4"] ?? issued["credit_alphanum12"]) as? [String: Any] {
                asset = credit["asset_code"] as? String
                issuer = credit["issuer"] as? String
            }
            if let asset {
                var lines = [strings.invariant((OathSendAmount.units(amount, decimals: 7) ?? amount) + " " + asset),
                             strings.text(.transactionTo) + ": " + strings.invariant(destination)]
                if let source = operation["source_account"] as? String {
                    lines.append(strings.text(.transactionFrom) + ": " + strings.invariant(source))
                }
                if let issuer { lines.append(strings.text(.multisigStellarIssuer) + ": " + strings.invariant(issuer)) }
                return (lines.joined(separator: "\n"), true)
            }
        }
        guard JSONSerialization.isValidJSONObject(value), let pretty = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: pretty, encoding: .utf8) else { return (json, false) }
        // Preserve copyable JSON bytes; only the text view has fixed direction.
        return (text, false)
    }
}
