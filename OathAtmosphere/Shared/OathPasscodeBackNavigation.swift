import SwiftUI
import UIKit

/// Override the navigation BAR action, leaving UIKit's native interactive pop
/// gestures intact. A custom SwiftUI back button would disable those gestures.
struct OathPasscodeBackNavigation: UIViewControllerRepresentable {
    @Environment(\.oathLocalizer) private var strings
    let isEnabled: Bool
    let onBack: () -> Void

    func makeUIViewController(context: Context) -> Controller { Controller() }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.isBackEnabled = isEnabled
        controller.onBack = onBack
        controller.backTitle = strings.text(.back)
        controller.apply()
    }

    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        controller.restore()
    }

    final class Controller: UIViewController {
        var isBackEnabled = true
        var onBack: () -> Void = {}
        var backTitle = ""
        private weak var installedOn: UIViewController?
        private weak var precedingItem: UINavigationItem?
        private var previousBackAction: UIAction?
        private var previousDisplayMode: UINavigationItem.BackButtonDisplayMode = .default
        private var blockedGestures: [(UIGestureRecognizer, Bool)] = []
        private let actionID = UIAction.Identifier("org.oathwallet.passcode.back")

        override func loadView() {
            view = UIView()
            view.backgroundColor = .clear
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

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            restore()
        }

        func apply() {
            guard let navigation = navigationController else { return }
            // Find this representable's own navigation destination, never an
            // unrelated top controller that may be arriving during a pop.
            var destination: UIViewController = self
            while let parent = destination.parent, parent !== navigation { destination = parent }
            guard destination.parent === navigation,
                  navigation.topViewController === destination else { return }

            if installedOn !== destination {
                restore()
                installedOn = destination
                previousBackAction = destination.navigationItem.backAction
                if let index = navigation.viewControllers.firstIndex(where: { $0 === destination }), index > 0 {
                    let previous = navigation.viewControllers[index - 1].navigationItem
                    precedingItem = previous
                    previousDisplayMode = previous.backButtonDisplayMode
                    previous.backButtonDisplayMode = .minimal
                }
            }

            let attributes: UIMenuElement.Attributes = isBackEnabled ? [] : .disabled
            if destination.navigationItem.backAction?.identifier != actionID
                || destination.navigationItem.backAction?.title != backTitle
                || destination.navigationItem.backAction?.attributes != attributes {
                destination.navigationItem.backAction = UIAction(
                    title: backTitle,
                    identifier: actionID, attributes: attributes
                ) { [weak self] _ in
                    guard let self, self.isBackEnabled else { return }
                    OathHaptics.shared.perform(.navigate) { self.onBack() }
                }
            }

            if !isBackEnabled && blockedGestures.isEmpty {
                var gestures = [navigation.interactivePopGestureRecognizer].compactMap { $0 }
                if #available(iOS 26.0, *), let content = navigation.interactiveContentPopGestureRecognizer {
                    gestures.append(content)
                }
                blockedGestures = gestures.map { ($0, $0.isEnabled) }
                gestures.forEach { $0.isEnabled = false }
            } else if isBackEnabled {
                restoreGestures()
            }
        }

        func restore() {
            if let installedOn, installedOn.navigationItem.backAction?.identifier == actionID {
                installedOn.navigationItem.backAction = previousBackAction
            }
            precedingItem?.backButtonDisplayMode = previousDisplayMode
            restoreGestures()
            installedOn = nil
            precedingItem = nil
            previousBackAction = nil
        }

        private func restoreGestures() {
            for (gesture, wasEnabled) in blockedGestures { gesture.isEnabled = wasEnabled }
            blockedGestures.removeAll()
        }
    }
}
