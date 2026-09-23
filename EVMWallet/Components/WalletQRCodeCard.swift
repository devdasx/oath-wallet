import SwiftUI

/// Layout shared by every card that shows a QR code above its title and value:
/// receive addresses, private keys, WIF and silent payment exports. Change a
/// number here and every one of those screens follows.
enum WalletQRCodeCardMetrics {
    /// Corner radius of the card surface.
    static let cornerRadius: CGFloat = 28
    /// Space between the card edge and the QR code on its top and both sides.
    static let codeInset: CGFloat = 12
    /// The QR code stops growing here; the card itself fills its container.
    static let codeMaxWidth: CGFloat = 356
    /// Space between the QR code's quiet zone and the title beneath it.
    static let titleSpacing: CGFloat = 4
    /// Space between the title, the value and the detail line.
    static let textSpacing: CGFloat = 8
    /// Horizontal inset of the text block.
    static let textInset: CGFloat = 20
    /// Space under the last line of text.
    static let bottomInset: CGFloat = 18
}

/// One surface for a QR code with its title, value and optional detail. The
/// value is the caller's view (an address, a private key) drawn in the card's
/// ink; the code, the title and every spacing are laid out here so that all
/// QR screens match.
struct WalletQRCodeCard<Value: View>: View {
    let payload: String
    let title: LocalizedStringKey
    let detail: String?
    let accessibilityLabel: LocalizedStringKey
    let codeAccessibilityIdentifier: String
    let showsBrandMark: Bool
    let cachesRenderedImage: Bool
    let animatesPayloadReplacement: Bool
    private let value: Value

    init(
        payload: String,
        title: LocalizedStringKey,
        detail: String? = nil,
        accessibilityLabel: LocalizedStringKey = "receive.qr.accessibility",
        codeAccessibilityIdentifier: String = "",
        showsBrandMark: Bool = false,
        cachesRenderedImage: Bool = true,
        animatesPayloadReplacement: Bool = false,
        @ViewBuilder value: () -> Value
    ) {
        self.payload = payload
        self.title = title
        self.detail = detail
        self.accessibilityLabel = accessibilityLabel
        self.codeAccessibilityIdentifier = codeAccessibilityIdentifier
        self.showsBrandMark = showsBrandMark
        self.cachesRenderedImage = cachesRenderedImage
        self.animatesPayloadReplacement = animatesPayloadReplacement
        self.value = value()
    }

    var body: some View {
        VStack(spacing: WalletQRCodeCardMetrics.titleSpacing) {
            code

            VStack(spacing: WalletQRCodeCardMetrics.textSpacing) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(WalletTheme.qrCodeInk.opacity(0.64))

                value

                if let detail {
                    Text(verbatim: detail)
                        .font(.footnote)
                        .foregroundStyle(WalletTheme.qrCodeInk.opacity(0.64))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, WalletQRCodeCardMetrics.textInset)
            .padding(.bottom, WalletQRCodeCardMetrics.bottomInset)
        }
        .frame(maxWidth: .infinity)
        .background(
            WalletTheme.qrCodeSurface,
            in: RoundedRectangle(
                cornerRadius: WalletQRCodeCardMetrics.cornerRadius,
                style: .continuous
            )
        )
        .overlay {
            RoundedRectangle(
                cornerRadius: WalletQRCodeCardMetrics.cornerRadius,
                style: .continuous
            )
            .stroke(WalletTheme.separator, lineWidth: 0.5)
        }
    }

    private var code: some View {
        ReceiveQRCodeImage(
            payload: payload,
            // The card owns the space around the code; the bitmap's own quiet
            // zone is the only white between the modules and the title.
            contentPadding: 0,
            accessibilityLabel: accessibilityLabel,
            showsBrandMark: showsBrandMark,
            cachesRenderedImage: cachesRenderedImage,
            animatesPayloadReplacement: animatesPayloadReplacement
        )
        .accessibilityIdentifier(codeAccessibilityIdentifier)
        .frame(maxWidth: WalletQRCodeCardMetrics.codeMaxWidth)
        .padding(.horizontal, WalletQRCodeCardMetrics.codeInset)
        .padding(.top, WalletQRCodeCardMetrics.codeInset)
    }
}
