import SwiftUI
import UIKit

extension View {
    /// Apply directly to multiline inputs, including prefilled, unfocused ones.
    /// Subsequent editing events also enforce this policy at the app root.
    func walletNonHyphenatingInput() -> some View {
        background { WalletTextWrappingObserver().accessibilityHidden(true) }
    }
}

private struct WalletTextWrappingObserver: UIViewRepresentable {
    func makeUIView(context: Context) -> Observer { Observer() }
    func updateUIView(_ view: Observer, context: Context) { view.refresh() }

    final class Observer: UIView {
        private weak var input: UITextView?
        private var lastSearchBounds: CGRect?

        init() {
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            backgroundColor = .clear
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func refresh() {
            lastSearchBounds = nil
            setNeedsLayout()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            lastSearchBounds = nil
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard window != nil, !bounds.isEmpty else { return }
            if let input, input.window === window {
                WalletTextWrapping.apply(to: input)
                return
            }
            guard lastSearchBounds != bounds else { return }
            lastSearchBounds = bounds
            // Scoped to this input's bounds, with a strict traversal budget.
            // Never install a window-wide scan or repeatedly search during typing.
            var budget = 128
            var ancestor = superview
            while let candidate = ancestor, !(candidate is UIWindow), budget > 0 {
                if let found = findInput(in: candidate, budget: &budget) {
                    input = found
                    WalletTextWrapping.apply(to: found)
                    return
                }
                ancestor = candidate.superview
            }
        }

        private func findInput(in view: UIView, budget: inout Int) -> UITextView? {
            guard budget > 0, view !== self else { return nil }
            budget -= 1
            let frame = view.convert(view.bounds, to: self)
            guard frame.intersects(bounds) else { return nil }
            if let textView = view as? UITextView { return textView }
            for child in view.subviews {
                if let found = findInput(in: child, budget: &budget) { return found }
            }
            return nil
        }
    }
}
