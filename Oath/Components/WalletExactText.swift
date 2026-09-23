import SwiftUI
import UIKit

/// Selectable, character-wrapped identifiers. The displayed, copied, and
/// accessible text all use the original string, without synthetic separators.
struct WalletExactText: UIViewRepresentable {
    let text: String
    var textStyle: UIFont.TextStyle = .body
    var monospaced = false
    var foregroundColor: Color = WalletTheme.secondaryLabel
    var selectable = true

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.multilineTextAlignment) private var alignment
    @Environment(\.layoutDirection) private var layoutDirection
    @WalletNativeTextPrivacy private var isPrivacyObscured: Bool

    init(
        _ text: String,
        textStyle: UIFont.TextStyle = .body,
        monospaced: Bool = false,
        foregroundColor: Color = WalletTheme.secondaryLabel,
        selectable: Bool = true
    ) {
        self.text = text
        self.textStyle = textStyle
        self.monospaced = monospaced
        self.foregroundColor = foregroundColor
        self.selectable = selectable
    }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.backgroundColor = .clear
        view.isEditable = false
        view.isScrollEnabled = false
        view.textContainerInset = .zero
        view.contentInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.textContainer.lineBreakMode = .byCharWrapping
        view.textContainer.maximumNumberOfLines = 0
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(dynamicTypeSize))
        let bodyFont = UIFont.preferredFont(forTextStyle: textStyle, compatibleWith: traits)
        let font = monospaced
            ? UIFont.monospacedSystemFont(ofSize: bodyFont.pointSize, weight: .regular)
            : bodyFont
        let attributed = Self.attributedText(
            text, font: font, alignment: nativeAlignment,
            foregroundColor: UIColor(foregroundColor)
        )
        // Updating/invalidation is not a privacy mask: keep the reviewed
        // identifier readable while other state is being refreshed.
        let obscured = isPrivacyObscured
        let visibilityChanged = view.isHidden != obscured
        if visibilityChanged { view.isHidden = obscured }
        let allowsSelection = selectable && !obscured
        if view.isSelectable != allowsSelection { view.isSelectable = allowsSelection }
        view.isUserInteractionEnabled = selectable && !obscured
        // Reinstall the content when a mask changes so the native text layout
        // returns with visibility, including after an authentication cover.
        if view.attributedText != attributed || visibilityChanged {
            view.attributedText = attributed
        }
        WalletTextWrapping.apply(to: view)
        view.isAccessibilityElement = !obscured
        view.accessibilityLabel = obscured ? nil : text
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(size.height))
    }

    static func attributedText(
        _ text: String,
        font: UIFont = .preferredFont(forTextStyle: .body),
        alignment: NSTextAlignment = .natural,
        foregroundColor: UIColor = .secondaryLabel
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byCharWrapping
        return NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: foregroundColor,
            .paragraphStyle: WalletTextWrapping.paragraphStyle(from: paragraph)
        ])
    }

    private var nativeAlignment: NSTextAlignment {
        // UIKit has physical text alignment values; retain the surrounding
        // SwiftUI environment's semantic leading/trailing alignment.
        switch alignment {
        case .center: .center
        case .leading: layoutDirection == .rightToLeft ? .right : .left
        case .trailing: layoutDirection == .rightToLeft ? .left : .right
        }
    }
}
