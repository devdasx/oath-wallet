import SwiftUI
import OathAnkr

struct OathWCPolkadotReview: View {
    let request: WalletConnectPolkadotRequest
    let review: PolkadotConnectReview?
    let close: @MainActor () -> Void
    @Environment(\.oathLocalizer) private var strings
    var body: some View {
        if let message = request.message {
            OathWCMessageReview(message: display(message), signIn:nil, account:request.account,
                                network:request.network.name, close:close)
        } else if let review {
            VStack(spacing:0) {
                OathSettingsRow(title:request.network.name, accessory:.none, networkLogo:"network-polkadot")
                OathWCValue(title:strings.text(.scannerWCAccount), value:request.account, leftToRight:true)
                OathWCValue(title:strings.text(.wcSignTransaction), value:review.callName, leftToRight:true)
                if let recipient = review.recipient {
                    OathWCValue(title:strings.text(.sendRecipient), value:recipient, leftToRight:true)
                }
                if let amount = review.nativeAmount {
                    OathWCValue(title:strings.text(.sendAmount), value:units(amount), leftToRight:true)
                }
                OathSettingsSectionRule()
                OathWCValue(title:strings.text(.wcMaximumFee), value:units(review.fee), leftToRight:true)
                NavigationLink {
                    OathWCContent {
                        Text(review.details).font(.system(.footnote,design:.monospaced))
                            .textSelection(.enabled).environment(\.layoutDirection,.leftToRight).padding(20)
                    }.navigationTitle(strings.text(.wcSignData)).navigationBarTitleDisplayMode(.inline)
                } label: { OathSettingsRow(title:strings.text(.wcSignData),icon:"text.alignleft") }
                    .buttonStyle(OathSettingsRowButtonStyle())
                if review.nativeAmount == nil { OathSettingsFooter { Text(strings.text(.wcCallWarning)) } }
            }
        }
    }
    private func units(_ amount: String) -> String {
        (OathSendAmount.units(amount,decimals:request.network.decimals) ?? amount) + " " + request.network.symbol
    }
    private func display(_ data: Data) -> String {
        if let text = String(data:data,encoding:.utf8), !text.unicodeScalars.contains(where:{
            $0.properties.isBidiControl || ($0.value < 32 && $0.value != 10 && $0.value != 9)
        }) { return text }
        return "0x" + data.map { String(format:"%02x",$0) }.joined()
    }
}
