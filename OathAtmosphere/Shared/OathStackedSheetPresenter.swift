import SwiftUI
import UIKit

/// Presents in the anchor's scene above the current modal, retaining the
/// underlying navigation, sheet and browser instead of dismissing them.
@MainActor final class OathStackedSheetPresenter: NSObject, UIAdaptivePresentationControllerDelegate {
    struct Presentation {
        let id: UUID
        let content: (@escaping () -> Void, @escaping (Bool) -> Void) -> AnyView
        let onDismiss: () -> Void
    }

    weak var window: UIWindow?
    var environment: EnvironmentValues?
    var hasPending: () -> Bool = { false }
    var takePending: () -> Presentation? = { nil }
    private(set) var controller: UIHostingController<AnyView>?
    private var active: Presentation?
    private var retry: Task<Void, Never>?

    func update() {
        if let controller, let active {
            controller.rootView = rootView(active)
            return
        }
        retry?.cancel()
        retry = Task { [weak self] in
            // SwiftUI can update its anchor during a presentation transition.
            // Waiting for UIKit is expected navigation, not a connection error.
            // Allow the current SwiftUI update to commit its own modal first;
            // yielding a task alone can run before SwiftUI calls present().
            do { try await Task.sleep(for: .milliseconds(150)) }
            catch { return }
            while !Task.isCancelled, let self, self.hasPending() {
                if self.presentPending() { return }
                do { try await Task.sleep(for: .milliseconds(150)) }
                catch { return }
            }
        }
    }

    private func presentPending() -> Bool {
        guard controller == nil, let window,
              window.windowScene?.activationState == .foregroundActive,
              var top = window.rootViewController else { return false }
        while let presented = top.presentedViewController { top = presented }
        guard top.viewIfLoaded?.window != nil, !top.isBeingDismissed, !top.isBeingPresented,
              top.transitionCoordinator == nil, !(top is UIAlertController) else { return false }
        guard let presentation = takePending() else { return true }
        active = presentation
        let host = Host(rootView: rootView(presentation))
        host.onDismiss = { [weak self] in self?.didDismiss(presentation.id) }
        host.modalPresentationStyle = .pageSheet
        host.sheetPresentationController?.detents = [.large()]
        host.sheetPresentationController?.prefersGrabberVisible = true
        // Keep interaction gated until the content publishes its current review
        // policy. Result screens remain dismissible with the native gesture.
        host.isModalInPresentation = true
        host.presentationController?.delegate = self
        controller = host
        top.view.endEditing(true)
        top.present(host, animated: true)
        return true
    }

    private func rootView(_ presentation: Presentation) -> AnyView {
        let content = presentation.content({ [weak self] in self?.dismiss(presentation.id) }, { [weak self] disabled in
            guard self?.active?.id == presentation.id else { return }
            self?.controller?.isModalInPresentation = disabled
        })
        if let environment { return AnyView(content.environment(\.self, environment)) }
        return content
    }

    func dismiss(_ id: UUID) {
        guard active?.id == id, let controller else { return }
        controller.dismiss(animated: true) { [weak self] in self?.didDismiss(id) }
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        guard presentationController.presentedViewController === controller, let id = active?.id else { return }
        didDismiss(id)
    }

    private func didDismiss(_ id: UUID) {
        guard let presentation = active, presentation.id == id else { return }
        active = nil
        controller = nil
        presentation.onDismiss()
        update()
    }

    private final class Host: UIHostingController<AnyView> {
        var onDismiss: (() -> Void)?
        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            // Covering this sheet with Safari or an address page is not dismissal.
            if isBeingDismissed || presentingViewController == nil {
                let finished = onDismiss
                DispatchQueue.main.async { finished?() }
            }
        }
    }
}
