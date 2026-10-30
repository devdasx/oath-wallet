import SwiftUI
import UIKit

/// Measure intrinsic result content, never the expanding scroll viewport.
struct OathWCResultHeight: PreferenceKey {
    enum Part: Hashable { case message, identity }
    static var defaultValue: [Part: CGFloat] { [:] }
    static func reduce(value: inout [Part: CGFloat], nextValue: () -> [Part: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

extension View {
    func oathWCMeasureResult(_ part: OathWCResultHeight.Part) -> some View {
        background {
            GeometryReader { geometry in
                Color.clear.preference(key: OathWCResultHeight.self, value: [part: geometry.size.height])
            }
        }
    }
}

/// One native detent remains installed for the whole connection/request flow.
/// Reviews fill the sheet; receipts fit their content without a new presenter.
struct OathWCAdaptiveSheet: ViewModifier {
    let fitsResult: Bool
    @State private var measurements: [OathWCResultHeight.Part: CGFloat] = [:]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var resultHeight: CGFloat? {
        guard fitsResult, let message = measurements[.message], message > 0 else { return nil }
        let height = measurements.values.reduce(0, +)
        return height.isFinite && height > 0 ? height : nil
    }

    func body(content: Content) -> some View {
        content
            .onPreferenceChange(OathWCResultHeight.self) { measurements = $0 }
            .background {
                OathWCDetentAnchor(contentHeight: resultHeight, reduceMotion: reduceMotion)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
    }
}

private struct OathWCDetentAnchor: UIViewControllerRepresentable {
    let contentHeight: CGFloat?
    let reduceMotion: Bool

    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.contentHeight = contentHeight
        controller.reduceMotion = reduceMotion
        controller.scheduleUpdate()
    }

    @MainActor final class Controller: UIViewController {
        var contentHeight: CGFloat?
        var reduceMotion = false
        private weak var fittedSheet: UISheetPresentationController?
        private var resolvedHeight: CGFloat?
        private var scheduled = false
        private var appeared = false
        private let identifier = UISheetPresentationController.Detent.Identifier("oath.walletconnect.flow")

        override func loadView() {
            view = UIView()
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
        }
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            appeared = true
            scheduleUpdate()
        }
        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            scheduleUpdate()
        }
        override func viewSafeAreaInsetsDidChange() {
            super.viewSafeAreaInsetsDidChange()
            scheduleUpdate()
        }
        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            scheduleUpdate()
        }

        func scheduleUpdate() {
            guard !scheduled else { return }
            scheduled = true
            // Layout and SwiftUI preference changes can arrive together. Never
            // invalidate detents recursively from their resolver or layout.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scheduled = false
                self.updateDetent()
            }
        }

        private func updateDetent() {
            guard viewIfLoaded?.window != nil else { return }
            var ancestor = parent
            while let controller = ancestor {
                if controller.presentingViewController != nil,
                   let sheet = controller.presentationController as? UISheetPresentationController {
                    guard !controller.isBeingDismissed else { return }
                    // This anchor occupies the navigation content below its
                    // toolbar. The system adds the bottom safe area itself.
                    let topInset = max(0, view.convert(.zero, to: controller.view).y)
                    let scale = max(traitCollection.displayScale, 1)
                    let height = contentHeight.map { ceil(($0 + topInset) * scale) / scale }
                    let isNewSheet = fittedSheet !== sheet
                    guard isNewSheet || height != resolvedHeight else { return }
                    fittedSheet = sheet
                    resolvedHeight = height
                    let changes = {
                        if isNewSheet {
                            sheet.detents = [.custom(identifier: self.identifier) { [weak self] context in
                                min(self?.resolvedHeight ?? context.maximumDetentValue, context.maximumDetentValue)
                            }]
                            sheet.selectedDetentIdentifier = self.identifier
                            sheet.prefersScrollingExpandsWhenScrolledToEdge = false
                        } else {
                            sheet.invalidateDetents()
                        }
                    }
                    if appeared && !reduceMotion { sheet.animateChanges(changes) }
                    else { changes() }
                    return
                }
                ancestor = controller.parent
            }
        }
    }
}
