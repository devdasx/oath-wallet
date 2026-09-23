import Testing
@testable import Aperture

struct RecoveryPhraseEditorStateTests {
    @Test func numberedUppercaseInputBecomesOnlyLowercaseWords() {
        var editor = RecoveryPhraseEditorState()
        editor.replace(with: "1. ABANDON, 2) ABILITY\n3: ABLE! 4. ABOUT")
        #expect(editor.words.map(\.value) == ["abandon", "ability", "able", "about"])
        #expect(editor.text == "abandon ability able about ")
        editor.updateFragment("HAB1IT")
        #expect(editor.fragment == "habit")
        #expect(editor.text == "abandon ability able about habit")
    }

    @Test func normalizationPreservesNonEnglishLettersAndCombiningMarks() {
        var editor = RecoveryPhraseEditorState()
        editor.replace(with: "1. ACADÉMIE 2. あいこくしん 3. 的")
        #expect(editor.words.map(\.value) == ["académie".decomposedStringWithCompatibilityMapping, "あいこくしん", "的"])
    }

    @Test func invalidPrefixFeedbackDistinguishesPartialFromCompletedWords() {
        #expect(!RecoveryPhraseCompletion.isInvalidFragment("hab", precedingWords: ["abandon"]))
        #expect(!RecoveryPhraseCompletion.isInvalidFragment("habit", precedingWords: ["abandon"]))
        #expect(!RecoveryPhraseCompletion.isInvalidFragment("", precedingWords: []))
        #expect(RecoveryPhraseCompletion.isInvalidFragment("uu", precedingWords: ["abandon"]))
        #expect(RecoveryPhraseCompletion.isInvalidWord("hab"))
        #expect(!RecoveryPhraseCompletion.isInvalidWord("habit"))
    }

    @Test func aWordOnlyCommitsAfterASeparatorOrDone() {
        var editor = RecoveryPhraseEditorState()
        editor.updateFragment("hello")
        #expect(editor.words.isEmpty)
        #expect(editor.text == "hello")
        editor.updateFragment("hello ")
        #expect(editor.words.map(\.value) == ["hello"])
        #expect(editor.fragment.isEmpty)
        editor.updateFragment("world")
        editor.finishWord()
        #expect(editor.words.map(\.value) == ["hello", "world"])
        #expect(editor.text == "hello world ")
    }

    @Test(arguments: [" ", "\n", "\t", "\u{3000}"])
    func separatorsAndPastedPhrasesPreserveWordOrder(separator: String) {
        var editor = RecoveryPhraseEditorState()
        editor.updateFragment("hello" + separator + "world" + separator + "he")
        #expect(editor.words.map(\.value) == ["hello", "world"])
        #expect(editor.fragment == "he")
        editor.selectSuggestion("help")
        #expect(editor.words.map(\.value) == ["hello", "world", "help"])
        editor.replace(with: "  alpha\n beta  gamma ")
        #expect(editor.words.map(\.value) == ["alpha", "beta", "gamma"])
        #expect(editor.fragment.isEmpty)
    }

    @Test func editingMiddleWordKeepsSuffixAndIdentity() {
        var editor = RecoveryPhraseEditorState(input: "alpha beta gamma ")
        let id = editor.words[1].id
        editor.edit(id)
        #expect(editor.fragment == "beta")
        #expect(editor.wordsBeforeFragment == ["alpha"])
        editor.updateFragment("b")
        #expect(editor.text == "alpha b gamma")
        editor.selectSuggestion("brave")
        #expect(editor.words.map(\.value) == ["alpha", "brave", "gamma"])
        #expect(editor.words[1].id == id)
    }

    @Test func editingPreservesPendingWordAndOtherDuplicates() {
        var editor = RecoveryPhraseEditorState(input: "hello hello hel")
        let firstID = editor.words[0].id
        let secondID = editor.words[1].id
        #expect(firstID != secondID)
        editor.edit(firstID)
        #expect(editor.words.map(\.value) == ["hello", "hello", "hel"])
        editor.updateFragment("help ")
        #expect(editor.words[0].id == firstID)
        editor.remove(secondID)
        #expect(editor.words.map(\.value) == ["help", "hel"])
    }

    @Test func pasteIntoMiddleEditKeepsFollowingWords() {
        var editor = RecoveryPhraseEditorState(input: "alpha beta gamma ")
        editor.edit(editor.words[1].id)
        editor.updateFragment("hello world he")
        #expect(editor.text == "alpha hello world he gamma")
        #expect(editor.wordsBeforeFragment == ["alpha", "hello", "world"])
        editor.selectSuggestion("help")
        #expect(editor.words.map(\.value) == ["alpha", "hello", "world", "help", "gamma"])
    }

    @Test func clearingAnEditOrTheWholePhraseLeavesNoStaleText() {
        var editor = RecoveryPhraseEditorState(input: "alpha beta gamma ")
        editor.edit(editor.words[1].id)
        editor.updateFragment("")
        editor.finishWord()
        #expect(editor.words.map(\.value) == ["alpha", "gamma"])
        editor.edit(editor.words[0].id)
        editor.remove(editor.words[0].id)
        #expect(editor.text == "gamma ")
        editor.clear()
        #expect(!editor.hasContent)
        #expect(editor.text.isEmpty)
        #expect(editor.editingID == nil)
    }

    @Test func tokenizingDoesNotChangeValidationOrPhraseOrder() {
        // Published BIP-39 fixture; no real wallet material or network requests.
        let words = Array(repeating: "abandon", count: 11) + ["about"]
        var editor = RecoveryPhraseEditorState(input: words.joined(separator: " "))
        #expect(RecoveryPhraseInputFeedback.evaluate(editor.text) == nil)
        editor.finishWord()
        #expect(editor.words.map(\.value) == words)
        #expect(RecoveryPhraseInputFeedback.evaluate(editor.text) == nil)
        editor.edit(editor.words[11].id)
        editor.updateFragment("invalid")
        #expect(RecoveryPhraseInputFeedback.evaluate(editor.text) != nil)
    }

    @Test func emptyBackspaceSelectsPreviousWordWithoutChangingThePhrase() {
        var editor = RecoveryPhraseEditorState(input: "hello hidden ")
        let id = editor.words[1].id
        editor.selectPreviousWord()
        #expect(editor.editingID == id)
        #expect(editor.fragment == "hidden")
        #expect(editor.selectionRequest != nil)
        #expect(editor.text == "hello hidden")
        editor.updateFragment("help")
        #expect(editor.selectionRequest == nil)
        editor.finishWord()
        #expect(editor.words.map(\.value) == ["hello", "help"])
        #expect(editor.words[1].id == id)
        editor.selectPreviousWord()
        editor.remove(id)
        #expect(editor.text == "hello ")
        #expect(editor.selectionRequest == nil)
    }

    @Test func backspaceAtAnEmptyMiddleWordPreservesTheSuffix() {
        var editor = RecoveryPhraseEditorState(input: "alpha beta gamma ")
        editor.edit(editor.words[1].id)
        editor.updateFragment("")
        editor.selectPreviousWord()
        #expect(editor.fragment == "alpha")
        #expect(editor.text == "alpha gamma")
        editor.remove(editor.words[0].id)
        #expect(editor.text == "gamma ")
        editor.clear()
        editor.selectPreviousWord()
        #expect(editor.text.isEmpty)
        #expect(editor.editingID == nil)
    }

    @Test func repeatedDeletionAtTheStartNeverMovesAfterTheSuffix() {
        var editor = RecoveryPhraseEditorState(input: "alpha beta gamma ")
        editor.edit(editor.words[1].id)
        editor.remove(editor.words[1].id)
        #expect(editor.inputPosition == 1)
        editor.selectPreviousWord()
        #expect(editor.fragment == "alpha")
        editor.remove(editor.words[0].id)
        for _ in 0..<8 { editor.selectPreviousWord() }
        #expect(editor.text == "gamma ")
        #expect(editor.inputPosition == 0)
        #expect(editor.wordsBeforeFragment.isEmpty)
        editor.updateFragment("hello ")
        #expect(editor.text == "hello gamma ")
    }

    @Test func typingIntoADeletedWordPositionPreservesPhraseOrder() {
        var editor = RecoveryPhraseEditorState(input: "alpha beta gamma ")
        editor.edit(editor.words[1].id)
        editor.remove(editor.words[1].id)
        editor.updateFragment("br")
        #expect(editor.text == "alpha br gamma")
        #expect(editor.wordsBeforeFragment == ["alpha"])
        editor.selectSuggestion("brave")
        #expect(editor.words.map(\.value) == ["alpha", "brave", "gamma"])
        editor.clear()
        #expect(editor.inputPosition == 0)
    }
}
