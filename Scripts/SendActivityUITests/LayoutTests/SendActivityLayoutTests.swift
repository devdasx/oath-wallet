import SwiftUI
import XCTest
@testable import SendActivityFixture

@MainActor final class SendActivityLayoutTests: XCTestCase {
    func testShortListUsesItsMeasuredContentHeightAndDisablesUnusedScrolling() async throws {
        let operations = (0..<2).map {
            SendOperation(database: WalletDatabase(), draft: SendDraft(recipient: "Recipient-\($0)", amount: "1"),
                          walletAddress: "fixture", nativeUnitUSDPrice: nil)
        }
        let window = try window {
            SendActivityExpandedCapsule(operations: operations, maximumHeight: 550,
                onOpen: { _ in }, onCollapse: {}, onDismissAll: {}, onDismissConfirmed: { _ in })
        }
        defer { window.isHidden = true; window.rootViewController = nil }
        let collection = try await list(in: window)
        try await Task.sleep(for: .milliseconds(300))
        let nativeHeight = collection.contentSize.height + collection.adjustedContentInset.top + collection.adjustedContentInset.bottom
        XCTAssertEqual(collection.bounds.height, nativeHeight, accuracy: 1,
                       "The capsule must size to native content instead of a row-height guess")
        XCTAssertFalse(collection.isScrollEnabled,
                       "A list that fits must leave its upward drag available to the capsule")
    }

    func testListPublishesScrollGeometry() async throws {
        var measurement: CGSize?
        let window = try window {
            List { Section { Text("First"); Text("Second") } }
                .listStyle(.plain)
                .contentMargins(.vertical, 0, for: .scrollContent)
                .onScrollGeometryChange(for: CGSize.self) { geometry in
                    CGSize(width: geometry.contentSize.height, height: geometry.containerSize.height)
                } action: { _, size in measurement = size }
                .frame(height: 200)
        }
        defer { window.isHidden = true; window.rootViewController = nil }
        _ = try await list(in: window)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNotNil(measurement, "Native List must publish geometry for adaptive capsule sizing")
    }

    func testPendingPopoverFitsNativeNavigationBarAndShortList() async throws {
        try await assertNativePopoverFits(transactionCount: 2)
    }

    func testSingleTransactionPopoverHasNoOuterContentPadding() async throws {
        try await assertNativePopoverFits(transactionCount: 1)
    }

    private func assertNativePopoverFits(transactionCount: Int) async throws {
        let operations = (0..<transactionCount).map {
            SendOperation(database: WalletDatabase(),
                draft: SendDraft(recipient: "Recipient-\($0)", amount: "1"),
                walletAddress: "fixture", nativeUnitUSDPrice: nil)
        }
        let pending = WalletPendingActivityStore()
        let window = try window {
            NavigationStack {
                Color.clear.toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        WalletPendingActivityToolbarButton(store: pending,
                            items: operations.map(WalletPendingActivityItem.operation),
                            maximumHeight: 480, onOpen: { _ in })
                    }
                }
            }
        }
        let owner = try XCTUnwrap(window.rootViewController)
        window.layoutIfNeeded()
        pending.isPresented = true
        defer {
            pending.isPresented = false
            owner.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
        }
        for _ in 0..<100 {
            if owner.presentedViewController != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let navigation = try XCTUnwrap(owner.presentedViewController as? UINavigationController)
        let collection = try await list(in: navigation.view)
        // Native popover morphing and preferred-size updates settle over
        // multiple layouts. Inspect the final geometry, not an animation frame.
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(100))
            let bar = navigation.navigationBar.convert(navigation.navigationBar.bounds, to: navigation.view)
            let viewport = collection.convert(collection.bounds, to: navigation.view)
            if abs(viewport.minY + collection.adjustedContentInset.top - bar.maxY) <= 1,
               abs(viewport.maxY - navigation.view.bounds.maxY) <= 1,
               !collection.isScrollEnabled { break }
        }
        let host = try XCTUnwrap(navigation.topViewController)
        let barFrame = navigation.navigationBar.convert(navigation.navigationBar.bounds, to: navigation.view)
        let listFrame = collection.convert(collection.bounds, to: navigation.view)
        let cells = collection.visibleCells.sorted { $0.frame.minY < $1.frame.minY }
        let first = try XCTUnwrap(cells.first)
        let last = try XCTUnwrap(cells.last)
        let cellFrame = first.convert(first.bounds, to: navigation.view)
        let lastFrame = last.convert(last.bounds, to: navigation.view)
        let geometry = "bar=\(barFrame), list=\(listFrame), cell=\(cellFrame), host=\(host.view.frame), safeArea=\(host.view.safeAreaInsets), preferred=\(host.preferredContentSize), content=\(collection.contentSize), insets=\(collection.adjustedContentInset)"
        XCTAssertEqual(cellFrame.minY, barFrame.maxY, accuracy: 1, geometry)
        XCTAssertEqual(cellFrame.minY, listFrame.minY + collection.adjustedContentInset.top, accuracy: 1, geometry)
        XCTAssertEqual(lastFrame.maxY, listFrame.maxY, accuracy: 1, geometry)
        XCTAssertEqual(listFrame.maxY, navigation.view.bounds.maxY, accuracy: 1, geometry)
        XCTAssertFalse(collection.isScrollEnabled, geometry)
    }

    private func window<Content: View>(@ViewBuilder content: () -> Content) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = UIHostingController(rootView: content())
        window.makeKeyAndVisible()
        return window
    }

    private func list(in view: UIView) async throws -> UICollectionView {
        for _ in 0..<100 {
            view.layoutIfNeeded()
            if let list = collection(in: view), list.numberOfSections > 0 { return list }
            try await Task.sleep(for: .milliseconds(20))
        }
        return try XCTUnwrap(collection(in: view))
    }

    private func collection(in view: UIView) -> UICollectionView? {
        if let list = view as? UICollectionView { return list }
        for child in view.subviews {
            if let found = collection(in: child) { return found }
        }
        return nil
    }
}
