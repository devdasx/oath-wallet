import SwiftUI
import OathAnkr

struct OathWCTronReview: View {
    let request: WalletConnectTronRequest
    let review: WalletConnectTronReview?
    let close: @MainActor () -> Void
    @Environment(\.oathLocalizer) private var strings
    var body: some View {
        if let message = request.message {
            OathWCMessageReview(message: display(Data(message.utf8)), signIn: nil, account: request.account,
                                network: request.network.walletConnectName, close: close)
        } else {
            VStack(spacing: 0) {
                OathSettingsRow(title: request.network.walletConnectName, accessory: .none, networkLogo: "network-tron")
                OathWCValue(title: strings.text(.scannerWCAccount), value: request.account, leftToRight: true)
                OathWCValue(title: strings.text(request.action == .approval ? .wcSpender : request.action == .contract ? .wcContractAddress : .sendRecipient), value: request.destination, leftToRight: true)
                if let review {
                    OathWCValue(title: strings.text(request.action == .approval ? .wcConfirmedLimit : .sendAmount),
                        value: (OathSendAmount.units(request.amount, decimals: review.decimals) ?? request.amount) + " " + review.symbol, leftToRight: true)
                    if request.reference != "native" {
                        OathWCValue(title: strings.text(.wcTokenContract), value: request.reference, leftToRight: true)
                    }
                    if request.action == .approval { OathSettingsFooter { Text(strings.text(.wcApprovalCallDetail)) } }
                    OathSettingsSectionRule()
                    OathWCValue(title: strings.text(.wcMaximumFee), value: (OathSendAmount.units(String(review.maximumFee), decimals: 6) ?? "—") + " TRX", leftToRight: true)
                }
                if !request.memo.isEmpty { OathWCValue(title: strings.text(.sendMemo), value: display(request.memo), leftToRight: true) }
                if !request.calldata.isEmpty {
                    NavigationLink {
                        OathWCContent {
                            Text(request.calldata.map { String(format: "%02x", $0) }.joined())
                                .font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                                .environment(\.layoutDirection, .leftToRight).padding(20)
                        }.navigationTitle(strings.text(.wcSignData)).navigationBarTitleDisplayMode(.inline)
                    } label: { OathSettingsRow(title: strings.text(.wcSignData), icon: "text.alignleft") }
                        .buttonStyle(OathSettingsRowButtonStyle())
                }
                if request.action == .contract { OathSettingsFooter { Text(strings.text(.wcCallWarning)) } }
            }
        }
    }
    private func display(_ data: Data) -> String {
        if let text = String(data: data, encoding: .utf8), !text.unicodeScalars.contains(where: {
            $0.properties.isBidiControl || ($0.value < 32 && $0.value != 10 && $0.value != 9)
        }) { return text }
        return "0x" + data.map { String(format: "%02x", $0) }.joined()
    }
}
