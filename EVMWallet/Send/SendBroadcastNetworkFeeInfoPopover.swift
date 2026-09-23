import SwiftUI

struct SendBroadcastNetworkFeeInfoPopover: View {
    @ScaledMetric(relativeTo: .body) private var preferredHeight: CGFloat = 220

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("send.broadcast.network_fee.info.title")
                    .font(WalletTypography.sheetTitle)
                    .accessibilityAddTraits(.isHeader)
                Text("send.broadcast.network_fee.info.message")
            }
            .font(.body)
            .fixedSize(horizontal: false, vertical: true)
            .padding(20)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(
            idealWidth: 320,
            maxWidth: 360,
            idealHeight: min(preferredHeight, 440),
            maxHeight: 440
        )
        .walletLocalePresentation()
    }
}
