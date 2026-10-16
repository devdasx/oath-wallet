import XCTest
import SwiftUI
@testable import OathAtmosphere

@MainActor final class OathAutofocusTests: XCTestCase {
    @Observable final class Fixture {
        var showsForm = false
        var onFocus: () -> Void = {}
    }

    private struct Form: View {
        let fixture: Fixture
        @State private var text = ""
        @State private var focused = false
        var body: some View {
            VStack(spacing: 24) {
                Text("Synthetic keyboard fixture")
                OathTextInput(text: $text, focused: $focused, title: "Name", identifier: "autofocus.fixture")
                Color.clear.frame(height: 200)
            }
            .padding(24)
            .oathAutofocus {
                fixture.onFocus()
                focused = true
            }
        }
    }

    private struct Sheet: View {
        let fixture: Fixture
        var body: some View {
            OathContentSizedSheet(contentID: fixture.showsForm, avoidsKeyboard: true) {
                Group {
                    if fixture.showsForm { Form(fixture: fixture) }
                    else { Text("Synthetic compact sheet").padding(24) }
                }
                .fixedSize(horizontal: false, vertical: true)
                .transition(.blurReplace)
            }
            .animation(.smooth, value: fixture.showsForm)
        }
    }

    private final class TrackedHost<Content: View>: UIHostingController<Content> {
        var appeared = false
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            appeared = true
        }
    }

    func testAnimatedPushFinishesBeforeAutomaticFocus() async throws {
        let (window, previous) = try window()
        let navigation = UINavigationController(rootViewController: UIViewController())
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        await settle()
        let fixture = Fixture()
        let host = TrackedHost(rootView: Form(fixture: fixture).environment(\.scenePhase, .active))
        var requests = 0
        fixture.onFocus = { [weak host] in
            requests += 1
            XCTAssertTrue(host?.appeared == true, "Focus must follow native push completion")
            if let view = host?.view { self.assertGeometrySettled(view) }
        }
        navigation.pushViewController(host, animated: true)
        XCTAssertEqual(requests, 0)
        try await waitUntil { Self.field(in: host.view)?.isFirstResponder == true }
        XCTAssertEqual(requests, 1)
        host.view.endEditing(true)
        await settle()
        XCTAssertEqual(requests, 1, "Dismissing the keyboard must not trigger autofocus again")
    }

    func testVisibleSheetFinishesResizingBeforeAutomaticFocus() async throws {
        let (window, previous) = try window()
        let root = UIViewController()
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer { root.dismiss(animated: false); window.isHidden = true; previous?.makeKey() }
        await settle()
        let fixture = Fixture()
        let host = TrackedHost(rootView: Sheet(fixture: fixture).environment(\.scenePhase, .active))
        host.modalPresentationStyle = .pageSheet
        await withCheckedContinuation { continuation in
            root.present(host, animated: true) { continuation.resume() }
        }
        let compactHeight = host.view.bounds.height
        var requests = 0
        fixture.onFocus = { [weak host] in
            requests += 1
            guard let host else { return XCTFail("Missing sheet") }
            XCTAssertTrue(host.appeared)
            XCTAssertGreaterThan(host.view.bounds.height, compactHeight, "The inserted form must be laid out first")
            self.assertGeometrySettled(host.view)
        }
        fixture.showsForm = true
        XCTAssertEqual(requests, 0)
        try await waitUntil { Self.field(in: host.view)?.isFirstResponder == true }
        XCTAssertEqual(requests, 1)
    }

    private func assertGeometrySettled(_ view: UIView, file: StaticString = #filePath, line: UInt = #line) {
        var ancestor: UIView? = view
        while let current = ancestor, !(current is UIWindow) {
            if let presented = current.layer.presentation() {
                XCTAssertEqual(presented.bounds.height, current.layer.bounds.height, accuracy: 1, file: file, line: line)
                XCTAssertEqual(presented.position.y, current.layer.position.y, accuracy: 1, file: file, line: line)
            }
            ancestor = current.superview
        }
    }

    private func window() throws -> (UIWindow, UIWindow?) {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        return (UIWindow(windowScene: scene), scene.windows.first(where: \.isKeyWindow))
    }

    private static func field(in view: UIView) -> UITextField? {
        if let field = view as? UITextField, field.accessibilityIdentifier == "autofocus.fixture" { return field }
        return view.subviews.lazy.compactMap { field(in: $0) }.first
    }

    private func settle() async { try? await Task.sleep(for: .milliseconds(100)) }

    private func waitUntil(_ predicate: @MainActor () -> Bool) async throws {
        for _ in 0..<500 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The synthetic form did not receive automatic focus")
        throw NSError(domain: "OathAutofocusTests", code: 1)
    }
}
