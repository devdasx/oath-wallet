import SwiftUI
import UIKit
import OathDiagnostics

public enum NativeRefreshFeedback: Sendable { case pullStep, started, succeeded, failed, finished }

/// A native List keeps content hit testing aligned with UIRefreshControl's
/// inset during refresh. Supply long collections as direct ForEach rows so the
/// system can reuse cells; do not put them in one enclosing stack.
public struct NativeRefreshScroll<Content: View>: View {
    @State private var attachmentOwner = AttachmentOwner()
    private let identifier: String
    private let tint: UIColor
    private let indicator: NativeRefreshIndicator
    private let timing: NativeRefreshTiming
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
                timing: NativeRefreshTiming = .untilFinished,
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
        self.timing = timing
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
        controller.scroll.accessibilityIdentifier = identifier
        controller.control.accessibilityIdentifier = identifier + ".refresh"
        let enabled = isEnabled && environment.scenePhase == .active
        controller.requestedEnabled = enabled
        if controller.refreshIdentity != refreshIdentity || controller.indicator != indicator || controller.timing != timing
            || (controller.enabled && !enabled) {
            controller.stop()
        }
        controller.refreshIdentity = refreshIdentity
        if controller.indicator != indicator { controller.indicatorView.removeFromSuperview() }
        controller.indicator = indicator
        controller.indicatorView.accessibilityIdentifier = identifier + ".brand"
        controller.timing = timing
        controller.enabled = enabled
        if controller.model.isActive != enabled { controller.model.isActive = enabled }
        if controller.model.labels != labels { controller.model.labels = labels }
        controller.tint = tint
        controller.control.tintColor = indicator == .system ? tint : .clear
        controller.control.isEnabled = controller.enabled
        controller.control.accessibilityElementsHidden = indicator != .system
        if indicator == .oathLogo {
            controller.logoIndicatorView.configuration = UIHostingConfiguration {
                AnyView(BrandedRefreshIndicator(model: controller.model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .environment(\.locale, environment.locale)
                    .environment(\.layoutDirection, environment.layoutDirection)
                    .environment(\.colorScheme, environment.colorScheme))
            }.margins(.all, 0)
        }
        controller.scroll.accessibilityCustomActions = indicator != .system ? [
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
        fileprivate let ringIndicatorView = ProgressRingRefreshIndicator(frame: .zero)
        fileprivate var indicatorView: UIView { indicator == .progressRing ? ringIndicatorView : logoIndicatorView }
        fileprivate lazy var logoIndicatorView: UIView & UIContentView = UIHostingConfiguration {
            AnyView(BrandedRefreshIndicator(model: self.model))
        }.margins(.all, 0).makeContentView()
        fileprivate let model = RefreshIndicatorModel()
        fileprivate var indicator: NativeRefreshIndicator = .system
        fileprivate var timing: NativeRefreshTiming = .untilFinished
        fileprivate var enabled = true
        fileprivate var requestedEnabled = true
        fileprivate var refreshIdentity: String?
        fileprivate var action: (@MainActor @Sendable () async throws -> Void)?
        fileprivate var onFailure: (@MainActor () -> Void)?
        fileprivate var onScroll: (@MainActor (CGFloat) -> Void)?
        fileprivate var feedback: (@MainActor (NativeRefreshFeedback) -> Void)?
        private let presentation = RefreshPresentation()
        private let backgroundRefresh = BackgroundRefresh()
        private var work: Task<Void, Never>?
        private var activeRequest: UUID?
        private var pullFeedback = RefreshPullFeedback()
        private var pullGesture = RefreshPullGesture()

        public override func loadView() {
            let anchor = RefreshScrollAnchor()
            anchor.attached = { [weak self] in self?.attachIfPossible() }
            view = anchor
        }

        public override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
            indicatorView.backgroundColor = .clear
            indicatorView.isUserInteractionEnabled = false
            logoIndicatorView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            indicatorView.alpha = 0
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
                    pullGesture.observe(position: target.contentOffset.y + target.adjustedContentInset.top,
                                        isPanning: false)
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
            indicatorView.removeFromSuperview()
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
            guard indicator != .system else { return }
            let panState = scrollView.panGestureRecognizer.state
            pullGesture.observe(position: -origin, isPanning: panState == .began || panState == .changed)
            let allowsPull = pullGesture.allowsRefresh
            var cycle = model.cycle
            if !allowsPull && (cycle.phase == .idle || cycle.phase == .pulling) {
                cycle.reset()
            } else {
                cycle.pull(distance: origin, isDragging: scrollView.isDragging && enabled && allowsPull)
            }
            // Gesture feedback is semantic; only the app's preference-aware driver
            // touches hardware. Bounce, loading and layout updates stay silent.
            if pullFeedback.update(progress: cycle.progress,
                                   isDragging: scrollView.isDragging,
                                   eligible: indicator == .progressRing && enabled && allowsPull
                                       && activeRequest == nil && !cycle.isReturning
                                       && (cycle.phase == .idle || cycle.phase == .pulling)) {
                feedback?(.pullStep)
            }
            // A filled ring is the activation threshold, not just decoration
            // ahead of UIKit's separate threshold. Keep all motion in UIKit.
            let startsRing = cycle.beginIfFilled(isDragging: scrollView.isDragging,
                eligible: indicator == .progressRing && enabled && allowsPull
                    && activeRequest == nil && action != nil)
            if cycle != model.cycle { model.cycle = cycle }
            if startsRing { startRefresh() }
            positionIndicator()
        }

        public func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            scrollViewDidScroll(scrollView)
        }

        fileprivate func positionIndicator() {
            guard isViewLoaded, let nativeControl = attachedScroll?.refreshControl else { return }
            // Keep the visual inside UIRefreshControl for its entire lifetime,
            // exactly like the logo. UIKit owns reveal, inset and return motion.
            if indicatorView.superview !== nativeControl {
                nativeControl.addSubview(indicatorView)
            }
            if indicator == .progressRing {
                ringIndicatorView.update(cycle: model.cycle, tint: tint, labels: model.labels,
                                         active: enabled, reduceMotion: UIAccessibility.isReduceMotionEnabled)
            }
            indicatorView.frame = nativeControl.bounds
            let distance = max(0, -(scroll.contentOffset.y + (restingTopInset ?? scroll.adjustedContentInset.top)))
            indicatorView.alpha = indicator != .system && model.cycle.phase != .idle
                ? (model.cycle.phase == .pulling || model.cycle.isReturning ? min(1, distance / 24) : 1) : 0
        }

        fileprivate func stop() {
            enabled = false
            activeRequest = nil
            work?.cancel()
            work = nil
            pullFeedback = RefreshPullFeedback()
            pullGesture = RefreshPullGesture()
            backgroundRefresh.cancel()
            presentation.detach()
            model.resetIfNeeded()
            if control.isRefreshing { control.endRefreshing() }
            positionIndicator()
        }

        private func styleControl() {
            // Re-seed after a screen returns or refresh is re-enabled without
            // requiring an offset change first. Never change a live pan's gate.
            let panState = scroll.panGestureRecognizer.state
            if panState != .began && panState != .changed {
                pullGesture.observe(position: scroll.contentOffset.y
                    + (restingTopInset ?? scroll.adjustedContentInset.top), isPanning: false)
            }
            scroll.accessibilityIdentifier = identifier
            control.accessibilityIdentifier = identifier + ".refresh"
            control.tintColor = indicator == .system ? tint : .clear
            control.isEnabled = enabled
            control.accessibilityElementsHidden = indicator != .system
            scroll.accessibilityCustomActions = indicator != .system ? [
                UIAccessibilityCustomAction(name: model.labels.pull, target: self,
                    selector: #selector(accessibilityRefresh))
            ] : nil
            positionIndicator()
        }

        fileprivate func refreshFromSystem() async {
            attachIfPossible()
            guard enabled else { control.endRefreshing(); return }
            // A later native callback joins the request already started by the
            // full ring; it must not run the action or activation feedback twice.
            if activeRequest == nil {
                // UIKit may emit its release event after a navigation swipe has
                // crossed the top. It must not bypass the gesture-start gate.
                if indicator != .system && !pullGesture.allowsRefresh {
                    control.endRefreshing()
                    return
                }
                if indicator != .system, !model.cycle.begin() {
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
                y: -(restingTopInset ?? scroll.adjustedContentInset.top)
                    - control.bounds.height), animated: true)
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
                if timing == .brief {
                    await presentBriefRefresh(request: request, action: action)
                    return
                }
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
                guard await presentResult(request: request, outcome: outcome) else { return }
                control.endRefreshing()
                activeRequest = nil
                work = nil
                scrollViewDidScroll(scroll)
                if failed { onFailure?() }
            }
        }

        private func presentResult(request: UUID, outcome: RefreshAction.Outcome?) async -> Bool {
            let failed = outcome == .failed
            let event: NativeRefreshFeedback = failed ? .failed : (outcome == nil ? .finished : .succeeded)
            if indicator != .system {
                if outcome == nil { model.cycle.acknowledge() }
                else { model.cycle.complete(succeeded: !failed) }
                positionIndicator()
                if indicator == .progressRing && !UIAccessibility.isReduceMotionEnabled {
                    await presentation.finishPresentation(startedAt: CACurrentMediaTime(),
                        minimumDuration: ProgressRingRefreshIndicator.transitionDuration)
                    guard !Task.isCancelled, activeRequest == request else { return false }
                }
                feedback?(event)
                // A timed check acknowledges the request, never announces that
                // data has finished updating when the provider is still running.
                UIAccessibility.post(notification: .announcement,
                    argument: failed ? model.labels.failed : (outcome == nil ? model.labels.refreshing : model.labels.succeeded))
                await presentation.finishPresentation(startedAt: CACurrentMediaTime(),
                    minimumDuration: indicator == .progressRing ? ProgressRingRefreshIndicator.resultHoldDuration : 0.65)
                guard !Task.isCancelled, activeRequest == request else { return false }
                model.cycle.returnToRest()
            } else {
                feedback?(event)
            }
            return true
        }

        private func presentBriefRefresh(request: UUID,
                                         action: @escaping @MainActor @Sendable () async throws -> Void) async {
            let outcome: RefreshAction.Outcome?
            do {
                outcome = try await backgroundRefresh.present(action: action, onCompletion: { [weak self] result in
                    // This callback can arrive after the animation is gone.
                    // RefreshAction still reports the original failure, and
                    // ownership cancellation suppresses obsolete callbacks.
                    if result == .failed { self?.onFailure?() }
                })
            } catch is CancellationError {
                // The presentation timer only throws for lifecycle cancellation.
                return
            } catch {
                OathDiagnostics.record(error, component: "OathNativeRefresh", operation: "briefPresentation")
                if activeRequest == request { stop() }
                return
            }
            guard !Task.isCancelled, activeRequest == request else { return }
            guard outcome != .cancelled else { stop(); return }
            // A pending action acknowledges this gesture at the fixed deadline;
            // the separately owned provider task continues and publishes data.
            guard await presentResult(request: request, outcome: outcome) else { return }
            control.endRefreshing()
            activeRequest = nil
            work = nil
            scrollViewDidScroll(scroll)
        }
    }
}

/// A background anchor affects neither content sizing nor hit testing.
private final class RefreshScrollAnchor: UIView {
    var attached: (() -> Void)?
    override func didMoveToWindow() { super.didMoveToWindow(); attached?() }
    override func didMoveToSuperview() { super.didMoveToSuperview(); attached?() }
}
