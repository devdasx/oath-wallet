import SwiftUI
import UIKit

/// UIKit owns the popover and its content-size animation. SwiftUI's fitted
/// presentation changes its outer frame without animating during navigation.
struct WalletHomeQuickActionsPopover<Content: View>: UIViewRepresentable {
    @Binding var isPresented: Bool
    let onDismiss: () -> Void
    var navigationBar: NavigationBar? = nil
    @ViewBuilder let content: () -> Content

    struct NavigationBar {
        let title: String
        let closeTitle: String
        let closeIdentifier: String
        let contentSize: CGSize
        let onClose: () -> Void
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIView {
        let view = AnchorView()
        let coordinator = context.coordinator
        view.onWindowAttachment = { [weak coordinator, weak view] in
            guard let view else { return }
            coordinator?.updatePresentation(from: view)
        }
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.update(
            sourceView: view,
            isPresented: $isPresented,
            content: content(),
            navigationBar: navigationBar,
            onDismiss: onDismiss
        )
    }

    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) {
        coordinator.tearDown()
    }

    private final class AnchorView: UIView {
        var onWindowAttachment: (() -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { onWindowAttachment?() }
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIPopoverPresentationControllerDelegate {
        private var presentation: UIViewController?
        private var host: UIHostingController<Content>?
        private var navigationBar: NavigationBar?
        private var content: Content?
        private var isPresented: Binding<Bool>?
        private var onDismiss: (() -> Void)?
        private var isDismissing = false

        func update(sourceView: UIView, isPresented: Binding<Bool>, content: Content, navigationBar: NavigationBar?, onDismiss: @escaping () -> Void) {
            self.isPresented = isPresented
            self.onDismiss = onDismiss
            self.content = content
            self.navigationBar = navigationBar
            updatePresentation(from: sourceView)
        }

        func updatePresentation(from sourceView: UIView) {
            guard let isPresented, let content else { return }
            if isPresented.wrappedValue {
                if let presentation {
                    host?.rootView = content
                    (presentation as? NavigationController)?.update(navigationBar)
                    return
                }
                guard let rootController = sourceView.window?.rootViewController else { return }
                let host = UIHostingController(rootView: content)
                // Navigation popovers receive measured list dimensions. Asking
                // the hosting view to fit itself reintroduces its safe-area and
                // viewport size into the very calculation that resizes it.
                host.sizingOptions = navigationBar == nil ? [.preferredContentSize] : []
                host.view.backgroundColor = .clear
                self.host = host
                let controller: UIViewController
                if let navigationBar {
                    host.edgesForExtendedLayout = []
                    let navigation = NavigationController(rootViewController: host)
                    navigation.view.backgroundColor = .clear
                    navigation.update(navigationBar)
                    controller = navigation
                } else {
                    controller = host
                }
                controller.modalPresentationStyle = .popover
                if let popover = controller.popoverPresentationController {
                    // sourceItem opts into the native iOS 26 morph in both
                    // directions; sourceView alone uses the older presentation.
                    popover.sourceItem = sourceItem(containing: sourceView, in: rootController)
                    popover.permittedArrowDirections = []
                    popover.delegate = self
                }
                presentation = controller
                // A toolbar hosts its button in a small child controller.
                // Present from the owning screen so UIKit also exposes the
                // popover as the modal accessibility surface.
                var presenter = rootController
                while let presented = presenter.presentedViewController {
                    presenter = presented
                }
                presenter.present(controller, animated: true)
            } else {
                dismissPresentedContent()
            }
        }

        private func sourceItem(
            containing anchor: UIView, in rootController: UIViewController
        ) -> any UIPopoverPresentationControllerSourceItem {
            // SwiftUI's floating toolbar is not a UIToolbar ancestor. Its
            // owning controller still exposes the real items through UIKit.
            let items = barButtonItems(in: rootController)
            if let item = items.first(where: {
                $0.customView.map { anchor.isDescendant(of: $0) } == true
            }) {
                return item
            }
            let center = CGPoint(x: anchor.bounds.midX, y: anchor.bounds.midY)
            return items.first(where: { $0.frame(in: anchor)?.contains(center) == true }) ?? anchor
        }

        private func barButtonItems(in controller: UIViewController) -> [UIBarButtonItem] {
            let navigationItem = controller.navigationItem
            // SwiftUI's top toolbar uses navigation item groups. Those replace
            // the legacy left/right arrays, so searching only the arrays loses
            // the actual source item and disables UIKit's toolbar morph.
            let groups = navigationItem.leadingItemGroups
                + navigationItem.centerItemGroups
                + navigationItem.trailingItemGroups
            let groupedItems = groups.flatMap { group in
                if group.isDisplayingRepresentativeItem, let item = group.representativeItem {
                    return [item]
                }
                return group.barButtonItems
            }
            return (controller.toolbarItems ?? [])
                + groupedItems
                + (navigationItem.leftBarButtonItems ?? [])
                + (navigationItem.rightBarButtonItems ?? [])
                + controller.children.flatMap { barButtonItems(in: $0) }
        }

        func dismissPresentedContent() {
            guard let presentation, !isDismissing else { return }
            isDismissing = true
            presentation.dismiss(animated: true) { [weak self] in
                self?.finishDismissal()
            }
        }

        func tearDown() {
            // The SwiftUI owner is being removed. Do not write back into its
            // state from a synchronous UIKit dismissal during dismantling.
            isPresented = nil
            onDismiss = nil
            content = nil
            let controller = presentation
            presentation = nil
            host = nil
            controller?.popoverPresentationController?.delegate = nil
            controller?.dismiss(animated: false)
        }

        func adaptivePresentationStyle(
            for controller: UIPresentationController,
            traitCollection: UITraitCollection
        ) -> UIModalPresentationStyle {
            .none
        }

        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            finishDismissal()
        }

        private func finishDismissal() {
            guard presentation != nil else { return }
            presentation = nil
            host = nil
            isDismissing = false
            if isPresented?.wrappedValue == true {
                isPresented?.wrappedValue = false
            }
            onDismiss?()
        }
    }

    /// Use measured content dimensions; UIKit adds native navigation chrome.
    @MainActor
    final class NavigationController: UINavigationController, UIGestureRecognizerDelegate {
        private var configuration: NavigationBar?

        override func viewDidLoad() {
            super.viewDidLoad()
            let pan = UIPanGestureRecognizer(target: self, action: #selector(swipedNavigationBar(_:)))
            pan.maximumNumberOfTouches = 1
            pan.delegate = self
            navigationBar.addGestureRecognizer(pan)
        }

        func update(_ configuration: NavigationBar?) {
            guard let configuration, let content = topViewController else { return }
            self.configuration = configuration
            if content.navigationItem.title != configuration.title {
                content.navigationItem.title = configuration.title
            }
            content.navigationItem.largeTitleDisplayMode = .never
            // Keep the native item stable through size/rotation updates, so an
            // in-flight close tap is never replaced by a newly created control.
            if content.navigationItem.leftBarButtonItem == nil {
                content.navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in
                    self?.configuration?.onClose()
                })
            }
            let close = content.navigationItem.leftBarButtonItem!
            close.accessibilityIdentifier = configuration.closeIdentifier
            close.accessibilityLabel = configuration.closeTitle
            if preferredContentSize != configuration.contentSize {
                preferredContentSize = configuration.contentSize
            }
        }

        @objc private func swipedNavigationBar(_ recognizer: UIPanGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            let offset = recognizer.translation(in: navigationBar)
            if offset.y < -36, abs(offset.y) > abs(offset.x) {
                configuration?.onClose()
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: navigationBar)
            return velocity.y < 0 && abs(velocity.y) > abs(velocity.x)
        }
    }
}
