import SwiftUI
import UIKit

@MainActor protocol OathSheetNativeMeasuring: AnyObject {
    var fittingContentHeight: CGFloat { get }
    var onContentSizeChange: (() -> Void)? { get set }
}

/// A native navigation/list screen can occupy the same presentation as the
/// measured SwiftUI states, without nesting sheets or scroll views.
struct OathSheetNativeScreen {
    let id: String
    let make: @MainActor () -> UIViewController & OathSheetNativeMeasuring
    let update: @MainActor (UIViewController & OathSheetNativeMeasuring) -> Void
}

/// Content-driven sizing for a native sheet. UIKit resolves the available
/// height; the hosting view measures at the sheet's real width, not a device
/// model or a hard-coded row height. Overflow remains a native scroll view.
struct OathContentSizedSheet<Content: View>: UIViewControllerRepresentable {
    let contentID: AnyHashable
    var nativeScreen: OathSheetNativeScreen? = nil
    var avoidsKeyboard = false
    var navigation: OathSheetNavigationConfiguration? = nil
    /// Receipts use the same solid canvas as history at every sheet height.
    var opaqueBackground = false
    @ViewBuilder let content: () -> Content

    func makeUIViewController(context: Context) -> Controller {
        let autofocusPresentation = OathAutofocusPresentation()
        let controller = Controller(contentID: contentID,
            rootView: HostedContent(content: content(), environment: context.environment,
                                    autofocusPresentation: autofocusPresentation),
            autofocusPresentation: autofocusPresentation)
        controller.configureLanguage(context.environment.oathLanguage)
        controller.configureSurface(opaque: opaqueBackground)
        return controller
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        if controller.contentID != contentID {
            controller.beginContentLayout()
            controller.contentID = contentID
            controller.resetScrollOnNextLayout = true
        }
        controller.configureLanguage(context.environment.oathLanguage)
        var transaction = context.transaction
        if transaction.animation != nil {
            // Observe at the hosting root so transitions around the form (not
            // just animations inside it) also finish before entry focus.
            let presentation = controller.autofocusPresentation
            let token = presentation.begin()
            transaction.addAnimationCompletion(criteria: .removed) { [weak presentation] in
                Task { @MainActor in presentation?.end(token) }
            }
        }
        withTransaction(transaction) {
            controller.host.rootView = HostedContent(content: content(), environment: context.environment,
                                                     autofocusPresentation: controller.autofocusPresentation,
                                                     onContentSizeChange: { [weak controller] in
                // Child SwiftUI state (for example revealing recovery words)
                // can change size without updating this representable's inputs.
                // Schedule a new native fit instead of keeping the old detent.
                controller?.beginContentLayout()
                DispatchQueue.main.async { [weak controller] in controller?.view.setNeedsLayout() }
            })
        }
        controller.reduceMotion = context.environment.accessibilityReduceMotion
        controller.configureKeyboardAvoidance(avoidsKeyboard)
        controller.configureSurface(opaque: opaqueBackground)
        controller.configureNavigation(navigation)
        controller.setNativeScreen(nativeScreen)
        controller.view.setNeedsLayout()
    }

    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        controller.autofocusPresentation.invalidate()
    }

    struct HostedContent: View {
        let content: Content
        let environment: EnvironmentValues
        let autofocusPresentation: OathAutofocusPresentation
        var onContentSizeChange: (() -> Void)? = nil

        var body: some View {
            // A native presentation can reset layoutDirection to the device
            // direction while preserving the app's selected language. Reapply it
            // inside the hosting root, after copying the environment.
            // SwiftUI mirrors semantic leading/trailing layout and symbols;
            // descendants can still opt into LTR for addresses/recovery words.
            content
                .environment(\.oathAutofocusPresentation, autofocusPresentation)
                .oathLanguage(environment.oathLanguage)
                .environment(\.self, environment)
                .onGeometryChange(for: CGSize.self, of: { $0.size }) { _ in onContentSizeChange?() }
        }
    }

    final class Controller: UIViewController {
        let host: UIHostingController<HostedContent>
        let autofocusPresentation: OathAutofocusPresentation
        private var contentLayout: UUID?
        private let scrollView = UIScrollView()
        private let hostedScreen = UIViewController()
        private var navigationConfiguration: OathSheetNavigationConfiguration?
        // Keep a pressed control alive while QR/content/layout updates arrive.
        // Only its callback and labels change; replacing the bar item between
        // touch-down and touch-up can silently drop the user's Close/Back tap.
        private lazy var closeButton = OathSheetNavigationControls.close(strings: OathLocalizer(language)) { [weak self] in
            guard let configuration = self?.navigationConfiguration, configuration.actionsEnabled else { return }
            configuration.onClose()
        }
        private lazy var backButton = OathSheetNavigationControls.back(strings: OathLocalizer(language), identifier: "") { [weak self] in
            guard let configuration = self?.navigationConfiguration, configuration.actionsEnabled else { return }
            configuration.onBack?()
        }
        private let menuButton = UIBarButtonItem(image: UIImage(systemName: "ellipsis"), menu: nil)
        private var fullHeightConstraint: NSLayoutConstraint!
        private var keyboardHeightConstraint: NSLayoutConstraint!
        private lazy var hostedNavigation = UINavigationController(rootViewController: hostedScreen)
        private var nativeController: (UIViewController & OathSheetNativeMeasuring)?
        private var nativeID: String?
        private weak var fittedSheet: UISheetPresentationController?
        private weak var sheetSurface: UIView?
        private var maximumDetentHeight: CGFloat = 0
        private var contentHeight: CGFloat = 0
        private var measuredDetentHeight: CGFloat = 0
        private var updateScheduled = false
        private var appeared = false
        private var language = OathLanguage.english
        private var opaqueBackground = false
        var reduceMotion = false
        var contentID: AnyHashable
        var resetScrollOnNextLayout = false

        init(contentID: AnyHashable, rootView: HostedContent, autofocusPresentation: OathAutofocusPresentation) {
            self.contentID = contentID
            self.autofocusPresentation = autofocusPresentation
            host = UIHostingController(rootView: rootView)
            super.init(nibName: nil, bundle: nil)
            // The container accounts for safe areas once, through its scroll
            // view. Do not make the hosted content measure them a second time.
            host.safeAreaRegions = []
            beginContentLayout()
        }

        func beginContentLayout() {
            if contentLayout == nil { contentLayout = autofocusPresentation.begin() }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

        override func loadView() {
            view = UIView()
            view.backgroundColor = .clear
            hostedScreen.view.backgroundColor = .clear
            hostedScreen.view.addSubview(scrollView)
            scrollView.translatesAutoresizingMaskIntoConstraints = false
            fullHeightConstraint = scrollView.bottomAnchor.constraint(equalTo: hostedScreen.view.bottomAnchor)
            keyboardHeightConstraint = scrollView.bottomAnchor.constraint(equalTo: hostedScreen.view.keyboardLayoutGuide.topAnchor)
            NSLayoutConstraint.activate([
                scrollView.topAnchor.constraint(equalTo: hostedScreen.view.topAnchor),
                scrollView.leadingAnchor.constraint(equalTo: hostedScreen.view.leadingAnchor),
                scrollView.trailingAnchor.constraint(equalTo: hostedScreen.view.trailingAnchor),
                fullHeightConstraint
            ])
            scrollView.backgroundColor = .clear
            scrollView.alwaysBounceVertical = false
            scrollView.accessibilityIdentifier = "options.scrollContent"
            hostedScreen.addChild(host)
            scrollView.addSubview(host.view)
            host.view.backgroundColor = .clear
            host.didMove(toParent: hostedScreen)
            // A real navigation controller supplies exactly the same native
            // bar-item geometry as the language state, even in narrow sheets.
            addChild(hostedNavigation)
            hostedNavigation.view.frame = view.bounds
            hostedNavigation.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            hostedNavigation.view.backgroundColor = .clear
            hostedNavigation.isToolbarHidden = true
            view.addSubview(hostedNavigation.view)
            hostedNavigation.didMove(toParent: self)
        }

        func configureKeyboardAvoidance(_ enabled: Bool) {
            loadViewIfNeeded()
            // UIKit follows the actual software keyboard (or bottom safe area
            // with a hardware keyboard); no keyboard-height padding is guessed.
            if enabled {
                fullHeightConstraint.isActive = false
                keyboardHeightConstraint.isActive = true
            } else {
                keyboardHeightConstraint.isActive = false
                fullHeightConstraint.isActive = true
            }
            scrollView.keyboardDismissMode = enabled ? .interactive : .none
        }

        func configureLanguage(_ language: OathLanguage) {
            loadViewIfNeeded()
            self.language = language
            for controller in [self, hostedNavigation, hostedScreen, host] {
                OathLayoutDirection.apply(language, to: controller)
            }
            OathLayoutDirection.apply(language, to: hostedNavigation.navigationBar)
            OathLayoutDirection.apply(language, to: scrollView)
            if let nativeController { OathLayoutDirection.apply(language, to: nativeController) }
        }

        func configureNavigation(_ configuration: OathSheetNavigationConfiguration?) {
            loadViewIfNeeded()
            navigationConfiguration = configuration
            hostedNavigation.setNavigationBarHidden(configuration == nil, animated: false)
            guard let configuration else { return }
            let strings = configuration.strings
            OathSheetNavigationControls.configure(hostedNavigation.navigationBar, strings: strings)
            if opaqueBackground {
                let appearance = hostedNavigation.navigationBar.standardAppearance.copy()
                appearance.configureWithOpaqueBackground()
                appearance.backgroundColor = OathSurfaceColors.groupedCanvas
                appearance.shadowColor = .clear
                hostedNavigation.navigationBar.standardAppearance = appearance
                hostedNavigation.navigationBar.scrollEdgeAppearance = appearance
                hostedNavigation.navigationBar.compactAppearance = appearance
            }
            let item = hostedScreen.navigationItem
            item.title = strings.text(configuration.title)
            closeButton.accessibilityLabel = strings.text(.close)
            closeButton.accessibilityIdentifier = configuration.closeIdentifier
            menuButton.menu = configuration.trailingMenu
            menuButton.tintColor = .label
            menuButton.accessibilityLabel = strings.text(.moreOptions)
            menuButton.accessibilityIdentifier = "transaction.share"
            if #available(iOS 26.0, *) {
                let hidesBackground = opaqueBackground && !configuration.preservesNativeButtonBackground
                closeButton.hidesSharedBackground = hidesBackground
                backButton.hidesSharedBackground = hidesBackground
                menuButton.hidesSharedBackground = hidesBackground
            }
            backButton.accessibilityLabel = strings.text(configuration.backLabel)
            backButton.accessibilityIdentifier = configuration.backIdentifier
            let close = configuration.showsCloseButton ? closeButton : nil
            let left: UIBarButtonItem?
            let right: UIBarButtonItem?
            if configuration.closeOnLeadingEdgeAtRoot && configuration.onBack == nil {
                left = close
                right = nil
            } else {
                right = close
                left = configuration.onBack == nil ? nil : backButton
            }
            if item.leftBarButtonItem !== left { item.leftBarButtonItem = left }
            let rightItems = [right, configuration.trailingMenu == nil ? nil : menuButton].compactMap { $0 }
            if item.rightBarButtonItems != rightItems { item.rightBarButtonItems = rightItems }
            item.rightBarButtonItem?.isEnabled = configuration.actionsEnabled
            item.leftBarButtonItem?.isEnabled = configuration.actionsEnabled
        }

        func setNativeScreen(_ screen: OathSheetNativeScreen?) {
            loadViewIfNeeded()
            if nativeID != screen?.id {
                if let nativeController {
                    nativeController.onContentSizeChange = nil
                    nativeController.view.endEditing(true)
                    nativeController.willMove(toParent: nil)
                    nativeController.view.removeFromSuperview()
                    nativeController.removeFromParent()
                }
                nativeController = nil
                nativeID = screen?.id
                if let screen {
                    let controller = screen.make()
                    OathLayoutDirection.apply(language, to: controller)
                    nativeController = controller
                    addChild(controller)
                    controller.view.frame = view.bounds
                    controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                    view.addSubview(controller.view)
                    controller.didMove(toParent: self)
                    controller.onContentSizeChange = { [weak self] in
                        self?.view.setNeedsLayout()
                    }
                }
                hostedNavigation.view.isHidden = screen != nil
                resetScrollOnNextLayout = screen == nil
            }
            if let screen, let nativeController { screen.update(nativeController) }
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            // Resolve the first detent before the presentation animation.
            measureContent()
            configureSheet()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            appeared = true
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            measureContent()
            configureSheet()
            updateSheetCanvas()
            if resetScrollOnNextLayout {
                resetScrollOnNextLayout = false
                scrollView.setContentOffset(CGPoint(x: -scrollView.adjustedContentInset.left,
                                                    y: -scrollView.adjustedContentInset.top), animated: false)
            }
            if let token = contentLayout {
                contentLayout = nil
                autofocusPresentation.end(token)
            }
        }

        private func measureContent() {
            if let nativeController {
                nativeController.view.frame = view.bounds
                nativeController.view.layoutIfNeeded()
                updateContentHeight(nativeController.fittingContentHeight)
                return
            }
            hostedNavigation.view.frame = view.bounds
            hostedNavigation.view.layoutIfNeeded()
            let inset = scrollView.adjustedContentInset
            let width = scrollView.bounds.width - inset.left - inset.right
            guard width.isFinite, width > 0 else { return }
            let size = host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
            guard size.height.isFinite, size.height > 0 else { return }
            let scale = max(traitCollection.displayScale, 1)
            let height = ceil(size.height * scale) / scale
            host.view.frame = CGRect(x: 0, y: 0, width: width, height: height)
            scrollView.contentSize = CGSize(width: width, height: height)
            contentHeight = height
            updateContentHeight(height + inset.top)
        }

        private func updateContentHeight(_ detentHeight: CGFloat) {
            guard detentHeight.isFinite, detentHeight > 0 else { return }
            contentHeight = detentHeight
            let scale = max(traitCollection.displayScale, 1)
            guard abs(measuredDetentHeight - detentHeight) >= 1 / scale else { return }
            measuredDetentHeight = detentHeight
            // Never invalidate during the detent resolver or recursively in
            // layout. Coalesce the content/locale/type-size changes instead.
            scheduleDetentUpdate()
        }

        private func configureSheet() {
            guard fittedSheet == nil, contentHeight > 0 else { return }
            var ancestor: UIViewController? = parent
            while let controller = ancestor {
                if controller.presentingViewController != nil,
                   let sheet = controller.presentationController as? UISheetPresentationController {
                    fittedSheet = sheet
                    let identifier = UISheetPresentationController.Detent.Identifier("oath.content")
                    sheet.detents = [.custom(identifier: identifier) { [weak self] context in
                        guard let self else { return nil }
                        // Read the system's available height; never guess from
                        // a device model, orientation, or fixed safe-area inset.
                        self.maximumDetentHeight = context.maximumDetentValue
                        // The system adds its bottom safe area to detents.
                        // Include only the top inset (grabber clearance) here.
                        return min(self.measuredDetentHeight, context.maximumDetentValue)
                    }]
                    sheet.selectedDetentIdentifier = identifier
                    sheet.prefersGrabberVisible = true
                    sheet.prefersScrollingExpandsWhenScrolledToEdge = false
                    sheet.prefersEdgeAttachedInCompactHeight = true
                    installSheetCanvas(in: sheet)
                    return
                }
                ancestor = controller.parent
            }
        }

        private func installSheetCanvas(in sheet: UISheetPresentationController) {
            // Cover the presentation's entire content surface, including the
            // grabber and bottom safe area, not just the inner scroll view.
            // Color the public hosting surface itself: adding a subview to a
            // UIHostingView can paint above SwiftUI's layer-rendered content.
            // UIKit still owns the native glass, corners and transitions.
            sheetSurface = sheet.presentedViewController.view
            updateSheetCanvas()
        }

        private func updateSheetCanvas() {
            guard let surface = sheetSurface else { return }
            if opaqueBackground {
                surface.backgroundColor = OathSurfaceColors.groupedCanvas
                return
            }
            guard maximumDetentHeight > 0 else { return }
            let height = surface.bounds.height - surface.safeAreaInsets.bottom
            // Partial sheets keep the system Liquid Glass. Blend onto the
            // grouped canvas only as the real presentation reaches full height.
            // This also follows interactive resizing and accessibility text.
            let progress = min(1, max(0, (height / maximumDetentHeight - 0.8) / 0.2))
            let opacity = progress * progress * (3 - 2 * progress)
            surface.backgroundColor = OathSurfaceColors.sheet.withAlphaComponent(opacity)
        }

        func configureSurface(opaque: Bool) {
            loadViewIfNeeded()
            opaqueBackground = opaque
            view.backgroundColor = opaque ? OathSurfaceColors.groupedCanvas : .clear
            hostedScreen.view.backgroundColor = opaque ? OathSurfaceColors.groupedCanvas : .clear
            updateSheetCanvas()
        }

        private func scheduleDetentUpdate() {
            guard !updateScheduled else { return }
            updateScheduled = true
            let token = autofocusPresentation.begin()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.updateScheduled = false
                guard let sheet = self.fittedSheet else {
                    self.autofocusPresentation.end(token)
                    return
                }
                if self.appeared && !self.reduceMotion {
                    // Keep autofocus blocked until the native resize animation
                    // finishes, including a password form inserted in-place.
                    CATransaction.begin()
                    CATransaction.setCompletionBlock { [weak presentation = self.autofocusPresentation] in
                        Task { @MainActor in presentation?.end(token) }
                    }
                    sheet.animateChanges { sheet.invalidateDetents() }
                    CATransaction.commit()
                } else {
                    sheet.invalidateDetents()
                    self.autofocusPresentation.end(token)
                }
            }
        }
    }
}
