import Combine
import SwiftUI
import UIKit

extension View {
    /// Opts a particular native input into a screen-owned Return action without
    /// changing the keyboard policy of other fields or scanning view hierarchies.
    func walletTextInputSubmitAction(
        identifier: String,
        returnKeyType: UIReturnKeyType,
        confirmsFromKeyboardAccessory: Bool = false,
        showsKeyboardDecimalKey: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        modifier(WalletTextInputSubmitModifier(
            identifier: identifier, returnKeyType: returnKeyType,
            confirmsFromKeyboardAccessory: confirmsFromKeyboardAccessory,
            showsKeyboardDecimalKey: showsKeyboardDecimalKey, action: action
        ))
    }
}

private struct WalletTextInputSubmitModifier: ViewModifier {
    let identifier: String
    let returnKeyType: UIReturnKeyType
    let confirmsFromKeyboardAccessory: Bool
    let showsKeyboardDecimalKey: Bool
    let action: () -> Void
    @State private var registration: WalletTextInputReturnKey.SubmitAction

    init(identifier: String, returnKeyType: UIReturnKeyType,
         confirmsFromKeyboardAccessory: Bool, showsKeyboardDecimalKey: Bool, action: @escaping () -> Void) {
        self.identifier = identifier
        self.returnKeyType = returnKeyType
        self.confirmsFromKeyboardAccessory = confirmsFromKeyboardAccessory
        self.showsKeyboardDecimalKey = showsKeyboardDecimalKey
        self.action = action
        _registration = State(initialValue: WalletTextInputReturnKey.SubmitAction(
            returnKeyType: returnKeyType
        ))
    }

    func body(content: Content) -> some View {
        content
            .accessibilityIdentifier(identifier)
            .multilineTextAlignment(WalletTextInputLayout.alignment)
            .submitLabel(returnKeyType == .next ? .next : .done)
            .onSubmit(action)
            .submitScope()
            .background(WalletTextInputSubmitAnchor(
                registration: registration, returnKeyType: returnKeyType,
                confirmsFromKeyboardAccessory: confirmsFromKeyboardAccessory,
                showsKeyboardDecimalKey: showsKeyboardDecimalKey, action: action
            ))
            .onReceive(NotificationCenter.default.publisher(for: UITextField.textDidBeginEditingNotification)
                .merge(with: NotificationCenter.default.publisher(for: UITextField.textDidChangeNotification))) { notification in
                    guard let field = notification.object as? UITextField,
                          registration.contains(field) else { return }
                    registration.perform = action
                    WalletTextInputReturnKey.install(registration, on: field)
                }
            .onDisappear { registration.perform = nil }
    }
}

/// SwiftUI's accessibility identifier belongs to its accessibility element, not
/// necessarily the UITextField. Match the editing notification to this field's
/// own bounds; no search of other views or access to their text is needed.
private struct WalletTextInputSubmitAnchor: UIViewRepresentable {
    let registration: WalletTextInputReturnKey.SubmitAction
    let returnKeyType: UIReturnKeyType
    let confirmsFromKeyboardAccessory: Bool
    let showsKeyboardDecimalKey: Bool
    let action: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        registration.anchor = view
        registration.perform = action
        registration.confirmsFromKeyboardAccessory = confirmsFromKeyboardAccessory
        registration.showsKeyboardDecimalKey = showsKeyboardDecimalKey
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        registration.anchor = view
        registration.perform = action
        registration.returnKeyType = returnKeyType
        registration.confirmsFromKeyboardAccessory = confirmsFromKeyboardAccessory
        registration.showsKeyboardDecimalKey = showsKeyboardDecimalKey
        if let field = registration.field, registration.contains(field) {
            let previousReturnKeyType = field.returnKeyType
            WalletTextInputReturnKey.install(on: field)
            if field.isFirstResponder, field.returnKeyType != previousReturnKeyType {
                field.reloadInputViews()
            }
        }
    }
}
