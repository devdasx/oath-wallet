import SwiftUI
import UIKit

/// Opt in only when the system back button is replaced for presentation.
/// UIKit still owns both recognizers, their targets and the interactive pop.
/// Never apply this to screens that hide Back to protect an in-flight operation.
struct OathNativeBackGesture: UIViewControllerRepresentable {
    var isEnabled = true

    func makeUIViewController(context: Context) -> Controller { Controller() }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.isBackEnabled = isEnabled
        controller.apply()
    }

    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        controller.restore()
    }

    final class Controller: UIViewController {
        var isBackEnabled = true
        private weak var destination: UIViewController?
        private var bindings: [Binding] = []

        private struct Binding {
            let gesture: UIGestureRecognizer
            let delegate: PopDelegate
            let wasEnabled: Bool
        }

        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
            view.isAccessibilityElement = false
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            apply()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            apply()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            apply()
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            restore()
        }

        func apply() {
            guard isBackEnabled else { restore(); return }
            // Missing ancestry during attachment/teardown is normal lifecycle,
            // not an app failure. No gestures or navigation events are logged.
            guard let navigation = navigationController else { return }
            var owner: UIViewController = self
            while let parent = owner.parent, parent !== navigation { owner = parent }
            guard owner.parent === navigation, navigation.topViewController === owner,
                  navigation.viewControllers.count > 1 else { return }

            if destination !== owner || bindings.contains(where: { $0.gesture.delegate !== $0.delegate }) {
                restore()
            }
            destination = owner
            if bindings.isEmpty {
                var gestures = [navigation.interactivePopGestureRecognizer].compactMap { $0 }
                if #available(iOS 26.0, *), let content = navigation.interactiveContentPopGestureRecognizer {
                    gestures.append(content)
                }
                bindings = gestures.map { gesture in
                    let proxy = PopDelegate(owner: self, original: gesture.delegate)
                    let binding = Binding(gesture: gesture, delegate: proxy, wasEnabled: gesture.isEnabled)
                    gesture.delegate = proxy
                    return binding
                }
            }
            for binding in bindings where !binding.gesture.isEnabled {
                binding.gesture.isEnabled = true
            }
        }

        fileprivate func canBegin(_ gesture: UIGestureRecognizer) -> Bool {
            guard isBackEnabled, let destination, let navigation = navigationController,
                  navigation.topViewController === destination, navigation.viewControllers.count > 1,
                  navigation.transitionCoordinator == nil, navigation.viewIfLoaded?.window != nil,
                  navigation.presentedViewController == nil, destination.presentedViewController == nil,
                  let pan = gesture as? UIPanGestureRecognizer else { return false }
            var motion = pan.velocity(in: navigation.view)
            if motion == .zero { motion = pan.translation(in: navigation.view) }
            let sign: CGFloat = navigation.view.effectiveUserInterfaceLayoutDirection == .rightToLeft ? -1 : 1
            return motion.x * sign > 0 && abs(motion.x) > abs(motion.y)
        }

        func restore() {
            for binding in bindings where binding.gesture.delegate === binding.delegate {
                binding.gesture.delegate = binding.delegate.original
                // A completed push/pop has already applied the new top
                // controller's policy. Do not overwrite it with this page's
                // earlier hidden-back-button state.
                if navigationController?.topViewController === destination {
                    binding.gesture.isEnabled = binding.wasEnabled
                }
            }
            bindings.removeAll()
            destination = nil
        }
    }

    /// Replace only the hidden-button begin veto. Preserve UIKit's decisions
    /// about touches, competing recognizers and failure relationships.
    private final class PopDelegate: NSObject, UIGestureRecognizerDelegate {
        weak var owner: Controller?
        weak var original: (any UIGestureRecognizerDelegate)?

        init(owner: Controller, original: (any UIGestureRecognizerDelegate)?) {
            self.owner = owner
            self.original = original
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            owner?.canBegin(gestureRecognizer) ?? false
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            original?.gestureRecognizer?(gestureRecognizer, shouldReceive: touch) ?? true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive press: UIPress) -> Bool {
            original?.gestureRecognizer?(gestureRecognizer, shouldReceive: press) ?? true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive event: UIEvent) -> Bool {
            original?.gestureRecognizer?(gestureRecognizer, shouldReceive: event) ?? true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            original?.gestureRecognizer?(gestureRecognizer, shouldRecognizeSimultaneouslyWith: otherGestureRecognizer) ?? false
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            original?.gestureRecognizer?(gestureRecognizer, shouldRequireFailureOf: otherGestureRecognizer) ?? false
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            original?.gestureRecognizer?(gestureRecognizer, shouldBeRequiredToFailBy: otherGestureRecognizer) ?? false
        }
    }
}
