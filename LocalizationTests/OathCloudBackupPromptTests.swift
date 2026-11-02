import XCTest
import SwiftUI
@testable import OathAtmosphere

@MainActor final class OathCloudBackupPromptTests: XCTestCase {
    private struct PromptHarness: View {
        @State private var started = false
        let submitted: (String) -> Void
        let strings = OathLocalizer(.english)
        var body: some View {
            OathBackupPageLayout(contentID: started, navigation: .init(
                strings: strings, title: started ? .cloudBackupSection : .cloudBackupPasswordTitle,
                backIdentifier: "test.back", onBack: {}, onClose: {}
            ), avoidsKeyboard: !started, showsActions: false) {
                Group {
                    if started {
                        ProgressView("Synthetic backup fixture")
                    } else {
                        OathBackupPasswordForm { password in
                            started = true
                            submitted(password)
                        }
                    }
                }.padding(20)
            } actions: { EmptyView() }
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
        let originalScroll = try XCTUnwrap(host.view.findBackupScroll())
        let formHeight = originalScroll.contentSize.height
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
        try await waitUntil("progress shrinks the same sheet after password submission") {
            host.view.findBackupScroll() === originalScroll &&
                originalScroll.contentSize.height < formHeight &&
                abs(originalScroll.backupViewportHeight - originalScroll.contentSize.height) < 12
        }
        XCTAssertTrue(root.presentedViewController === host, "Starting the backup keeps the same bottom sheet")
        XCTAssertNil(host.presentedViewController)
    }

    @Observable final class OfferFixture {
        var showingManual = false
        var includesManual = false
    }

    private struct OfferHarness: View {
        let state: OfferFixture
        let session: OathWalletSession
        let recovery: OathRecoveryPhraseModel
        let strings = OathLocalizer(.english)

        var body: some View {
            OathBackupPageLayout(contentID: state.showingManual, navigation: .init(
                strings: strings, title: state.showingManual ? .showRecoveryPhrase : .walletBackup,
                backIdentifier: "test.back", onBack: state.showingManual ? { state.showingManual = false } : nil,
                onClose: {}
            ), showsActions: state.showingManual) {
                if state.showingManual {
                    OathRecoveryWarningContent(model: recovery, fitsBackupSheet: true)
                } else {
                    OathBackupOfferMenu(offer: state.includesManual ? .cloudOrManual : .cloudOnly,
                                        cloudStatus: .unconfirmed, manualTitle: .showRecoveryPhrase,
                                        onCloud: {}, onManual: { state.showingManual = true })
                }
            } actions: {
                if state.showingManual {
                    OathRecoveryWarningAction(model: recovery, session: session)
                }
            }
        }
    }

    func testBackupStepsRefitInPlaceInsideTheSameSheet() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let oldKey = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let session = OathWalletSession()
        let recovery = OathRecoveryPhraseModel(walletID: UUID().uuidString, reader: session.vault)
        let state = OfferFixture()
        let pages = OfferHarness(state: state, session: session, recovery: recovery)
        let root = UIHostingController(rootView: Color.clear.sheet(isPresented: .constant(true)) {
            pages.presentationBackground(Color(uiColor: OathSurfaceColors.groupedCanvas))
        })
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer { root.dismiss(animated: false); window.isHidden = true; oldKey?.makeKey() }
        try await waitUntil("SwiftUI presents the backup sheet") { root.presentedViewController != nil }
        let host = try XCTUnwrap(root.presentedViewController)
        try await waitUntil("compact chooser without a footer") {
            guard let scroll = host.view.findBackupScroll() else { return false }
            guard host.sheetPresentationController?.selectedDetentIdentifier?.rawValue == "oath.content" else { return false }
            return host.transitionCoordinator == nil && scroll.contentSize.height > 0 &&
                abs(scroll.backupViewportHeight - scroll.contentSize.height) < 12 && host.view.bounds.height < window.bounds.height * 0.7
        }
        let cloudOnlyHeight = host.view.bounds.height
        state.includesManual = true
        try await waitUntil("second backup option grows the chooser to fit") {
            guard let scroll = host.view.findBackupScroll() else { return false }
            return host.view.bounds.height > cloudOnlyHeight + 20 &&
                abs(scroll.backupViewportHeight - scroll.contentSize.height) < 12
        }
        let rootHeight = host.view.bounds.height
        let nav = try XCTUnwrap(host.findBackupNavigation())
        let originalPage = try XCTUnwrap(nav.topViewController)
        let originalScroll = try XCTUnwrap(host.view.findBackupScroll())
        try await waitForSheetMotion(host, in: window, change: { state.showingManual = true }) {
            guard nav.topViewController === originalPage, nav.viewControllers.count == 1,
                  nav.topViewController?.navigationItem.leftBarButtonItem != nil,
                  let scroll = nav.topViewController?.view.findBackupScroll(),
                  scroll === originalScroll, host.view.bounds.height > rootHeight else { return false }
            return abs(scroll.backupViewportHeight - scroll.contentSize.height) < 12 &&
                host.view.bounds.height < window.bounds.height - window.safeAreaInsets.top - 32
        }
        let warningHeight = host.view.bounds.height
        XCTAssertTrue(root.presentedViewController === host)
        XCTAssertNil(host.presentedViewController)

        try await waitForSheetMotion(host, in: window, change: { state.showingManual = false }) {
            nav.topViewController === originalPage && host.view.findBackupScroll() === originalScroll &&
                nav.topViewController?.navigationItem.leftBarButtonItem == nil &&
                abs(host.view.bounds.height - rootHeight) < 2
        }
        print("In-place backup heights (points): iCloud only \(cloudOnlyHeight), both options \(rootHeight), warning \(warningHeight), back \(host.view.bounds.height)")
    }

    /// UIKit sets the model frame to its destination immediately. Sample the
    /// presentation tree so a snap to the right final height still fails.
    private func waitForSheetMotion(_ host: UIViewController, in window: UIWindow, change: () -> Void,
                                    file: StaticString = #filePath, line: UInt = #line,
                                    destinationReached: () -> Bool) async throws {
        func displayedTop() -> CGFloat? {
            guard let surface = host.view.layer.presentation(), let screen = window.layer.presentation() else { return nil }
            return surface.convert(surface.bounds.origin, to: screen).y
        }
        func targetTop() -> CGFloat { host.view.convert(host.view.bounds, to: window).minY }

        try await waitUntil("previous resize finishes", file: file, line: line) {
            displayedTop().map { abs($0 - targetTop()) < 1 } == true
        }
        let start = targetTop()
        var samples: [CGFloat] = []
        change()
        try await waitUntil("visible sheet reaches its new size", file: file, line: line) {
            guard let y = displayedTop() else { return false }
            samples.append(y)
            return destinationReached() && abs(y - targetTop()) < 1
        }
        let distance = targetTop() - start
        XCTAssertGreaterThan(abs(distance), 20, file: file, line: line)
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let progress = samples.map { ($0 - start) / distance }
        XCTAssertTrue(progress.contains { (0.02..<0.5).contains($0) } &&
                      progress.contains { (0.5..<0.98).contains($0) },
                      "Expected intermediate sheet positions in both halves of the resize; observed \(progress)",
                      file: file, line: line)
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
        XCTFail("Backup sheet did not reach: \(phase)", file: file, line: line)
        throw NSError(domain: "CloudBackupPromptTest", code: 1)
    }
}

private extension UIView {
    func findBackupScroll() -> UIScrollView? {
        if let scroll = self as? UIScrollView, scroll.accessibilityIdentifier == "options.scrollContent" { return scroll }
        return subviews.lazy.compactMap { $0.findBackupScroll() }.first
    }
}

private extension UIViewController {
    func findBackupNavigation() -> UINavigationController? {
        if let navigation = self as? UINavigationController { return navigation }
        return children.lazy.compactMap { $0.findBackupNavigation() }.first
    }
}

private extension UIScrollView {
    var backupViewportHeight: CGFloat { bounds.height - adjustedContentInset.top - adjustedContentInset.bottom }
}
