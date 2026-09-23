import Foundation
import Testing
@testable import Aperture

struct RecoveryPhraseInputFeedbackTests {
    @Test(arguments: ["", " \n\t "])
    func emptyInputHasNoError(_ input: String) {
        #expect(RecoveryPhraseInputFeedback.evaluate(input) == nil)
    }

    @Test
    func identifiesFirstUnrecognizedWordWithoutIncludingItInMessage() {
        let input = "abandon amount notaword zoo anotherbadword"
        let feedback = RecoveryPhraseInputFeedback.evaluate(input)
        #expect(feedback == .unknownWord(position: 3))
        #expect(feedback?.message.contains("notaword") == false)
        #expect(feedback?.message.contains("anotherbadword") == false)
    }

    @Test(arguments: [1, 3, 11, 13, 25])
    func explainsUnsupportedCounts(_ count: Int) {
        let phrase = Array(repeating: "abandon", count: count).joined(separator: " ")
        #expect(RecoveryPhraseInputFeedback.evaluate(phrase) == .unsupportedWordCount(count))
    }

    @Test
    func explainsBadChecksumWithoutInventingAnIncorrectWord() {
        let phrase = Array(repeating: "abandon", count: 12).joined(separator: " ")
        #expect(RecoveryPhraseInputFeedback.evaluate(phrase) == .invalidPhrase)
    }

    @Test(arguments: BIP39Language.allCases)
    func acceptsValidPhrasesInEverySupportedWordList(_ language: BIP39Language) throws {
        let word = try #require(BIP39Mnemonic.wordEntries(for: language).first?.word)
        let prefix = Array(repeating: word, count: 11).joined(separator: " ")
        let last = try #require(BIP39Mnemonic.lastWordCandidates(precedingPhrase: prefix)
            .first { $0.language == language })
        let phrase = prefix + " " + last.word
        #expect(RecoveryPhraseInputFeedback.evaluate(phrase) == nil)
        #expect(RecoveryPhraseInputFeedback.evaluate("\n" + phrase + "  ") == nil)
    }

    @Test(arguments: [
        "cycle rocket west magnet parrot shuffle foot correct salt library feed song",
        "bitter grass shiver impose acquire brush forget axis eager alone wine silver"
    ])
    func acceptsSupportedElectrumPhrases(_ phrase: String) {
        #expect(RecoveryPhraseInputFeedback.evaluate(phrase) == nil)
    }

    @Test
    func correctingAndClearingInputRemovesFeedback() {
        let prefix = Array(repeating: "abandon", count: 11).joined(separator: " ")
        #expect(RecoveryPhraseInputFeedback.evaluate(prefix + " notaword") == .unknownWord(position: 12))
        #expect(RecoveryPhraseInputFeedback.evaluate(prefix + " about") == nil)
        #expect(RecoveryPhraseInputFeedback.evaluate("") == nil)
    }
}
