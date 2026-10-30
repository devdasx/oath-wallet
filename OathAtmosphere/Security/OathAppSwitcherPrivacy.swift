import UIKit

/// A synchronous scene cover, installed before UIKit captures its app-switcher
/// snapshot. It blurs the real window, including any presented sheets.
@MainActor final class OathAppSwitcherPrivacy: UIView {
    private let blur = UIVisualEffectView()
    private let shade = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        accessibilityElementsHidden = true
        isUserInteractionEnabled = true
        addSubview(blur)
        blur.contentView.addSubview(shade)
        updateAppearance()
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) {
            (view: OathAppSwitcherPrivacy, _: UITraitCollection) in view.updateAppearance()
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        blur.frame = bounds
        shade.frame = bounds
    }

    func updateAppearance() {
        let opaque = UIAccessibility.isReduceTransparencyEnabled
        let dark = traitCollection.userInterfaceStyle == .dark
        blur.effect = opaque ? nil : UIBlurEffect(style: .systemUltraThinMaterial)
        blur.backgroundColor = opaque ? .systemBackground : .clear
        shade.backgroundColor = (dark ? UIColor.black : .white)
            .withAlphaComponent(UIAccessibility.isDarkerSystemColorsEnabled ? 0.36 : 0.2)
    }
}
