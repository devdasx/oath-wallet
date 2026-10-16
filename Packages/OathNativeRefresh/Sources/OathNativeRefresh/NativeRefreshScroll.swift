import SwiftUI
import UIKit

public enum NativeRefreshFeedback: Sendable { case started, succeeded, failed }

/// A native List keeps content hit testing aligned with UIRefreshControl's
/// inset during refresh. Supply long collections as direct ForEach rows so the
/// system can reuse cells; do not put them in one enclosing stack.
public struct NativeRefreshScroll<Content: View>: View {
    @State private var attachmentOwner = AttachmentOwner()
    private let identifier: String
    private let tint: UIColor
    private let indicator: NativeRefreshIndicator
    private let labels: NativeRefreshLabels
    private let isEnabled: Bool
    private let refreshIdentity: String?
    private let action: @MainActor @Sendable () async throws -> Void
    private let onFailure: @MainActor () -> Void
    private let onScroll: @MainActor (CGFloat) -> Void
    private let feedback: @MainActor (NativeRefreshFeedback) -> Void
    private let content: Content

    public init(identifier: String, tint: UIColor,
                indicator: NativeRefreshIndicator = .system,
                labels: NativeRefreshLabels = .english,
                isEnabled: Bool = true, refreshIdentity: String? = nil,
                action: @escaping @MainActor @Sendable () async throws -> Void,
                onFailure: @escaping @MainActor () -> Void,
                onScroll: @escaping @MainActor (CGFloat) -> Void,
                feedback: @escaping @MainActor (NativeRefreshFeedback) -> Void = { _ in },
                @ViewBuilder content: () -> Content) {
        self.identifier = identifier
        self.tint = tint
        self.indicator = indicator
        self.labels = labels
        self.isEnabled = isEnabled
        self.refreshIdentity = refreshIdentity
        self.action = action
        self.onFailure = onFailure
        self.onScroll = onScroll
        self.feedback = feedback
        self.content = content()
    }

    public var body: some View {
        // ScrollView.refreshable shifts rendered content but leaves SwiftUI
        // button targets at the pre-refresh origin on affected iOS versions.
        // Native list cells move their content and interaction geometry together.
        List {
            content
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .listRowSpacing(0)
        .navigationLinkIndicatorVisibility(.hidden)
        .environment(\.defaultMinListRowHeight, 0)
        .contentMargins(.all, 0, for: .scrollContent)
        .scrollContentBackground(.hidden)
        .refreshable { await attachmentOwner.controller?.refreshFromSystem() }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.always, axes: .vertical)
        .scrollDismissesKeyboard(.interactively)
        .accessibilityIdentifier(identifier)
        .background(Attachment(owner: attachmentOwner, configure: configure))
    }

    private final class AttachmentOwner {
        weak var controller: Controller?
    }

    private struct Attachment: UIViewControllerRepresentable {
        let owner: AttachmentOwner
        let configure: @MainActor (Controller, EnvironmentValues) -> Void
        func makeUIViewController(context: Context) -> Controller {
            // UIKit objects are created once by the representable, not by each
            // transient SwiftUI View initializer during a balance update.
            let controller = Controller()
            owner.controller = controller
            configure(controller, context.environment)
            return controller
        }
        func updateUIViewController(_ controller: Controller, context: Context) {
            configure(controller, context.environment)
        }
        static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
            controller.detach()
        }
    }

    private func configure(_ controller: Controller, environment: EnvironmentValues) {
        controller.loadViewIfNeeded()
        controller.identifier = identifier
        controller.indicatorHost.view.accessibilityIdentifier = identifier + ".brand"
        controller.scroll.accessibilityIdentifier = identifier
        controller.control.accessibilityIdentifier = identifier + ".refresh"
        let enabled = isEnabled && environment.scenePhase == .active
        controller.requestedEnabled = enabled
        if controller.refreshIdentity != refreshIdentity || controller.indicator != indicator
            || (controller.enabled && !enabled) {
            controller.stop()
        }
        controller.refreshIdentity = refreshIdentity
        controller.indicator = indicator
        controller.enabled = enabled
        if controller.model.isActive != enabled { controller.model.isActive = enabled }
        if controller.model.labels != labels { controller.model.labels = labels }
        controller.tint = tint
        controller.control.tintColor = indicator == .system ? tint : .clear
        controller.control.isEnabled = controller.enabled
        controller.control.accessibilityElementsHidden = indicator != .system
        controller.indicatorHost.rootView = AnyView(BrandedRefreshIndicator(model: controller.model)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // This independent host must not inherit SwiftUI's private host
            // state. Only forward the public values used by the indicator.
            // Accessibility preferences are supplied by this host's window.
            .environment(\.locale, environment.locale)
            .environment(\.layoutDirection, environment.layoutDirection)
            .environment(\.colorScheme, environment.colorScheme))
        controller.scroll.accessibilityCustomActions = indicator == .oathLogo ? [
            UIAccessibilityCustomAction(name: labels.pull, target: controller,
                                       selector: #selector(Controller.accessibilityRefresh))
        ] : nil
        controller.action = action
        controller.onFailure = onFailure
        controller.onScroll = onScroll
        controller.feedback = feedback
        controller.attachIfPossible()
        controller.positionIndicator()
    }

    @MainActor public final class Controller: UIViewController {
        private weak var attachedScroll: UIScrollView?
        private let unattachedScroll = UIScrollView()
        fileprivate var scroll: UIScrollView { attachedScroll ?? unattachedScroll }
        private var offsetObservation: NSKeyValueObservation?
        private var restingTopInset: CGFloat?
        private let unattachedControl = UIRefreshControl()
        fileprivate var control: UIRefreshControl { scroll.refreshControl ?? unattachedControl }
        fileprivate var tint = UIColor.label
        fileprivate var identifier = ""
        fileprivate let indicatorHost = UIHostingController(rootView: AnyView(EmptyView()))
        fileprivate let model = RefreshIndicatorModel()
        fileprivate var indicator: NativeRefreshIndicator = .system
        fileprivate var enabled = true
        fileprivate var requestedEnabled = true
        fileprivate var refreshIdentity: String?
        fileprivate var action: (@MainActor @Sendable () async throws -> Void)?
        fileprivate var onFailure: (@MainActor () -> Void)?
        fileprivate var onScroll: (@MainActor (CGFloat) -> Void)?
        fileprivate var feedback: (@MainActor (NativeRefreshFeedback) -> Void)?
        private let presentation = RefreshPresentation()
        private var work: Task<Void, Never>?
        private var activeRequest: UUID?

        public override func loadView() {
            let anchor = RefreshScrollAnchor()
            anchor.attached = { [weak self] in self?.attachIfPossible() }
            view = anchor
        }

        public override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
            indicatorHost.safeAreaRegions = []
            indicatorHost.view.backgroundColor = .clear
            indicatorHost.view.isUserInteractionEnabled = false
            indicatorHost.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            indicatorHost.view.alpha = 0
        }

        fileprivate func attachIfPossible() {
            guard isViewLoaded, view.window != nil else { return }
            if let attachedScroll, attachedScroll.window === view.window {
                styleControl()
                return
            }
            var ancestor = view.superview
            while let candidate = ancestor, !(candidate is UIWindow) {
                if let target = findScroll(in: candidate) {
                    if attachedScroll === target {
                        styleControl()
                        return
                    }
                    let wasEnabled = enabled
                    detach()
                    enabled = wasEnabled
                    attachedScroll = target
                    restingTopInset = target.adjustedContentInset.top
                    var responder: UIResponder? = target
                    while let current = responder, !(current is UIViewController) { responder = current.next }
                    let owner = responder as? UIViewController
                    owner?.addChild(indicatorHost)
                    indicatorHost.didMove(toParent: owner)
                    presentation.attach(target)
                    styleControl()
                    // Observe public geometry; never replace SwiftUI's delegate
                    // or gesture recognizer, which own laziness and scrolling.
                    offsetObservation = target.observe(\.contentOffset, options: [.new]) { [weak self] scroll, _ in
                        MainActor.assumeIsolated { self?.scrollViewDidScroll(scroll) }
                    }
                    target.panGestureRecognizer.addTarget(self, action: #selector(panChanged))
                    return
                }
                ancestor = candidate.superview
            }
        }

        /// The anchor belongs to the viewport, never a reusable row. Resolve
        /// the refreshable scroll in the nearest owning view branch. A SwiftUI
        /// background anchor can have a different safe-area frame from List,
        /// so its frame is not used to reposition content or to test touches.
        private func findScroll(in candidate: UIView) -> UIScrollView? {
            if let scroll = candidate as? UIScrollView, !scroll.isHidden,
               scroll.window === view.window, scroll.refreshControl != nil,
               scroll.accessibilityIdentifier == nil || scroll.accessibilityIdentifier == identifier {
                return scroll
            }
            for child in candidate.subviews {
                if let scroll = findScroll(in: child) { return scroll }
            }
            return nil
        }

        fileprivate func detach() {
            stop()
            offsetObservation = nil
            if let target = attachedScroll {
                target.panGestureRecognizer.removeTarget(self, action: #selector(panChanged))
            }
            indicatorHost.willMove(toParent: nil)
            indicatorHost.view.removeFromSuperview()
            indicatorHost.removeFromParent()
            attachedScroll = nil
            restingTopInset = nil
        }

        @objc private func panChanged() { scrollViewDidScroll(scroll) }

        public override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            enabled = requestedEnabled
            if model.isActive != enabled { model.isActive = enabled }
            attachIfPossible()
            presentation.attach(scroll)
        }

        public override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            stop()
        }

        public override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            attachIfPossible()
            positionIndicator()
        }

        public func scrollViewDidScroll(_ scrollView: UIScrollView) {
            if activeRequest == nil && !control.isRefreshing && !model.cycle.isReturning {
                restingTopInset = scrollView.adjustedContentInset.top
            }
            let origin = -(scrollView.contentOffset.y + (restingTopInset ?? scrollView.adjustedContentInset.top))
            onScroll?(origin)
            guard indicator == .oathLogo else { return }
            var cycle = model.cycle
            cycle.pull(distance: origin, isDragging: scrollView.isDragging && enabled)
            if cycle != model.cycle { model.cycle = cycle }
            positionIndicator()
        }

        public func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            scrollViewDidScroll(scrollView)
        }

        fileprivate func positionIndicator() {
            guard isViewLoaded, let nativeControl = attachedScroll?.refreshControl else { return }
            // The logo is content of the real refresh control, not an overlay
            // positioned against the scroll viewport. UIKit owns its origin,
            // safe-area adjustment, reveal and collapse beneath navigation.
            if indicatorHost.view.superview !== nativeControl {
                nativeControl.addSubview(indicatorHost.view)
            }
            indicatorHost.view.frame = nativeControl.bounds
            let distance = max(0, -(scroll.contentOffset.y + (restingTopInset ?? scroll.adjustedContentInset.top)))
            indicatorHost.view.alpha = indicator == .oathLogo && model.cycle.phase != .idle
                ? (model.cycle.phase == .pulling ? min(1, distance / 24) : 1) : 0
        }

        fileprivate func stop() {
            enabled = false
            activeRequest = nil
            work?.cancel()
            work = nil
            presentation.detach()
            model.resetIfNeeded()
            if control.isRefreshing { control.endRefreshing() }
            positionIndicator()
        }

        private func styleControl() {
            scroll.accessibilityIdentifier = identifier
            control.accessibilityIdentifier = identifier + ".refresh"
            control.tintColor = indicator == .system ? tint : .clear
            control.isEnabled = enabled
            control.accessibilityElementsHidden = indicator != .system
            scroll.accessibilityCustomActions = indicator == .oathLogo ? [
                UIAccessibilityCustomAction(name: model.labels.pull, target: self,
                    selector: #selector(accessibilityRefresh))
            ] : nil
            positionIndicator()
        }

        fileprivate func refreshFromSystem() async {
            attachIfPossible()
            guard enabled else { control.endRefreshing(); return }
            // Only the native release/threshold event starts touch refresh.
            // Pull geometry fills the logo but never begins wallet work.
            if activeRequest == nil {
                if indicator == .oathLogo, !model.cycle.begin() {
                    // A threshold event during the result's return is not a
                    // new user request and must not pin the control open.
                    control.endRefreshing()
                    return
                }
                startRefresh()
            }
            await work?.value
        }

        @objc fileprivate func accessibilityRefresh() -> Bool {
            guard enabled, attachedScroll?.refreshControl != nil,
                  activeRequest == nil, model.cycle.begin() else { return false }
            startRefresh()
            // Only an explicit accessibility action needs programmatic reveal.
            // Touch gestures never write offsets or manually change insets.
            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x,
                y: -(restingTopInset ?? scroll.adjustedContentInset.top) - control.bounds.height), animated: true)
            return true
        }

        private func startRefresh() {
            guard enabled, activeRequest == nil, let action else { return }
            let request = UUID()
            activeRequest = request
            feedback?(.started)
            presentation.attach(scroll)
            let startedAt = CACurrentMediaTime()
            model.startedAt = .now
            if !control.isRefreshing { control.beginRefreshing() }
            positionIndicator()
            work = Task { [weak self] in
                guard let self else { return }
                let outcome = await RefreshAction.run(action: action,
                    isCurrent: { self.activeRequest == request })
                guard outcome != .cancelled else {
                    if activeRequest == request { stop() }
                    return
                }
                let failed = outcome == .failed
                guard !Task.isCancelled, activeRequest == request else { return }
                await presentation.finishPresentation(startedAt: startedAt)
                guard !Task.isCancelled, activeRequest == request else { return }
                if indicator == .oathLogo {
                    model.cycle.complete(succeeded: !failed)
                    feedback?(failed ? .failed : .succeeded)
                    UIAccessibility.post(notification: .announcement,
                                         argument: failed ? model.labels.failed : model.labels.succeeded)
                    await presentation.finishPresentation(startedAt: CACurrentMediaTime(), minimumDuration: 0.65)
                    guard !Task.isCancelled, activeRequest == request else { return }
                    model.cycle.returnToRest()
                } else {
                    feedback?(failed ? .failed : .succeeded)
                }
                control.endRefreshing()
                activeRequest = nil
                work = nil
                scrollViewDidScroll(scroll)
                if failed { onFailure?() }
            }
        }
    }
}

/// A background anchor affects neither content sizing nor hit testing.
private final class RefreshScrollAnchor: UIView {
    var attached: (() -> Void)?
    override func didMoveToWindow() { super.didMoveToWindow(); attached?() }
    override func didMoveToSuperview() { super.didMoveToSuperview(); attached?() }
}
