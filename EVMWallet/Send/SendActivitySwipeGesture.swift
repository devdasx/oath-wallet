import SwiftUI

/// Native recognition crosses the UIKit-backed List boundary without replacing native rows.
struct SendActivitySwipeGesture: UIGestureRecognizerRepresentable {
    let isEnabled: Bool
    let onTranslation: (CGSize) -> Void
    let onDismiss: () -> Void

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.maximumNumberOfTouches = 1
        recognizer.delegate = context.coordinator
        recognizer.isEnabled = isEnabled
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        recognizer.isEnabled = isEnabled
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let offset = recognizer.translation(in: nil)
        let translation = CGSize(width: offset.x, height: offset.y)
        switch recognizer.state {
        case .began, .changed:
            let upward = offset.y < 0 && abs(offset.y) > abs(offset.x)
            onTranslation(upward ? CGSize(width: 0, height: offset.y) : .zero)
        case .ended:
            onTranslation(.zero)
            if SendStatusCapsule.shouldDismiss(translation: translation) { onDismiss() }
        case .cancelled, .failed:
            onTranslation(.zero)
        default:
            break
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: nil)
            return velocity.y < 0 && abs(velocity.y) > abs(velocity.x)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
