import SwiftUI
import UIKit

struct ReceiveDetailsContent: View {
    let token: ReceiveToken
    let variant: ReceiveTokenVariant
    let walletAddress: String
    let database: WalletDatabase

    var body: some View {
        ReceiveSelectionDetailsScreen(
            token: token,
            variant: variant,
            walletAddress: walletAddress,
            database: database
        )
    }
}

/// A selectable address label that preserves the exact address while asking
/// TextKit to wrap at characters. This avoids iOS inserting visual hyphens at
/// automatic line breaks in long cryptocurrency addresses.
struct ReceiveAddressText: UIViewRepresentable {
    @WalletNativeTextPrivacy private var isPrivacyObscured: Bool
    enum Typography {
        case body
        case monospacedBody
    }

    let address: String
    let typography: Typography
    let alignment: NSTextAlignment
    let foregroundColor: UIColor

    init(
        _ address: String,
        typography: Typography = .body,
        alignment: NSTextAlignment = .center,
        foregroundColor: UIColor = .secondaryLabel
    ) {
        self.address = address
        self.typography = typography
        self.alignment = alignment
        self.foregroundColor = foregroundColor
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.adjustsFontForContentSizeCategory = true
        textView.textContainerInset = .zero
        textView.contentInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainer.lineBreakMode = .byCharWrapping
        textView.textContainer.maximumNumberOfLines = 0
        textView.textContainer.widthTracksTextView = true
        textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textView.setContentCompressionResistancePriority(
            .required,
            for: .vertical
        )
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        let obscured = isPrivacyObscured
        textView.isHidden = obscured
        if textView.isSelectable != !obscured { textView.isSelectable = !obscured }
        textView.isUserInteractionEnabled = !obscured
        textView.attributedText = Self.attributedAddress(
            address,
            typography: typography,
            alignment: alignment,
            foregroundColor: foregroundColor
        )
        WalletTextWrapping.apply(to: textView)
        textView.isAccessibilityElement = !obscured
        textView.accessibilityLabel = obscured ? nil : WalletLocalization.string(
            "receive.details.address.section"
        )
        textView.accessibilityValue = obscured ? nil : address
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: UITextView,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width,
              width.isFinite,
              width > 0 else {
            return nil
        }
        let fittingSize = uiView.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude)
        )
        return CGSize(width: width, height: ceil(fittingSize.height))
    }

    static func attributedAddress(
        _ address: String,
        typography: Typography = .body,
        alignment: NSTextAlignment = .center,
        foregroundColor: UIColor = .secondaryLabel
    ) -> NSAttributedString {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = alignment
        paragraphStyle.lineBreakMode = .byCharWrapping

        let preferredBodyFont = UIFontMetrics(forTextStyle: .body).scaledFont(
            for: UIFont.systemFont(ofSize: 19)
        )
        let font: UIFont
        switch typography {
        case .body:
            font = preferredBodyFont
        case .monospacedBody:
            font = UIFont.monospacedSystemFont(
                ofSize: preferredBodyFont.pointSize,
                weight: .regular
            )
        }

        return NSAttributedString(
            string: address,
            attributes: [
                .font: font,
                .foregroundColor: foregroundColor,
                .paragraphStyle: WalletTextWrapping.paragraphStyle(from: paragraphStyle)
            ]
        )
    }
}

struct SolanaReceivePathMenu: View {
    let availableKinds: [SolanaDerivationKind]
    @Binding var selectedKind: SolanaDerivationKind

    var body: some View {
        Menu {
            Picker(
                "receive.solana.path.title",
                selection: $selectedKind
            ) {
                ForEach(availableKinds) { kind in
                    Text(LocalizedStringKey(kind.localizedNameKey))
                        .tag(kind)
                }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .accessibilityLabel(Text("receive.solana.path.title"))
        .accessibilityValue(
            Text(LocalizedStringKey(selectedKind.localizedNameKey))
        )
        .accessibilityIdentifier("solanaReceiveDerivationPathMenu")
    }
}

extension View {
    func receiveAddressReplacementTransition(
        identity: String,
        reduceMotion: Bool
    ) -> some View {
        id(identity)
            .transition(
                reduceMotion
                    ? .identity
                    : AnyTransition(.blurReplace)
            )
    }
}
