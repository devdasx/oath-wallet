import SwiftUI
import UIKit
import ObjectiveC
import Combine

/// Default policy for SwiftUI fields, multiline fields, search, and alert text fields.
/// Return is handled before UIKit changes the text, not by repairing a binding
/// afterward. In particular, a pasted recovery phrase may still contain spaces
/// and line breaks; pressing Return must not change that credential.
@MainActor
enum WalletTextInputReturnKey {
    private static var delegateAssociation: UInt8 = 0
    private static var inputOwnedReturnAssociation: UInt8 = 0

    /// Word-token editors explicitly own Return as part of text editing. All
    /// other inputs retain the default dismiss-only behavior.
    static func preserveInputReturnHandling(on field: UITextField) {
        objc_setAssociatedObject(field, &inputOwnedReturnAssociation, true, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    /// A screen-owned exception to the default dismiss-only policy. The native
    /// delegate holds this weakly so reused fields cannot retain a departed flow.
    @MainActor
    final class SubmitAction {
        var returnKeyType: UIReturnKeyType
        var confirmsFromKeyboardAccessory = false
        var showsKeyboardDecimalKey = false
        weak var anchor: UIView?
        weak var field: UITextField?
        var perform: (() -> Void)?

        init(returnKeyType: UIReturnKeyType) {
            self.returnKeyType = returnKeyType
        }

        func contains(_ field: UITextField) -> Bool {
            guard let anchor, let window = anchor.window, field.window === window,
                  !anchor.bounds.isEmpty else { return false }
            let center = CGPoint(x: field.bounds.midX, y: field.bounds.midY)
            return anchor.bounds.contains(field.convert(center, to: anchor))
        }
    }

    static func install(_ action: SubmitAction, on field: UITextField) {
        action.field = field
        forwardingDelegate(for: field, original: field.delegate).submitAction = action
        install(on: field)
    }

    static func install(on object: Any?) {
        guard let input = object as? UIView else { return }
        guard objc_getAssociatedObject(input, &inputOwnedReturnAssociation) as? Bool != true else { return }
        if let field = input as? UITextField {
            let delegate = forwardingDelegate(for: field, original: field.delegate)
            if field.delegate !== delegate { field.delegate = delegate }
            // Search already has a cancel control. Keep its native Search key
            // instead of turning it into the app's Done/checkmark key.
            let returnKeyType: UIReturnKeyType = field is UISearchTextField
                ? .search : (delegate.action(for: field)?.returnKeyType ?? .done)
            if field.returnKeyType != returnKeyType { field.returnKeyType = returnKeyType }
            (field.inputAccessoryView as? WalletKeyboardAccessoryView)?.updateDecimalKey()
        } else if let view = input as? UITextView {
            let delegate = forwardingDelegate(for: view, original: view.delegate)
            if view.delegate !== delegate { view.delegate = delegate }
            if view.returnKeyType != .done { view.returnKeyType = .done }
        }
    }

    static func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
        )
    }

    /// The shared checkmark dismisses by default. Notes explicitly opt into
    /// saving; a passphrase's Next/Return action must never run by accident.
    static func confirmFromKeyboardAccessory(_ input: UIView) {
        guard input.isFirstResponder else { return }
        var perform: (() -> Void)?
        if let field = input as? UITextField,
           let delegate = objc_getAssociatedObject(field, &delegateAssociation) as? ReturnKeyDelegate,
           let action = delegate.action(for: field), action.confirmsFromKeyboardAccessory {
            perform = action.perform
        }
        guard input.resignFirstResponder() else { return }
        perform?()
    }

    static func showsKeyboardDecimalKey(for field: UITextField) -> Bool {
        guard let delegate = objc_getAssociatedObject(field, &delegateAssociation) as? ReturnKeyDelegate else {
            return false
        }
        return delegate.action(for: field)?.showsKeyboardDecimalKey == true
    }

    private static func forwardingDelegate(
        for input: UIView,
        original: (any NSObjectProtocol)?
    ) -> ReturnKeyDelegate {
        let delegate: ReturnKeyDelegate
        if let installed = objc_getAssociatedObject(input, &delegateAssociation) as? ReturnKeyDelegate {
            delegate = installed
        } else {
            delegate = ReturnKeyDelegate()
            // UIKit's delegate properties are weak. The input owns the proxy,
            // while the proxy only weakly references SwiftUI's coordinator.
            objc_setAssociatedObject(input, &delegateAssociation, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        // SwiftUI can replace its coordinator when a field is reused. Refresh
        // the forwarding target without chaining proxies or retaining a screen.
        if original !== delegate {
            // A reused field can arrive with another input's proxy. Keep only
            // the underlying coordinator, never a chain of app-owned proxies.
            var target = original
            var visited: Set<ObjectIdentifier> = [ObjectIdentifier(delegate)]
            while let proxy = target as? ReturnKeyDelegate {
                guard visited.insert(ObjectIdentifier(proxy)).inserted else {
                    target = nil
                    break
                }
                target = proxy.original
            }
            delegate.original = target
        }
        return delegate
    }

    private final class ReturnKeyDelegate: NSObject, UITextFieldDelegate, UITextViewDelegate {
        weak var original: (any NSObjectProtocol)?
        weak var submitAction: SubmitAction?
        private var queriedSelectors: Set<Selector> = []

        func action(for field: UITextField) -> SubmitAction? {
            guard let submitAction, submitAction.perform != nil,
                  submitAction.contains(field) else { return nil }
            return submitAction
        }

        nonisolated override func responds(to selector: Selector!) -> Bool {
            if super.responds(to: selector) { return true }
            return MainActor.assumeIsolated { respondingTarget(for: selector) != nil }
        }

        nonisolated override func forwardingTarget(for selector: Selector!) -> Any? {
            let target = MainActor.assumeIsolated {
                ForwardingTarget(object: respondingTarget(for: selector))
            }
            return target.object ?? super.forwardingTarget(for: selector)
        }

        private func respondingTarget(for selector: Selector) -> (any NSObjectProtocol)? {
            // External delegate wrappers may ask this proxy the same question.
            // Decline only that recursive lookup; other optional callbacks must
            // still reach the coordinator. UIKit invokes these hooks on main.
            guard let original, original !== self,
                  queriedSelectors.insert(selector).inserted else { return nil }
            defer { queriedSelectors.remove(selector) }
            return original.responds(to: selector) ? original : nil
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            submitOrDismiss(textField)
            // Do not forward Return to a coordinator that saves, advances to
            // another field, navigates, or triggers an alert's default action.
            return false
        }

        func textField(
            _ textField: UITextField,
            shouldChangeCharactersIn range: NSRange,
            replacementString string: String
        ) -> Bool {
            if isReturn(string) {
                submitOrDismiss(textField)
                return false
            }
            return (original as? any UITextFieldDelegate)?.textField?(
                textField, shouldChangeCharactersIn: range, replacementString: string
            ) ?? true
        }

        func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText text: String
        ) -> Bool {
            if isReturn(text) {
                textView.resignFirstResponder()
                return false
            }
            return (original as? any UITextViewDelegate)?.textView?(
                textView, shouldChangeTextIn: range, replacementText: text
            ) ?? true
        }

        @available(iOS 26.0, *)
        func textView(
            _ textView: UITextView,
            shouldChangeTextInRanges ranges: [NSValue],
            replacementText text: String
        ) -> Bool {
            if isReturn(text) {
                textView.resignFirstResponder()
                return false
            }
            let delegate = original as? any UITextViewDelegate
            if let result = delegate?.textView?(
                textView, shouldChangeTextInRanges: ranges, replacementText: text
            ) { return result }
            // Match UIKit's documented fallback for delegates that implement
            // only the original, single-range validation method.
            guard let firstRange = ranges.first?.rangeValue else { return true }
            let range = ranges.dropFirst().reduce(firstRange) { NSUnionRange($0, $1.rangeValue) }
            return delegate?.textView?(
                textView, shouldChangeTextIn: range, replacementText: text
            ) ?? true
        }

        private func isReturn(_ replacement: String) -> Bool {
            replacement == "\n" || replacement == "\r" || replacement == "\r\n"
        }

        private func submitOrDismiss(_ field: UITextField) {
            if let action = action(for: field), let perform = action.perform {
                // Done always ends editing, including screen-owned save actions.
                // Next leaves the focus handoff to its registered callback.
                if action.returnKeyType == .done { field.resignFirstResponder() }
                perform()
            } else {
                field.resignFirstResponder()
            }
        }

        // NSObject's forwarding hook is nonisolated even though UIKit invokes
        // its input delegates on the main thread. This value never leaves that
        // synchronous call; the box bridges only Swift's isolation annotation.
        private struct ForwardingTarget: @unchecked Sendable {
            let object: (any NSObjectProtocol)?
        }
    }
}

@MainActor
enum WalletTextInputConfiguration {
    static func apply(_ layoutDirection: LayoutDirection, to object: Any?) {
        WalletTextInputLayout.apply(layoutDirection, to: object)
        WalletTextWrapping.apply(to: object)
        WalletTextInputReturnKey.install(on: object)
        WalletKeyboardAccessory.install(on: object, layoutDirection: layoutDirection)
    }
}

extension View {
    /// Install once at the app root. Editing events identify the actual native
    /// input, including toolbar search, alerts, and reused SwiftUI coordinators.
    /// No view-hierarchy traversal or layout-time delegate mutation is needed.
    func walletTextInputConfiguration(_ layoutDirection: LayoutDirection) -> some View {
        onReceive(NotificationCenter.default.publisher(for: UITextField.textDidBeginEditingNotification)
            .merge(with:
                NotificationCenter.default.publisher(for: UITextField.textDidChangeNotification),
                NotificationCenter.default.publisher(for: UITextView.textDidBeginEditingNotification),
                NotificationCenter.default.publisher(for: UITextView.textDidChangeNotification)
            )) { notification in
                WalletTextInputConfiguration.apply(layoutDirection, to: notification.object)
                if let input = notification.object as? UIView {
                    // SwiftUI may finish reconciling a field's accessory in the
                    // same turn as a focus or binding update. Reconcile once on
                    // the next turn, only if this input still owns focus.
                    DispatchQueue.main.async { [weak input] in
                        guard let input, input.isFirstResponder else { return }
                        WalletKeyboardAccessory.install(on: input, layoutDirection: layoutDirection)
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)
                .merge(with: NotificationCenter.default.publisher(for: UIResponder.keyboardDidChangeFrameNotification))) { _ in
                    WalletKeyboardAccessory.reconcileKeyboardTransition()
                }
    }
}
