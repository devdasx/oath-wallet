import SwiftUI
import UIKit

/// One circular keypad for setup, confirmation and authentication. UIKit owns
/// the native glass, touch tracking, highlighting and press motion.
public struct OathNumericKeypad: UIViewRepresentable {
    @Environment(\.oathLocalizer) private var strings
    public enum Key: Equatable, Sendable { case digit(Int), delete, biometrics }
    public enum Biometrics: Equatable, Sendable { case faceID, touchID }

    private let enabled: Bool
    private let deleteEnabled: Bool
    private let biometrics: Biometrics?
    private let onKey: (Key) -> Void

    public init(isEnabled: Bool = true, isDeleteEnabled: Bool,
                biometrics: Biometrics? = nil,
                onKey: @escaping (Key) -> Void) {
        enabled = isEnabled
        deleteEnabled = isDeleteEnabled
        self.biometrics = biometrics
        self.onKey = onKey
    }

    public func makeUIView(context: Context) -> OathKeypadView { OathKeypadView() }

    public func updateUIView(_ view: OathKeypadView, context: Context) {
        view.configure(enabled: enabled, deleteEnabled: deleteEnabled, biometrics: biometrics,
                       strings: strings, action: onKey)
    }
}

public final class OathKeypadView: UIView {
    private var keys: [OathKeypadButton] = []
    private var action: ((OathNumericKeypad.Key) -> Void)?
    private var acceptsInput = false

    public init() {
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        semanticContentAttribute = .forceLeftToRight
        isAccessibilityElement = false
        for digit in 1...9 { addKey(.digit(digit)) }
        addKey(.biometrics)
        addKey(.digit(0))
        addKey(.delete)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init()") }

    public override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric,
               height: OathKeypadGeometry.circularSize(diameter: OathKeypadGeometry.circularDiameter).height)
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        for (index, key) in keys.enumerated() {
            key.frame = OathKeypadGeometry.circularFrame(row: index / 3, column: index % 3, size: bounds.size)
        }
    }

    fileprivate func configure(enabled: Bool, deleteEnabled: Bool,
                               biometrics: OathNumericKeypad.Biometrics?,
                               strings: OathLocalizer,
                               action: @escaping (OathNumericKeypad.Key) -> Void) {
        self.action = action
        acceptsInput = enabled
        // Face ID and verification temporarily block interaction, not the
        // keypad's appearance. Keep unavailable actions semantically disabled
        // for accessibility without applying UIButton's gray disabled style.
        isUserInteractionEnabled = enabled
        for key in keys {
            key.localize(strings)
            let available = key.key != .delete || deleteEnabled
            key.setEnabled(available)
            if enabled && available { key.accessibilityTraits.remove(.notEnabled) }
            else { key.accessibilityTraits.insert(.notEnabled) }
            if key.key == .biometrics {
                key.isHidden = biometrics == nil
                key.setBiometricSymbol(biometrics == .faceID ? "faceid" : "touchid")
                key.accessibilityLabel = strings.format(.useBiometrics,
                    strings.invariant(biometrics == .faceID ? "Face ID" : "Touch ID"))
            }
        }
        setNeedsLayout()
    }

    private func addKey(_ value: OathNumericKeypad.Key) {
        let key = OathKeypadButton(key: value)
        // One native primary action supports touch, VoiceOver and keyboard
        // activation. A cancelled press never enters a digit.
        key.addTarget(self, action: #selector(activate(_:)), for: .primaryActionTriggered)
        addSubview(key)
        keys.append(key)
    }

    @objc private func activate(_ sender: OathKeypadButton) {
        guard acceptsInput, sender.isEnabled else { return }
        OathHaptics.shared.play(.input)
        action?(sender.key)
    }
}

private final class OathKeypadButton: UIButton {
    let key: OathNumericKeypad.Key
    private var language = OathLanguage.english
    private var localizedNumber: String?
    private var biometricSymbol = "faceid"
    private var configuredWidth: CGFloat = -1
    private var presentationNeedsUpdate = true

    init(key: OathNumericKeypad.Key) {
        self.key = key
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        isAccessibilityElement = true
        semanticContentAttribute = .forceLeftToRight
        switch key {
        case .digit(let digit):
            localizedNumber = String(digit)
            accessibilityLabel = String(digit)
            accessibilityIdentifier = "keypad.digit.\(digit)"
        case .delete:
            accessibilityIdentifier = "keypad.delete"
        case .biometrics:
            accessibilityIdentifier = "keypad.biometrics"
        }
        configurePresentationIfNeeded()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(key:)") }

    func setEnabled(_ enabled: Bool) {
        if isEnabled != enabled { isEnabled = enabled }
    }

    override func layoutSubviews() {
        configurePresentationIfNeeded()
        super.layoutSubviews()
    }

    func setBiometricSymbol(_ name: String) {
        guard biometricSymbol != name else { return }
        biometricSymbol = name
        invalidatePresentation()
    }

    func localize(_ strings: OathLocalizer) {
        let languageChanged = language != strings.language
        language = strings.language
        accessibilityLanguage = strings.language.rawValue
        switch key {
        case .digit(let digit):
            let number = strings.number(digit)
            if localizedNumber != number {
                localizedNumber = number
                invalidatePresentation()
            }
            accessibilityLabel = number
            // Numeric positions and Latin T9 legends stay invariant, as on iOS.
        case .delete: accessibilityLabel = strings.text(.deleteDigit)
        case .biometrics: break
        }
        if languageChanged { invalidatePresentation() }
    }

    private func invalidatePresentation() {
        presentationNeedsUpdate = true
        setNeedsLayout()
    }

    private func configurePresentationIfNeeded() {
        // SwiftUI updates this representable after each digit. Replacing the
        // configuration then would interrupt UIKit's press/release animation.
        // Only actual content/geometry changes rebuild the presentation.
        guard presentationNeedsUpdate || configuredWidth != bounds.width else { return }
        presentationNeedsUpdate = false
        configuredWidth = bounds.width
        var config: UIButton.Configuration = .plain()
        if case .digit = key {
            if #available(iOS 26.0, *) {
                config = .clearGlass()
            } else {
                config.background.visualEffect = UIBlurEffect(style: .systemThinMaterial)
            }
            config.cornerStyle = .capsule
        }
        config.baseForegroundColor = .label
        config.contentInsets = .zero
        config.titleAlignment = .center
        contentHorizontalAlignment = .center
        contentVerticalAlignment = .center

        switch key {
        case .digit(let digit):
            let size = bounds.width > 0 ? bounds.width : OathKeypadGeometry.circularDiameter
            let numberSize = size * 0.46
            let numberFont = language == .arabic
                ? UIFont(name: OathArabicFont.regular.rawValue, size: numberSize) ?? .systemFont(ofSize: numberSize)
                : .systemFont(ofSize: numberSize, weight: .regular)
            let lettersSize = size * 0.13
            config.attributedTitle = AttributedString(localizedNumber ?? String(digit),
                attributes: AttributeContainer([.font: numberFont]))
            let legend = OathKeypadGeometry.letters[digit]
            if !legend.isEmpty {
                config.attributedSubtitle = AttributedString(legend, attributes: AttributeContainer([
                    .font: UIFont.systemFont(ofSize: lettersSize, weight: .semibold),
                    .kern: 2
                ]))
            }
            config.titlePadding = -1
        case .delete, .biometrics:
            config.image = key == .delete
                ? UIImage(systemName: "delete.left")
                : UIImage(systemName: biometricSymbol)
            config.preferredSymbolConfigurationForImage = .init(pointSize: 26, weight: .regular)
        }
        configuration = config
    }
}
