import SwiftUI
import UIKit

/// Receive presentation of `WalletQRCodeCard`: the exact destination
/// address directly beneath its QR code, with the address change animated.
struct ReceiveQRCodeAddressCard: View {
    let address: String
    let payload: String
    let showsBrandMark: Bool
    let animatesPayloadReplacement: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        address: String,
        payload: String,
        showsBrandMark: Bool = true,
        animatesPayloadReplacement: Bool = false
    ) {
        self.address = address
        self.payload = payload
        self.showsBrandMark = showsBrandMark
        self.animatesPayloadReplacement = animatesPayloadReplacement
    }

    var body: some View {
        WalletQRCodeCard(
            payload: payload,
            title: "receive.details.address.section",
            showsBrandMark: showsBrandMark,
            animatesPayloadReplacement: animatesPayloadReplacement
        ) {
            ReceiveAddressText(
                address,
                foregroundColor: UIColor(WalletTheme.qrCodeInk)
            )
            .frame(maxWidth: .infinity)
            .receiveAddressReplacementTransition(
                identity: address,
                reduceMotion:
                    reduceMotion || !animatesPayloadReplacement
            )
        }
        .animation(
            reduceMotion || !animatesPayloadReplacement
                ? nil
                : .smooth(duration: 0.28),
            value: address
        )
    }
}
