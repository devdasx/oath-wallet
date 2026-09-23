import SwiftUI
import UIKit

/// Uses one measurement for both the word's ideal width and its wrapped height.
/// A word stays on one line whenever it fits; unusually long words wrap by
/// character, without inserting hyphens into recovery material.
struct RecoveryPhraseWordLabel: UIViewRepresentable {
    let word: String
    var isInvalid = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @WalletNativeTextPrivacy private var isPrivacyObscured: Bool

    func makeUIView(context: Context) -> UILabel {
        let label = UILabel()
        label.numberOfLines = 0
        label.lineBreakMode = .byCharWrapping
        label.isAccessibilityElement = false // The numbered pill owns the label.
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        return label
    }

    func updateUIView(_ label: UILabel, context: Context) {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(dynamicTypeSize))
        label.font = .preferredFont(forTextStyle: .title3, compatibleWith: traits)
        label.text = word
        label.textColor = UIColor(isInvalid ? WalletTheme.danger : WalletTheme.primaryLabel)
        label.isHidden = isPrivacyObscured
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UILabel, context: Context) -> CGSize? {
        let ideal = uiView.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude,
                                             height: CGFloat.greatestFiniteMagnitude))
        let width = min(ceil(ideal.width), proposal.width ?? ceil(ideal.width))
        let fitted = uiView.sizeThatFits(CGSize(width: max(1, width), height: CGFloat.greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(fitted.height))
    }
}
