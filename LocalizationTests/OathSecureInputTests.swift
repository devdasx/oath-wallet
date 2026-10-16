import SwiftUI
import XCTest
@testable import OathAtmosphere

/// Synthetic text only: exercise UIKit's secure editing buffer and the real
/// representables. No wallets, Keychain credentials or network operations.
@MainActor final class OathSecureInputTests: XCTestCase {
    enum Focus { case password, confirmation, key, name }

    @Observable final class Fixture {
        var password = "Synthetic Pässword 🔑 123"
        var confirmation = "Synthetic confirmation"
        var key = "synthetic-private-key-input"
        var name = "Synthetic contact"
        var focus: Focus?
        var enabled = true
        var language = OathLanguage.english
    }

    private struct Form: View {
        @Bindable var fixture: Fixture

        var body: some View {
            VStack(spacing: 20) {
                VStack(spacing: 0) {
                    password($fixture.password, id: "test.password", focus: .password)
                    Divider().padding(.horizontal, OathInputMetrics.horizontalInset)
                    password($fixture.confirmation, id: "test.confirmation", focus: .confirmation)
                }
                .oathInputBackground()
                OathTextInput(text: $fixture.key, focused: binding(.key),
                    title: "Private key", identifier: "test.key", secret: true)
                    .oathSettingsField()
                OathTextInput(text: $fixture.name, focused: binding(.name),
                    title: "Name", identifier: "test.name")
                    .oathSettingsField()
            }
            .padding(20)
            .disabled(!fixture.enabled)
            .oathLanguage(fixture.language)
        }

        private func password(_ text: Binding<String>, id: String, focus: Focus) -> some View {
            OathSecureInput(text: text, title: "Password", identifier: id, returnKey: .next,
                wantsFocus: fixture.focus == focus, resignsFocus: fixture.focus == nil,
                onFocus: { fixture.focus = focus }, onDismissKeyboard: { fixture.focus = nil },
                onSubmit: { fixture.focus = .confirmation })
                .oathInputRow()
        }

        private func binding(_ focus: Focus) -> Binding<Bool> {
            Binding(get: { fixture.focus == focus }, set: { value in
                if value { fixture.focus = focus }
                else if fixture.focus == focus { fixture.focus = nil }
            })
        }
    }

    func testEyePreservesPasswordSelectionAndSubsequentTyping() async throws {
        let fixture = Fixture()
        let (window, previous, host) = try present(fixture)
        defer { host.view.endEditing(true); window.isHidden = true; previous?.makeKey() }
        let password = try await field("test.password", in: host.view)
        let confirmation = try await field("test.confirmation", in: host.view)
        let eye = try eye(password)
        XCTAssertTrue(password.isSecureTextEntry)
        fixture.focus = .password
        try await waitUntil { password.isFirstResponder }
        let start = try XCTUnwrap(password.position(from: password.beginningOfDocument, offset: 2))
        let end = try XCTUnwrap(password.position(from: password.beginningOfDocument, offset: 5))
        password.selectedTextRange = password.textRange(from: start, to: end)
        let original = fixture.password
        eye.sendActions(for: .touchUpInside)
        XCTAssertFalse(password.isSecureTextEntry)
        XCTAssertTrue(password.isFirstResponder)
        XCTAssertEqual(password.text, original)
        XCTAssertEqual(selection(password), NSRange(location: 2, length: 3))
        XCTAssertEqual(eye.accessibilityLabel, "Hide password")
        XCTAssertTrue(confirmation.isSecureTextEntry, "Each field controls its own visibility")

        password.insertText("!")
        let replaced = (original as NSString).replacingCharacters(in: NSRange(location: 2, length: 3), with: "!")
        XCTAssertEqual(password.text, replaced)
        try await waitUntil { fixture.password == replaced }
        fixture.name = "Updated synthetic contact"
        await drainUpdates()
        XCTAssertFalse(password.isSecureTextEntry, "A SwiftUI update must not reset visibility")
        eye.sendActions(for: .touchUpInside)
        XCTAssertTrue(password.isSecureTextEntry)
        XCTAssertEqual(selection(password), NSRange(location: 3, length: 0))
        password.insertText("?")
        let edited = (replaced as NSString).replacingCharacters(in: NSRange(location: 3, length: 0), with: "?")
        XCTAssertEqual(password.text, edited)
        try await waitUntil { fixture.password == edited }
        XCTAssertEqual(password.text, edited, "Typing after hiding must not clear the secure buffer")

        eye.sendActions(for: .touchUpInside)
        fixture.focus = .confirmation
        try await waitUntil { confirmation.isFirstResponder }
        XCTAssertTrue(password.isSecureTextEntry, "Moving to another field conceals the password")
        try self.eye(confirmation).sendActions(for: .touchUpInside)
        XCTAssertFalse(confirmation.isSecureTextEntry)
        NotificationCenter.default.post(name: UIScene.willDeactivateNotification, object: window.windowScene)
        XCTAssertTrue(confirmation.isSecureTextEntry, "App switcher entry must conceal revealed text")
        XCTAssertEqual(fixture.password, edited)
        XCTAssertEqual(fixture.confirmation, "Synthetic confirmation")
    }

    func testRTLEyeAndPrivateKeyVisibilitySurviveViewUpdates() async throws {
        let fixture = Fixture()
        fixture.language = .arabic
        let (window, previous, host) = try present(fixture)
        defer { host.view.endEditing(true); window.isHidden = true; previous?.makeKey() }
        let key = try await field("test.key", in: host.view)
        let password = try await field("test.password", in: host.view)
        let name = try await field("test.name", in: host.view)
        host.view.layoutIfNeeded()
        let keyEye = try eye(key)
        let passwordEye = try eye(password)
        XCTAssertLessThan(keyEye.convert(keyEye.bounds, to: key).midX, key.bounds.midX)
        XCTAssertLessThan(passwordEye.convert(passwordEye.bounds, to: password).midX, password.bounds.midX)
        XCTAssertEqual(keyEye.accessibilityLabel, "إظهار المفتاح الخاص")
        XCTAssertEqual(key.textAlignment, .left, "Private key text keeps its literal LTR order")
        XCTAssertGreaterThanOrEqual(keyEye.bounds.width, 44)
        XCTAssertGreaterThanOrEqual(keyEye.bounds.height, 44)
        XCTAssertEqual(name.bounds.height, password.bounds.height, accuracy: 0.5,
                       "Contact and passphrase content must have the same single-line height")
        XCTAssertEqual(key.bounds.height, password.bounds.height, accuracy: 0.5)
        XCTAssertNil(name.leftView)
        XCTAssertNil(name.rightView)

        fixture.focus = .key
        try await waitUntil { key.isFirstResponder }
        keyEye.sendActions(for: .touchUpInside)
        XCTAssertFalse(key.isSecureTextEntry)
        let end = key.endOfDocument
        key.selectedTextRange = key.textRange(from: end, to: end)
        key.insertText("-edited")
        try await waitUntil { fixture.key == "synthetic-private-key-input-edited" }
        await drainUpdates()
        XCTAssertFalse(key.isSecureTextEntry)
        fixture.language = .english
        try await waitUntil { keyEye.accessibilityLabel == "Hide private key" }
        host.view.layoutIfNeeded()
        XCTAssertTrue(try eye(key) === keyEye)
        XCTAssertTrue(keyEye.isDescendant(of: key))
        XCTAssertGreaterThan(keyEye.convert(keyEye.bounds, to: key).midX, key.bounds.midX)
        XCTAssertFalse(key.isSecureTextEntry)

        fixture.enabled = false
        try await waitUntil { !key.isEnabled }
        XCTAssertTrue(key.isSecureTextEntry)
        XCTAssertFalse(keyEye.isEnabled)
        XCTAssertEqual(key.text, fixture.key)
        keyEye.sendActions(for: .touchUpInside)
        XCTAssertTrue(key.isSecureTextEntry, "Disabled fields cannot reveal text")
    }

    private func present(_ fixture: Fixture) throws -> (UIWindow, UIWindow?, UIHostingController<Form>) {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: Form(fixture: fixture))
        window.rootViewController = host
        window.makeKeyAndVisible()
        return (window, previous, host)
    }

    private func eye(_ field: OathEntryTextField) throws -> UIButton {
        try XCTUnwrap((field.leftView ?? field.rightView) as? UIButton)
    }

    private func selection(_ field: UITextField) -> NSRange? {
        guard let selected = field.selectedTextRange else { return nil }
        return NSRange(location: field.offset(from: field.beginningOfDocument, to: selected.start),
                       length: field.offset(from: selected.start, to: selected.end))
    }

    private func field(_ id: String, in view: UIView) async throws -> OathEntryTextField {
        try await waitUntil { self.find(id, in: view)?.bounds.width ?? 0 > 0 }
        return try XCTUnwrap(find(id, in: view))
    }

    private func find(_ id: String, in view: UIView) -> OathEntryTextField? {
        if let field = view as? OathEntryTextField, field.accessibilityIdentifier == id { return field }
        return view.subviews.lazy.compactMap { self.find(id, in: $0) }.first
    }

    private func drainUpdates() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }

    private func waitUntil(file: StaticString = #filePath, line: UInt = #line,
                           _ predicate: @MainActor () -> Bool) async throws {
        for _ in 0..<300 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Synthetic secure field did not settle", file: file, line: line)
        throw NSError(domain: "OathSecureInputTests", code: 1)
    }
}
