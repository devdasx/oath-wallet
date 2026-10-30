import SwiftUI
import UIKit

/// A native single-line field with the same keyboard accessory as recovery
/// import and password forms. Search opts out of the accessory. UIKit owns
/// selection, IME and keyboard.
struct OathTextInput: UIViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    let title: String
    let identifier: String
    var prominent = false
    var secret = false
    var showsSecretVisibility = true
    var address = false
    var showsKeyboardAccessory = true
    var returnKeyType: UIReturnKeyType = .done
    var onSubmit: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> Field {
        let field = Field()
        field.delegate = context.coordinator
        field.inputAccessoryView = showsKeyboardAccessory ? context.coordinator.accessory : nil
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.returnKeyType = .done
        field.adjustsFontForContentSizeCategory = true
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.addTarget(context.coordinator, action: #selector(Coordinator.edited), for: .editingChanged)
        return field
    }

    func updateUIView(_ field: Field, context: Context) {
        context.coordinator.parent = self
        context.coordinator.accessory.updateAppearance(context.environment.colorScheme == .dark ? .dark : .light)
        context.coordinator.focus.update(focused: focused, enabled: context.environment.isEnabled)
        // Editing and keyboard geometry updates must not reconfigure native
        // input traits, fonts, placeholders and visibility controls. UIKit can
        // invalidate text layout and keyboard state even for equal assignments.
        let configuration = Configuration(language: context.environment.oathLanguage,
            dynamicType: context.environment.dynamicTypeSize,
            contentSize: field.traitCollection.preferredContentSizeCategory,
            title: title, identifier: identifier, prominent: prominent, secret: secret,
            showsSecretVisibility: showsSecretVisibility, address: address, returnKey: returnKeyType)
        if context.coordinator.configuration != configuration {
            context.coordinator.configuration = configuration
            let language = context.environment.oathLanguage
            let style: UIFont.TextStyle = prominent ? .largeTitle : .body
            field.font = language == .arabic
                ? (prominent ? OathArabicFont.semibold : .regular).uiFont(size: prominent ? 34 : 17, relativeTo: style)
                : UIFontMetrics(forTextStyle: style).scaledFont(for: .systemFont(ofSize: prominent ? 34 : 17,
                                                                               weight: prominent ? .semibold : .regular))
            field.textColor = prominent ? .white : .label
            field.keyboardType = secret || address ? .asciiCapable : .default
            field.returnKeyType = returnKeyType
            field.smartQuotesType = .no
            field.smartDashesType = .no
            field.smartInsertDeleteType = .no
            if secret { field.font = UIFont.preferredFont(forTextStyle: .body) }
            field.tintColor = prominent ? .white : .tintColor
            field.textAlignment = prominent ? .center : .natural
            field.autocapitalizationType = prominent ? .words : .none
            field.semanticContentAttribute = secret || address ? .forceLeftToRight : (language.isRightToLeft ? .forceRightToLeft : .forceLeftToRight)
            if secret || address { field.textAlignment = .left }
            context.coordinator.accessory.toolbar.semanticContentAttribute = language.isRightToLeft ? .forceRightToLeft : .forceLeftToRight
            field.attributedPlaceholder = NSAttributedString(string: title, attributes: [.foregroundColor: prominent ? UIColor.white.withAlphaComponent(0.7) : UIColor.placeholderText])
            field.accessibilityLabel = title
            field.accessibilityIdentifier = identifier
            field.configureVisibility(sensitive: secret, showsControl: showsSecretVisibility, rightToLeft: language.isRightToLeft,
                showLabel: context.environment.oathLocalizer.text(.showPrivateKey),
                hideLabel: context.environment.oathLocalizer.text(.hidePrivateKey), identifier: identifier)
        }
        if field.isEnabled != context.environment.isEnabled { field.isEnabled = context.environment.isEnabled }
        let accessory: UIView? = showsKeyboardAccessory ? context.coordinator.accessory : nil
        if field.inputAccessoryView !== accessory {
            field.inputAccessoryView = accessory
            if field.isFirstResponder { field.reloadInputViews() }
        }
        // Preserve live composition unless the model explicitly clears the
        // field. Clear must also discard marked text and the old undo buffer.
        if field.text != text, field.markedTextRange == nil || text.isEmpty {
            if text.isEmpty {
                field.unmarkText()
                field.undoManager?.removeAllActions()
            }
            field.text = text
        }
        context.coordinator.accessory.toolbar.update(words: [], doneLabel: context.environment.oathLocalizer.text(.done),
            onWord: { _ in }, onDone: { [weak coordinator = context.coordinator] in coordinator?.dismissFocus() })
        field.setFocus(focused && field.isEnabled)
        if !field.isEnabled { context.coordinator.reportFocus(false, from: field) }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: Field, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite else { return nil }
        return CGSize(width: width, height: max(OathInputMetrics.minimumContentHeight,
                                                uiView.intrinsicContentSize.height + (prominent ? 12 : 0)))
    }
    static func dismantleUIView(_ field: Field, coordinator: Coordinator) {
        coordinator.focus.invalidate()
        field.delegate = nil
        field.setFocus(false)
        field.resignFirstResponder()
        field.conceal()
        if coordinator.parent.secret { field.text = nil }
        field.inputAccessoryView = nil
        coordinator.accessory.toolbar.clear()
    }

    fileprivate struct Configuration: Equatable {
        let language: OathLanguage
        let dynamicType: DynamicTypeSize
        let contentSize: UIContentSizeCategory
        let title: String
        let identifier: String
        let prominent: Bool
        let secret: Bool
        let showsSecretVisibility: Bool
        let address: Bool
        let returnKey: UIReturnKeyType
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        fileprivate var configuration: Configuration?
        var parent: OathTextInput
        let accessory = OathKeyboardAccessory()
        let focus = OathTextInputFocus()
        init(_ parent: OathTextInput) { self.parent = parent }
        @objc func edited(_ field: UITextField) {
            guard (field as? OathEntryTextField)?.isUpdatingVisibility != true else { return }
            parent.text = field.text ?? ""
        }
        func textFieldDidBeginEditing(_ textField: UITextField) { reportFocus(true, from: textField) }
        func textFieldDidEndEditing(_ textField: UITextField) { reportFocus(false, from: textField) }
        func reportFocus(_ focused: Bool, from field: UITextField) {
            focus.receive(focused) { [weak self, weak field] value in
                guard let self, let field, field.delegate === self,
                      field.isFirstResponder == value, self.parent.focused != value else { return }
                self.parent.focused = value
            }
        }
        func dismissFocus() {
            focus.cancelPending()
            if parent.focused { parent.focused = false }
        }
        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            dismissFocus()
            parent.onSubmit()
            return false
        }
        func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
            guard parent.secret, let current = textField.text else { return true }
            return (current as NSString).replacingCharacters(in: range, with: string).utf8.count <= 2_048
        }
    }

    final class Field: OathEntryTextField {
        private var wantsFocus = false
        private var scheduled = false
        func setFocus(_ wanted: Bool) {
            guard wanted != wantsFocus else { return }
            wantsFocus = wanted
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
                } else if !self.wantsFocus, self.isFirstResponder { self.resignFirstResponder() }
            }
        }
    }
}
