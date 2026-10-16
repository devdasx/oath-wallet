import SwiftUI
import UIKit

extension View {
    /// Use for automatic entry focus only. Taps, Return-to-next-field and the
    /// shared keyboard's Done action continue to respond immediately.
    func oathAutofocus(when ready: Bool = true, _ focus: @escaping @MainActor () -> Void) -> some View {
        modifier(OathAutofocusModifier(ready: ready, focus: focus))
    }
}

private struct OathAutofocusPresentationKey: EnvironmentKey {
    static let defaultValue: OathAutofocusPresentation? = nil
}

extension EnvironmentValues {
    var oathAutofocusPresentation: OathAutofocusPresentation? {
        get { self[OathAutofocusPresentationKey.self] }
        set { self[OathAutofocusPresentationKey.self] = newValue }
    }
}

private struct OathAutofocusModifier: ViewModifier {
    let ready: Bool
    let focus: @MainActor () -> Void
    @Environment(\.isEnabled) private var enabled
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.oathAutofocusPresentation) private var presentation
    @State private var gate = OathAutofocusGate()

    func body(content: Content) -> some View {
        content
            .background {
                OathAutofocusLifecycle(gate: gate, presentation: presentation,
                    enabled: ready && enabled, active: scenePhase == .active, focus: focus)
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .transaction { [gate] transaction in
                // Covers a form swapped into an already visible sheet as well
                // as SwiftUI transitions without a new navigation controller.
                guard transaction.animation != nil else { return }
                let token = gate.beginAnimation()
                transaction.addAnimationCompletion(criteria: .removed) { [weak gate] in
                    Task { @MainActor in gate?.endAnimation(token) }
                }
            }
    }
}

private struct OathAutofocusLifecycle: UIViewControllerRepresentable {
    let gate: OathAutofocusGate
    let presentation: OathAutofocusPresentation?
    let enabled: Bool
    let active: Bool
    let focus: @MainActor () -> Void

    func makeUIViewController(context: Context) -> Controller { Controller(gate: gate) }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.observe(presentation)
        gate.update(enabled: enabled, active: active) { [weak controller] in
            guard let controller, controller.viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive,
                  !controller.isBeingDismissed, !controller.isMovingFromParent else { return }
            focus()
        }
    }

    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) { controller.cancel() }

    final class Controller: UIViewController {
        private let gate: OathAutofocusGate
        private var presentation: OathAutofocusPresentation?
        private var observation: UUID?

        init(gate: OathAutofocusGate) {
            self.gate = gate
            super.init(nibName: nil, bundle: nil)
            gate.activate()
        }
        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

        override func loadView() {
            view = UIView()
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            // A child added to an existing host can appear while an ancestor
            // is still presenting. UIKit supplies that ancestor's coordinator.
            // Register before completion dispatch starts, not in viewDidAppear.
            if let transition = transitionCoordinator {
                let token = gate.beginAnimation()
                let registered = transition.animate(alongsideTransition: nil) { [weak gate] _ in
                    gate?.endAnimation(token)
                }
                if !registered { gate.endAnimation(token) }
            }
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            gate.setAppeared(true)
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            gate.setAppeared(false)
        }

        func observe(_ presentation: OathAutofocusPresentation?) {
            guard self.presentation !== presentation else { return }
            if let observation { self.presentation?.removeObserver(observation) }
            self.presentation = presentation
            observation = presentation?.observe { [weak gate] in gate?.setPresentationReady($0) }
            if presentation == nil { gate.setPresentationReady(true) }
        }

        func cancel() {
            if let observation { presentation?.removeObserver(observation) }
            observation = nil
            presentation = nil
            gate.invalidate()
        }
    }
}
