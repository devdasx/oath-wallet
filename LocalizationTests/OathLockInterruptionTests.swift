import XCTest
import SwiftUI
import OathNativeLock
@testable import OathAtmosphere

/// Reproduce a presenting sheet disappearing during a background lock. This
/// is UIKit presentation behavior and cannot be checked with a host-only test.
@MainActor final class OathLockInterruptionTests: XCTestCase {
    @Observable final class Model {
        var locked = false
        var showsSheet = false
        var closeSheet: (() -> Void)?
    }

    private struct Root: View {
        let model: Model
        var body: some View {
            Color.gray.overlay { Text("Public test home") }
                .sheet(isPresented: Binding(get: { model.showsSheet }, set: { model.showsSheet = $0 })) {
                    Sheet(model: model)
                }
                .disabled(model.locked)
                .accessibilityHidden(model.locked)
                .background {
                    NativeLockPresentation(isLocked: model.locked) { _ in
                        Text("Fixture passcode").accessibilityIdentifier("fixture.lock")
                    }
                }
        }
    }

    private struct Sheet: View {
        let model: Model
        @Environment(\.dismiss) private var dismiss
        var body: some View {
            OathContentSizedSheet(contentID: "lock.interruption", navigation: .init(
                strings: OathLocalizer(.english), title: .receive, backIdentifier: "fixture.back",
                onBack: nil, onClose: { dismiss() })) {
                Text("Synthetic receive sheet").padding(40)
            }
            .onChange(of: model.locked, initial: true) { _, _ in model.closeSheet = { dismiss() } }
        }
    }

    /// Models UIKit refusing an in-flight presentation without completing it.
    private final class RejectingHost: UIHostingController<Root> {
        var rejectsNextPresentation = true
        override func present(_ controller: UIViewController, animated: Bool, completion: (() -> Void)? = nil) {
            if rejectsNextPresentation {
                rejectsNextPresentation = false
                return
            }
            super.present(controller, animated: animated, completion: completion)
        }
    }

    private final class MissingCompletionHost: UIHostingController<Root> {
        override func present(_ controller: UIViewController, animated: Bool, completion: (() -> Void)? = nil) {
            super.present(controller, animated: animated, completion: nil)
        }
    }

    private func withWindow(root: UIViewController, run: (UIWindow) async throws -> Void) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        try await waitUntil("The scene root is attached") { root.viewIfLoaded?.window === window }
        try await run(window)
    }

    func testLockRecoversWhenItsPresentingSheetIsDismissed() async throws {
        let model = Model()
        let root = UIHostingController(rootView: Root(model: model))
        try await withWindow(root: root) { window in
            let sheet = UIViewController()
            sheet.modalPresentationStyle = .pageSheet
            root.present(sheet, animated: false)
            try await waitUntil("The existing sheet is visible") { sheet.viewIfLoaded?.window === window }
            model.locked = true
            try await waitUntil("The lock is presented above the sheet") {
                sheet.presentedViewController?.viewIfLoaded?.window === window
            }
            let firstLock = try XCTUnwrap(sheet.presentedViewController)

            // A SwiftUI navigation pop removes the asset-owned Receive sheet and
            // every UIKit presentation above it, without authenticating the user.
            root.dismiss(animated: false)
            try await waitUntil("The old lock has detached") { firstLock.viewIfLoaded?.window == nil }
            try await waitUntil("A locked scene must present a new usable lock after an external dismissal") {
                guard let current = root.presentedViewController else { return false }
                return current !== sheet && current !== firstLock && current.viewIfLoaded?.window === window
            }
            XCTAssertTrue(model.locked, "Presentation recovery must never authenticate the session")
            XCTAssertFalse(sheet.view.accessibilityElementsHidden, "The removed sheet's accessibility protection is restored")
            XCTAssertTrue(root.view.accessibilityElementsHidden, "The replacement protects its new presenter")
            model.locked = false
            try await waitUntil("Authentication dismisses the replacement lock") { root.presentedViewController == nil }
            XCTAssertFalse(root.view.accessibilityElementsHidden)
        }
    }

    func testRejectedPresentationRetriesWithoutAnotherSwiftUIUpdate() async throws {
        let model = Model()
        let root = RejectingHost(rootView: Root(model: model))
        try await withWindow(root: root) { window in
            model.locked = true
            try await waitUntil("A rejected presentation must retry without a state change") {
                root.presentedViewController?.viewIfLoaded?.window === window
            }
            XCTAssertFalse(root.rejectsNextPresentation)
            XCTAssertTrue(model.locked)
            model.locked = false
            try await waitUntil("Authentication dismisses the recovered lock") { root.presentedViewController == nil }
            XCTAssertFalse(root.view.accessibilityElementsHidden)
        }
    }

    func testExternalDismissalAfterAuthenticationDoesNotRelock() async throws {
        let model = Model()
        let root = UIHostingController(rootView: Root(model: model))
        try await withWindow(root: root) { window in
            model.locked = true
            try await waitUntil("The initial lock is visible") {
                root.presentedViewController?.viewIfLoaded?.window === window
            }
            model.locked = false
            root.dismiss(animated: false)
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertNil(root.presentedViewController, "Recovery must respect completed authentication")
            XCTAssertFalse(root.view.accessibilityElementsHidden)
        }
    }

    func testVisibleLockCanUnlockWithoutPresentationCompletion() async throws {
        let model = Model()
        let root = MissingCompletionHost(rootView: Root(model: model))
        try await withWindow(root: root) { window in
            model.locked = true
            try await waitUntil("The lock is actually visible") {
                root.presentedViewController?.viewIfLoaded?.window === window
            }
            model.locked = false
            try await waitUntil("A visible lock must accept authentication without a presentation completion") {
                root.presentedViewController == nil
            }
            XCTAssertFalse(root.view.accessibilityElementsHidden)
        }
    }

    func testRetainedSwiftUISheetCanCloseAfterUnlocking() async throws {
        let model = Model()
        let root = UIHostingController(rootView: Root(model: model))
        try await withWindow(root: root) { window in
            model.showsSheet = true
            try await waitUntil("The SwiftUI sheet is visible") {
                root.presentedViewController?.viewIfLoaded?.window === window && model.closeSheet != nil
            }
            let sheet = try XCTUnwrap(root.presentedViewController)
            model.locked = true
            try await waitUntil("The sheet is covered by the lock") {
                sheet.presentedViewController?.viewIfLoaded?.window === window
            }
            model.locked = false
            try await waitUntil("Only the lock is dismissed") { sheet.presentedViewController == nil }
            try XCTUnwrap(model.closeSheet)()
            try await waitUntil("The original sheet's Close action still dismisses it") { root.presentedViewController == nil }
            XCTAssertFalse(model.showsSheet)
        }
    }

    private func waitUntil(_ message: String, _ predicate: @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail(message)
        throw NSError(domain: "OathLockInterruptionTests", code: 1)
    }
}
