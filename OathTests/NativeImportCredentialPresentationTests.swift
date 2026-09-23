import SwiftUI
import Testing
import UIKit
import WalletCore
@testable import Aperture

/// Native UI assertions only. Initial fixtures never enter the typing capture
/// path, and Continue pushes a test destination without persisting a wallet.
@MainActor
@Suite(.serialized)
struct NativeImportCredentialPresentationTests {
    @Test(arguments: ImportDraftTestFlow.allCases, [NativeListTestLayout.phone, .pad, .padLandscape, .largeTextRTL])
    func growingPhraseStaysAboveImport(flow: ImportDraftTestFlow, layout: NativeListTestLayout) async throws {
        let host = try NativeListTestHost(layout: layout) {
            CredentialPresentationFixture(flow: flow, credential: .recoveryPhrase, input: "")
                .environment(\.dynamicTypeSize, layout == .padLandscape ? .accessibility3 : layout.textSize)
        }
        defer { host.close() }
        try await SendEntryUIProbe.wait(in: host.rootView) {
            SendEntryUIProbe.views(UITextField.self, in: host.rootView).contains { $0.isFirstResponder }
        }
        let field = try #require(SendEntryUIProbe.views(UITextField.self, in: host.rootView).first { $0.isFirstResponder })
        // Public invalid input only. Force multiple rows while the growing
        // field shows inline completions below the previous viewport.
        for _ in 0..<4 {
            field.insertText(Array(repeating: "hello", count: 20).joined(separator: " ") + " ")
            field.insertText("ha")
            try await assertInputVisible(field, host: host)
            field.insertText("mster ")
        }
        try await assertInputVisible(field, host: host)
        // Growing a single unfinished word can also wrap the input to a new row.
        field.insertText(String(repeating: "m", count: 24))
        try await assertInputVisible(field, host: host)
        field.selectedTextRange = field.textRange(from: field.beginningOfDocument, to: field.endOfDocument)
        field.deleteBackward()
        field.deleteBackward()
        try await SendEntryUIProbe.wait(in: host.rootView) {
            SendEntryUIProbe.views(UITextField.self, in: host.rootView).contains {
                $0.isFirstResponder && $0.text == "hamster"
            }
        }
        let editing = try #require(SendEntryUIProbe.views(UITextField.self, in: host.rootView).first { $0.isFirstResponder })
        try await assertInputVisible(editing, host: host)
    }

    private func assertInputVisible(_ field: UITextField, host: NativeListTestHost) async throws {
        var fieldFrame = CGRect.zero
        var visibleBottom = CGFloat.zero
        do {
            try await SendEntryUIProbe.wait(in: host.rootView) {
                guard let action = SendEntryUIProbe.element("importCredentialContinue", in: host.rootView) else { return false }
                visibleBottom = action.accessibilityFrame.minY
                fieldFrame = field.convert(field.bounds, to: nil)
                return field.isFirstResponder && fieldFrame.height >= 44 && fieldFrame.maxY <= visibleBottom - 8
                    && fieldFrame.minY >= host.rootView.safeAreaInsets.top
            }
        } catch {
            Issue.record("Active input \(fieldFrame) must stay above controls at \(visibleBottom).")
            throw error
        }
    }

    @Test(arguments: ImportDraftTestFlow.allCases, [NativeListTestLayout.phone, .pad, .largeTextRTL])
    func returnUsesTheLatestPhraseAndNeverImportsIt(flow: ImportDraftTestFlow, layout: NativeListTestLayout) async throws {
        let prefix = Array(repeating: "abandon", count: 11).joined(separator: " ")
        let host = try NativeListTestHost(layout: layout) {
            CredentialPresentationFixture(flow: flow, credential: .recoveryPhrase, input: prefix + " ")
        }
        defer { host.close() }
        try await SendEntryUIProbe.wait(in: host.rootView) {
            SendEntryUIProbe.views(UITextField.self, in: host.rootView).contains { $0.isFirstResponder }
        }
        let field = try #require(SendEntryUIProbe.views(UITextField.self, in: host.rootView).first { $0.isFirstResponder })
        WalletTextInputConfiguration.apply(layout.direction, to: field)
        // Incomplete phrase: Return leaves an empty insertion point focused.
        #expect(field.delegate?.textFieldShouldReturn?(field) == false)
        #expect(field.isFirstResponder)
        field.insertText("about")
        // Return immediately, before the async import draft can be prepared.
        #expect(field.delegate?.textFieldShouldReturn?(field) == false)
        #expect(!field.isFirstResponder)
        try await enabledContinue(host)
        #expect(host.navigationController?.viewControllers.count == 1)
        #expect(SendEntryUIProbe.element("recoveryPhraseWord_12", in: host.rootView)?.accessibilityValue == "about")
    }

    @Test(arguments: ImportDraftTestFlow.allCases, [NativeListTestLayout.phone, .pad, .largeTextRTL])
    func recoveryInputFocusesOnOpeningAndRespectsKeyboardDismissal(
        flow: ImportDraftTestFlow, layout: NativeListTestLayout
    ) async throws {
        for modal in [false, true] {
            let host = try NativeListTestHost(layout: layout) {
                if modal {
                    Color.clear.sheet(isPresented: .constant(true)) {
                        CredentialPresentationFixture(flow: flow, credential: .recoveryPhrase, input: "")
                    }
                } else {
                    CredentialPresentationFixture(flow: flow, credential: .recoveryPhrase, input: "")
                }
            }
            defer { host.close() }
            let root = try #require(host.rootView.window)
            try await SendEntryUIProbe.wait(in: root) {
                SendEntryUIProbe.views(UITextField.self, in: root).contains { $0.isFirstResponder }
            }
            let field = try #require(SendEntryUIProbe.views(UITextField.self, in: root).first { $0.isFirstResponder })
            #expect(field.accessibilityIdentifier == "recoveryPhraseInlineInput")
            field.insertText("hello ")
            try await SendEntryUIProbe.wait(in: root) {
                SendEntryUIProbe.element("recoveryPhraseWord_1", in: root)?.accessibilityValue == "hello"
            }
            root.endEditing(true)
            try await SendEntryUIProbe.wait(in: root) {
                !SendEntryUIProbe.views(UITextField.self, in: root).contains { $0.isFirstResponder }
            }
            root.setNeedsLayout()
            root.layoutIfNeeded()
            await Task.yield()
            #expect(!field.isFirstResponder)
        }
    }

    @Test(arguments: ImportDraftTestFlow.allCases, NativeListTestLayout.allCases)
    func completionAppearsInsideTheFieldAndReturnAcceptsIt(
        flow: ImportDraftTestFlow, layout: NativeListTestLayout
    ) async throws {
        let host = try NativeListTestHost(layout: layout) {
            CredentialPresentationFixture(flow: flow, credential: .recoveryPhrase, input: "")
        }
        defer { host.close() }
        try await SendEntryUIProbe.wait(in: host.rootView) {
            SendEntryUIProbe.views(UITextField.self, in: host.rootView).contains { $0.isFirstResponder }
        }
        let field = try #require(SendEntryUIProbe.views(UITextField.self, in: host.rootView).first { $0.isFirstResponder })
        field.insertText("ab")
        try await SendEntryUIProbe.wait(in: host.rootView) {
            SendEntryUIProbe.views(UILabel.self, in: field).contains {
                $0.accessibilityIdentifier == "recoveryPhraseInlineCompletion" && !$0.isHidden && $0.text == "andon"
            }
        }
        let ending = try #require(SendEntryUIProbe.views(UILabel.self, in: field).first {
            $0.accessibilityIdentifier == "recoveryPhraseInlineCompletion"
        })
        #expect(field.text == "ab")
        #expect(field.bounds.contains(ending.frame))
        #expect(ending.font == field.font)
        #expect(ending.textColor != field.textColor)
        let window = try #require(field.window)
        let insertion = field.textInputView.convert(field.caretRect(for: field.endOfDocument), to: window)
        let preview = ending.convert(ending.bounds, to: window)
        #expect(abs(preview.minX - insertion.minX) <= 0.5)
        #expect(abs(preview.midY - insertion.midY) <= 0.5)
        #expect(SendEntryUIProbe.element("recoveryWordSuggestions", in: host.rootView) == nil)
        #expect(!SendEntryUIProbe.views(UICollectionView.self, in: host.rootView).contains { $0.contentSize.height > 0 })
        let action = try #require(SendEntryUIProbe.element("importCredentialContinue", in: host.rootView))
        #expect(action.accessibilityTraits.contains(.notEnabled))
        #expect(field.delegate?.textFieldShouldReturn?(field) == false)
        try await SendEntryUIProbe.wait(in: host.rootView) {
            SendEntryUIProbe.element("recoveryPhraseWord_1", in: host.rootView)?.accessibilityValue == "abandon"
        }
        #expect(field.text == "")
        #expect(field.isFirstResponder)
        #expect(host.navigationController?.viewControllers.count == 1)
    }

    @Test(arguments: ImportDraftTestFlow.allCases, [NativeListTestLayout.phone, .pad, .largeTextRTL])
    func continuingThenReturningPreservesValidCredentialsWithoutReadyCopy(
        flow: ImportDraftTestFlow, layout: NativeListTestLayout
    ) async throws {
        let wallet = try #require(HDWallet(strength: 128, passphrase: ""))
        let key = wallet.getKeyForCoin(coin: .ethereum).data.map { String(format: "%02x", $0) }.joined()
        for credential in [WalletImportCredential.recoveryPhrase, .privateKey] {
            let value = credential == .recoveryPhrase ? wallet.mnemonic : key
            let host = try NativeListTestHost(layout: layout) {
                CredentialPresentationFixture(flow: flow, credential: credential, input: value)
            }
            defer { host.close() }
            try await enabledContinue(host)
            #expect(!labels(in: host.rootView).contains("Ready to Import This Wallet"))
            #expect(!labels(in: host.rootView).contains("import.credential.ready"))
            let navigation = try #require(host.navigationController)
            try SendEntryUIProbe.activate("importCredentialContinue", in: host.rootView)
            try await SendEntryUIProbe.wait(in: host.rootView) {
                navigation.viewControllers.count == 2 && navigation.transitionCoordinator == nil
            }
            #expect(navigation.presentedViewController == nil)
            #expect(navigation.popViewController(animated: true) != nil)
            try await SendEntryUIProbe.wait(in: host.rootView) {
                navigation.viewControllers.count == 1 && navigation.transitionCoordinator == nil
            }
            try await enabledContinue(host)
            let screen = try #require(navigation.topViewController?.view)
            if credential == .recoveryPhrase {
                let words = value.split(separator: " ").map(String.init)
                // Compare as booleans so no generated secret enters test output.
                let preserved = words.enumerated().allSatisfy { index, word in
                    SendEntryUIProbe.element("recoveryPhraseWord_\(index + 1)", in: screen)?
                        .accessibilityValue == word
                }
                #expect(preserved)
            } else {
                let editor = try #require(SendEntryUIProbe.views(UITextView.self, in: screen).first { $0.isEditable })
                let inputWasPreserved = editor.text == value
                #expect(inputWasPreserved)
            }
        }
    }

    private func enabledContinue(
        _ host: NativeListTestHost, sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        try await SendEntryUIProbe.wait(in: host.rootView, sourceLocation: sourceLocation) {
            SendEntryUIProbe.element("importCredentialContinue", in: host.rootView)?
                .accessibilityTraits.contains(.notEnabled) == false
        }
    }

    private func labels(in root: NSObject) -> Set<String> {
        var visited: Set<ObjectIdentifier> = []
        func visit(_ object: NSObject) -> Set<String> {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return [] }
            var result = Set(object.accessibilityLabel.map { [$0] } ?? [])
            let count = object.accessibilityElementCount()
            if count > 0 && count < 1_000 {
                for index in 0..<count {
                    if let child = object.accessibilityElement(at: index) as? NSObject {
                        result.formUnion(visit(child))
                    }
                }
            }
            if let view = object as? UIView {
                for child in view.subviews { result.formUnion(visit(child)) }
            }
            return result
        }
        return visit(root)
    }
}

private struct CredentialPresentationFixture: View {
    let flow: ImportDraftTestFlow
    let credential: WalletImportCredential
    let input: String
    @State private var showsNextStep = false

    var body: some View {
        NavigationStack {
            Group {
                switch (flow, credential) {
                case (.onboarding, .recoveryPhrase):
                    ImportWalletCredentialView(credential: credential, initialInput: input) { _ in showsNextStep = true }
                case (.walletSwitcher, .recoveryPhrase):
                    WalletSwitcherRecoveryImportScreen(credential: credential, initialInput: input) { _ in showsNextStep = true }
                case (.onboarding, .privateKey):
                    PrivateKeyCredentialView(network: .evm, initialInput: input) { _ in showsNextStep = true }
                case (.walletSwitcher, .privateKey):
                    WalletSwitcherPrivateKeyImportScreen(network: .evm, initialInput: input) { _ in showsNextStep = true }
                }
            }
            .navigationDestination(isPresented: $showsNextStep) {
                Text("common.done")
            }
        }
    }
}
