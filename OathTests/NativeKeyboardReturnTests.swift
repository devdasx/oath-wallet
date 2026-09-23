import SwiftUI
import Testing
import UIKit
@testable import Aperture

@MainActor
@Suite(.serialized)
struct NativeKeyboardReturnTests {
    @Test
    func searchFieldsKeepOneProxyAndNativeTokenCapabilityQueriesTerminate() throws {
        let searchBar = UISearchBar()
        let input = searchBar.searchTextField
        WalletTextInputReturnKey.install(on: input)
        let proxy = try #require(input.delegate)
        let selector = NSSelectorFromString("searchTextField:itemProviderForCopyingToken:")
        for _ in 0..<20 {
            WalletTextInputReturnKey.install(on: input)
            #expect(input.delegate === proxy)
            // This is the exact optional capability lookup in the crash stack.
            _ = proxy.responds(to: selector)
        }
        input.text = "BTC"
        #expect(searchBar.text == "BTC")
        #expect(proxy.textFieldShouldReturn?(input) == false)
    }

    @Test
    func recursiveCapabilityLookupStopsWithoutHidingOtherDelegateMethods() throws {
        let input = UITextField()
        let original = KeyboardReturnReentrantDelegate()
        input.delegate = original
        WalletTextInputReturnKey.install(on: input)
        let proxy = try #require(input.delegate)
        original.proxy = proxy
        let selector = NSSelectorFromString("walletUnsupportedKeyboardCapability:")
        for _ in 0..<20 {
            #expect(!proxy.responds(to: selector))
            #expect((proxy as? NSObject)?.forwardingTarget(for: selector) == nil)
        }
        #expect(original.maximumDepth == 1)
        proxy.textFieldDidEndEditing?(input)
        #expect(original.endCount == 1)
    }

    @Test
    func coordinatorHandoffUnwrapsOtherInputsProxies() throws {
        let first = UITextField()
        let second = UITextField()
        let original = KeyboardReturnFieldDelegate()
        first.delegate = original
        WalletTextInputReturnKey.install(on: first)
        let firstProxy = try #require(first.delegate)
        second.delegate = firstProxy
        WalletTextInputReturnKey.install(on: second)
        let secondProxy = try #require(second.delegate)
        first.delegate = secondProxy
        WalletTextInputReturnKey.install(on: first)
        #expect(first.delegate === firstProxy)
        // This would recurse between the two proxies without unwrapping.
        first.delegate?.textFieldDidEndEditing?(first)
        second.delegate?.textFieldDidEndEditing?(second)
        #expect(original.endCount == 2)
        #expect(!firstProxy.responds(to: NSSelectorFromString("walletUnsupportedKeyboardCapability:")))
    }

    @Test(arguments: [NativeListTestLayout.phone, .padLandscape, .largeTextRTL])
    func nativeSearchRemainsEditableAndReturnDismissesAcrossReactivation(layout: NativeListTestLayout) async throws {
        let state = KeyboardSearchFixtureState()
        let host = try NativeListTestHost(layout: layout) {
            KeyboardSearchFixture(state: state)
                .walletTextInputConfiguration(layout.direction)
        }
        defer { host.close() }
        try await SendEntryUIProbe.wait(in: host.rootView) {
            host.navigationController?.topViewController?.navigationItem.searchController != nil
        }
        let search = try #require(host.navigationController?.topViewController?.navigationItem.searchController)
        let field = search.searchBar.searchTextField
        for query in ["BTC", "Bitcoin", "بيتكوين"] {
            search.isActive = true
            #expect(field.becomeFirstResponder())
            try await SendEntryUIProbe.wait(in: host.rootView) { field.isFirstResponder }
            let original = field.delegate
            field.text = ""
            field.insertText(query)
            search.searchResultsUpdater?.updateSearchResults(for: search)
            try await SendEntryUIProbe.wait(in: host.rootView) { state.query == query }
            WalletTextInputReturnKey.install(on: field)
            try #require(field.delegate === original)
            _ = field.delegate?.responds(to: NSSelectorFromString("searchTextField:itemProviderForCopyingToken:"))
            #expect(field.returnKeyType == .search)
            #expect(field.inputAccessoryView == nil)
            #expect(field.delegate?.textFieldShouldReturn?(field) == false)
            try await SendEntryUIProbe.wait(in: host.rootView) { !field.isFirstResponder }
            #expect(state.query == query)
        }
    }

    @Test(arguments: [NativeListTestLayout.phone, .padLandscape, .largeTextRTL])
    func screenOwnedDoneUsesLatestDraftAndDismissesOnce(layout: NativeListTestLayout) async throws {
        let saved = ListActionRecorder<String>()
        let host = try NativeListTestHost(layout: layout) {
            KeyboardSubmitFixture(initialNote: "Existing note", saved: saved)
                .walletTextInputConfiguration(layout.direction)
        }
        defer { host.close() }
        try await SendEntryUIProbe.wait(in: host.rootView) {
            SendEntryUIProbe.views(UITextField.self, in: host.rootView).contains {
                $0.text == "Existing note"
            }
        }
        let field = try #require(SendEntryUIProbe.views(UITextField.self, in: host.rootView).first)
        #expect(field.becomeFirstResponder())
        field.insertText(" updated")
        try await SendEntryUIProbe.wait(in: host.rootView) {
            field.text == "Existing note updated" && field.returnKeyType == .done
        }
        #expect(saved.actions.isEmpty)
        #expect(field.delegate?.textFieldShouldReturn?(field) == false)
        try await SendEntryUIProbe.wait(in: host.rootView) { !field.isFirstResponder }
        #expect(saved.actions == ["Existing note updated"])
        host.rootView.setNeedsLayout()
        host.rootView.layoutIfNeeded()
        await Task.yield()
        #expect(saved.actions.count == 1)
        #expect(!field.isFirstResponder)
    }

    @Test(arguments: [LayoutDirection.leftToRight, .rightToLeft])
    func editingEventsConfigureLateInputsWithoutLayoutScanning(direction: LayoutDirection) async throws {
        let mounted = ListActionRecorder<Bool>()
        let host = try NativeListTestHost {
            Color.clear.walletTextInputConfiguration(direction)
                .onAppear { mounted.actions.append(true) }
        }
        defer { host.close() }
        // Mount this root's notification subscription before emitting editing
        // events; otherwise only the host application's English root sees them.
        try await SendEntryUIProbe.wait(in: host.rootView) { !mounted.actions.isEmpty }
        // Native toolbar/alert inputs can appear after the SwiftUI hierarchy
        // settles. Configuration follows the real editing event, not geometry.
        let input = KeyboardConfigurationProbe(frame: CGRect(x: 20, y: 120, width: 220, height: 44))
        input.text = "public fixture"
        input.returnKeyType = .next
        host.rootView.addSubview(input)
        #expect(input.becomeFirstResponder())
        await Task.yield()
        #expect(input.returnKeyType == .done)
        // The app-host test process also has its English app window observing
        // editing events. Record this root's requested direction independently.
        #expect(input.requestedDirections.contains(
            direction == .leftToRight ? .leftToRight : .rightToLeft
        ))
        let original = KeyboardReturnFieldDelegate()
        input.delegate = original
        NotificationCenter.default.post(name: UITextField.textDidChangeNotification, object: input)
        await Task.yield()
        #expect(input.delegate !== original)
        #expect(input.delegate?.textFieldShouldReturn?(input) == false)
        #expect(!input.isFirstResponder)
        #expect(original.returnCount == 0)
    }

    @Test(arguments: [UIKeyboardType.decimalPad, .numberPad, .asciiCapableNumberPad])
    func numericEditingKeepsNativeWritingDirection(keyboardType: UIKeyboardType) {
        let input = KeyboardConfigurationProbe(frame: CGRect(x: 0, y: 0, width: 200, height: 44))
        input.keyboardType = keyboardType
        input.text = "50000.25"
        input.selectedTextRange = input.textRange(from: input.endOfDocument, to: input.endOfDocument)
        for direction in [LayoutDirection.rightToLeft, .leftToRight, .rightToLeft] {
            WalletTextInputConfiguration.apply(direction, to: input)
        }
        #expect(input.requestedDirections.isEmpty)
        #expect(input.text == "50000.25")
        #expect(input.selectedTextRange?.isEmpty == true)
        #expect(input.returnKeyType == .done)
    }

    @Test(arguments: [NativeListTestLayout.phone, .pad])
    func productionRecipientReturnDismissesWithoutAdvancingTheSendFlow(layout: NativeListTestLayout) async throws {
        let database = try WalletDatabase.temporary()
        let settings = WalletSettingsStore(database: database)
        let host = try NativeListTestHost(layout: layout) {
            SendFlowView(
                database: database,
                walletAddress: NativeListTestFixtures.address,
                walletAssets: [],
                preparationRevision: UUID(),
                initialRoute: SendFlowPlanner.manualEntryRoute(for: SendEntryTestFixtures.ethereum)
            )
            .environment(settings)
            .environment(SendActivityStore())
            .environment(\.walletCurrencyContext, SendEntryTestFixtures.currency)
            .walletTextInputConfiguration(layout == .largeTextRTL ? .rightToLeft : .leftToRight)
        }
        defer { host.close() }
        try await SendEntryUIProbe.wait(in: host.rootView) {
            host.navigationController?.viewControllers.count == 2
                && !SendEntryUIProbe.views(UITextView.self, in: host.rootView).isEmpty
        }
        let navigation = try #require(host.navigationController)
        let recipientController = try #require(navigation.topViewController)
        let input = try #require(SendEntryUIProbe.views(UITextView.self, in: recipientController.view).first)
        // Send intentionally waits for a user tap before opening its keyboard.
        #expect(input.becomeFirstResponder())
        await Task.yield()
        input.inputAccessoryView = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 64))
        WalletTextInputConfiguration.apply(layout.direction, to: input)
        #expect(input.inputAccessoryView == nil)
        let recipient = SendEntryTestFixtures.address(for: .ethereum)
        input.text = recipient
        input.delegate?.textViewDidChange?(input)
        await Task.yield()
        let delegate = try #require(input.delegate)
        #expect(input.returnKeyType == .done)
        if #available(iOS 26.0, *) {
            #expect(delegate.textView?(
                input,
                shouldChangeTextInRanges: [NSValue(range: input.selectedRange)],
                replacementText: "\n"
            ) == false)
        } else {
            #expect(delegate.textView?(
                input,
                shouldChangeTextIn: input.selectedRange,
                replacementText: "\n"
            ) == false)
        }
        await Task.yield()
        #expect(!input.isFirstResponder)
        #expect(input.text == recipient)
        #expect(navigation.viewControllers.count == 2)
        #expect(navigation.topViewController === recipientController)
        #expect(navigation.presentedViewController == nil)
    }

    @Test(arguments: NativeListTestLayout.allCases)
    func multilineReturnMustDismissBeforeInsertingANewline(layout: NativeListTestLayout) async throws {
        let state = KeyboardReturnFixtureState()
        let host = try NativeListTestHost(layout: layout) {
            KeyboardReturnFixture(state: state)
        }
        defer { host.close() }
        try await SendEntryUIProbe.wait(in: host.rootView) {
            SendEntryUIProbe.views(UITextView.self, in: host.rootView)
                .first?.isFirstResponder == true
        }
        let input = try #require(SendEntryUIProbe.views(UITextView.self, in: host.rootView).first)
        let delegate = try #require(input.delegate)
        #expect(String(reflecting: type(of: delegate)).contains("ReturnKeyDelegate"))
        #expect(input.returnKeyType == .done)
        // Exercise UIKit's pre-edit delegate contract. insertText alone is a
        // programmatic edit; the companion UI tests press the real Return key.
        let shouldInsert: Bool
        if #available(iOS 26.0, *) {
            shouldInsert = delegate.textView?(
                input,
                shouldChangeTextInRanges: [NSValue(range: input.selectedRange)],
                replacementText: "\n"
            ) ?? true
        } else {
            shouldInsert = delegate.textView?(
                input,
                shouldChangeTextIn: input.selectedRange,
                replacementText: "\n"
            ) ?? true
        }
        #expect(!shouldInsert)
        if shouldInsert { input.insertText("\n") }
        await Task.yield()
        #expect(state.text == "Return test")
        #expect(input.text == "Return test")
        #expect(!input.isFirstResponder)
        #expect(state.submissions == 0)
    }

    @Test(arguments: ["\n", "\r", "\r\n"])
    func returnIsRejectedBeforeEitherMultilineEditCallbackChangesTheSelection(replacement: String) throws {
        let input = UITextView()
        input.text = "keep this selection"
        input.selectedRange = NSRange(location: 5, length: 4)
        let original = KeyboardReturnLegacyViewDelegate()
        input.delegate = original
        WalletTextInputReturnKey.install(on: input)
        let delegate = try #require(input.delegate)
        let selection = input.selectedRange

        #expect(delegate.textView?(input, shouldChangeTextIn: selection, replacementText: replacement) == false)
        if #available(iOS 26.0, *) {
            #expect(delegate.textView?(
                input,
                shouldChangeTextInRanges: [NSValue(range: selection)],
                replacementText: replacement
            ) == false)
        }
        #expect(input.text == "keep this selection")
        #expect(input.selectedRange == selection)
        #expect(original.edits.isEmpty)
    }

    @Test(arguments: [false, true])
    func normalAndSecureFieldsDoNotForwardReturnToAnAction(isSecure: Bool) throws {
        let input = UITextField()
        input.isSecureTextEntry = isSecure
        input.text = "unchanged"
        let original = KeyboardReturnFieldDelegate()
        input.delegate = original
        WalletTextInputReturnKey.install(on: input)
        let delegate = try #require(input.delegate)

        #expect(delegate.textFieldShouldReturn?(input) == false)
        for replacement in ["\n", "\r", "\r\n"] {
            #expect(delegate.textField?(
                input, shouldChangeCharactersIn: NSRange(location: 0, length: 9),
                replacementString: replacement
            ) == false)
        }
        #expect(original.returnCount == 0)
        #expect(original.edits.isEmpty)
        #expect(input.text == "unchanged")
        #expect(input.isSecureTextEntry == isSecure)
        #expect(input.returnKeyType == .done)
    }

    @Test
    func fieldValidationDeletionAndOtherDelegateCallbacksArePreserved() throws {
        let input = UITextField()
        let original = KeyboardReturnFieldDelegate()
        input.delegate = original
        WalletTextInputReturnKey.install(on: input)
        let delegate = try #require(input.delegate)
        let range = NSRange(location: 0, length: 0)
        for replacement in ["a", "", "first\nsecond\r\nthird", "العربية"] {
            #expect(delegate.textField?(input, shouldChangeCharactersIn: range, replacementString: replacement) == true)
            #expect(original.edits.last?.text == replacement)
        }
        original.allowsChange = false
        #expect(delegate.textField?(input, shouldChangeCharactersIn: range, replacementString: "reject") == false)
        delegate.textFieldDidChangeSelection?(input)
        delegate.textFieldDidEndEditing?(input)
        #expect(original.selectionCount == 1)
        #expect(original.endCount == 1)
    }

    @Test
    func multilineValidationAndPastedContentUseTheOriginalDelegate() throws {
        let input = UITextView()
        let original = KeyboardReturnLegacyViewDelegate()
        input.delegate = original
        WalletTextInputReturnKey.install(on: input)
        let delegate = try #require(input.delegate)
        let range = NSRange(location: 3, length: 2)
        for replacement in ["a", "", "first\nsecond\r\nthird", "العربية"] {
            #expect(delegate.textView?(input, shouldChangeTextIn: range, replacementText: replacement) == true)
            #expect(original.edits.last?.text == replacement)
            #expect(original.edits.last?.range == range)
        }
        original.allowsChange = false
        #expect(delegate.textView?(input, shouldChangeTextIn: range, replacementText: "reject") == false)
        delegate.textViewDidChange?(input)
        delegate.textViewDidChangeSelection?(input)
        delegate.textViewDidEndEditing?(input)
        #expect(original.changeCount == 1)
        #expect(original.selectionCount == 1)
        #expect(original.endCount == 1)
    }

    @Test
    @available(iOS 26.0, *)
    func newMultirangeCallbackFallsBackToTheLegacyUnionRange() throws {
        let input = UITextView()
        let original = KeyboardReturnLegacyViewDelegate()
        input.delegate = original
        WalletTextInputReturnKey.install(on: input)
        let delegate = try #require(input.delegate)
        let ranges = [NSValue(range: NSRange(location: 2, length: 3)), NSValue(range: NSRange(location: 7, length: 2))]
        #expect(delegate.textView?(input, shouldChangeTextInRanges: ranges, replacementText: "pasted\ntext") == true)
        #expect(original.edits.last?.range == NSRange(location: 2, length: 7))
        #expect(original.edits.last?.text == "pasted\ntext")
        original.allowsChange = false
        #expect(delegate.textView?(input, shouldChangeTextInRanges: ranges, replacementText: "reject") == false)
    }

    @Test
    @available(iOS 26.0, *)
    func newMultirangeCallbackPreservesTheNewDelegateInsteadOfCallingLegacyValidation() throws {
        let input = UITextView()
        let original = KeyboardReturnMultirangeViewDelegate()
        input.delegate = original
        WalletTextInputReturnKey.install(on: input)
        let delegate = try #require(input.delegate)
        let ranges = [NSValue(range: NSRange(location: 2, length: 3)), NSValue(range: NSRange(location: 7, length: 2))]
        #expect(delegate.textView?(input, shouldChangeTextInRanges: ranges, replacementText: "pasted\ntext") == true)
        #expect(original.ranges == ranges)
        #expect(original.replacement == "pasted\ntext")
        #expect(original.edits.isEmpty)
        original.allowsChange = false
        #expect(delegate.textView?(input, shouldChangeTextInRanges: ranges, replacementText: "reject") == false)
    }

    @Test
    func repeatedInstallationDoesNotChainProxiesAndTracksCoordinatorReplacement() throws {
        let input = UITextField()
        let first = KeyboardReturnFieldDelegate()
        let second = KeyboardReturnFieldDelegate()
        input.delegate = first
        WalletTextInputReturnKey.install(on: input)
        let proxy = try #require(input.delegate)
        WalletTextInputReturnKey.install(on: input)
        #expect(input.delegate === proxy)
        input.delegate = second
        WalletTextInputReturnKey.install(on: input)
        #expect(input.delegate === proxy)
        proxy.textFieldDidEndEditing?(input)
        #expect(first.endCount == 0)
        #expect(second.endCount == 1)
    }

    @Test
    func inputOwnsTheProxyWithoutRetainingItsOriginalCoordinator() throws {
        let input = UITextField()
        weak var released: KeyboardReturnFieldDelegate?
        do {
            let original = KeyboardReturnFieldDelegate()
            released = original
            input.delegate = original
            WalletTextInputReturnKey.install(on: input)
        }
        #expect(released == nil)
        #expect(input.delegate != nil)
        #expect(input.delegate?.textFieldShouldReturn?(input) == false)
        #expect(input.delegate?.textField?(input, shouldChangeCharactersIn: NSRange(), replacementString: "a") == true)
    }
}

private struct KeyboardSubmitFixture: View {
    let saved: ListActionRecorder<String>
    @State private var note: String

    init(initialNote: String, saved: ListActionRecorder<String>) {
        self.saved = saved
        _note = State(initialValue: initialNote)
    }

    var body: some View {
        List {
            TextField("wallet.transaction.details.notes.placeholder", text: $note)
                .walletTextInputDirection()
                .walletTextInputSubmitAction(identifier: "noteSubmitFixture", returnKeyType: .done) {
                    saved.actions.append(note)
                }
        }
    }
}

@MainActor
@Observable
private final class KeyboardReturnFixtureState {
    var text = "Return test"
    var submissions = 0
}

private struct KeyboardReturnFixture: View {
    @Environment(\.layoutDirection) private var layoutDirection
    @Bindable var state: KeyboardReturnFixtureState
    @FocusState private var isFocused: Bool

    var body: some View {
        List {
            TextField("send.recipient.placeholder", text: $state.text, axis: .vertical)
                .lineLimit(3...5)
                .walletTextInputDirection()
                .focused($isFocused)
                .onSubmit {
                    state.submissions += 1
                    isFocused = false
                }
        }
        .walletTextInputConfiguration(layoutDirection)
        .task { isFocused = true }
    }
}

private struct KeyboardReturnEdit {
    let range: NSRange
    let text: String
}

@MainActor
private final class KeyboardReturnFieldDelegate: NSObject, UITextFieldDelegate {
    var allowsChange = true
    var edits: [KeyboardReturnEdit] = []
    var returnCount = 0
    var selectionCount = 0
    var endCount = 0

    func textFieldShouldReturn(_ input: UITextField) -> Bool { returnCount += 1; return true }
    func textFieldDidChangeSelection(_ input: UITextField) { selectionCount += 1 }
    func textFieldDidEndEditing(_ input: UITextField) { endCount += 1 }
    func textField(_ input: UITextField, shouldChangeCharactersIn range: NSRange, replacementString text: String) -> Bool {
        edits.append(KeyboardReturnEdit(range: range, text: text))
        return allowsChange
    }
}

@MainActor
private class KeyboardReturnLegacyViewDelegate: NSObject, UITextViewDelegate {
    var allowsChange = true
    var edits: [KeyboardReturnEdit] = []
    var changeCount = 0
    var selectionCount = 0
    var endCount = 0

    func textViewDidChange(_ input: UITextView) { changeCount += 1 }
    func textViewDidChangeSelection(_ input: UITextView) { selectionCount += 1 }
    func textViewDidEndEditing(_ input: UITextView) { endCount += 1 }
    func textView(_ input: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        edits.append(KeyboardReturnEdit(range: range, text: text))
        return allowsChange
    }
}

@MainActor
private final class KeyboardReturnMultirangeViewDelegate: KeyboardReturnLegacyViewDelegate {
    var ranges: [NSValue] = []
    var replacement = ""

    func textView(_ input: UITextView, shouldChangeTextInRanges ranges: [NSValue], replacementText text: String) -> Bool {
        self.ranges = ranges
        replacement = text
        return allowsChange
    }
}

@MainActor
private final class KeyboardConfigurationProbe: UITextField {
    var requestedDirections: [NSWritingDirection] = []

    override func setBaseWritingDirection(_ writingDirection: NSWritingDirection, for range: UITextRange) {
        requestedDirections.append(writingDirection)
        super.setBaseWritingDirection(writingDirection, for: range)
    }
}

@MainActor
private final class KeyboardReturnReentrantDelegate: NSObject, UITextFieldDelegate {
    weak var proxy: (any UITextFieldDelegate)?
    var depth = 0
    var maximumDepth = 0
    var endCount = 0

    nonisolated override func responds(to selector: Selector!) -> Bool {
        if super.responds(to: selector) { return true }
        return MainActor.assumeIsolated {
            depth += 1
            maximumDepth = max(maximumDepth, depth)
            defer { depth -= 1 }
            // Bound the fixture so the regression fails instead of crashing
            // the entire test host when run against the old implementation.
            guard depth < 8 else { return false }
            return proxy?.responds(to: selector) == true
        }
    }

    func textFieldDidEndEditing(_ input: UITextField) { endCount += 1 }
}

@MainActor
@Observable
private final class KeyboardSearchFixtureState {
    var query = ""
}

private struct KeyboardSearchFixture: View {
    @Bindable var state: KeyboardSearchFixtureState

    var body: some View {
        NavigationStack {
            List { Text("receive.title") }
                .searchable(text: $state.query, placement: .toolbar, prompt: Text("receive.search.prompt"))
                .walletTextInputDirection()
        }
    }
}
