import SwiftUI
import UIKit

struct WalletHomeFirstFrameObserver: UIViewRepresentable {
    let onFirstRenderedFrame:
        @MainActor @Sendable () -> Void

    func makeUIView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.onFirstRenderedFrame = onFirstRenderedFrame
        return view
    }

    func updateUIView(
        _ uiView: ObserverView,
        context: Context
    ) {
        uiView.onFirstRenderedFrame = onFirstRenderedFrame
        uiView.beginObservingIfPossible()
    }

    static func dismantleUIView(
        _ uiView: ObserverView,
        coordinator: ()
    ) {
        uiView.stopObserving()
    }

    @MainActor
    final class ObserverView: UIView {
        var onFirstRenderedFrame:
            (@MainActor @Sendable () -> Void)?

        private var displayLink: CADisplayLink?
        private var didDeliverFrame = false
        private var observedDisplayTicks = 0

        override init(frame: CGRect) {
            super.init(frame: frame)
            isHidden = true
            isUserInteractionEnabled = false
            accessibilityElementsHidden = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            beginObservingIfPossible()
        }

        func beginObservingIfPossible() {
            guard window != nil,
                  !didDeliverFrame,
                  displayLink == nil else {
                return
            }
            let displayLink = CADisplayLink(
                target: self,
                selector: #selector(displayLinkDidFire)
            )
            displayLink.add(to: .main, forMode: .common)
            self.displayLink = displayLink
        }

        func stopObserving() {
            displayLink?.invalidate()
            displayLink = nil
        }

        @objc
        private func displayLinkDidFire() {
            guard !didDeliverFrame else { return }
            observedDisplayTicks += 1
            guard observedDisplayTicks >= 2 else { return }
            stopObserving()
            didDeliverFrame = true
            onFirstRenderedFrame?()
        }
    }
}
