import SwiftUI
import UIKit

/// Multiline native input with a real keyboard accessory toolbar. UITextView
/// supplies cursor/selection and IME behavior on every supported iOS version.
@MainActor struct OathMnemonicTextInput: UIViewRepresentable {
    static let contentPadding: CGFloat = 16
    @Bindable var draft: OathRecoveryPhraseDraft
    @Binding var isFocused: Bool
    let strings: OathLocalizer

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> InputView {
        let view = InputView()
        view.delegate = context.coordinator
        // The enclosing field owns the fill, including its inline action area.
        view.backgroundColor = .clear
        view.isScrollEnabled = false
        view.textContainerInset = UIEdgeInsets(top: Self.contentPadding, left: Self.contentPadding,
                                              bottom: Self.contentPadding, right: Self.contentPadding)
        view.textContainer.lineFragmentPadding = 0
        view.adjustsFontForContentSizeCategory = true
        let font = UIFont.preferredFont(forTextStyle: .body)
        if view.font != font { view.font = font }
        view.textColor = .label
        // Phrase order follows its word list even when surrounding UI is RTL.
        view.semanticContentAttribute = .forceLeftToRight
        view.textAlignment = .left
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.spellCheckingType = .no
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.inlinePredictionType = .no
        view.textContentType = nil
        view.returnKeyType = .done
        view.enablesReturnKeyAutomatically = true
        if #available(iOS 18.0, *) { view.writingToolsBehavior = .none }
        view.inputAssistantItem.leadingBarButtonGroups = []
        view.inputAssistantItem.trailingBarButtonGroups = []
        view.accessibilityIdentifier = "recovery.phrase"
        context.coordinator.accessory.sizeToFit()
        view.inputAccessoryView = context.coordinator.accessory
        return view
    }

    func updateUIView(_ view: InputView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.accessory.updateAppearance(context.environment.colorScheme == .dark ? .dark : .light)
        coordinator.updating = true
        defer { coordinator.updating = false }
        view.accessibilityLabel = strings.text(.recoveryPhrase)
        view.accessibilityHint = strings.text(.recoveryDetail)
        let font = UIFont.preferredFont(forTextStyle: .body)
        if view.font != font { view.font = font }
        if coordinator.editRevision != draft.editRevision {
            coordinator.editRevision = draft.editRevision
            view.unmarkText()
            view.undoManager?.removeAllActions()
            // UIKit owns live edits and the caret. Reapplying a SwiftUI snapshot
            // between its selection and text callbacks can overwrite a keystroke.
            // Only explicit paste, scan, completion, and reset revise this value.
            if view.text != draft.text { view.text = draft.text; view.invalidateIntrinsicContentSize() }
            if view.selectedRange != draft.selection, Range(draft.selection, in: draft.text) != nil {
                view.selectedRange = draft.selection
            }
        }
        coordinator.refreshToolbar(composing: view.markedTextRange != nil)
        view.wantsFocus = isFocused
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: InputView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0, width.isFinite else { return nil }
        let content = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        // An empty, non-scrolling UITextView reports zero natural width. Keep
        // SwiftUI's proposed width. Reserve three real text lines at the current
        // Dynamic Type size, then let UITextView grow without a height cap.
        let lineHeight = (uiView.font ?? UIFont.preferredFont(forTextStyle: .body)).lineHeight
        let minimumHeight = ceil(lineHeight * 3) + uiView.textContainerInset.top + uiView.textContainerInset.bottom
        return CGSize(width: width, height: max(content.height, minimumHeight))
    }

    static func dismantleUIView(_ view: InputView, coordinator: Coordinator) {
        view.delegate = nil
        view.resignFirstResponder()
        view.undoManager?.removeAllActions()
        view.text = ""
        view.inputAccessoryView = nil
        coordinator.toolbar.clear()
    }

    final class InputView: UITextView {
        var wantsFocus = false { didSet { if wantsFocus != oldValue { synchronizeFocus() } } }
        private var focusUpdateScheduled = false
        override func didMoveToWindow() { super.didMoveToWindow(); synchronizeFocus() }
        private func synchronizeFocus() {
            guard !focusUpdateScheduled else { return }
            focusUpdateScheduled = true
            // First-responder changes can synchronously relayout SwiftUI while
            // updateUIView is running. Perform them after that transaction.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.focusUpdateScheduled = false
                guard self.window != nil else { return }
                if self.wantsFocus, !self.isFirstResponder {
                    if let accessory = self.inputAccessoryView {
                        accessory.frame.size.width = self.window?.bounds.width ?? self.bounds.width
                        accessory.sizeToFit()
                    }
                    self.becomeFirstResponder()
                } else if !self.wantsFocus, self.isFirstResponder { self.resignFirstResponder() }
            }
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: OathMnemonicTextInput
        var updating = false
        var editRevision = -1
        let accessory = OathKeyboardAccessory(identifierPrefix: "recovery")
        var toolbar: OathKeyboardToolbar { accessory.toolbar }

        init(_ parent: OathMnemonicTextInput) { self.parent = parent }

        func refreshToolbar(composing: Bool) {
            toolbar.update(words: composing ? [] : parent.draft.suggestions,
                           doneLabel: parent.strings.text(.done),
                           onWord: { [weak self] in self?.parent.draft.complete($0) },
                           onDone: { [weak self] in self?.parent.isFocused = false })
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !updating else { return }
            parent.draft.text = textView.text
            if parent.draft.selection != textView.selectedRange { parent.draft.selection = textView.selectedRange }
            parent.draft.attemptedImport = false
            parent.draft.inputRejected = false
            parent.draft.isComposing = textView.markedTextRange != nil
            textView.invalidateIntrinsicContentSize()
            refreshToolbar(composing: textView.markedTextRange != nil)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !updating else { return }
            let composing = textView.markedTextRange != nil
            let changed = parent.draft.selection != textView.selectedRange || parent.draft.isComposing != composing
            guard changed else { return }
            if parent.draft.selection != textView.selectedRange { parent.draft.selection = textView.selectedRange }
            if parent.draft.isComposing != composing { parent.draft.isComposing = composing }
            refreshToolbar(composing: composing)
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            if !updating, !parent.isFocused { parent.isFocused = true }
        }
        func textViewDidEndEditing(_ textView: UITextView) {
            if !updating, parent.isFocused { parent.isFocused = false }
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            if text == "\n", textView.markedTextRange == nil {
                parent.isFocused = false
                return false
            }
            guard Range(range, in: textView.text) != nil else { return false }
            let count = textView.text.utf16.count - range.length + text.utf16.count
            guard count <= OathMnemonicValidator.maximumInputLength else {
                parent.draft.inputRejected = true
                parent.draft.attemptedImport = true
                return false
            }
            return true
        }
    }

}
