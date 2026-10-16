import XCTest
import SwiftUI
@testable import OathAtmosphere

@MainActor final class OathCloudBackupPromptTests: XCTestCase {
    private struct PromptHarness: View {
        @State private var started = false
        let submitted: (String) -> Void
        let strings = OathLocalizer(.english)
        var body: some View {
            OathContentSizedSheet(contentID: started, avoidsKeyboard: !started, navigation: .init(
                strings: strings, title: .cloudBackupPasswordTitle, backIdentifier: "test.back", onBack: { }, onClose: { }
            )) {
                Group {
                    if started {
                        ProgressView("Synthetic backup fixture")
                    } else {
                        OathBackupPasswordForm { password in
                            started = true
                            submitted(password)
                        }
                    }
                }
                .padding(20)
                .fixedSize(horizontal: false, vertical: true)
            }
            .environment(\.oathLanguage, .english)
        }
    }

    func testPasswordPageStaysInSheetAndWaitsForKeyboardBeforeSubmission() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let oldKey = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let root = UIViewController()
        window.rootViewController = root; window.makeKeyAndVisible()
        defer { root.dismiss(animated: false); window.isHidden = true; oldKey?.makeKey() }
        var submitted = false
        var keyboardDidHide = false
        var presentationFinished = false
        var keyboardFrame: CGRect?
        let observer = NotificationCenter.default.addObserver(forName: UIResponder.keyboardDidHideNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { keyboardDidHide = true }
        }
        let shown = NotificationCenter.default.addObserver(forName: UIResponder.keyboardDidShowNotification, object: nil, queue: .main) { note in
            let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
            MainActor.assumeIsolated { keyboardFrame = frame }
        }
        let editing = NotificationCenter.default.addObserver(forName: UITextField.textDidBeginEditingNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                XCTAssertTrue(presentationFinished, "Automatic focus must follow animated sheet presentation")
            }
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
            NotificationCenter.default.removeObserver(shown)
            NotificationCenter.default.removeObserver(editing)
        }
        let host = UIHostingController(rootView: PromptHarness { password in
            XCTAssertEqual(password, "fixture-password")
            XCTAssertNil(Self.alert(in: root), "Password entry must never present an alert")
            XCTAssertTrue(keyboardDidHide, "Processing must wait for the keyboard's actual completion")
            submitted = true
        }.environment(\.scenePhase, .active)) // Match the lifecycle environment supplied by OathSceneRoot.
        host.modalPresentationStyle = .pageSheet
        root.present(host, animated: true) { presentationFinished = true }
        do {
            try await waitUntil("autofocus and keyboard presentation") {
                Self.fields(in: host.view).first?.isFirstResponder == true && keyboardFrame != nil
            }
        } catch {
            XCTFail("Fields: \(Self.fields(in: host.view).count), first responder: \(Self.fields(in: host.view).first?.isFirstResponder == true), keyboard shown: \(keyboardFrame != nil)")
            throw error
        }
        let fields = Self.fields(in: host.view)
        XCTAssertEqual(fields.count, 2)
        let first = try XCTUnwrap(fields.first)
        let second = try XCTUnwrap(fields.last)
        XCTAssertNil(Self.alert(in: root))
        XCTAssertNil(host.presentedViewController, "Keep the form inside the already presented sheet")
        XCTAssertTrue(root.presentedViewController === host)
        XCTAssertTrue(first.isSecureTextEntry && second.isSecureTextEntry)
        let keyboardTop = try XCTUnwrap(keyboardFrame).minY
        XCTAssertLessThanOrEqual(second.convert(second.bounds, to: window).maxY, keyboardTop,
                                 "The native keyboard guide must keep both inputs visible")

        first.insertText("1234567")
        try await Task.sleep(for: .milliseconds(30))
        pressReturn(first)
        try await waitUntil("Return advances to confirmation") { second.isFirstResponder }
        second.insertText("1234567")
        try await Task.sleep(for: .milliseconds(30))
        pressReturn(second)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(submitted, "Seven characters must not pass")
        XCTAssertTrue(second.isFirstResponder)

        first.becomeFirstResponder()
        first.selectedTextRange = first.textRange(from: first.beginningOfDocument, to: first.endOfDocument)
        first.insertText("fixture-password")
        try await Task.sleep(for: .milliseconds(30))
        pressReturn(first)
        try await waitUntil("Return advances after editing password") { second.isFirstResponder }
        second.selectedTextRange = second.textRange(from: second.beginningOfDocument, to: second.endOfDocument)
        second.insertText("different-password")
        try await Task.sleep(for: .milliseconds(30))
        pressReturn(second)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(submitted)
        XCTAssertTrue(second.isFirstResponder, "Invalid confirmation must keep the keyboard open")
        second.selectedTextRange = second.textRange(from: second.beginningOfDocument, to: second.endOfDocument)
        second.insertText("fixture-password")
        try await Task.sleep(for: .milliseconds(30))
        pressReturn(second)
        XCTAssertFalse(submitted, "The submit handler must not run during dismissal")
        try await waitUntil("valid Return submits after keyboard dismissal") { submitted }
        XCTAssertFalse(first.isFirstResponder || second.isFirstResponder)
        XCTAssertTrue(keyboardDidHide, "The software keyboard must finish hiding before processing")
        XCTAssertTrue(root.presentedViewController === host, "Starting the backup keeps the same bottom sheet")
        XCTAssertNil(host.presentedViewController)
    }

    private func pressReturn(_ field: UITextField) {
        // UITextField receives the keyboard Return through its delegate;
        // insertText("\n") is text insertion, not that control event.
        XCTAssertEqual(field.delegate?.textFieldShouldReturn?(field), false)
    }

    private static func fields(in view: UIView) -> [UITextField] {
        if let field = view as? UITextField, field.isSecureTextEntry { return [field] }
        return view.subviews.flatMap { fields(in: $0) }.sorted {
            $0.convert($0.bounds, to: nil).minY < $1.convert($1.bounds, to: nil).minY
        }
    }
    private static func alert(in controller: UIViewController) -> UIAlertController? {
        if let alert = controller as? UIAlertController { return alert }
        if let presented = controller.presentedViewController, let alert = alert(in: presented) { return alert }
        return controller.children.compactMap { alert(in: $0) }.first
    }
    private func waitUntil(_ phase: String, file: StaticString = #filePath, line: UInt = #line,
                           _ predicate: @MainActor () -> Bool) async throws {
        for _ in 0..<500 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Password sheet did not reach: \(phase)", file: file, line: line)
        throw NSError(domain: "CloudBackupPromptTest", code: 1)
    }
}
