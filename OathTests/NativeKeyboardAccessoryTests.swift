import SwiftUI
import Testing
import UIKit
@testable import Aperture

@MainActor
@Suite(.serialized)
struct NativeKeyboardAccessoryTests {
    enum Input: CaseIterable {
        case text, secure, decimal, number, multiline, search

        func make() -> UIView {
            if self == .multiline { return UITextView() }
            let field = self == .search ? UISearchTextField() : UITextField()
            field.isSecureTextEntry = self == .secure
            if self == .decimal { field.keyboardType = .decimalPad }
            if self == .number { field.keyboardType = .asciiCapableNumberPad }
            return field
        }
    }

    @Test(arguments: Input.allCases.filter { $0 != .search })
    func editingInstallsOneCheckmarkAndDismissesWithoutChangingText(kind: Input) async throws {
        let host = try NativeListTestHost {
            Color.clear.walletTextInputConfiguration(.leftToRight)
        }
        defer { host.close() }
        let input = kind.make()
        input.frame = CGRect(x: 24, y: 150, width: 250, height: 60)
        host.rootView.addSubview(input)
        #expect(input.becomeFirstResponder())
        try await SendEntryUIProbe.wait(in: host.rootView) { self.accessory(of: input) != nil }
        let accessory = try #require(accessory(of: input))
        if let field = input as? UITextField { field.insertText("123.45") }
        if let view = input as? UITextView { view.insertText("public\nfixture") }
        for _ in 0..<4 { WalletTextInputConfiguration.apply(.leftToRight, to: input) }
        #expect(self.accessory(of: input) === accessory)
        #expect(accessory.confirmButton.configuration?.image != nil)
        #expect(accessory.confirmButton.configuration?.title == nil)
        #expect(accessory.confirmButton.accessibilityLabel == WalletLocalization.string("common.done"))
        accessory.confirmButton.sendActions(for: .touchUpInside)
        try await SendEntryUIProbe.wait(in: host.rootView) { !input.isFirstResponder }
        if let field = input as? UITextField { #expect(field.text == "123.45") }
        if let view = input as? UITextView { #expect(view.text == "public\nfixture") }
        #expect(input.becomeFirstResponder())
        try await SendEntryUIProbe.wait(in: host.rootView) { input.isFirstResponder }
        #expect(self.accessory(of: input) === accessory)
        accessory.confirmButton.sendActions(for: .touchUpInside)
        #expect(!input.isFirstResponder)
    }

    @Test(arguments: [NativeListTestLayout.phone, .padLandscape, .largeTextRTL])
    func searchRemovesEntireAccessoryAcrossFocusAndKeyboardChanges(layout: NativeListTestLayout) async throws {
        let host = try NativeListTestHost {
            Color.clear.walletTextInputConfiguration(layout.direction)
        }
        defer { host.close() }
        let search = UISearchBar()
        search.frame = CGRect(x: 24, y: 150, width: 280, height: 56)
        host.rootView.addSubview(search)
        let field = search.searchTextField
        let converter = UITextField(frame: CGRect(x: 24, y: 240, width: 250, height: 44))
        converter.keyboardType = .decimalPad
        host.rootView.addSubview(converter)

        for _ in 0..<2 {
            #expect(field.becomeFirstResponder())
            // Remove both a formerly installed checkmark and a SwiftUI-created
            // placeholder, so neither the button nor an empty toolbar survives.
            for toolbar in [WalletKeyboardAccessoryView(input: field), UIView()] {
                field.inputAccessoryView = toolbar
                WalletTextInputConfiguration.apply(layout.direction, to: field)
                WalletKeyboardAccessory.reconcileKeyboardTransition()
                #expect(field.inputAccessoryView == nil)
                #expect(field.returnKeyType == .search)
                #expect(field.isFirstResponder)
            }
            field.insertText("BTC")
            await Task.yield()
            #expect(field.inputAccessoryView == nil)
            #expect(search.text?.contains("BTC") == true)
            #expect(converter.becomeFirstResponder())
            WalletTextInputConfiguration.apply(layout.direction, to: converter)
            #expect(converter.inputAccessoryView is WalletKeyboardAccessoryView)
        }
    }

    @Test(arguments: NativeListTestLayout.allCases)
    func accessoryKeepsGapAndMirrorsTrailingControl(layout: NativeListTestLayout) throws {
        let field = UITextField()
        WalletKeyboardAccessory.install(on: field, layoutDirection: layout.direction)
        let accessory = try #require(field.inputAccessoryView as? WalletKeyboardAccessoryView)
        accessory.frame = CGRect(x: 0, y: 0, width: layout.size.width, height: 64)
        accessory.layoutIfNeeded()
        let frame = accessory.confirmButton.frame
        #expect(frame.height == 44 && frame.width == 44)
        #expect(frame.minY == 8)
        #expect(accessory.bounds.maxY - frame.maxY == 12)
        if layout.direction == .rightToLeft {
            #expect(frame.minX == 16)
        } else {
            #expect(accessory.bounds.maxX - frame.maxX == 16)
        }
        #expect(accessory.systemLayoutSizeFitting(CGSize(width: 320, height: 1)).height == 64)
    }

    @Test
    func confirmationSavesLatestNoteOnceButDoesNotSubmitOtherInputs() async throws {
        let saved = ListActionRecorder<String>()
        let host = try NativeListTestHost {
            KeyboardAccessoryNoteFixture(saved: saved)
                .walletTextInputConfiguration(.leftToRight)
        }
        defer { host.close() }
        try await SendEntryUIProbe.wait(in: host.rootView) {
            SendEntryUIProbe.views(UITextField.self, in: host.rootView).count == 2
        }
        let fields = SendEntryUIProbe.views(UITextField.self, in: host.rootView)
        let note = try #require(fields.first { $0.text == "Note" })
        #expect(note.becomeFirstResponder())
        note.insertText(" updated")
        try await SendEntryUIProbe.wait(in: host.rootView) { note.text == "Note updated" }
        // Let the SwiftUI binding update the registered closure before tapping.
        try await Task.sleep(for: .milliseconds(100))
        let accessory = try #require(note.inputAccessoryView as? WalletKeyboardAccessoryView)
        accessory.confirmButton.sendActions(for: .touchUpInside)
        accessory.confirmButton.sendActions(for: .touchUpInside)
        #expect(saved.actions == ["Note updated"])
        #expect(!note.isFirstResponder)
        let other = try #require(fields.first { $0 !== note })
        #expect(other.becomeFirstResponder())
        let otherAccessory = try #require(other.inputAccessoryView as? WalletKeyboardAccessoryView)
        otherAccessory.confirmButton.sendActions(for: .touchUpInside)
        #expect(saved.actions == ["Note updated"])
        #expect(!other.isFirstResponder)
    }

    @Test
    func accessoryDoesNotRetainInputAndReplacesEmptyPlaceholders() throws {
        weak var released: UITextField?
        var retainedAccessory: WalletKeyboardAccessoryView?
        do {
            let field = UITextField()
            released = field
            WalletKeyboardAccessory.install(on: field, layoutDirection: .leftToRight)
            retainedAccessory = try #require(field.inputAccessoryView as? WalletKeyboardAccessoryView)
        }
        #expect(released == nil)
        retainedAccessory?.confirmButton.sendActions(for: .touchUpInside)
        let field = UITextField()
        field.inputAccessoryView = UIView()
        WalletKeyboardAccessory.install(on: field, layoutDirection: .leftToRight)
        #expect(field.inputAccessoryView is WalletKeyboardAccessoryView)
        let installed = field.inputAccessoryView
        field.inputAccessoryView = UIView()
        WalletKeyboardAccessory.install(on: field, layoutDirection: .rightToLeft)
        #expect(field.inputAccessoryView === installed)
        field.inputAccessoryView = nil
        field.inputView = UIView()
        WalletKeyboardAccessory.install(on: field, layoutDirection: .leftToRight)
        #expect(field.inputAccessoryView == nil)
    }

    @Test(arguments: [false, true])
    func productionNumericScreensChooseAccessoryFromScreenActions(filter: Bool) async throws {
        let proceeded = ListActionRecorder<Bool>()
        let host = try NativeListTestHost {
            Group {
                if filter {
                    WalletActivityFilterView(filter: WalletActivityFilter(), availableNetworks: [],
                                             availableDateRange: nil) { _ in proceeded.actions.append(true) }
                } else {
                    NavigationStack {
                        SendTextAddressScreen(prepareRequest: { _ in .failed("unused-test-action") },
                                              onProceed: { _ in proceeded.actions.append(true) })
                    }
                }
            }
            .walletTextInputConfiguration(.leftToRight)
        }
        defer { host.close() }
        let list = try await host.list()
        let cell = try await host.cell(at: IndexPath(item: filter ? 0 : 1, section: filter ? 2 : 0), in: list)
        let input = try #require(SendEntryUIProbe.views(UITextField.self, in: cell).first)
        #expect(input.keyboardType == (filter ? .asciiCapableNumberPad : .decimalPad))
        #expect(input.becomeFirstResponder())
        if !filter {
            // The production Continue form must remove the whole accessory,
            // even when SwiftUI recreates a generated toolbar during editing.
            input.inputAccessoryView = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 64))
            WalletTextInputConfiguration.apply(.leftToRight, to: input)
            try await SendEntryUIProbe.wait(in: host.rootView) { input.inputAccessoryView == nil }
            input.insertText("0.25")
            try await SendEntryUIProbe.wait(in: host.rootView) { input.text == "0.25" }
            #expect(input.inputAccessoryView == nil)
            #expect(proceeded.actions.isEmpty)
            input.resignFirstResponder()
            return
        }
        try await SendEntryUIProbe.wait(in: host.rootView) {
            (input.inputAccessoryView as? WalletKeyboardAccessoryView)?.decimalButton.isHidden == false
        }
        let accessory = try #require(input.inputAccessoryView as? WalletKeyboardAccessoryView)
        accessory.decimalButton.sendActions(for: .touchUpInside)
        try await SendEntryUIProbe.wait(in: host.rootView) { input.text == "0." }
        input.insertText("25")
        try await SendEntryUIProbe.wait(in: host.rootView) { input.text == "0.25" }
        #expect(!accessory.decimalButton.isEnabled)
        accessory.decimalButton.sendActions(for: .touchUpInside)
        #expect(input.text == "0.25")
        accessory.confirmButton.sendActions(for: .touchUpInside)
        try await SendEntryUIProbe.wait(in: host.rootView) { !input.isFirstResponder }
        #expect(proceeded.actions.isEmpty)
        #expect(input.text == "0.25")
    }

    @Test(arguments: [false, true])
    func screenActionRemovesEntireAccessoryForTextAndMultilineInputs(multiline: Bool) async throws {
        let host = try NativeListTestHost { Color.clear.walletTextInputConfiguration(.leftToRight) }
        defer { host.close() }
        let input: UIView = multiline ? UITextView() : UITextField()
        input.frame = CGRect(x: 24, y: 150, width: 250, height: 60)
        host.rootView.addSubview(input)
        #expect(input.becomeFirstResponder())
        try await SendEntryUIProbe.wait(in: host.rootView) { self.accessory(of: input) != nil }
        let scope = WalletKeyboardActionScopeView()
        scope.frame = host.rootView.bounds
        host.rootView.addSubview(scope)
        scope.active = true
        WalletKeyboardAccessory.register(scope)
        defer { WalletKeyboardAccessory.unregister(scope) }
        #expect(scope.contains(input))
        #expect(input.inputAccessoryView == nil)
        input.frame.origin.y = -200
        WalletKeyboardAccessory.reconcileKeyboardTransition()
        #expect(input.inputAccessoryView == nil)
        input.frame.origin.y = 150
        // Leaving the Continue screen restores the accessory for reused inputs.
        scope.active = false
        WalletKeyboardAccessory.unregister(scope)
        #expect(accessory(of: input) != nil)
        #expect(input.isFirstResponder)
        accessory(of: input)?.confirmButton.sendActions(for: .touchUpInside)
        #expect(!input.isFirstResponder)
    }

    @Test
    func underlyingContinueScreenDoesNotSuppressPresentedConverterAccessory() async throws {
        let host = try NativeListTestHost {
            Form { TextField("send.recipient.placeholder", text: .constant("")) }
                .walletKeyboardUsesScreenAction()
                .walletTextInputConfiguration(.leftToRight)
        }
        defer { host.close() }
        let list = try await host.list()
        let cell = try await host.cell(at: IndexPath(item: 0, section: 0), in: list)
        let original = try #require(SendEntryUIProbe.views(UITextField.self, in: cell).first)
        #expect(original.becomeFirstResponder())
        original.inputAccessoryView = UIView()
        WalletTextInputConfiguration.apply(.leftToRight, to: original)
        #expect(original.inputAccessoryView == nil)
        let presented = UIViewController()
        presented.view.backgroundColor = .systemBackground
        let converter = UITextField(frame: CGRect(x: 24, y: 160, width: 250, height: 44))
        converter.keyboardType = .decimalPad
        presented.view.addSubview(converter)
        let root = try #require(host.rootView.window?.rootViewController)
        root.present(presented, animated: false)
        try await SendEntryUIProbe.wait(in: presented.view) { presented.view.window != nil }
        #expect(converter.becomeFirstResponder())
        WalletTextInputConfiguration.apply(.leftToRight, to: converter)
        let accessory = try #require(converter.inputAccessoryView as? WalletKeyboardAccessoryView)
        accessory.confirmButton.sendActions(for: .touchUpInside)
        #expect(!converter.isFirstResponder)
        presented.dismiss(animated: false)
    }

    private func accessory(of input: UIView) -> WalletKeyboardAccessoryView? {
        if let field = input as? UITextField { return field.inputAccessoryView as? WalletKeyboardAccessoryView }
        return (input as? UITextView)?.inputAccessoryView as? WalletKeyboardAccessoryView
    }
}

private struct KeyboardAccessoryNoteFixture: View {
    let saved: ListActionRecorder<String>
    @State private var note = "Note"
    @State private var other = "Other"

    var body: some View {
        Form {
            TextField("wallet.transaction.details.notes.placeholder", text: $note)
                .walletTextInputSubmitAction(identifier: "accessoryNote", returnKeyType: .done,
                                            confirmsFromKeyboardAccessory: true) {
                    saved.actions.append(note)
                }
            TextField("wallet.transaction.details.notes.placeholder", text: $other)
                .walletTextInputSubmitAction(identifier: "accessoryOther", returnKeyType: .next) {
                    saved.actions.append("Unexpected submit")
                }
        }
    }
}
