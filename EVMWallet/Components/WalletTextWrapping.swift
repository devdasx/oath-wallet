import UIKit

/// Presentation only: never insert/remove characters in addresses, keys, or
/// user-entered text. Real hyphens and the exact copy/signing value stay intact.
@MainActor
enum WalletTextWrapping {
    static func paragraphStyle(from original: NSParagraphStyle? = nil) -> NSParagraphStyle {
        let style = (original?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        style.usesDefaultHyphenation = false
        style.hyphenationFactor = 0
        return style
    }

    static func apply(to object: Any?) {
        guard let view = object as? UITextView else { return }
        if let manager = view.textLayoutManager {
            manager.usesHyphenation = false
        } else {
            view.layoutManager.usesDefaultHyphenation = false
        }

        let typingStyle = view.typingAttributes[.paragraphStyle] as? NSParagraphStyle
        if typingStyle == nil || needsUpdate(typingStyle) {
            var attributes = view.typingAttributes
            attributes[.paragraphStyle] = paragraphStyle(from: typingStyle)
            view.typingAttributes = attributes
        }

        let storage = view.textStorage
        var updates: [(NSRange, NSParagraphStyle)] = []
        storage.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: storage.length)) {
            value, range, _ in
            let style = value as? NSParagraphStyle
            if style == nil || needsUpdate(style) {
                updates.append((range, paragraphStyle(from: style)))
            }
        }
        guard !updates.isEmpty else { return }
        // Attribute-only edits preserve selection, undo history, and SwiftUI's
        // binding/coordinator. Avoid setting attributedText while the user types.
        storage.beginEditing()
        for (range, style) in updates {
            storage.addAttribute(.paragraphStyle, value: style, range: range)
        }
        storage.endEditing()
    }

    private static func needsUpdate(_ style: NSParagraphStyle?) -> Bool {
        style?.usesDefaultHyphenation == true || style?.hyphenationFactor != 0
    }
}
