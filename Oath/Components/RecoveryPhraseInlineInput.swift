import SwiftUI
import UIKit

/// A native word input. Reconcile tokenized text synchronously with
/// UIKit so committing a word cannot leave it in the keyboard's editing buffer.
struct RecoveryPhraseInlineInput: UIViewRepresentable {
    let text: String
    var isInvalid = false
    let completion: (String) -> RecoveryPhraseCompletion?
    let hasOtherWords: Bool
    let isFocused: Bool
    let selectionRequest: UUID?
    let onFocusChange: (Bool) -> Void
    let onChange: (String) -> String
    let onDeleteBackward: (Bool) -> String?
    /// Commits the word and returns whether the full phrase permits dismissal.
    let onSubmit: (String?) -> Bool

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @WalletNativeTextPrivacy private var isPrivacyObscured: Bool
    @Environment(\.revealRecoveryPhraseInput) private var revealInput

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    static func dismantleUIView(_ field: WordTextField, coordinator: Coordinator) {
        field.text = ""
        field.undoManager?.removeAllActions()
        field.delegate = nil
        field.wantsFocus = false
        field.hasOtherWords = false
        field.onDeleteBackward = nil
        field.onInsertSpace = nil
        field.completion = nil
        field.accessibilityCustomActions = nil
        field.revealInput = nil
        field.removeTarget(coordinator, action: nil, for: .allEvents)
        field.resignFirstResponder()
    }

    func makeUIView(context: Context) -> WordTextField {
        let field = WordTextField()
        WalletTextInputReturnKey.preserveInputReturnHandling(on: field)
        field.text = ""
        field.borderStyle = .none
        // SwiftUI owns the capsule so its contour animates with the layout.
        field.backgroundColor = .clear
        field.writingToolsBehavior = .none
        field.autocorrectionType = .no
        field.inlinePredictionType = .no
        field.spellCheckingType = .no
        field.autocapitalizationType = .none
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.returnKeyType = .done
        field.delegate = context.coordinator
        field.onDeleteBackward = { [weak coordinator = context.coordinator] selected in
            coordinator?.parent.onDeleteBackward(selected)
        }
        field.onInsertSpace = { [weak coordinator = context.coordinator, weak field] in
            guard let field else { return false }
            return coordinator?.acceptSpaceCompletion(field) ?? false
        }
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        field.accessibilityIdentifier = "recoveryPhraseInlineInput"
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateUIView(_ field: WordTextField, context: Context) {
        context.coordinator.parent = self
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(dynamicTypeSize))
        field.font = .preferredFont(forTextStyle: .title3, compatibleWith: traits)
        field.textColor = UIColor(isInvalid ? WalletTheme.danger : WalletTheme.primaryLabel)
        field.tintColor = UIColor(WalletTheme.accent)
        field.accessibilityLabel = String(localized: "import.credential.recovery.title")
        field.isHidden = isPrivacyObscured
        field.hasOtherWords = hasOtherWords
        // Never replace an active marked range while an IME is composing a word.
        if field.markedTextRange == nil && field.text != text { field.text = text }
        field.selectionRequest = selectionRequest
        field.revealInput = revealInput
        field.wantsFocus = isFocused && !isPrivacyObscured
        field.reconcileFocus()
        context.coordinator.refreshCompletion(field)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: WordTextField, context: Context) -> CGSize? {
        let font = uiView.font ?? .preferredFont(forTextStyle: .title3)
        let height = max(44, ceil(font.lineHeight) + 16)
        // Match the pills' 12-point side padding, plus room for the caret.
        // An empty field is one compact capsule, then grows with the word.
        let preview = text + (isFocused ? completion(text)?.suffix ?? "" : "")
        let naturalWidth = ceil(preview.size(withAttributes: [.font: font]).width) + 28
        return CGSize(width: min(max(height, naturalWidth), proposal.width ?? .greatestFiniteMagnitude),
                      height: height)
    }

    final class WordTextField: UITextField {
        private static let deletionBoundary = "\u{200B}"

        // The keyboard needs a position before the active word to keep Delete
        // repeating across token boundaries. This is native input context only;
        // the public text, draft and accessibility value never include it.
        override var text: String? {
            get {
                let value = super.text ?? ""
                return value.hasPrefix(Self.deletionBoundary) ? String(value.dropFirst()) : value
            }
            set { super.text = Self.deletionBoundary + (newValue ?? "") }
        }

        override var accessibilityValue: String? {
            get { text }
            set { super.accessibilityValue = newValue }
        }

        override var selectedTextRange: UITextRange? {
            get { super.selectedTextRange }
            set {
                guard let range = newValue,
                      (super.text ?? "").hasPrefix(Self.deletionBoundary),
                      offset(from: beginningOfDocument, to: range.start) == 0 else {
                    super.selectedTextRange = newValue
                    return
                }
                let end = offset(from: beginningOfDocument, to: range.end) == 0 ? wordStart : range.end
                super.selectedTextRange = textRange(from: wordStart, to: end)
            }
        }

        override func selectAll(_ sender: Any?) {
            selectedTextRange = textRange(from: wordStart, to: endOfDocument)
        }

        override func copy(_ sender: Any?) {
            // Normalize system selections too, so the keyboard-only boundary
            // can never enter copied recovery material.
            selectedTextRange = super.selectedTextRange
            super.copy(sender)
        }

        override func cut(_ sender: Any?) {
            selectedTextRange = super.selectedTextRange
            super.cut(sender)
        }

        var wordStart: UITextPosition {
            position(from: beginningOfDocument, offset: 1) ?? beginningOfDocument
        }

        func restoreDeletionBoundary() {
            guard !(super.text ?? "").hasPrefix(Self.deletionBoundary) else { return }
            let selection = selectedTextRange.map {
                (offset(from: beginningOfDocument, to: $0.start), offset(from: beginningOfDocument, to: $0.end))
            }
            text = super.text
            if let selection,
               let start = position(from: beginningOfDocument, offset: selection.0 + 1),
               let end = position(from: beginningOfDocument, offset: selection.1 + 1) {
                selectedTextRange = textRange(from: start, to: end)
            }
        }

        var hasOtherWords = false
        var wantsFocus = false
        var updatingFocus = false
        var selectionRequest: UUID?
        var onDeleteBackward: ((Bool) -> String?)?
        var onInsertSpace: (() -> Bool)?
        var revealInput: RecoveryPhraseRevealAction?
        var completion: RecoveryPhraseCompletion?
        var completionSource = ""
        private(set) var displayedCompletion: RecoveryPhraseCompletion?
        private let completionLabel = UILabel()
        private var appliedSelectionRequest: UUID?
        private var focusUpdateScheduled = false
        private var visibilityUpdateScheduled = false
        private var requestedVisibility: VisibilityRequest?

        override init(frame: CGRect) {
            super.init(frame: frame)
            // Mnemonic entry is LTR even when the app or keyboard language is RTL.
            semanticContentAttribute = .forceLeftToRight
            textAlignment = .left
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .left
            paragraph.baseWritingDirection = .leftToRight
            defaultTextAttributes[.paragraphStyle] = paragraph
            completionLabel.semanticContentAttribute = .forceLeftToRight
            completionLabel.textAlignment = .left
            completionLabel.isUserInteractionEnabled = false
            completionLabel.isAccessibilityElement = false
            completionLabel.accessibilityIdentifier = "recoveryPhraseInlineCompletion"
            completionLabel.lineBreakMode = .byClipping
            completionLabel.isHidden = true
            addSubview(completionLabel)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        private struct VisibilityRequest: Equatable {
            let inputRect: CGRect
            let viewportHeight: CGFloat
            let anchor: UnitPoint
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            updateCompletionPresentation()
            requestVisibilityUpdate()
        }

        func updateCompletionPresentation() {
            displayedCompletion = nil
            completionLabel.isHidden = true
            guard isFirstResponder, !isHidden, markedTextRange == nil,
                  text == completionSource, !completionSource.isEmpty,
                  let selection = selectedTextRange, selection.isEmpty,
                  offset(from: selection.end, to: endOfDocument) == 0,
                  let completion, let font else { return }
            // UITextInput geometry belongs to textInputView, which UIKit can
            // inset inside the field. The preview is our direct subview, so
            // convert the caret before aligning its ending to the typed word.
            let caret = convert(caretRect(for: endOfDocument), from: textInputView)
            let suffixWidth = ceil(completion.suffix.size(withAttributes: [.font: font]).width)
            // Match the input's explicit LTR paragraph direction.
            let x = caret.minX
            let frame = CGRect(x: x, y: caret.midY - font.lineHeight / 2,
                               width: suffixWidth, height: font.lineHeight)
            // Never offer an ending the user cannot see (e.g. while the input
            // is constrained during rotation or a growing-width animation).
            guard frame.minX >= 10, frame.maxX <= bounds.width - 10 else { return }
            completionLabel.font = font
            completionLabel.textColor = UIColor(WalletTheme.secondaryLabel)
            completionLabel.text = completion.suffix
            completionLabel.frame = frame
            completionLabel.isHidden = false
            bringSubviewToFront(completionLabel)
            displayedCompletion = completion
        }

        override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            requestVisibilityUpdate()
        }

        override func setBaseWritingDirection(_ writingDirection: NSWritingDirection, for range: UITextRange) {
            // App-wide editing notifications reapply the app language. This
            // field owns the recovery-only exception, including reused edits.
            super.setBaseWritingDirection(.leftToRight, for: range)
        }

        override func textRect(forBounds bounds: CGRect) -> CGRect {
            bounds.insetBy(dx: 12, dy: 8)
        }

        override func editingRect(forBounds bounds: CGRect) -> CGRect { textRect(forBounds: bounds) }

        // Completed pills are also text in this input's backing store. Keep
        // native Delete available when the current word buffer is empty.
        override var hasText: Bool { !(text ?? "").isEmpty || hasOtherWords }

        override func insertText(_ text: String) {
            // UITextInput insertion can bypass UITextFieldDelegate (including
            // keyboard input paths). Handle the separator at both boundaries.
            if text == " ", onInsertSpace?() == true { return }
            super.insertText(text)
        }

        override func deleteBackward() {
            guard markedTextRange == nil else {
                super.deleteBackward()
                return
            }
            let hasFragment = !(text ?? "").isEmpty
            let selectsWholeWord = hasFragment && selectedTextRange.map {
                offset(from: beginningOfDocument, to: $0.start) <= 1
                    && offset(from: $0.end, to: endOfDocument) == 0
            } == true
            if !hasFragment || selectsWholeWord, let canonical = onDeleteBackward?(selectsWholeWord) {
                text = canonical
                selectedTextRange = textRange(from: wordStart, to: endOfDocument)
            } else if hasFragment {
                super.deleteBackward()
            }
            updateCompletionPresentation()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            reconcileFocus()
        }

        func reconcileFocus() {
            guard window != nil, !focusUpdateScheduled else { return }
            focusUpdateScheduled = true
            // UIKit focus can invalidate SwiftUI layout. Reconcile on the next
            // main-queue turn, outside updateUIView, using the latest request.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.focusUpdateScheduled = false
                guard self.window != nil else { return }
                self.updatingFocus = true
                if self.isFirstResponder != self.wantsFocus {
                    if self.wantsFocus { self.becomeFirstResponder() } else { self.resignFirstResponder() }
                }
                if self.isFirstResponder, self.markedTextRange == nil,
                   let request = self.selectionRequest, request != self.appliedSelectionRequest {
                    self.selectedTextRange = self.textRange(from: self.wordStart, to: self.endOfDocument)
                    self.appliedSelectionRequest = request
                }
                self.updatingFocus = false
                self.updateCompletionPresentation()
                self.requestVisibilityUpdate()
            }
        }

        private func requestVisibilityUpdate() {
            guard window != nil, !visibilityUpdateScheduled else { return }
            visibilityUpdateScheduled = true
            // Measure after SwiftUI has placed the growing capsule and updated
            // the scroll view's keyboard / bottom-bar insets, outside layout.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.visibilityUpdateScheduled = false
                self.revealInScrollViewIfNeeded()
            }
        }

        private func revealInScrollViewIfNeeded() {
            guard isFirstResponder, wantsFocus, !isHidden, window != nil else {
                requestedVisibility = nil
                return
            }
            var ancestor = superview
            while let view = ancestor, !(view is UIScrollView) { ancestor = view.superview }
            guard let scroll = ancestor as? UIScrollView else { return }
            guard !scroll.isTracking, !scroll.isDragging, !scroll.isDecelerating else {
                requestedVisibility = nil
                return
            }
            let insets = scroll.adjustedContentInset
            let visibleTop = scroll.contentOffset.y + insets.top
            let visibleBottom = scroll.contentOffset.y + scroll.bounds.height - insets.bottom
            guard visibleBottom > visibleTop else { return }
            let rect = convert(bounds, to: scroll)
            let anchor: UnitPoint
            if rect.maxY > visibleBottom + 0.5 {
                anchor = .bottom
            } else if rect.height <= visibleBottom - visibleTop, rect.minY < visibleTop - 0.5 {
                anchor = .top
            } else {
                requestedVisibility = nil
                return
            }
            let request = VisibilityRequest(
                inputRect: rect, viewportHeight: visibleBottom - visibleTop, anchor: anchor
            )
            guard requestedVisibility != request else { return }
            requestedVisibility = request
            // The scroll view belongs to SwiftUI. Its proxy keeps scroll state
            // synchronized with the animated word layout and safe-area bar.
            revealInput?(anchor)
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: RecoveryPhraseInlineInput
        init(parent: RecoveryPhraseInlineInput) { self.parent = parent }

        @objc func changed(_ field: UITextField) {
            guard field.markedTextRange == nil else { return }
            (field as? WordTextField)?.restoreDeletionBoundary()
            let canonical = parent.onChange(field.text ?? "")
            if field.text != canonical {
                field.text = canonical
                field.selectedTextRange = field.textRange(from: field.endOfDocument, to: field.endOfDocument)
            }
            if let field = field as? WordTextField { refreshCompletion(field) }
        }

        func refreshCompletion(_ field: WordTextField) {
            field.completionSource = field.text ?? ""
            field.completion = parent.completion(field.text ?? "")
            field.updateCompletionPresentation()
            field.setNeedsLayout()
            // Keep the actual accessibility value as typed. VoiceOver offers
            // the preview as a separate, explicit action instead.
            if let completion = field.completion {
                field.accessibilityCustomActions = [UIAccessibilityCustomAction(
                    name: EnglishNumbers.localized("import.recovery.completion.accept", completion.word)
                ) { [weak self, weak field] _ in
                    guard let self, let field, field.isFirstResponder,
                          field.markedTextRange == nil,
                          field.text == field.completionSource,
                          let selection = field.selectedTextRange, selection.isEmpty,
                          field.offset(from: selection.end, to: field.endOfDocument) == 0,
                          field.completion == completion else { return false }
                    _ = self.submit(field, completion: completion.word)
                    return true
                }]
            } else {
                field.accessibilityCustomActions = nil
            }
        }

        func textFieldDidChangeSelection(_ textField: UITextField) {
            (textField as? WordTextField)?.updateCompletionPresentation()
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            guard (textField as? WordTextField)?.updatingFocus != true else { return }
            (textField as? WordTextField)?.wantsFocus = true
            parent.onFocusChange(true)
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            guard (textField as? WordTextField)?.updatingFocus != true else { return }
            (textField as? WordTextField)?.wantsFocus = false
            parent.onFocusChange(false)
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            guard textField.markedTextRange == nil else { return false }
            changed(textField)
            let completion = (textField as? WordTextField)?.displayedCompletion?.word
            return submit(textField, completion: completion)
        }

        private func submit(_ textField: UITextField, completion: String?) -> Bool {
            let shouldDismiss = parent.onSubmit(completion)
            (textField as? WordTextField)?.wantsFocus = !shouldDismiss
            if shouldDismiss { textField.resignFirstResponder() }
            // Committing a word clears the native buffer synchronously so a
            // subsequent keystroke starts the next token, even before redraw.
            // End editing first: UIKit can reconcile the prior editing buffer
            // while resigning, which would otherwise restore the committed word.
            textField.text = ""
            textField.selectedTextRange = textField.textRange(from: textField.endOfDocument, to: textField.endOfDocument)
            if let field = textField as? WordTextField { refreshCompletion(field) }
            return false
        }

        func textField(
            _ textField: UITextField,
            shouldChangeCharactersIn range: NSRange,
            replacementString string: String
        ) -> Bool {
            if string == "\n" || string == "\r" || string == "\r\n" {
                return textFieldShouldReturn(textField)
            }
            if string == " ", range.length == 0,
               range.location == (textField.text ?? "").utf16.count + 1,
               let field = textField as? WordTextField,
               field.markedTextRange == nil {
                if acceptSpaceCompletion(field) { return false }
            }
            return true
        }

        func acceptSpaceCompletion(_ field: WordTextField) -> Bool {
            field.updateCompletionPresentation()
            guard let completion = field.displayedCompletion else { return false }
            // Use the normal tokenizer to preserve focus, edit position, and
            // the owning draft's callback while clearing UIKit synchronously.
            field.text = completion.word + " "
            changed(field)
            return true
        }
    }
}
