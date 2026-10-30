import SwiftUI
import UIKit

/// UITextField lets Return stay in the form when validation fails. SwiftUI's
/// SecureField ends editing on Return before its onSubmit callback can veto it.
struct OathSecureInput: UIViewRepresentable {
    @Binding var text: String
    let title: String
    let identifier: String
    let returnKey: UIReturnKeyType
    let wantsFocus: Bool
    let resignsFocus: Bool
    let onFocus: () -> Void
    let onDismissKeyboard: () -> Void
    let onSubmit: () -> Void
    var minimumPasswordLength: Int? = 8
    var isExistingPassword = false

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> Field {
        let field = Field()
        if isExistingPassword {
            field.textContentType = .password
        } else if let minimumPasswordLength {
            field.textContentType = .newPassword
            field.passwordRules = UITextInputPasswordRules(descriptor: "minlength: \(minimumPasswordLength);")
        }
        field.smartInsertDeleteType = .no
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.textColor = .label
        field.adjustsFontForContentSizeCategory = true
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.inputAccessoryView = context.coordinator.accessory
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.edited), for: .editingChanged)
        return field
    }
    func updateUIView(_ field: Field, context: Context) {
        context.coordinator.parent = self
        context.coordinator.accessory.updateAppearance(context.environment.colorScheme == .dark ? .dark : .light)
        context.coordinator.accessory.toolbar.update(words: [], doneLabel: context.environment.oathLocalizer.text(.done),
            onWord: { _ in }, onDone: { [weak coordinator = context.coordinator] in coordinator?.parent.onDismissKeyboard() })
        let language = context.environment.oathLanguage
        field.font = language == .arabic
            ? OathArabicFont.regular.uiFont(size: 17, relativeTo: .body)
            : .preferredFont(forTextStyle: .body)
        field.semanticContentAttribute = language.isRightToLeft ? .forceRightToLeft : .forceLeftToRight
        context.coordinator.accessory.toolbar.semanticContentAttribute = field.semanticContentAttribute
        field.textAlignment = .natural
        field.placeholder = title
        field.accessibilityLabel = title
        field.accessibilityIdentifier = identifier
        field.configureVisibility(sensitive: true, rightToLeft: language.isRightToLeft,
            showLabel: context.environment.oathLocalizer.text(.showPassword),
            hideLabel: context.environment.oathLocalizer.text(.hidePassword), identifier: identifier)
        field.returnKeyType = returnKey
        field.isEnabled = context.environment.isEnabled
        if field.markedTextRange == nil, field.text != text { field.text = text }
        field.setFocus(wanted: wantsFocus, resign: resignsFocus)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: Field, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite else { return nil }
        return CGSize(width: width, height: max(OathInputMetrics.minimumContentHeight, uiView.intrinsicContentSize.height))
    }
    static func dismantleUIView(_ field: Field, coordinator: Coordinator) {
        coordinator.accessory.toolbar.clear()
        field.inputAccessoryView = nil
        field.delegate = nil
        field.setFocus(wanted: false, resign: true)
        field.resignFirstResponder()
        field.conceal()
        field.text = nil
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: OathSecureInput
        let accessory = OathKeyboardAccessory()
        init(_ parent: OathSecureInput) { self.parent = parent }
        @objc func edited(_ field: UITextField) {
            guard (field as? OathEntryTextField)?.isUpdatingVisibility != true else { return }
            parent.text = field.text ?? ""
        }
        func textFieldDidBeginEditing(_ textField: UITextField) { parent.onFocus() }
        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            parent.onSubmit()
            // Focus moves directly to confirmation, or stays on invalid input.
            // A valid submit dismisses the keyboard through the shared gate.
            return false
        }
    }

    final class Field: OathEntryTextField {
        private var wantsFocus = false
        private var resignsFocus = false
        private var scheduled = false
        func setFocus(wanted: Bool, resign: Bool) {
            guard wanted != wantsFocus || resign != resignsFocus else { return }
            wantsFocus = wanted; resignsFocus = resign
            synchronizeFocus()
        }
        override func didMoveToWindow() { super.didMoveToWindow(); synchronizeFocus() }
        private func synchronizeFocus() {
            guard !scheduled else { return }
            scheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scheduled = false
                guard self.window != nil else { return }
                if self.wantsFocus, !self.isFirstResponder {
                    self.inputAccessoryView?.frame.size.width = self.window?.bounds.width ?? self.bounds.width
                    self.inputAccessoryView?.sizeToFit()
                    self.becomeFirstResponder()
                }
                else if self.resignsFocus, self.isFirstResponder { self.resignFirstResponder() }
            }
        }
    }
}
