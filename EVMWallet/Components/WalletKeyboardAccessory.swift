import SwiftUI
import UIKit
import ObjectiveC

/// One accessory for native text, secure, numeric and multiline inputs.
/// Search fields use their existing search/cancel controls without an accessory.
/// UIKit moves it with the keyboard, including interactive dismissal and iPad
/// floating keyboards. It never measures a screen-wide keyboard notification.
@MainActor
enum WalletKeyboardAccessory {
    private static var accessoryAssociation: UInt8 = 0
    private static weak var activeInput: UIView?
    private static var activeLayoutDirection = LayoutDirection.leftToRight
    private static let actionScopes = NSHashTable<WalletKeyboardActionScopeView>.weakObjects()

    static func register(_ scope: WalletKeyboardActionScopeView) {
        actionScopes.add(scope)
        reconcileKeyboardTransition()
    }

    static func unregister(_ scope: WalletKeyboardActionScopeView) {
        actionScopes.remove(scope)
        reconcileKeyboardTransition()
    }

    static func install(on object: Any?, layoutDirection: LayoutDirection) {
        guard let input = object as? UIView else { return }
        let existing: UIView?
        if let field = input as? UITextField {
            guard field.inputView == nil else { return }
            existing = field.inputAccessoryView
        } else if let view = input as? UITextView {
            guard view.inputView == nil else { return }
            existing = view.inputAccessoryView
        } else {
            return
        }
        if input.isFirstResponder {
            activeInput = input
            activeLayoutDirection = layoutDirection
        }
        if input is UISearchTextField
            || actionScopes.allObjects.contains(where: { $0.contains(input) }) {
            // Remove the accessory itself, including its measured height. Merely
            // hiding the checkmark leaves an empty strip above the keyboard.
            guard existing != nil else { return }
            if let field = input as? UITextField { field.inputAccessoryView = nil }
            if let view = input as? UITextView { view.inputAccessoryView = nil }
            if input.isFirstResponder { input.reloadInputViews() }
            return
        }
        // SwiftUI can supply an empty accessory even when no `.keyboard`
        // toolbar is declared. Adopt it too, rather than mistaking that empty
        // placeholder for an app-owned toolbar and leaving this input out.
        let accessory: WalletKeyboardAccessoryView
        if let stored = objc_getAssociatedObject(input, &accessoryAssociation) as? WalletKeyboardAccessoryView {
            accessory = stored
        } else {
            accessory = WalletKeyboardAccessoryView(input: input)
            objc_setAssociatedObject(input, &accessoryAssociation, accessory, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        accessory.semanticContentAttribute = layoutDirection == .rightToLeft
            ? .forceRightToLeft : .forceLeftToRight
        accessory.confirmButton.accessibilityLabel = WalletLocalization.string("common.done")
        accessory.overrideUserInterfaceStyle = input.traitCollection.userInterfaceStyle
        accessory.updateDecimalKey()

        guard existing !== accessory else { return }
        if let field = input as? UITextField {
            field.inputAccessoryView = accessory
        } else if let view = input as? UITextView {
            view.inputAccessoryView = accessory
        }
        if input.isFirstResponder { input.reloadInputViews() }
    }

    static func reconcileKeyboardTransition() {
        guard let input = activeInput, input.isFirstResponder, input.window != nil else { return }
        // SwiftUI can replace its empty generated accessory after a List's
        // focus/layout update. Reconcile the active input when UIKit updates
        // the keyboard too, without scanning views or polling every frame.
        install(on: input, layoutDirection: activeLayoutDirection)
    }
}

extension View {
    /// The screen already supplies a Continue/submit action above the keyboard.
    /// Keep the system keyboard, but omit the redundant dismiss accessory.
    func walletKeyboardUsesScreenAction() -> some View {
        modifier(WalletKeyboardScreenActionModifier())
    }
}

private struct WalletKeyboardScreenActionModifier: ViewModifier {
    @State private var active = false

    func body(content: Content) -> some View {
        content.background(WalletKeyboardActionScope(active: active))
            .onAppear { active = true }
            .onDisappear { active = false }
    }
}

private struct WalletKeyboardActionScope: UIViewRepresentable {
    let active: Bool

    func makeUIView(context: Context) -> WalletKeyboardActionScopeView {
        WalletKeyboardActionScopeView()
    }

    func updateUIView(_ view: WalletKeyboardActionScopeView, context: Context) {
        view.active = active
        if active { WalletKeyboardAccessory.register(view) }
        else { WalletKeyboardAccessory.unregister(view) }
    }

    static func dismantleUIView(_ view: WalletKeyboardActionScopeView, coordinator: ()) {
        view.active = false
        WalletKeyboardAccessory.unregister(view)
    }
}

/// A weak, presentation-scoped marker, not a global "hide keyboard toolbar"
/// flag. A covered form cannot remove the accessory from a presented converter,
/// alert, or another window. No button-title matching or text inspection.
@MainActor
final class WalletKeyboardActionScopeView: UIView {
    var active = false

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { nil }

    func contains(_ input: UIView) -> Bool {
        guard active, let window, input.window === window,
              let owner = Self.controller(for: self) else { return false }
        var controller = Self.controller(for: input)
        while let current = controller {
            if current === owner {
                // Scrolling a focused field outside the viewport must not
                // bring back the accessory; the policy belongs to the screen.
                return true
            }
            controller = current.parent
        }
        return false
    }

    private static func controller(for view: UIView) -> UIViewController? {
        var responder: UIResponder? = view
        while let current = responder {
            if let controller = current as? UIViewController { return controller }
            responder = current.next
        }
        return nil
    }
}

/// The gap is part of the accessory's measured height, not padding applied to
/// a button inside SwiftUI's system-sized `.keyboard` toolbar slot.
@MainActor
final class WalletKeyboardAccessoryView: UIInputView {
    static let buttonSize: CGFloat = 44
    static let topSpacing: CGFloat = 8
    static let keyboardSpacing: CGFloat = 12
    static let horizontalSpacing: CGFloat = 16
    static let accessoryHeight = topSpacing + buttonSize + keyboardSpacing

    let confirmButton = UIButton(type: .system)
    let decimalButton = UIButton(type: .system)
    private weak var input: UIView?

    init(input: UIView) {
        self.input = input
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: Self.accessoryHeight),
                   inputViewStyle: .default)
        allowsSelfSizing = true
        autoresizingMask = [.flexibleWidth]
        backgroundColor = .clear
        isOpaque = false
        accessibilityIdentifier = "walletKeyboardAccessory"

        confirmButton.configuration = WalletNativeKeyboardButtonStyle.configuration()
        confirmButton.accessibilityIdentifier = "walletKeyboardConfirm"
        confirmButton.accessibilityLabel = WalletLocalization.string("common.done")
        confirmButton.translatesAutoresizingMaskIntoConstraints = false
        confirmButton.addTarget(self, action: #selector(confirm), for: .touchUpInside)
        addSubview(confirmButton)
        decimalButton.configuration = WalletNativeKeyboardButtonStyle.configuration(isConfirmation: false)
        decimalButton.accessibilityIdentifier = "walletKeyboardDecimal"
        decimalButton.translatesAutoresizingMaskIntoConstraints = false
        decimalButton.addTarget(self, action: #selector(insertDecimal), for: .touchUpInside)
        addSubview(decimalButton)
        updateDecimalKey()
        NSLayoutConstraint.activate([
            confirmButton.widthAnchor.constraint(equalToConstant: Self.buttonSize),
            confirmButton.heightAnchor.constraint(equalToConstant: Self.buttonSize),
            confirmButton.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor,
                                                     constant: -Self.horizontalSpacing),
            confirmButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.keyboardSpacing),
            decimalButton.widthAnchor.constraint(equalToConstant: Self.buttonSize),
            decimalButton.heightAnchor.constraint(equalToConstant: Self.buttonSize),
            decimalButton.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor,
                                                     constant: Self.horizontalSpacing),
            decimalButton.bottomAnchor.constraint(equalTo: confirmButton.bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: Self.accessoryHeight)
    }

    override func systemLayoutSizeFitting(_ targetSize: CGSize) -> CGSize {
        CGSize(width: targetSize.width, height: Self.accessoryHeight)
    }

    override func systemLayoutSizeFitting(
        _ targetSize: CGSize,
        withHorizontalFittingPriority horizontalFittingPriority: UILayoutPriority,
        verticalFittingPriority: UILayoutPriority
    ) -> CGSize {
        CGSize(width: targetSize.width, height: Self.accessoryHeight)
    }

    @objc private func confirm() {
        guard let input, input.isFirstResponder else { return }
        UniHaptic.play(.commit)
        WalletTextInputReturnKey.confirmFromKeyboardAccessory(input)
    }

    func updateDecimalKey() {
        guard let field = input as? UITextField else {
            decimalButton.isHidden = true
            return
        }
        decimalButton.isHidden = !WalletTextInputReturnKey.showsKeyboardDecimalKey(for: field)
        guard !decimalButton.isHidden else { return }
        decimalButton.isEnabled = !(field.text ?? "").contains(".")
    }

    @objc private func insertDecimal() {
        guard let field = input as? UITextField, field.isFirstResponder,
              WalletTextInputReturnKey.showsKeyboardDecimalKey(for: field),
              !(field.text ?? "").contains(".") else { return }
        UniHaptic.play(.tap)
        field.insertText((field.text ?? "").isEmpty ? "0." : ".")
        updateDecimalKey()
    }
}
