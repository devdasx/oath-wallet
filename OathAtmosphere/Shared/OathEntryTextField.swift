import UIKit

/// One native field owns the text, selection and keyboard while the eye changes
/// visibility. Replacing a SecureField with a TextField loses that editing state.
@MainActor
class OathEntryTextField: UITextField {
    private let visibilityButton = VisibilityButton(type: .system)
    private var sensitive = false
    private(set) var isSecretVisible = false
    private(set) var isUpdatingVisibility = false
    private var showLabel = ""
    private var hideLabel = ""

    override init(frame: CGRect) {
        super.init(frame: frame)
        visibilityButton.frame.size = CGSize(width: 44, height: 44)
        visibilityButton.tintColor = .secondaryLabel
        visibilityButton.setPreferredSymbolConfiguration(
            UIImage.SymbolConfiguration(pointSize: 19, weight: .regular), forImageIn: .normal)
        visibilityButton.addTarget(self, action: #selector(toggleVisibility), for: .touchUpInside)
        addTarget(self, action: #selector(editingEnded), for: .editingDidEnd)
        NotificationCenter.default.addObserver(self, selector: #selector(deactivated),
            name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(deactivated),
            name: UIScene.willDeactivateNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override var isEnabled: Bool {
        didSet {
            visibilityButton.isEnabled = isEnabled
            if !isEnabled { conceal() }
        }
    }

    func configureVisibility(sensitive: Bool, showsControl: Bool = true, rightToLeft: Bool,
                             showLabel: String, hideLabel: String, identifier: String) {
        self.showLabel = showLabel
        self.hideLabel = hideLabel
        visibilityButton.accessibilityIdentifier = identifier + ".visibility"
        visibilityButton.accessibilityHint = accessibilityLabel
        if self.sensitive != sensitive {
            self.sensitive = sensitive
            isSecretVisible = false
            isSecureTextEntry = sensitive
        }
        if !showsControl { conceal() }
        // Password/key content can stay LTR while the control follows the app.
        // UIKit mirrors leftView/rightView when the field itself is RTL. A
        // private-key field stays LTR, so only that case needs the left overlay.
        let mirrored = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let left = sensitive && showsControl && (rightToLeft != mirrored)
        let right = sensitive && showsControl && !left
        if leftView !== (left ? visibilityButton : nil) || rightView !== (right ? visibilityButton : nil) {
            leftView = nil
            rightView = nil
            if left { leftView = visibilityButton }
            if right { rightView = visibilityButton }
        }
        leftViewMode = left ? .always : .never
        rightViewMode = right ? .always : .never
        updateVisibilityButton()
    }

    @objc private func toggleVisibility() {
        guard sensitive, isEnabled else { return }
        OathHaptics.shared.play(.selection)
        setVisible(!isSecretVisible)
    }

    func conceal() {
        guard sensitive, isSecretVisible else { return }
        setVisible(false)
    }

    private func setVisible(_ visible: Bool) {
        let value = text ?? ""
        let selection = selectedTextRange.map {
            (offset(from: beginningOfDocument, to: $0.start), offset(from: beginningOfDocument, to: $0.end))
        }
        isUpdatingVisibility = true
        defer { isUpdatingVisibility = false }
        isSecretVisible = visible
        isSecureTextEntry = !visible
        // A simple `text = value` leaves UIKit's clear-on-next-insertion flag
        // armed when re-hiding a password. Reinsert through the native editing
        // buffer, suppressing only this programmatic editingChanged feedback.
        text = nil
        insertText(value)
        if let selection,
           let start = position(from: beginningOfDocument, offset: selection.0),
           let end = position(from: beginningOfDocument, offset: selection.1) {
            selectedTextRange = textRange(from: start, to: end)
        }
        updateVisibilityButton()
    }

    private func updateVisibilityButton() {
        visibilityButton.setImage(UIImage(systemName: isSecretVisible ? "eye.slash" : "eye"), for: .normal)
        visibilityButton.accessibilityLabel = isSecretVisible ? hideLabel : showLabel
    }

    @objc private func editingEnded() { conceal() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { conceal() }
    }

    @objc nonisolated private func deactivated() {
        // UIKit posts lifecycle events on main. Keep the selector safe even if
        // a caller posts from another queue; never enter an isolated ObjC thunk.
        if Thread.isMainThread {
            MainActor.assumeIsolated { conceal() }
        } else {
            Task { @MainActor [weak self] in self?.conceal() }
        }
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    private final class VisibilityButton: UIButton {
        override var intrinsicContentSize: CGSize { minimumTarget(super.intrinsicContentSize) }
        override func sizeThatFits(_ size: CGSize) -> CGSize { minimumTarget(super.sizeThatFits(size)) }
        private func minimumTarget(_ size: CGSize) -> CGSize {
            CGSize(width: max(44, size.width), height: max(44, size.height))
        }
    }
}
