import SwiftUI
import UIKit

/// Numeric controls keep the familiar `1 2 3` ordering independently from
/// the surrounding language direction. Only the control subtree opts out of
/// locale-driven mirroring; titles, instructions, and navigation remain
/// semantic and continue to follow the selected language.
enum WalletNumericKeypadLayout {
    static let direction: LayoutDirection = .leftToRight
}

extension View {
    func walletNumericKeypadLayout() -> some View {
        environment(
            \.layoutDirection,
            WalletNumericKeypadLayout.direction
        )
    }
}

enum WalletTextInputLayout {
    static let alignment = TextAlignment.leading

    @MainActor
    static func apply(
        _ layoutDirection: LayoutDirection,
        to object: Any?
    ) {
        if let textField = object as? UITextField {
            apply(layoutDirection, to: textField)
        } else if let textView = object as? UITextView {
            apply(layoutDirection, to: textView)
        }
    }

    @MainActor
    private static func apply(
        _ layoutDirection: LayoutDirection,
        to textField: UITextField
    ) {
        // Numbers have their own bidirectional text rules. Rewriting the whole
        // paragraph after each edit interferes with UIKit's numeric editing
        // layout and horizontal scrolling in RTL. Leave numeric controls under
        // UIKit's natural writing-direction handling; surrounding UI remains
        // locale-driven.
        switch textField.keyboardType {
        case .decimalPad, .numberPad, .asciiCapableNumberPad:
            return
        default:
            break
        }
        let alignment = leadingAlignment(
            for: textField, preserving: textField.textAlignment
        )
        if let range = textField.textRange(
            from: textField.beginningOfDocument,
            to: textField.endOfDocument
        ) {
            textField.setBaseWritingDirection(
                writingDirection(for: layoutDirection), for: range
            )
        }
        // Setting paragraph direction can restore natural alignment. Resolve
        // the semantic leading edge after UIKit updates its paragraph style.
        textField.textAlignment = alignment
    }

    @MainActor
    private static func apply(
        _ layoutDirection: LayoutDirection,
        to textView: UITextView
    ) {
        let alignment = leadingAlignment(
            for: textView, preserving: textView.textAlignment
        )
        if let range = textView.textRange(
            from: textView.beginningOfDocument,
            to: textView.endOfDocument
        ) {
            textView.setBaseWritingDirection(
                writingDirection(for: layoutDirection), for: range
            )
        }
        textView.textAlignment = alignment
    }

    @MainActor
    private static func leadingAlignment(
        for input: UIView, preserving alignment: NSTextAlignment
    ) -> NSTextAlignment {
        // UIKit's natural alignment can retain the host app's language after
        // a SwiftUI locale change. Resolve leading from the native view's
        // direction; do not change its layout or centered/justified controls.
        guard alignment != .center, alignment != .justified else { return alignment }
        return input.effectiveUserInterfaceLayoutDirection == .rightToLeft ? .right : .left
    }

    private static func writingDirection(
        for layoutDirection: LayoutDirection
    ) -> NSWritingDirection {
        switch layoutDirection {
        case .leftToRight:
            .leftToRight
        case .rightToLeft:
            .rightToLeft
        @unknown default:
            .leftToRight
        }
    }
}

extension View {
    func walletTextInputDirection() -> some View {
        modifier(WalletTextInputDirectionModifier())
    }
}

private struct WalletTextInputDirectionModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .submitLabel(.done)
            .onSubmit(of: [.text, .search]) {
                WalletTextInputReturnKey.dismissKeyboard()
            }
            .submitScope()
            .multilineTextAlignment(WalletTextInputLayout.alignment)
            // SwiftUI owns the field's initial layout and Return label. Native
            // delegate/writing-direction configuration is installed by the app's
            // editing notifications, including search fields and reused inputs.
            // Do not search the entire UIKit hierarchy during layout: a screen
            // anchor need not intersect its toolbar's search field, which made
            // the former geometry cache miss and rescan on every layout pass.
    }
}
