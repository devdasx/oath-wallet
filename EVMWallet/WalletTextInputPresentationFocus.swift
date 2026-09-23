import SwiftUI
import UIKit

extension View {
    /// Explicit opt-in for credential entry, converters, and requested Settings tools.
    /// Browsing, pickers, search, and shared text-input styling never opt in.
    /// Request focus once, after native navigation/presentation has completed.
    /// A redraw or a deliberate keyboard dismissal must not request it again.
    func walletFocusOnPresentation(_ action: @escaping @MainActor () -> Void) -> some View {
        background {
            WalletInputPresentationObserver(action: action)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }

}

private struct WalletInputPresentationObserver: UIViewControllerRepresentable {
    let action: @MainActor () -> Void

    func makeUIViewController(context: Context) -> Controller {
        Controller(action: action)
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.action = action
    }

    @MainActor
    final class Controller: UIViewController {
        var action: @MainActor () -> Void
        private var didRequestFocus = false

        init(action: @escaping @MainActor () -> Void) {
            self.action = action
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func loadView() {
            view = UIView(frame: .zero)
            view.isUserInteractionEnabled = false
            view.backgroundColor = .clear
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard !didRequestFocus else { return }
            didRequestFocus = true
            action()
        }
    }
}
