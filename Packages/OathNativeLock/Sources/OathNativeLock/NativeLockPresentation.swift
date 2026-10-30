import SwiftUI
import UIKit

/// Cold launch has no previously presented screen. Install the same native
/// blur/keypad controller as a child in the first hierarchy, rather than waiting
/// for a root appearance callback to present a modal over a blank frame.
public struct NativeInitialLock<Content: View>: UIViewControllerRepresentable {
    private let isLocked: Bool
    private let animatesUnlock: Bool
    private let onUnlocked: () -> Void
    private let content: (Bool) -> Content

    public init(isLocked: Bool, animatesUnlock: Bool = true, onUnlocked: @escaping () -> Void,
                @ViewBuilder content: @escaping (_ isVisible: Bool) -> Content) {
        self.isLocked = isLocked
        self.animatesUnlock = animatesUnlock
        self.onUnlocked = onUnlocked
        self.content = content
    }

    public func makeUIViewController(context: Context) -> Controller {
        let controller = Controller()
        configure(controller, environment: context.environment)
        return controller
    }

    public func updateUIViewController(_ controller: Controller, context: Context) {
        configure(controller, environment: context.environment)
    }

    private func configure(_ controller: Controller, environment: EnvironmentValues) {
        controller.configure(isLocked: isLocked, animatesUnlock: animatesUnlock, colorScheme: environment.colorScheme,
                             onUnlocked: onUnlocked) { visible in
            AnyView(content(visible)
                .environment(\.locale, environment.locale)
                .environment(\.layoutDirection, environment.layoutDirection)
                .environment(\.dynamicTypeSize, environment.dynamicTypeSize)
                .environment(\.scenePhase, environment.scenePhase)
                .environment(\.colorScheme, environment.colorScheme)
                .environment(\.isEnabled, true)
                .accessibilityHidden(false))
        }
    }

    public static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        controller.tearDown()
    }

    @MainActor public final class Controller: UIViewController {
        private let lock = NativeLockController(content: AnyView(EmptyView()), colorScheme: .light)
        private var makeContent: ((Bool) -> AnyView)?
        private var requested = true
        private var onUnlocked: (() -> Void)?

        // This inline cover shares SwiftUI's status-bar owner with Home. Let
        // the root's native toolbar preference control contrast: forwarding
        // style to `lock` leaves its dark icons cached after the cover is
        // removed, until another navigation transition refreshes the owner.
        // The later modal lock captures appearance independently below.
        public override var childForStatusBarHidden: UIViewController? { lock }

        public override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .clear
            addChild(lock)
            view.addSubview(lock.view)
            lock.view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                lock.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                lock.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                lock.view.topAnchor.constraint(equalTo: view.topAnchor),
                lock.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            ])
            lock.didMove(toParent: self)
            lock.visibilityChanged = { [weak self] in
                guard let self, let makeContent else { return }
                lock.update(content: makeContent(lock.isVisible))
            }
        }

        fileprivate func configure(isLocked: Bool, animatesUnlock: Bool, colorScheme: ColorScheme,
                                   onUnlocked: @escaping () -> Void,
                                   content: @escaping (Bool) -> AnyView) {
            requested = isLocked
            self.onUnlocked = onUnlocked
            makeContent = content
            loadViewIfNeeded()
            lock.updateAppearance(colorScheme)
            lock.update(content: content(lock.isVisible))
            if isLocked {
                if lock.isRevealing { lock.cancelReveal() }
            } else if !lock.isRevealing {
                lock.reveal(animated: animatesUnlock) { [weak self] in
                    guard let self, !requested else { return }
                    self.onUnlocked?()
                    UIAccessibility.post(notification: .screenChanged, argument: nil)
                }
            }
        }

        fileprivate func tearDown() {
            lock.visibilityChanged = nil
            onUnlocked = nil
            makeContent = nil
            lock.cancelReveal()
        }
    }
}

/// A non-dismissible, scene-local modal above the current presentation chain.
/// UIKit keeps the actual presenting views underneath `.overFullScreen`, so
/// the effect samples live content, including an already presented sheet.
public struct NativeLockPresentation<Content: View>: UIViewControllerRepresentable {
    private let isLocked: Bool
    private let animatesUnlock: Bool
    private let content: (Bool) -> Content

    public init(isLocked: Bool, animatesUnlock: Bool = true, @ViewBuilder content: @escaping (_ isVisible: Bool) -> Content) {
        self.isLocked = isLocked
        self.animatesUnlock = animatesUnlock
        self.content = content
    }

    public func makeUIViewController(context: Context) -> NativeLockAnchorController {
        NativeLockAnchorController()
    }

    public func updateUIViewController(_ controller: NativeLockAnchorController, context: Context) {
        let environment = context.environment
        controller.configure(isLocked: isLocked, animatesUnlock: animatesUnlock, colorScheme: environment.colorScheme) { visible in
            // Transfer public presentation values individually. Copying the
            // entire environment also transfers SwiftUI's internal host state,
            // which can suppress the new host's accessibility at cold launch.
            // App-defined environment values belong on the supplied content.
            AnyView(content(visible)
                .environment(\.locale, environment.locale)
                .environment(\.layoutDirection, environment.layoutDirection)
                .environment(\.dynamicTypeSize, environment.dynamicTypeSize)
                .environment(\.scenePhase, environment.scenePhase)
                .environment(\.colorScheme, environment.colorScheme)
                // The presented lock is a new interaction/accessibility scope.
                // A disabled/hidden presenting screen must not hide its keys.
                .environment(\.isEnabled, true)
                .accessibilityHidden(false))
        }
    }

    public static func dismantleUIViewController(_ controller: NativeLockAnchorController, coordinator: ()) {
        controller.tearDown()
    }
}

@MainActor
public final class NativeLockAnchorController: UIViewController {
    private weak var sceneWindow: UIWindow?
    private var lockController: NativeLockController?
    private var makeContent: ((Bool) -> AnyView)?
    private var colorScheme: ColorScheme = .light
    private var requested = false
    private var animatesUnlock = true
    private var retryScheduled = false
    private var presenting = false
    private var dismissing = false
    private var waitingForTransition = false
    private var tornDown = false

    public override func loadView() {
        let anchor = WindowAnchorView()
        anchor.isUserInteractionEnabled = false
        anchor.isAccessibilityElement = false
        anchor.didAttach = { [weak self] window in
            self?.sceneWindow = window
            self?.reconcile()
        }
        view = anchor
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if let window = view.window { sceneWindow = window }
        reconcile()
    }

    fileprivate func configure(isLocked: Bool, animatesUnlock: Bool, colorScheme: ColorScheme, content: @escaping (Bool) -> AnyView) {
        requested = isLocked
        self.animatesUnlock = animatesUnlock
        self.colorScheme = colorScheme
        makeContent = content
        if let controller = lockController {
            controller.updateAppearance(colorScheme)
            controller.update(content: content(controller.isVisible))
        }
        reconcile()
    }

    private func reconcile() {
        guard !tornDown else { return }
        if requested, let controller = lockController, controller.isRevealing {
            // A second background visit during the authenticated reveal must
            // restore the blur immediately, never finish an obsolete dismissal.
            controller.cancelReveal()
        }
        guard !presenting, !dismissing else { return }
        if let controller = lockController {
            if controller.isBeingDismissed {
                // A presenting sheet may be removed independently of the
                // authentication flow. Wait for UIKit to detach both modals.
                retryAfterTransition()
                return
            }
            if controller.presentingViewController == nil,
               controller.viewIfLoaded?.window == nil,
               !controller.isBeingPresented {
                discardDetachedLock(controller)
            }
        }
        if requested {
            guard lockController == nil, let window = sceneWindow,
                  let root = window.rootViewController, let makeContent else { return }
            var presenter = root
            while let next = presenter.presentedViewController { presenter = next }
            if let transition = presenter.transitionCoordinator {
                guard !waitingForTransition else { return }
                waitingForTransition = true
                let registered = transition.animate(alongsideTransition: nil) { [weak self] _ in
                    self?.waitingForTransition = false
                    self?.reconcile()
                }
                if registered { return }
                waitingForTransition = false
            }
            guard !presenter.isBeingDismissed, !presenter.isBeingPresented,
                  presenter.viewIfLoaded?.window != nil else {
                retryAfterTransition()
                return
            }
            window.endEditing(true)
            let controller = NativeLockController(content: makeContent(false), colorScheme: colorScheme)
            controller.visibilityChanged = { [weak self, weak controller] in
                guard let self, let controller, self.lockController === controller,
                      let makeContent = self.makeContent else { return }
                if controller.isVisible { self.presenting = false }
                controller.update(content: makeContent(controller.isVisible))
                if !controller.isVisible {
                    // Reconcile after disappearance finishes; the presenting
                    // chain still contains the old modal inside this callback.
                    self.retryAfterTransition()
                }
            }
            lockController = controller
            presenting = true
            controller.protectPresentingAccessibility(presenter.view)
            // No fade/slide on lock: content must be obscured in the first
            // frame, and changing an effect view's ancestor alpha breaks blur.
            presenter.present(controller, animated: false) { [weak self, weak controller] in
                guard let self, let controller, self.lockController === controller else { return }
                self.presenting = false
                self.reconcile()
            }
            // UIKit can reject a presentation during a simultaneous dismissal
            // without calling its completion. Do not leave `presenting` latched
            // forever with Home protected but no keypad on screen.
            DispatchQueue.main.async { [weak self, weak controller] in
                guard let self, let controller, self.lockController === controller,
                      self.presenting, controller.presentingViewController == nil,
                      controller.viewIfLoaded?.window == nil, !controller.isBeingPresented else { return }
                self.presenting = false
                self.discardDetachedLock(controller)
                self.retryAfterTransition()
            }
        } else if let controller = lockController, !controller.isRevealing {
            controller.reveal(animated: animatesUnlock) { [weak self, weak controller] in
                guard let self, let controller, self.lockController === controller,
                      !self.requested else { return }
                self.dismissing = true
                // Dismiss only OUR modal; the sheet and navigation beneath it
                // remain presented and retain their scroll/selection state.
                // Release status-bar ownership before detachment, then ask the
                // actual presenter to resolve its current native appearance.
                let presenter = controller.presentingViewController
                controller.modalPresentationCapturesStatusBarAppearance = false
                presenter?.setNeedsStatusBarAppearanceUpdate()
                controller.dismiss(animated: false) {
                    presenter?.setNeedsStatusBarAppearanceUpdate()
                    controller.restorePresentingAccessibility()
                    guard self.lockController === controller else { return }
                    self.dismissing = false
                    self.lockController = nil
                    self.reconcile()
                    if !self.requested {
                        UIAccessibility.post(notification: .screenChanged, argument: nil)
                    }
                }
            }
        }
    }

    private func discardDetachedLock(_ controller: NativeLockController) {
        guard lockController === controller else { return }
        // Stop old visibility/reveal callbacks before dropping the reference;
        // an obsolete completion must never dismiss a replacement lock.
        controller.visibilityChanged = nil
        controller.cancelReveal()
        controller.restorePresentingAccessibility()
        lockController = nil
    }

    private func retryAfterTransition() {
        guard !tornDown, !retryScheduled else { return }
        retryScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.retryScheduled = false
            if let controller = self.lockController,
               controller.presentingViewController == nil, controller.viewIfLoaded?.window == nil,
               !controller.isBeingPresented, !controller.isBeingDismissed {
                // External dismissal can interrupt a presentation before its
                // completion. Actual detachment also releases that pending work.
                self.presenting = false
                self.dismissing = false
            }
            self.reconcile()
        }
    }

    fileprivate func tearDown() {
        tornDown = true
        lockController?.visibilityChanged = nil
        lockController?.cancelReveal()
        lockController?.restorePresentingAccessibility()
        lockController?.dismiss(animated: false)
        lockController = nil
        makeContent = nil
    }
}

private final class WindowAnchorView: UIView {
    var didAttach: ((UIWindow) -> Void)?
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if let window { didAttach?(window) }
    }
}

@MainActor
private final class NativeLockController: UIViewController {
    private let backdrop = UIVisualEffectView()
    private let shade = UIView()
    private let host: UIHostingController<AnyView>
    private var revealAnimator: UIViewPropertyAnimator?
    private var revealCompletion: (() -> Void)?
    private var revealState = LockRevealState()
    private var animatesReveal = true
    private weak var protectedView: UIView?
    private var originalAccessibilityHidden = false
    private(set) var isVisible = false
    var isRevealing: Bool { revealState.isRevealing }
    var visibilityChanged: (() -> Void)?

    init(content: AnyView, colorScheme: ColorScheme) {
        host = UIHostingController(rootView: content)
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalPresentationCapturesStatusBarAppearance = true
        isModalInPresentation = true
        updateAppearance(colorScheme)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(content:)") }

    override var prefersStatusBarHidden: Bool { false }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .portrait }
    override var shouldAutorotate: Bool { false }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.accessibilityViewIsModal = true
        backdrop.accessibilityIdentifier = "wallet.lock.liveBlur"
        view.addSubview(backdrop)
        backdrop.contentView.addSubview(shade)
        addChild(host)
        host.view.backgroundColor = .clear
        backdrop.contentView.addSubview(host.view)
        host.didMove(toParent: self)
        for (child, parent) in [(backdrop, view!), (shade, backdrop.contentView), (host.view!, backdrop.contentView)] {
            child.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                child.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
                child.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
                child.topAnchor.constraint(equalTo: parent.topAnchor),
                child.bottomAnchor.constraint(equalTo: parent.bottomAnchor)
            ])
        }
        applyBackdrop()
        NotificationCenter.default.addObserver(self, selector: #selector(accessibilityChanged),
            name: UIAccessibility.reduceTransparencyStatusDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(accessibilityChanged),
            name: UIAccessibility.darkerSystemColorsStatusDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(sceneActivated(_:)),
            name: UIScene.didActivateNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(sceneActivated(_:)),
            name: UIScene.willEnterForegroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(sceneBackgrounded(_:)),
            name: UIScene.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(sceneBackgrounded(_:)),
            name: UIScene.didDisconnectNotification, object: nil)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isVisible = true
        visibilityChanged?()
        UIAccessibility.post(notification: .screenChanged, argument: nil)
        startRevealIfReady()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        isVisible = false
        suspendReveal()
        visibilityChanged?()
    }

    func update(content: AnyView) { host.rootView = content }

    func updateAppearance(_ colorScheme: ColorScheme) {
        let style: UIUserInterfaceStyle = colorScheme == .dark ? .dark : .light
        guard overrideUserInterfaceStyle != style else { return }
        // Match the scene's effective preference, without changing the window
        // or the screen/sheet retained beneath this modal.
        overrideUserInterfaceStyle = style
        if isViewLoaded, !isRevealing { applyBackdrop() }
        setNeedsStatusBarAppearanceUpdate()
    }

    func protectPresentingAccessibility(_ presentingView: UIView) {
        protectedView = presentingView
        originalAccessibilityHidden = presentingView.accessibilityElementsHidden
        // Shield only the existing UIKit view, outside the modal's own hosting
        // controller and accessibility scope.
        presentingView.accessibilityElementsHidden = true
    }

    func restorePresentingAccessibility() {
        protectedView?.accessibilityElementsHidden = originalAccessibilityHidden
        protectedView = nil
    }

    @objc private func accessibilityChanged() {
        guard !isRevealing else { return }
        applyBackdrop()
    }

    private func applyBackdrop() {
        let opaque = UIAccessibility.isReduceTransparencyEnabled
        backdrop.effect = opaque ? nil : UIBlurEffect(style: .systemUltraThinMaterial)
        backdrop.backgroundColor = opaque ? .systemBackground : .clear
        let tint: UIColor = overrideUserInterfaceStyle == .dark ? .black : .white
        shade.backgroundColor = tint.withAlphaComponent(UIAccessibility.isDarkerSystemColorsEnabled ? 0.36 : 0.2)
    }

    func reveal(animated: Bool, completion: @escaping () -> Void) {
        guard !isRevealing else { return }
        animatesReveal = animated
        revealState.request()
        revealCompletion = completion
        host.view.isUserInteractionEnabled = false
        // Keep isVisible true until disappearance: reporting disappearance now
        // resets SwiftUI's passcode layout before its native fade can begin.
        startRevealIfReady()
    }

    @objc private func sceneActivated(_ notification: Notification) {
        guard let scene = notification.object as? UIScene,
              scene === view.window?.windowScene else { return }
        startRevealIfReady()
    }

    @objc private func sceneBackgrounded(_ notification: Notification) {
        guard let scene = notification.object as? UIScene,
              scene === view.window?.windowScene else { return }
        suspendReveal()
    }

    private func suspendReveal() {
        guard revealState.phase == .animating else { return }
        // Suspend only when actually offscreen, never for Face ID's transient
        // foreground-inactive state. The session's background lock also cancels
        // authentication and invalidates this reveal's completion revision.
        revealState.suspend()
        stopRevealAnimation()
    }

    private func startRevealIfReady() {
        let activation = view.window?.windowScene?.activationState
        let isForeground = activation == .foregroundActive || activation == .foregroundInactive
        guard let revision = revealState.begin(
            isForeground: isForeground,
            isVisible: isVisible && view.window != nil) else { return }
        if !animatesReveal {
            // Leave the current SwiftUI update before removing its cover. No
            // timer, animation completion or scene-activation event is awaited.
            DispatchQueue.main.async { [weak self] in self?.finishReveal(revision: revision) }
            return
        }
        view.layoutIfNeeded()
        // A simple UIKit dissolve with no slide, scale, or spring. Animate the
        // effect itself: fading a UIVisualEffectView ancestor breaks live blur.
        // Reduce Motion retains a brief fade. Reduce Transparency fades its
        // opaque background color instead of cutting straight to the screen.
        // Start changing the first visible frame. A longer ease-in made the
        // authenticated keypad appear stuck before the dissolve became clear.
        let duration = UIAccessibility.isReduceMotionEnabled ? 0.12 : 0.18
        let animator = UIViewPropertyAnimator(duration: duration, curve: .easeOut) {
            self.backdrop.effect = nil
            self.backdrop.backgroundColor = .clear
            self.shade.backgroundColor = .clear
            self.host.view.alpha = 0
        }
        animator.addCompletion { [weak self] position in
            guard position == .end else { return }
            self?.finishReveal(revision: revision)
        }
        revealAnimator = animator
        animator.startAnimation()
    }

    private func finishReveal(revision: UInt) {
        guard revealState.complete(revision: revision) else { return }
        revealAnimator = nil
        let completion = revealCompletion
        revealCompletion = nil
        completion?()
    }

    func cancelReveal() {
        revealState.cancel()
        revealCompletion = nil
        stopRevealAnimation()
        host.view.isUserInteractionEnabled = true
        isVisible = view.window != nil
        visibilityChanged?()
    }

    private func stopRevealAnimation() {
        revealAnimator?.stopAnimation(true)
        revealAnimator = nil
        UIView.performWithoutAnimation {
            host.view.alpha = 1
            applyBackdrop()
        }
    }
}
