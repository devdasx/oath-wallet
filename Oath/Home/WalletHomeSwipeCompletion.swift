import SwiftUI
import UIKit

/// Keeps a swipe action's row in its original section until UIKit has finished
/// returning it horizontally. Moving the same cell between sections before then
/// makes the swipe-close animator use the cell's new vertical layout as its origin.
@MainActor
final class WalletHomeSwipeCompletion: NSObject {
    weak var anchor: UIView?
    private var pendingAction: (@MainActor () -> Void)?
    private var displayLink: CADisplayLink?

    func performAfterClosing(_ action: @escaping @MainActor () -> Void) {
        guard pendingAction == nil else { return }
        guard let cell = containingCell,
              cell.configurationState.isSwiped || hasUnfinishedMovement(cell) else {
            action()
            return
        }
        pendingAction = action
        let link = CADisplayLink(target: self, selector: #selector(checkCompletion))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func detach() {
        anchor = nil
        guard let action = takePendingAction() else { return }
        // Dismantling can happen during a SwiftUI update (for example, scrolling
        // the row offscreen). Preserve the requested pin outside that update.
        Task { @MainActor in action() }
    }

    private var containingCell: UICollectionViewCell? {
        var view = anchor
        while let current = view {
            if let cell = current as? UICollectionViewCell { return cell }
            view = current.superview
        }
        return nil
    }

    @objc private func checkCompletion() {
        guard let cell = containingCell, cell.window != nil else {
            finish()
            return
        }
        guard !cell.configurationState.isSwiped, !hasUnfinishedMovement(cell) else { return }
        finish()
    }

    private func hasUnfinishedMovement(_ cell: UICollectionViewCell) -> Bool {
        var view: UIView? = cell
        while let current = view, !(current is UICollectionView) {
            let model = current.layer
            // isSwiped becomes false when closing starts. Even a subpixel
            // remainder can still belong to UIKit's running close animator;
            // changing sections then causes a one-frame vertical jump.
            if model.animationKeys()?.isEmpty == false { return true }
            if let rendered = model.presentation(),
               abs(rendered.position.x - model.position.x) > 0.001
                || abs(rendered.bounds.minX - model.bounds.minX) > 0.001
                || abs(rendered.transform.m41 - model.transform.m41) > 0.001 {
                return true
            }
            view = current.superview
        }
        return false
    }

    private func finish() {
        takePendingAction()?()
    }

    private func takePendingAction() -> (@MainActor () -> Void)? {
        displayLink?.invalidate()
        displayLink = nil
        let action = pendingAction
        pendingAction = nil
        return action
    }
}

final class WalletHomeSwipeAnchorView: UIView {}

struct WalletHomeSwipeCompletionAnchor: UIViewRepresentable {
    let completion: WalletHomeSwipeCompletion

    func makeUIView(context: Context) -> UIView {
        let view = WalletHomeSwipeAnchorView()
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        completion.anchor = view
        return view
    }

    func updateUIView(_ view: UIView, context: Context) { completion.anchor = view }
    func makeCoordinator() -> WalletHomeSwipeCompletion { completion }

    static func dismantleUIView(_ view: UIView, coordinator: WalletHomeSwipeCompletion) {
        coordinator.detach()
    }
}
