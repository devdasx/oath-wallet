import SwiftUI
import XCTest
@testable import HomeQuickActionsMenuFixture

@MainActor
final class HomeQuickActionsLayoutTests: XCTestCase {
    func testRootEndsAtSettingsAndHasNoPopoverArrow() async throws {
        try await withPresentation(FixturePresentation()) { presentation in
            try await self.waitUntil {
                self.find(UICollectionView.self, in: presentation.view)?.numberOfSections == 1
            }
            let list = try XCTUnwrap(self.find(UICollectionView.self, in: presentation.view))
            try await self.waitUntil { list.numberOfItems(inSection: 0) == 4 }
            try await self.waitUntil { presentation.transitionCoordinator == nil }
            try await Task.sleep(for: .milliseconds(300))
            let lastRow = try XCTUnwrap(list.layoutAttributesForItem(at: IndexPath(item: 3, section: 0)))
            let rowBottom = list.convert(lastRow.frame, to: presentation.view).maxY
            XCTAssertEqual(presentation.view.bounds.height - rowBottom, 0, accuracy: 1,
                           "Unused footer below the final Settings row")
            XCTAssertEqual(presentation.view.bounds.width, 340, accuracy: 1)
            let popover = try XCTUnwrap(presentation.popoverPresentationController)
            XCTAssertTrue(popover.sourceItem is UIBarButtonItem, "Popover did not resolve its real toolbar item")
            XCTAssertTrue(popover.permittedArrowDirections.isEmpty)
            XCTAssertTrue(popover.arrowDirection.isEmpty)
            XCTAssertNil(self.find(UINavigationController.self, in: presentation),
                         "The options must remain independent of the Home navigation stack")
        }
    }

    func testTopToolbarResolvesNativeSourceItem() async throws {
        try await withPresentation(FixturePresentation(topAnchor: true)) { presentation in
            let popover = try XCTUnwrap(presentation.popoverPresentationController)
            XCTAssertTrue(popover.sourceItem is UIBarButtonItem,
                          "Top toolbar fell back to a view anchor: \(String(describing: popover.sourceItem))")
            try await self.waitUntil { presentation.transitionCoordinator == nil }
            XCTAssertEqual(presentation.view.bounds.width, 340, accuracy: 1)
        }
    }

    func testTopAndBottomToolbarsUseMatchingAnimatedTransitions() async throws {
        var openingDurations: [TimeInterval] = []
        var closingDurations: [TimeInterval] = []
        for topAnchor in [false, true] {
            let lifecycle = PresentationState()
            try await withPresentation(FixturePresentation(topAnchor: topAnchor, lifecycle: lifecycle)) { presentation in
                let popover = try XCTUnwrap(presentation.popoverPresentationController)
                let item = try XCTUnwrap(popover.sourceItem as? UIBarButtonItem)
                try await self.waitUntil { presentation.view.window != nil }
                let opening = try XCTUnwrap(presentation.transitionCoordinator)
                XCTAssertTrue(opening.isAnimated)
                XCTAssertGreaterThan(opening.transitionDuration, 0)
                openingDurations.append(opening.transitionDuration)
                try await self.waitUntil { presentation.transitionCoordinator == nil }
                XCTAssertEqual(presentation.view.bounds.width, 340, accuracy: 1)
                let window = try XCTUnwrap(presentation.view.window)
                let sourceFrame = try XCTUnwrap(item.frame(in: window))
                XCTAssertGreaterThan(sourceFrame.width, 0)
                if topAnchor {
                    XCTAssertLessThan(sourceFrame.midY, window.bounds.midY)
                } else {
                    XCTAssertGreaterThan(sourceFrame.midY, window.bounds.midY)
                }
                lifecycle.isPresented = false
                try await self.waitUntil { presentation.isBeingDismissed }
                let closing = try XCTUnwrap(presentation.transitionCoordinator)
                XCTAssertTrue(closing.isAnimated)
                XCTAssertGreaterThan(closing.transitionDuration, 0)
                closingDurations.append(closing.transitionDuration)
                try await self.waitUntil { lifecycle.dismissals == 1 }
                XCTAssertNil(presentation.presentingViewController)
                XCTAssertEqual(lifecycle.dismissals, 1)
                XCTAssertEqual(item.frame(in: window), sourceFrame,
                               "The options item must return to its original toolbar position")
            }
        }
        XCTAssertEqual(openingDurations[0], openingDurations[1], accuracy: 0.01)
        XCTAssertEqual(closingDurations[0], closingDurations[1], accuracy: 0.01)
    }

    func testEveryShippedRTLLanguageUsesNativeListDirection() async throws {
        for identifier in ["ar", "fa", "he", "sd", "ur"] {
            let locale = Locale(identifier: identifier + "@numbers=latn")
            let direction: LayoutDirection = locale.language.characterDirection == .rightToLeft
                ? .rightToLeft : .leftToRight
            try await withPresentation(FixturePresentation()
                .environment(\.locale, locale)
                .environment(\.layoutDirection, direction)) { presentation in
                    try await self.waitUntil {
                        self.find(UICollectionView.self, in: presentation.view)?
                            .cellForItem(at: IndexPath(item: 0, section: 0)) != nil
                    }
                    let list = try XCTUnwrap(self.find(UICollectionView.self, in: presentation.view))
                    let cell = try XCTUnwrap(list.cellForItem(at: IndexPath(item: 0, section: 0)))
                    XCTAssertEqual(cell.effectiveUserInterfaceLayoutDirection, .rightToLeft, identifier)
                }
        }
    }

    func testNativePopoverAnimatesBothDimensionsAndCanResizeBackImmediately() async throws {
        let size = ResizeState()
        try await withPresentation(ResizePresentation(size: size)) { presentation in
            try await self.waitUntil { presentation.transitionCoordinator == nil }
            try await self.waitUntil { abs(presentation.view.bounds.height - 280) < 1 }
            let initialSize = presentation.view.bounds.size
            size.expanded = true
            let expandedFrames = try await self.sampleSize(of: presentation)
            XCTAssertEqual(presentation.view.bounds.width, 380, accuracy: 1)
            XCTAssertEqual(presentation.view.bounds.height, 540, accuracy: 1)
            XCTAssertTrue(expandedFrames.contains { $0.width > 341 && $0.width < 379 },
                          "Width jumped instead of animating: \(expandedFrames)")
            XCTAssertTrue(expandedFrames.contains { $0.height > 281 && $0.height < 539 },
                          "Height jumped instead of animating: \(expandedFrames)")
            size.expanded = false
            let returnedFrames = try await self.sampleSize(of: presentation)
            XCTAssertTrue(returnedFrames.contains { $0.width > 341 && $0.width < 379 })
            XCTAssertEqual(presentation.view.bounds.width, initialSize.width, accuracy: 1)
            XCTAssertEqual(presentation.view.bounds.height, initialSize.height, accuracy: 1)

            size.expanded = true
            try await Task.sleep(for: .milliseconds(100))
            size.expanded = false
            _ = try await self.sampleSize(of: presentation)
            XCTAssertEqual(presentation.view.bounds.width, initialSize.width, accuracy: 1)
            XCTAssertEqual(presentation.view.bounds.height, initialSize.height, accuracy: 1)
        }
    }

    private func sampleSize(of presentation: UIViewController) async throws -> [CGSize] {
        var sizes: [CGSize] = []
        for _ in 0..<80 {
            sizes.append(presentation.view.layer.presentation()?.bounds.size ?? presentation.view.bounds.size)
            try await Task.sleep(for: .milliseconds(10))
        }
        return sizes
    }

    private func withPresentation<Content: View>(
        _ content: Content, verify: (UIViewController) async throws -> Void
    ) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: content)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKey()
        }
        try await waitUntil { host.presentedViewController != nil }
        let presentation = try XCTUnwrap(host.presentedViewController)
        try await verify(presentation)
    }

    private func waitUntil(_ ready: () -> Bool) async throws {
        for _ in 0..<200 {
            if ready() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Native presentation did not settle")
    }

    private func find<T: UIViewController>(_ type: T.Type, in controller: UIViewController) -> T? {
        if let match = controller as? T { return match }
        return controller.children.lazy.compactMap { self.find(type, in: $0) }.first
    }

    private func find<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        return view.subviews.lazy.compactMap { self.find(type, in: $0) }.first
    }
}

private struct FixturePresentation: View {
    var topAnchor = false
    var lifecycle: PresentationState? = nil
    @Environment(\.locale) private var locale
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var isPresented = false
    @State private var currencies: [SettingsCurrency] = []
    @State private var settings = WalletSettingsStore()

    var body: some View {
        NavigationStack {
            Color.clear
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {} label: { Image(systemName: "plus") }
                    }
                    if #available(iOS 26.0, *) {
                        ToolbarSpacer(.fixed, placement: .topBarTrailing)
                    }
                    ToolbarItem(placement: topAnchor ? .topBarTrailing : .bottomBar) {
                        Button {} label: {
                            Image(systemName: "gearshape.2")
                                .font(.subheadline.weight(.semibold))
                        }
                        .task {
                            let snapshot = await FXRatesClient.shared.cachedSnapshot() ?? .baseCurrencyFallback
                            currencies = SettingsCurrencyCatalog.currencies(from: snapshot, locale: locale)
                            if let lifecycle { lifecycle.isPresented = true }
                            else { isPresented = true }
                        }
                        .background {
                            WalletHomeQuickActionsPopover(
                                isPresented: lifecycle.map { state in
                                    Binding(get: { state.isPresented }, set: { state.isPresented = $0 })
                                } ?? $isPresented,
                                onDismiss: { lifecycle?.dismissals += 1 }
                            ) {
                                WalletHomeQuickActionsFlow(initialCurrencies: currencies, onSelect: { _ in }, onCurrencySelected: {})
                                    .environment(settings)
                                    .environment(\.locale, locale)
                                    .environment(\.layoutDirection, layoutDirection)
                            }
                        }
                    }
                }
        }
    }

}

@MainActor @Observable
private final class ResizeState {
    var expanded = false
}

/// Exercises the production presentation bridge separately from content changes,
/// so a passing navigation test cannot conceal an instantaneous outer-frame jump.
private struct ResizePresentation: View {
    let size: ResizeState
    @State private var isPresented = false

    var body: some View {
        Color.clear
            .task { isPresented = true }
            .background {
                WalletHomeQuickActionsPopover(isPresented: $isPresented, onDismiss: {}) {
                    Color.clear.frame(
                        minWidth: 0, idealWidth: size.expanded ? 380 : 340, maxWidth: 420,
                        minHeight: 0, idealHeight: size.expanded ? 540 : 280, maxHeight: 620
                    )
                }
            }
    }
}

@MainActor @Observable
private final class PresentationState {
    var isPresented = false
    var dismissals = 0
}
