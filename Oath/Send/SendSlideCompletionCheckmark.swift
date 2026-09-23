import SwiftUI
import UIKit

/// Uses the same native DrawOn effect as SwiftUI's .symbolEffect(.drawOn).
/// UIImageView supplies its actual completion callback, so receipt navigation
/// never depends on guessing the symbol animation's duration.
struct SendSlideCompletionCheckmark: UIViewRepresentable {
    let symbolSize: CGFloat
    let tint: Color
    let reduceMotion: Bool
    let onCompletion: (Bool) -> Void

    func makeUIView(context: Context) -> CheckmarkView {
        let view = CheckmarkView()
        view.contentMode = .center
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        view.alpha = 0
        return view
    }

    func updateUIView(_ view: CheckmarkView, context: Context) {
        view.configureSymbol(size: symbolSize)
        view.tintColor = UIColor(tint)
        view.reduceMotion = reduceMotion
        view.onCompletion = onCompletion
        view.startIfReady()
    }

    static func dismantleUIView(_ view: CheckmarkView, coordinator: ()) {
        view.cancel()
    }

    final class CheckmarkView: UIImageView {
        var reduceMotion = false
        var onCompletion: ((Bool) -> Void)?
        private var started = false
        private var startScheduled = false
        private var completed = false
        private var cancelled = false
        private var symbolSize: CGFloat?

        func configureSymbol(size: CGFloat) {
            guard symbolSize != size else { return }
            symbolSize = size
            image = UIImage(systemName: "checkmark",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: .semibold))
            if #available(iOS 26.0, *) {
                // DrawOn reveals a symbol from its drawn-off state.
                addSymbolEffect(.drawOff.wholeSymbol, animated: false)
            }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            startIfReady()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            startIfReady()
        }

        func startIfReady() {
            guard !started, !startScheduled, !cancelled, window != nil, image != nil,
                  bounds.width > 0, bounds.height > 0 else { return }
            startScheduled = true
            // SwiftUI inserts and lays out this view with animations disabled.
            // Start on the next main-loop turn, outside that insertion transaction.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.startScheduled = false
                guard !self.started, !self.cancelled, self.window != nil else { return }
                self.reveal()
            }
        }

        private func reveal() {
            started = true
            if #available(iOS 26.0, *), !reduceMotion {
                alpha = 1
                addSymbolEffect(.drawOn.wholeSymbol, options: .nonRepeating) { [weak self] context in
                    // Symbol callbacks do not promise actor isolation. Hop
                    // before reading the context or touching SwiftUI state.
                    Task { @MainActor [weak self] in
                        self?.finish(context.isFinished)
                    }
                }
            } else {
                // Reduce Motion and older systems show a quiet opacity reveal.
                removeAllSymbolEffects(animated: false)
                UIView.animate(withDuration: 0.16, animations: {
                    self.alpha = 1
                }, completion: { [weak self] finished in
                    Task { @MainActor [weak self] in self?.finish(finished) }
                })
            }
        }

        func cancel() {
            cancelled = true
            onCompletion = nil
            removeAllSymbolEffects(animated: false)
            layer.removeAllAnimations()
        }

        private func finish(_ finished: Bool) {
            guard !completed, !cancelled else { return }
            completed = true
            onCompletion?(finished)
        }
    }
}
