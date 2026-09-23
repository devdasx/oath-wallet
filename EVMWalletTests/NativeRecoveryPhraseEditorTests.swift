import SwiftUI
import Testing
import UIKit
@testable import Aperture

/// Standalone input controls: no persistence, remote callbacks, clipboard, or screenshots.
@MainActor
@Suite(.serialized)
struct NativeRecoveryPhraseEditorTests {
    @Test(arguments: [NativeListTestLayout.phone, .pad, .largeTextRTL])
    func invalidTypingIsLowercaseAndRedAndClearRemovesEverything(layout: NativeListTestLayout) async throws {
        let recorder = ListActionRecorder<String>()
        let host = try NativeListTestHost(layout: layout) {
            PhraseEditorFixture(initialInput: "habit ", recorder: recorder)
        }
        defer { host.close() }
        let field = try await input(host)
        #expect(field.becomeFirstResponder())
        field.insertText("UU")
        try await SendEntryUIProbe.wait(in: host.rootView) {
            field.text == "uu" && field.textColor == UIColor(WalletTheme.danger)
        }
        #expect(recorder.actions.last == "habit uu")
        field.insertText(" ")
        try await SendEntryUIProbe.wait(in: host.rootView) {
            SendEntryUIProbe.views(UILabel.self, in: host.rootView).contains {
                $0.text == "uu" && $0.textColor == UIColor(WalletTheme.danger)
            }
        }
        try SendEntryUIProbe.activate("recoveryPhraseClear", in: host.rootView)
        try await SendEntryUIProbe.wait(in: host.rootView) {
            recorder.actions.last == "" && field.text == ""
        }
        #expect(SendEntryUIProbe.element("recoveryPhraseWord_1", in: host.rootView) == nil)
    }

    @Test(arguments: [NativeListTestLayout.phone, .pad, .largeTextRTL], ["ar", "fa", "he", "ur"])
    func recoveryLayoutAndTypingMatchLTRInRTLLanguages(layout: NativeListTestLayout, language: String) async throws {
        var referenceFrames: [CGRect] = []
        for direction in [LayoutDirection.leftToRight, .rightToLeft] {
            let recorder = ListActionRecorder<String>()
            let host = try NativeListTestHost(layout: layout) {
                PhraseEditorFixture(initialInput: "head good wolf hand goat gadget ", recorder: recorder)
                    .environment(\.locale, Locale(identifier: language))
                    .environment(\.layoutDirection, direction)
                    .walletTextInputConfiguration(direction)
            }
            defer { host.close() }
            let field = try await input(host)
            #expect(field.becomeFirstResponder())
            field.insertText("ham")
            try await completionWidth("hammer", field: field, host: host)
            try await completion("mer", field: field, host: host)
            #expect(field.textAlignment == .left)
            #expect(field.effectiveUserInterfaceLayoutDirection == .leftToRight)
            #expect(field.baseWritingDirection(for: field.endOfDocument, in: .backward) == .leftToRight)
            let start = field.caretRect(for: field.beginningOfDocument)
            let end = field.caretRect(for: field.endOfDocument)
            #expect(start.minX < end.minX)
            var frames = try (1...6).map { index in
                let pill = try #require(SendEntryUIProbe.element("recoveryPhraseWord_\(index)", in: host.rootView))
                return pill.accessibilityFrame
            }
            frames.append(field.convert(field.bounds, to: nil))
            if direction == .leftToRight {
                referenceFrames = frames
            } else {
                for (actual, expected) in zip(frames, referenceFrames) {
                    #expect(abs(actual.minX - expected.minX) < 1)
                    #expect(abs(actual.minY - expected.minY) < 1)
                    #expect(abs(actual.width - expected.width) < 1)
                }
            }
            field.insertText(" ")
            #expect(recorder.actions.last == "head good wolf hand goat gadget hammer ")
            field.deleteBackward()
            #expect(field.text == "hammer")
            #expect(field.baseWritingDirection(for: field.endOfDocument, in: .backward) == .leftToRight)
            #expect(field.isFirstResponder)
        }
    }

    @Test
    func dictionaryCompletionPreservesCompleteAndUnknownWords() {
        #expect(RecoveryPhraseCompletion.match(fragment: "ab", precedingWords: [])?.word == "abandon")
        #expect(RecoveryPhraseCompletion.match(fragment: "HAM", precedingWords: ["abandon"])?.suffix == "mer")
        for value in ["", "ab ", "notaword", "cat", "act", "car", "hello", "café"] {
            #expect(RecoveryPhraseCompletion.match(fragment: value, precedingWords: []) == nil)
        }
        #expect(RecoveryPhraseCompletion.match(fragment: String(repeating: "a", count: 129), precedingWords: []) == nil)
    }

    @Test(arguments: BIP39Language.allCases)
    func dictionaryCompletionUsesThePhraseLanguage(language: BIP39Language) throws {
        let entries = BIP39Mnemonic.wordEntries(for: language)
        let context = entries.prefix(12).map(\.word)
        // Some languages use whole one-character words, with no ending to preview.
        for entry in entries.prefix(12) {
            #expect(RecoveryPhraseCompletion.match(fragment: entry.word, precedingWords: context) == nil)
        }
        if language == .chineseSimplified || language == .chineseTraditional { return }
        let match = try #require(entries.lazy.compactMap { entry -> RecoveryPhraseCompletion? in
            guard entry.word.count > 2 else { return nil }
            return RecoveryPhraseCompletion.match(fragment: String(entry.word.dropLast()), precedingWords: context)
        }.first)
        #expect(entries.contains { $0.word == match.word })
        #expect(!match.suffix.isEmpty)
    }

    @Test(arguments: NativeListTestLayout.allCases)
    func completionSharesTheTypedWordLineAsTheInputGrows(layout: NativeListTestLayout) async throws {
        let recorder = ListActionRecorder<String>()
        let host = try NativeListTestHost(layout: layout) { PhraseEditorFixture(recorder: recorder) }
        defer { host.close() }
        let field = try await input(host)
        #expect(field.becomeFirstResponder())
        for (letter, suffix, word) in [("h", "abit", "habit"), ("a", "bit", "habit"),
                                        ("m", "mer", "hammer"), ("s", "ter", "hamster")] {
            field.insertText(letter)
            try await completionWidth(word, field: field, host: host)
            try await completion(suffix, field: field, host: host)
            #expect(field.isFirstResponder)
            #expect(recorder.actions.last == field.text)
        }
    }

    @Test(arguments: [NativeListTestLayout.phone, .pad, .largeTextRTL])
    func completionRemainsPreviewUntilExplicitlyAccepted(layout: NativeListTestLayout) async throws {
        let recorder = ListActionRecorder<String>()
        let host = try NativeListTestHost(layout: layout) { PhraseEditorFixture(recorder: recorder) }
        defer { host.close() }
        let field = try await input(host)
        #expect(field.becomeFirstResponder())
        let emptyWidth = field.bounds.width
        field.insertText("ham")
        try await completion("mer", field: field, host: host)
        try await completionWidth("hammer", field: field, host: host)
        #expect(field.text == "ham")
        #expect(recorder.actions.last == "ham")
        #expect(field.bounds.width > emptyWidth)
        field.insertText("s")
        try await completion("ter", field: field, host: host)
        try await completionWidth("hamster", field: field, host: host)
        #expect(recorder.actions.last == "hams")
        #expect(field.delegate?.textFieldShouldReturn?(field) == false)
        #expect(recorder.actions.last == "hamster ")
        #expect(field.text == "")
        #expect(field.isFirstResponder)
        // Space accepts the visible preview; losing focus preserves typing.
        field.insertText("ham")
        try await completion("mer", field: field, host: host)
        field.insertText(" ")
        #expect(recorder.actions.last == "hamster hammer ")
        #expect(field.text == "")
        #expect(field.isFirstResponder)
        field.insertText("ab")
        try await completion("andon", field: field, host: host)
        field.resignFirstResponder()
        try await SendEntryUIProbe.wait(in: host.rootView) { recorder.actions.last == "hamster hammer ab " }
    }

    @Test
    func selectingPreviousWordDoesNotAnimateFromTheDeletedWordSlot() async throws {
        let recorder = ListActionRecorder<String>()
        let host = try NativeListTestHost {
            PhraseEditorFixture(
                initialInput: "head good wolf hand goat gadget yard ice oak jacket table vacant ",
                editingWordIndex: 11,
                recorder: recorder
            )
        }
        defer { host.close() }
        let field = try await input(host)
        try await SendEntryUIProbe.wait(in: host.rootView) { field.isFirstResponder && field.text == "vacant" }
        field.selectedTextRange = field.textRange(from: field.beginningOfDocument, to: field.endOfDocument)
        field.deleteBackward()
        #expect(field.text == "")
        host.rootView.layoutIfNeeded()
        await Task.yield()
        let oldPosition = field.convert(field.bounds, to: host.rootView).origin
        field.deleteBackward()
        #expect(field.text == "table")
        // Sample the actual native field over the former spring's duration.
        // Ignore the old slot before SwiftUI's first layout, then require the
        // word to stay at its destination throughout the remaining frames.
        var positions: [CGPoint] = []
        for _ in 0..<24 {
            try await Task.sleep(for: .milliseconds(16))
            host.rootView.layoutIfNeeded()
            let position = field.convert(field.bounds, to: host.rootView).origin
            if !positions.isEmpty || abs(position.x - oldPosition.x) > 0.5 || abs(position.y - oldPosition.y) > 0.5 {
                positions.append(position)
            }
        }
        let first = try #require(positions.first)
        #expect(positions.count > 12)
        #expect(positions.allSatisfy { abs($0.x - first.x) <= 0.5 && abs($0.y - first.y) <= 0.5 })
        #expect(field.isFirstResponder)
        #expect(SendEntryUIProbe.views(UITextField.self, in: host.rootView).first === field)
        #expect(recorder.actions.last == "head good wolf hand goat gadget yard ice oak jacket table")
    }

    @Test
    func spaceCompletionKeepsNextKeystrokeAndPastedWordsLiteral() async throws {
        let recorder = ListActionRecorder<String>()
        let host = try NativeListTestHost { PhraseEditorFixture(recorder: recorder) }
        defer { host.close() }
        let field = try await input(host)
        #expect(field.becomeFirstResponder())
        field.insertText("ham")
        try await completion("mer", field: field, host: host)
        field.insertText(" ")
        field.insertText("ab")
        #expect(recorder.actions.last == "hammer ab")
        try await completion("andon", field: field, host: host)
        // A multi-character insertion must not accept or rewrite a preview.
        field.insertText(" ham notaword ")
        #expect(recorder.actions.last == "hammer ab ham notaword ")
        #expect(field.text == "")
        #expect(field.isFirstResponder)
    }

    @Test(arguments: ["selection", "middle", "composition"])
    func spaceDoesNotAcceptAHiddenCompletion(scenario: String) async throws {
        let recorder = ListActionRecorder<String>()
        let host = try NativeListTestHost { PhraseEditorFixture(recorder: recorder) }
        defer { host.close() }
        let field = try await input(host)
        #expect(field.becomeFirstResponder())
        field.insertText("ham")
        try await completion("mer", field: field, host: host)
        let range: NSRange
        switch scenario {
        case "selection":
            field.selectedTextRange = field.textRange(from: field.beginningOfDocument, to: field.endOfDocument)
            range = NSRange(location: 0, length: 3)
        case "middle":
            let middle = try #require(field.position(from: field.beginningOfDocument, offset: 1))
            field.selectedTextRange = field.textRange(from: middle, to: middle)
            range = NSRange(location: 1, length: 0)
        default:
            field.setMarkedText("ham", selectedRange: NSRange(location: 3, length: 0))
            range = NSRange(location: 3, length: 0)
        }
        #expect(field.delegate?.textField?(field, shouldChangeCharactersIn: range, replacementString: " ") == true)
        #expect(recorder.actions.last == "ham")
    }

    @Test
    func selectionCompositionAndDeletionDoNotAcceptHiddenCompletions() async throws {
        let recorder = ListActionRecorder<String>()
        let host = try NativeListTestHost { PhraseEditorFixture(recorder: recorder) }
        defer { host.close() }
        let field = try await input(host)
        #expect(field.becomeFirstResponder())
        field.insertText("ham")
        try await completion("mer", field: field, host: host)
        field.selectedTextRange = field.textRange(from: field.beginningOfDocument, to: field.endOfDocument)
        field.delegate?.textFieldDidChangeSelection?(field)
        try await completion(nil, field: field, host: host)
        #expect(field.delegate?.textFieldShouldReturn?(field) == false)
        #expect(recorder.actions.last == "ham ")
        field.insertText("ab")
        try await completion("andon", field: field, host: host)
        let middle = try #require(field.position(from: field.beginningOfDocument, offset: 1))
        field.selectedTextRange = field.textRange(from: middle, to: middle)
        field.delegate?.textFieldDidChangeSelection?(field)
        try await completion(nil, field: field, host: host)
        #expect(field.delegate?.textFieldShouldReturn?(field) == false)
        #expect(recorder.actions.last == "ham ab ")
        field.setMarkedText("ham", selectedRange: NSRange(location: 3, length: 0))
        try await completion(nil, field: field, host: host)
        #expect(field.delegate?.textFieldShouldReturn?(field) == false)
        #expect(recorder.actions.last == "ham ab ")
        field.unmarkText()
        field.sendActions(for: .editingChanged)
        try await completion("mer", field: field, host: host)
        field.deleteBackward()
        try await completion("bit", field: field, host: host)
        #expect(field.text == "ha")
        #expect(recorder.actions.last == "ham ab ha")
    }

    @Test
    func acceptingLastCompletionDismissesKeyboardOnlyForValidMnemonic() async throws {
        let prefix = Array(repeating: "abandon", count: 11).joined(separator: " ") + " "
        let recorder = ListActionRecorder<String>()
        let host = try NativeListTestHost { PhraseEditorFixture(initialInput: prefix, recorder: recorder) }
        defer { host.close() }
        let field = try await input(host)
        #expect(field.becomeFirstResponder())
        field.insertText("abou")
        try await completion("t", field: field, host: host)
        #expect(field.delegate?.textFieldShouldReturn?(field) == false)
        #expect(recorder.actions.last == prefix + "about ")
        #expect(!field.isFirstResponder)
    }

    private func completion(_ suffix: String?, field: UITextField, host: NativeListTestHost) async throws {
        try await SendEntryUIProbe.wait(in: host.rootView) {
            guard let label = SendEntryUIProbe.views(UILabel.self, in: field).first(where: {
                $0.accessibilityIdentifier == "recoveryPhraseInlineCompletion"
            }) else { return false }
            return suffix.map { label.text == $0 && !label.isHidden } ?? label.isHidden
        }
        guard suffix != nil else { return }
        let label = try #require(SendEntryUIProbe.views(UILabel.self, in: field).first {
            $0.accessibilityIdentifier == "recoveryPhraseInlineCompletion"
        })
        let window = try #require(field.window)
        // Compare the native insertion point and the visible ending in their
        // common window coordinates, including UIKit's text-input insets.
        let insertion = field.textInputView.convert(field.caretRect(for: field.endOfDocument), to: window)
        let ending = label.convert(label.bounds, to: window)
        #expect(abs(ending.minX - insertion.minX) <= 0.5, "Completion must follow the typed letters")
        #expect(abs(ending.midY - insertion.midY) <= 0.5, "Completion must share the native text line")
        #expect(label.font == field.font)
        #expect(label.numberOfLines == 1)
        #expect(field.bounds.contains(label.frame))
    }

    private func completionWidth(_ word: String, field: UITextField, host: NativeListTestHost) async throws {
        let font = try #require(field.font)
        let width = max(max(44, ceil(font.lineHeight) + 16), ceil(word.size(withAttributes: [.font: font]).width) + 28)
        try await SendEntryUIProbe.wait(in: host.rootView) { abs(field.bounds.width - width) < 0.5 }
    }

    @Test(arguments: [false, true])
    func acceptingCompletionWhileEditingKeepsFollowingWordsInOrder(useSpace: Bool) async throws {
        let recorder = ListActionRecorder<String>()
        let host = try NativeListTestHost {
            PhraseEditorFixture(initialInput: "hello world yellow ", editingWordIndex: 1, recorder: recorder)
        }
        defer { host.close() }
        try await SendEntryUIProbe.wait(in: host.rootView) {
            SendEntryUIProbe.views(UITextField.self, in: host.rootView).contains {
                $0.isFirstResponder && $0.text == "world"
            }
        }
        let field = try #require(SendEntryUIProbe.views(UITextField.self, in: host.rootView).first { $0.isFirstResponder })
        field.selectedTextRange = field.textRange(from: field.beginningOfDocument, to: field.endOfDocument)
        field.insertText("ham")
        try await completion("mer", field: field, host: host)
        #expect(recorder.actions.last == "hello ham yellow")
        if useSpace {
            field.insertText(" ")
        } else {
            #expect(field.delegate?.textFieldShouldReturn?(field) == false)
        }
        #expect(recorder.actions.last == "hello hammer yellow ")
        #expect(field.text == "")
        #expect(field.isFirstResponder)
    }

    @Test(arguments: [NativeListTestLayout.phone, .pad, .largeTextRTL])
    func returnCommitsEachWordWithoutDismissingOrRepeatingIt(layout: NativeListTestLayout) async throws {
        let recorder = ListActionRecorder<String>()
        let host = try NativeListTestHost(layout: layout) { PhraseEditorFixture(recorder: recorder) }
        defer { host.close() }
        let field = try await input(host)
        #expect(field.becomeFirstResponder())
        field.insertText("hello")
        WalletTextInputConfiguration.apply(layout.direction, to: field)
        #expect(field.delegate?.textFieldShouldReturn?(field) == false)
        #expect(field.isFirstResponder)
        #expect(field.text == "")
        // No redraw between Return and the next keystroke: the native buffer
        // must already be empty, so the previous word cannot be duplicated.
        field.insertText("hidden")
        WalletTextInputConfiguration.apply(layout.direction, to: field)
        #expect(field.delegate?.textField?(field, shouldChangeCharactersIn: NSRange(), replacementString: "\n") == false)
        #expect(field.text == "")
        #expect(field.isFirstResponder)
        try await SendEntryUIProbe.wait(in: host.rootView) {
            recorder.actions.last == "hello hidden "
                && SendEntryUIProbe.element("recoveryPhraseWord_2", in: host.rootView)?.accessibilityValue == "hidden"
        }
        #expect(field.delegate?.textFieldShouldReturn?(field) == false)
        #expect(field.isFirstResponder)
        #expect(recorder.actions.last == "hello hidden ")
    }

    @Test(arguments: ["empty", "incomplete", "invalidChecksum", "unknownWord", "bip39", "electrum"])
    func returnDismissesOnlyForAValidCompletePhrase(scenario: String) async throws {
        let prefix = Array(repeating: "abandon", count: 11).joined(separator: " ")
        let phrase: String
        switch scenario {
        case "empty": phrase = ""
        case "incomplete": phrase = prefix
        case "invalidChecksum": phrase = prefix + " abandon"
        case "unknownWord": phrase = prefix + " notaword"
        case "electrum": phrase = "cycle rocket west magnet parrot shuffle foot correct salt library feed song"
        default: phrase = prefix + " about"
        }
        let isValid = scenario == "bip39" || scenario == "electrum"
        let recorder = ListActionRecorder<String>()
        let host = try NativeListTestHost {
            PhraseEditorFixture(initialInput: phrase, recorder: recorder)
        }
        defer { host.close() }
        let field = try await input(host)
        #expect(field.becomeFirstResponder())
        WalletTextInputConfiguration.apply(.leftToRight, to: field)
        #expect(field.delegate?.textFieldShouldReturn?(field) == false)
        #expect(field.isFirstResponder == !isValid)
        #expect(field.text == "")
        #expect(recorder.actions.last == (phrase.isEmpty ? "" : phrase + " "))
        await Task.yield()
        host.rootView.layoutIfNeeded()
        #expect(field.isFirstResponder == !isValid)
    }

    @Test(arguments: [true, false])
    func onlyCompleteUnfocusedPhrasesHideTheEmptyInput(valid: Bool) async throws {
        let words = Array(repeating: "abandon", count: 11) + [valid ? "about" : "abandon"]
        let host = try NativeListTestHost {
            PhraseEditorFixture(initialInput: words.joined(separator: " ") + " ", recorder: ListActionRecorder())
        }
        defer { host.close() }
        try await SendEntryUIProbe.wait(in: host.rootView) {
            SendEntryUIProbe.views(UILabel.self, in: host.rootView).filter {
                words.contains($0.text ?? "")
            }.count >= 12
        }
        let inputs = SendEntryUIProbe.views(UITextField.self, in: host.rootView)
        #expect(inputs.isEmpty == valid)
    }

    @Test(arguments: NativeListTestLayout.allCases)
    func typingCreatesNumberedPillsAndKeepsKeyboardFocus(
        layout: NativeListTestLayout
    ) async throws {
        let recorder = ListActionRecorder<String>()
        let host = try NativeListTestHost(layout: layout) {
            PhraseEditorFixture(recorder: recorder)
        }
        defer { host.close() }
        let field = try await input(host)
        #expect(field.borderStyle == .none)
        #expect(field.becomeFirstResponder())
        field.insertText("hello")
        try await SendEntryUIProbe.wait(in: host.rootView) { recorder.actions.last == "hello" }
        #expect(SendEntryUIProbe.element("recoveryPhraseWord_1", in: host.rootView) == nil)
        field.insertText(" ")
        try await SendEntryUIProbe.wait(in: host.rootView) {
            recorder.actions.last == "hello "
        }
        #expect(field.text == "")
        #expect(SendEntryUIProbe.element("recoveryPhraseWord_1", in: host.rootView) != nil)
        #expect(field.isFirstResponder)
        field.insertText("world help hello world help ")
        try await SendEntryUIProbe.wait(in: host.rootView) {
            guard let first = SendEntryUIProbe.element("recoveryPhraseWord_1", in: host.rootView),
                  let last = SendEntryUIProbe.element("recoveryPhraseWord_6", in: host.rootView) else { return false }
            return first.accessibilityFrame.height >= 43.99 && last.accessibilityFrame.height >= 43.99
                && abs(first.accessibilityFrame.minX - (host.rootView.window!.bounds.minX + 28)) < 0.1
        }
        #expect(recorder.actions.last == "hello world help hello world help ")
        let pills = try (1...6).map { index in
            try #require(SendEntryUIProbe.element("recoveryPhraseWord_\(index)", in: host.rootView))
        }
        let frames = pills.map { $0.accessibilityFrame }
        #expect(abs(frames[0].minX - (host.rootView.window!.bounds.minX + 28)) < 2)
        for frame in frames {
            #expect(frame.width > 0 && frame.height >= 43.99)
            #expect(frame.minX >= host.rootView.window!.bounds.minX)
            #expect(frame.maxX <= host.rootView.window!.bounds.maxX)
        }
        for (index, frame) in frames.enumerated() {
            for other in frames.dropFirst(index + 1) {
                #expect(!frame.insetBy(dx: 1, dy: 1).intersects(other))
            }
        }
        if abs(frames[0].midY - frames[1].midY) < 1 {
            #expect(frames[0].midX < frames[1].midX)
        }
        #expect(pills[0].accessibilityValue == "hello")
        #expect(pills[0].accessibilityTraits.contains(UIAccessibilityTraits.button))
        #expect(field.isFirstResponder)
        field.insertText("final")
        host.rootView.endEditing(true)
        try await SendEntryUIProbe.wait(in: host.rootView) {
            SendEntryUIProbe.element("recoveryPhraseWord_7", in: host.rootView)?.accessibilityValue == "final"
        }
    }

    @Test(arguments: [NativeListTestLayout.phone, .pad, .largeTextRTL])
    func nativePillMenuEditsInPlaceAndClearsOneWord(layout: NativeListTestLayout) async throws {
        let recorder = ListActionRecorder<String>()
        let host = try NativeListTestHost(layout: layout) {
            PhraseEditorFixture(initialInput: "alpha beta gamma ", recorder: recorder)
        }
        defer { host.close() }
        let input = try await input(host)
        #expect(input.becomeFirstResponder())
        try await menuAction(0, word: 2, host: host)
        // The outgoing empty field can remain in UIKit during the pill
        // transition. Wait for the actual in-place editor to own focus.
        try await SendEntryUIProbe.wait(in: host.rootView) {
            SendEntryUIProbe.views(UITextField.self, in: host.rootView).contains {
                $0.text == "beta" && $0.isFirstResponder
            }
        }
        let field = try #require(SendEntryUIProbe.views(UITextField.self, in: host.rootView)
            .first { $0.text == "beta" && $0.isFirstResponder })
        field.selectedTextRange = field.textRange(from: field.beginningOfDocument, to: field.endOfDocument)
        field.insertText("brave ")
        try await SendEntryUIProbe.wait(in: host.rootView) {
            recorder.actions.last == "alpha brave gamma "
                && SendEntryUIProbe.element("recoveryPhraseWord_2", in: host.rootView)?.accessibilityValue == "brave"
        }
        try await menuAction(1, word: 2, host: host)
        #expect(recorder.actions.last == "alpha gamma ")
        try await SendEntryUIProbe.wait(in: host.rootView) {
            SendEntryUIProbe.element("recoveryPhraseWord_2", in: host.rootView)?.accessibilityValue == "gamma"
        }
        #expect(SendEntryUIProbe.element("recoveryPhraseWord_3", in: host.rootView) == nil)
    }

    @Test(arguments: [DynamicTypeSize.large, .accessibility5])
    func pillWordsUseTheirNaturalWidthAndStayInsideTheirBackground(textSize: DynamicTypeSize) async throws {
        let values = ["hello", "hidden", "interrogation"]
        let host = try NativeListTestHost {
            PhraseEditorFixture(initialInput: values.joined(separator: " ") + " ", recorder: ListActionRecorder())
                .environment(\.dynamicTypeSize, textSize)
        }
        defer { host.close() }
        try await SendEntryUIProbe.wait(in: host.rootView) {
            SendEntryUIProbe.views(UILabel.self, in: host.rootView).filter {
                values.contains($0.text ?? "") && $0.bounds.height > 0
            }.count == values.count
        }
        for (index, value) in values.enumerated() {
            let word = try #require(SendEntryUIProbe.views(UILabel.self, in: host.rootView)
                .first { $0.text == value })
            let requiredHeight = word.sizeThatFits(CGSize(width: word.bounds.width, height: .greatestFiniteMagnitude)).height
            #expect(word.bounds.height >= requiredHeight - 1)
            let frame = word.convert(word.bounds, to: nil)
            let pill = try #require(SendEntryUIProbe.element("recoveryPhraseWord_\(index + 1)", in: host.rootView))
            #expect(pill.accessibilityFrame.insetBy(dx: -1, dy: -1).contains(frame))
            #expect(frame.minX >= 28 && frame.maxX <= host.rootView.window!.bounds.maxX - 28)
            if textSize == .large {
                #expect(word.bounds.height <= ceil(word.font.lineHeight) + 1)
                let naturalWidth = ceil(value.size(withAttributes: [.font: word.font!]).width)
                #expect(word.bounds.width >= naturalWidth - 1)
            }
        }
    }

    @Test(arguments: [NativeListTestLayout.phone, .pad, .largeTextRTL])
    func backspaceSelectsThenDeletesTheWholeWord(layout: NativeListTestLayout) async throws {
        let recorder = ListActionRecorder<String>()
        let host = try NativeListTestHost(layout: layout) {
            PhraseEditorFixture(initialInput: "hello hidden ", recorder: recorder)
        }
        defer { host.close() }
        let field = try await input(host)
        #expect(field.becomeFirstResponder())
        field.deleteBackward()
        let editing = try await selectedInput("hidden", host: host)
        #expect(recorder.actions.last == "hello hidden")
        editing.deleteBackward()
        try await SendEntryUIProbe.wait(in: host.rootView) {
            recorder.actions.last == "hello " && SendEntryUIProbe.views(UITextField.self, in: host.rootView)
                .contains { $0.isFirstResponder && $0.text == "" }
        }
        let empty = try #require(SendEntryUIProbe.views(UITextField.self, in: host.rootView).first { $0.isFirstResponder })
        empty.deleteBackward()
        let first = try await selectedInput("hello", host: host)
        first.insertText("help ")
        try await SendEntryUIProbe.wait(in: host.rootView) {
            recorder.actions.last == "help " && SendEntryUIProbe.element("recoveryPhraseWord_1", in: host.rootView)?.accessibilityValue == "help"
        }
        #expect(SendEntryUIProbe.element("recoveryPhraseWord_2", in: host.rootView) == nil)
    }

    @Test func movingTheCaretAllowsCharacterEditingAfterBackspaceSelection() async throws {
        let recorder = ListActionRecorder<String>()
        let host = try NativeListTestHost {
            PhraseEditorFixture(initialInput: "hello hidden ", recorder: recorder)
        }
        defer { host.close() }
        let field = try await input(host)
        #expect(field.becomeFirstResponder())
        field.deleteBackward()
        let editing = try await selectedInput("hidden", host: host)
        editing.selectedTextRange = editing.textRange(from: editing.endOfDocument, to: editing.endOfDocument)
        editing.deleteBackward()
        #expect(recorder.actions.last == "hello hidde")
        editing.insertText("n ")
        try await SendEntryUIProbe.wait(in: host.rootView) { recorder.actions.last == "hello hidden " }
    }

    @Test(arguments: [NativeListTestLayout.phone, .pad, .largeTextRTL])
    func repeatedDeleteKeepsTheOriginalKeyboardInputUntilAllWordsAreRemoved(layout: NativeListTestLayout) async throws {
        let words = ["hello", "hidden", "brave", "sand", "catch", "venue"]
        let recorder = ListActionRecorder<String>()
        let host = try NativeListTestHost(layout: layout) {
            PhraseEditorFixture(initialInput: words.joined(separator: " ") + " ", recorder: recorder)
        }
        defer { host.close() }
        let field = try await input(host)
        #expect(field.becomeFirstResponder())
        for remaining in stride(from: words.count, through: 1, by: -1) {
            // A held key continues sending events to the same native input.
            // Do not find/refocus a replacement text field between events.
            #expect(field.hasText)
            #expect(field.isFirstResponder)
            field.deleteBackward()
            let editing = try await selectedInput(words[remaining - 1], host: host)
            #expect(editing === field)
            #expect(field.isFirstResponder)
            field.deleteBackward()
            let expected = words.prefix(remaining - 1).joined(separator: " ")
            try await SendEntryUIProbe.wait(in: host.rootView) {
                recorder.actions.last == (expected.isEmpty ? "" : expected + " ")
                    && field.text == "" && field.hasText == !expected.isEmpty
            }
            #expect(field.isFirstResponder)
        }
        // No delayed deletion after the repeat events stop or typing resumes.
        field.deleteBackward()
        #expect(recorder.actions.last == "")
        field.insertText("hello ")
        try await SendEntryUIProbe.wait(in: host.rootView) { recorder.actions.last == "hello " }
        #expect(field.isFirstResponder)
    }

    @Test func keyboardBoundaryNeverEntersThePhraseOrASelection() async throws {
        let recorder = ListActionRecorder<String>()
        let host = try NativeListTestHost { PhraseEditorFixture(recorder: recorder) }
        defer { host.close() }
        let field = try await input(host)
        #expect(field.becomeFirstResponder())
        #expect(field.text == "")
        #expect(!field.hasText)
        field.insertText("hidden")
        #expect(recorder.actions.last == "hidden")
        #expect(field.accessibilityValue == "hidden")
        field.selectAll(nil)
        let selection = try #require(field.selectedTextRange)
        #expect(field.text(in: selection) == "hidden")
        // Even an explicit whole-document selection excludes keyboard context.
        field.selectedTextRange = field.textRange(from: field.beginningOfDocument, to: field.endOfDocument)
        #expect(field.text(in: try #require(field.selectedTextRange)) == "hidden")
        field.insertText("alpha beta ")
        #expect(recorder.actions.last == "alpha beta ")
        field.deleteBackward()
        #expect(field.text == "beta")
        #expect(field.text(in: try #require(field.selectedTextRange)) == "beta")
        field.deleteBackward()
        #expect(recorder.actions.last == "alpha ")
        #expect(recorder.actions.allSatisfy { !$0.contains("\u{200B}") })
    }

    @Test func repeatedDeleteStopsAtTheBeginningOfAMiddleEdit() async throws {
        let recorder = ListActionRecorder<String>()
        let host = try NativeListTestHost {
            PhraseEditorFixture(initialInput: "alpha beta gamma ", editingWordIndex: 1, recorder: recorder)
        }
        defer { host.close() }
        let field = try await input(host)
        #expect(field.becomeFirstResponder())
        field.selectAll(nil)
        for _ in 0..<10 { field.deleteBackward() }
        try await SendEntryUIProbe.wait(in: host.rootView) { !field.hasText }
        #expect(recorder.actions.last == "gamma ")
        field.insertText("new ")
        #expect(recorder.actions.last == "new gamma ")
    }

    @Test func rapidDeleteRepeatsReconcileBeforeTheNextSwiftUIUpdate() async throws {
        let recorder = ListActionRecorder<String>()
        let host = try NativeListTestHost {
            PhraseEditorFixture(initialInput: "hello hidden brave ", recorder: recorder)
        }
        defer { host.close() }
        let field = try await input(host)
        #expect(field.becomeFirstResponder())
        // Repeat can arrive faster than the next SwiftUI layout pass.
        for _ in 0..<6 { field.deleteBackward() }
        #expect(recorder.actions.last == "")
        try await SendEntryUIProbe.wait(in: host.rootView) { !field.hasText }
        #expect(field.isFirstResponder)
    }

    @Test func repeatedDeleteFromAMiddleEditLeavesFollowingWordsUntouched() async throws {
        let recorder = ListActionRecorder<String>()
        let host = try NativeListTestHost {
            PhraseEditorFixture(initialInput: "alpha beta gamma ", recorder: recorder)
        }
        defer { host.close() }
        let field = try await input(host)
        #expect(field.becomeFirstResponder())
        try await menuAction(0, word: 2, host: host)
        try await SendEntryUIProbe.wait(in: host.rootView) { field.isFirstResponder && field.text == "beta" }
        field.selectedTextRange = field.textRange(from: field.beginningOfDocument, to: field.endOfDocument)
        field.deleteBackward()
        field.deleteBackward()
        field.deleteBackward()
        for _ in 0..<8 { field.deleteBackward() }
        try await SendEntryUIProbe.wait(in: host.rootView) { recorder.actions.last == "gamma " && field.text == "" }
        #expect(field.isFirstResponder)
        field.insertText("hello ")
        try await SendEntryUIProbe.wait(in: host.rootView) { recorder.actions.last == "hello gamma " }
    }

    private func selectedInput(_ value: String, host: NativeListTestHost) async throws -> UITextField {
        var selected: UITextField?
        try await SendEntryUIProbe.wait(in: host.rootView) {
            selected = SendEntryUIProbe.views(UITextField.self, in: host.rootView).first {
                $0.isFirstResponder && $0.text == value && $0.selectedTextRange.map { $0.isEmpty == false } == true
            }
            return selected != nil
        }
        return try #require(selected)
    }

    @Test func markedCompositionIsNotTokenizedUntilCommitted() async throws {
        let recorder = ListActionRecorder<String>()
        let host = try NativeListTestHost { PhraseEditorFixture(recorder: recorder) }
        defer { host.close() }
        let field = try await input(host)
        #expect(field.becomeFirstResponder())
        field.setMarkedText("あい", selectedRange: NSRange(location: 2, length: 0))
        field.sendActions(for: .editingChanged)
        #expect(SendEntryUIProbe.element("recoveryPhraseWord_1", in: host.rootView) == nil)
        field.unmarkText()
        field.sendActions(for: .editingChanged)
        field.insertText(" ")
        try await SendEntryUIProbe.wait(in: host.rootView) {
            SendEntryUIProbe.element("recoveryPhraseWord_1", in: host.rootView)?.accessibilityValue == "あい"
        }
        #expect(recorder.actions.last == "あい ")
        #expect(field.text == "")
    }

    private func input(_ host: NativeListTestHost) async throws -> UITextField {
        try await SendEntryUIProbe.wait(in: host.rootView) {
            !SendEntryUIProbe.views(UITextField.self, in: host.rootView).isEmpty
        }
        return try #require(SendEntryUIProbe.views(UITextField.self, in: host.rootView).first)
    }

    private func menuAction(_ index: Int, word: Int, host: NativeListTestHost) async throws {
        var candidate: UIButton?
        try await SendEntryUIProbe.wait(in: host.rootView) {
            guard let pill = SendEntryUIProbe.element("recoveryPhraseWord_\(word)", in: host.rootView) else {
                return false
            }
            let center = CGPoint(x: pill.accessibilityFrame.midX, y: pill.accessibilityFrame.midY)
            // SwiftUI may retain a different UIKit subview order after a pill
            // is replaced. Activate the numbered pill at its actual position.
            candidate = SendEntryUIProbe.views(UIButton.self, in: host.rootView).first {
                $0.menu != nil && !$0.isHidden && $0.convert($0.bounds, to: nil).contains(center)
            }
            return candidate != nil
        }
        let button = try #require(candidate)
        let interaction = try #require(button.contextMenuInteraction)
        defer { interaction.dismissMenu() }
        button.performPrimaryAction()
        var actions: [UIAction] = []
        try await SendEntryUIProbe.wait(in: host.rootView) {
            interaction.updateVisibleMenu { menu in
                actions = menuActions(menu)
                return menu
            }
            return actions.count == 2
        }
        #expect(actions[0].image == nil && actions[1].image == nil)
        let action = actions[index]
        interaction.dismissMenu()
        button.sendAction(action)
    }

    private func menuActions(_ menu: UIMenu) -> [UIAction] {
        menu.children.flatMap { element in
            if let action = element as? UIAction { return [action] }
            if let menu = element as? UIMenu { return menuActions(menu) }
            return []
        }
    }
}

private struct PhraseEditorFixture: View {
    @State private var state: RecoveryPhraseEditorState
    @State private var focus: Bool
    let recorder: ListActionRecorder<String>

    init(initialInput: String = "", editingWordIndex: Int? = nil, recorder: ListActionRecorder<String>) {
        var state = RecoveryPhraseEditorState(input: initialInput)
        if let editingWordIndex { state.edit(state.words[editingWordIndex].id) }
        _state = State(initialValue: state)
        _focus = State(initialValue: editingWordIndex != nil)
        self.recorder = recorder
    }

    var body: some View {
        ScrollView {
            RecoveryPhraseEditor(state: $state, isFocused: $focus) { recorder.actions.append($0) }
                .padding(28)
        }
    }
}


@MainActor
@Suite(.serialized)
struct SelfCustodyInputSecurityTests {
    @Test
    func applicationRejectsThirdPartyKeyboards() {
        let delegate = PushNotificationAppDelegate()
        #expect(!delegate.application(
            UIApplication.shared, shouldAllowExtensionPointIdentifier: .keyboard
        ))
    }

    @Test
    func credentialTypingDisablesSystemWritingToolsAndPrediction() async throws {
        let recorder = ListActionRecorder<String>()
        let host = try NativeListTestHost(layout: .phone) {
            PhraseEditorFixture(recorder: recorder)
        }
        defer { host.close() }
        try await SendEntryUIProbe.wait(in: host.rootView) {
            !SendEntryUIProbe.views(UITextField.self, in: host.rootView).isEmpty
        }
        let field = try #require(SendEntryUIProbe.views(UITextField.self, in: host.rootView).first)
        #expect(field.writingToolsBehavior == .none)
        #expect(field.autocorrectionType == .no)
        #expect(field.inlinePredictionType == .no)
        #expect(field.spellCheckingType == .no)
        #expect(field.becomeFirstResponder())
        field.insertText("habit")
        try await SendEntryUIProbe.wait(in: host.rootView) {
            recorder.actions.last == "habit"
        }
        #expect(field.text == "habit")
    }
}
