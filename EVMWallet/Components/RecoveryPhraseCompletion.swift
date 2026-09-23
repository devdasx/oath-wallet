import Foundation

/// A local dictionary preview. It is never part of the phrase until accepted.
struct RecoveryPhraseCompletion: Equatable {
    let word: String
    let suffix: String

    static func isInvalidFragment(_ fragment: String, precedingWords: [String]) -> Bool {
        !fragment.isEmpty && BIP39Mnemonic.matchingWordEntries(
            prefix: fragment, precedingWords: precedingWords
        ).isEmpty
    }

    static func isInvalidWord(_ word: String) -> Bool {
        BIP39Mnemonic.firstUnknownWordPosition(in: word) != nil
    }

    static func match(fragment: String, precedingWords: [String]) -> Self? {
        let prefix = fragment.decomposedStringWithCompatibilityMapping.lowercased()
        guard !prefix.isEmpty, !prefix.contains(where: \.isWhitespace) else { return nil }
        let matches = BIP39Mnemonic.matchingWordEntries(prefix: prefix, precedingWords: precedingWords)
        // A complete word must remain exactly what the user entered, even if
        // it is also a prefix of a longer word or belongs to another language.
        guard !matches.contains(where: { $0.word == prefix }) else { return nil }
        let entry = matches.min {
            if ($0.language == .english) != ($1.language == .english) { return $0.language == .english }
            if $0.word != $1.word { return $0.word < $1.word }
            return $0.language.rawValue < $1.language.rawValue
        }
        guard let entry else { return nil }
        return Self(word: entry.word, suffix: String(entry.word.dropFirst(prefix.count)))
    }
}
