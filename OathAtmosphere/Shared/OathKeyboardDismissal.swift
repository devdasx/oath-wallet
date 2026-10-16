import SwiftUI
import UIKit

/// Wait for UIKit's real keyboard completion, including hardware-keyboard use.
/// This never presents or dismisses a controller, and holds no password itself.
struct OathKeyboardDismissal: UIViewControllerRepresentable {
    let requested: Bool
    let onDismiss: () -> Void

    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.onDismiss = onDismiss
        controller.update(requested: requested)
    }
    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) { controller.cancel() }

    final class Controller: UIViewController {
        var onDismiss: (() -> Void)?
        private var keyboardVisible = false
        private var requested = false
        private var finished = false

        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
            NotificationCenter.default.addObserver(self, selector: #selector(keyboardShown), name: UIResponder.keyboardWillShowNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(keyboardHidden), name: UIResponder.keyboardDidHideNotification, object: nil)
        }
        func update(requested: Bool) {
            guard self.requested != requested else { return }
            self.requested = requested
            guard requested else { finished = false; return }
            // Responder changes may update SwiftUI; leave its current layout
            // transaction before requesting the system keyboard dismissal.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.requested, let window = self.view.window else { return }
                window.endEditing(true)
                self.finishIfReady()
            }
        }
        @objc private func keyboardShown() { keyboardVisible = true }
        @objc private func keyboardHidden() { keyboardVisible = false; finishIfReady() }
        private func finishIfReady() {
            guard requested, !finished, !keyboardVisible else { return }
            finished = true
            onDismiss?()
        }
        func cancel() { requested = false; onDismiss = nil; NotificationCenter.default.removeObserver(self) }
        deinit { NotificationCenter.default.removeObserver(self) }
    }
}
