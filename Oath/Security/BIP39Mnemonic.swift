import CryptoKit
import Foundation
import WalletCore

enum BIP39Language: String, CaseIterable, Sendable {
    case chineseSimplified = "chinese_simplified"
    case chineseTraditional = "chinese_traditional"
    case czech
    case english
    case french
    case italian
    case japanese
    case korean
    case portuguese
    case spanish

    fileprivate var resourceName: String {
        "bip39_\(rawValue)"
    }
}

struct BIP39MnemonicValidation: Equatable, Sendable {
    let normalizedPhrase: String
    let language: BIP39Language
    let wordCount: Int
}

struct BIP39WordEntry: Hashable, Identifiable, Sendable {
    let language: BIP39Language
    let index: Int
    let word: String

    var id: String {
        "\(language.rawValue):\(index)"
    }

    var binaryIndex: String {
        let value = String(index, radix: 2)
        return String(repeating: "0", count: max(0, 11 - value.count)) + value
    }
}

enum BIP39Mnemonic {
    static let permittedWordCounts = [12, 15, 18, 21, 24]
    static let permittedIncompleteWordCounts = permittedWordCounts.map {
        $0 - 1
    }
    private static let maximumPhraseUTF8Count = 4_096
    private static let maximumWordUTF8Count = 128

    static var supportedLanguages: [BIP39Language] {
        wordLists.map(\.language)
    }

    static func wordEntries(
        for language: BIP39Language
    ) -> [BIP39WordEntry] {
        wordLists.first { $0.language == language }?.entries ?? []
    }

    static func matchingWordEntries(
        prefix: String,
        precedingWords: [String]
    ) -> [BIP39WordEntry] {
        let normalizedPrefix = prefix
            .decomposedStringWithCompatibilityMapping
            .lowercased()
        guard !normalizedPrefix.isEmpty,
              normalizedPrefix.utf8.count <= maximumWordUTF8Count
        else {
            return []
        }

        let normalizedPrecedingWords = precedingWords.map {
            $0.decomposedStringWithCompatibilityMapping
        }
        let compatibleLists = wordLists.filter { wordList in
            normalizedPrecedingWords.allSatisfy {
                wordList.indices[$0] != nil
            }
        }
        let candidateLists = compatibleLists.isEmpty
            ? wordLists
            : compatibleLists

        return candidateLists.flatMap { wordList in
            wordList.entries.filter {
                $0.word.hasPrefix(normalizedPrefix)
            }
        }
    }

    static func lastWordCandidates(
        precedingPhrase: String
    ) -> [BIP39WordEntry] {
        let normalized = normalizedPhrase(precedingPhrase)
        guard !normalized.isEmpty,
              normalized.utf8.count <= maximumPhraseUTF8Count
        else {
            return []
        }

        let words = normalized.split(separator: " ").map(String.init)
        guard permittedIncompleteWordCounts.contains(words.count),
              words.allSatisfy({
                  !$0.isEmpty && $0.utf8.count <= maximumWordUTF8Count
              })
        else {
            return []
        }

        return wordLists.flatMap { wordList -> [BIP39WordEntry] in
            let precedingIndices = words.compactMap {
                wordList.indices[$0]
            }
            guard precedingIndices.count == words.count else {
                return []
            }

            return wordList.entries.filter { candidate in
                checksumIsValid(
                    indices: precedingIndices + [candidate.index]
                )
            }
        }
    }

    static func candidateLanguages(
        for words: [String]
    ) -> [BIP39Language] {
        let normalizedWords = words.map {
            $0.decomposedStringWithCompatibilityMapping
        }
        guard !normalizedWords.isEmpty else {
            return supportedLanguages
        }
        return wordLists.compactMap { wordList in
            normalizedWords.allSatisfy { wordList.indices[$0] != nil }
                ? wordList.language
                : nil
        }
    }

    static func firstUnknownWordPosition(in phrase: String) -> Int? {
        let words = normalizedPhrase(phrase).split(separator: " ")
        return words.enumerated().first { _, word in
            !wordLists.contains { $0.indices[String(word)] != nil }
        }.map { $0.offset + 1 }
    }

    static func validation(
        of phrase: String
    ) -> BIP39MnemonicValidation? {
        let normalized = normalizedPhrase(phrase)
        guard !normalized.isEmpty,
              normalized.utf8.count <= maximumPhraseUTF8Count
        else {
            return nil
        }
        let words = normalized.split(separator: " ").map(String.init)
        guard permittedWordCounts.contains(words.count),
              words.allSatisfy({
                  !$0.isEmpty && $0.utf8.count <= maximumWordUTF8Count
              })
        else {
            return nil
        }

        for wordList in wordLists {
            let indices = words.compactMap { wordList.indices[$0] }
            guard indices.count == words.count,
                  checksumIsValid(indices: indices)
            else {
                continue
            }
            return BIP39MnemonicValidation(
                normalizedPhrase: normalized,
                language: wordList.language,
                wordCount: words.count
            )
        }
        return nil
    }

    static func isValid(_ phrase: String) -> Bool {
        validation(of: phrase) != nil
    }

    static func hdWallet(
        mnemonic phrase: String,
        passphrase: String = ""
    ) -> HDWallet? {
        guard let validation = validation(of: phrase) else {
            return nil
        }

        // Validation above supports every bundled official BIP-39 word list.
        // Wallet Core's own check is English-only, so do not repeat it here.
        return HDWallet(
            mnemonic: validation.normalizedPhrase,
            passphrase: passphrase.decomposedStringWithCompatibilityMapping,
            check: false
        )
    }

    static func normalizedPhrase(_ phrase: String) -> String {
        phrase
            .decomposedStringWithCompatibilityMapping
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .joined(separator: " ")
    }

    private static let wordLists: [BIP39WordList] = {
        BIP39Language.allCases.compactMap(BIP39WordList.init)
    }()

    private static func checksumIsValid(indices: [Int]) -> Bool {
        let totalBitCount = indices.count * 11
        let entropyBitCount = totalBitCount * 32 / 33
        let checksumBitCount = totalBitCount - entropyBitCount
        guard entropyBitCount.isMultiple(of: 8),
              checksumBitCount == entropyBitCount / 32
        else {
            return false
        }

        var bits = [Bool]()
        bits.reserveCapacity(totalBitCount)
        for index in indices {
            guard (0..<2_048).contains(index) else {
                return false
            }
            for shift in stride(from: 10, through: 0, by: -1) {
                bits.append(((index >> shift) & 1) == 1)
            }
        }

        var entropy = Data(repeating: 0, count: entropyBitCount / 8)
        for bitIndex in 0..<entropyBitCount where bits[bitIndex] {
            let byteIndex = bitIndex / 8
            let bitOffset = 7 - (bitIndex % 8)
            entropy[byteIndex] |= UInt8(1 << bitOffset)
        }

        let digest = Array(SHA256.hash(data: entropy))
        for checksumIndex in 0..<checksumBitCount {
            let shift = 7 - (checksumIndex % 8)
            let expected = Int((digest[checksumIndex / 8] >> shift) & 1)
            let actual = bits[entropyBitCount + checksumIndex] ? 1 : 0
            guard expected == actual else {
                return false
            }
        }
        return true
    }
}

private struct BIP39WordList {
    let language: BIP39Language
    let entries: [BIP39WordEntry]
    let indices: [String: Int]

    init?(language: BIP39Language) {
        guard let url = Self.resourceURL(for: language),
              let contents = try? String(contentsOf: url, encoding: .utf8)
        else {
            return nil
        }

        let words = contents
            .split(whereSeparator: \.isNewline)
            .map {
                String($0).decomposedStringWithCompatibilityMapping
            }
        guard words.count == 2_048,
              Set(words).count == 2_048
        else {
            return nil
        }

        self.language = language
        self.entries = words.enumerated().map { index, word in
            BIP39WordEntry(
                language: language,
                index: index,
                word: word
            )
        }
        self.indices = Dictionary(
            uniqueKeysWithValues: words.enumerated().map { index, word in
                (word, index)
            }
        )
    }

    private static func resourceURL(
        for language: BIP39Language
    ) -> URL? {
        for bundle in candidateBundles {
            if let url = bundle.url(
                forResource: language.resourceName,
                withExtension: "txt",
                subdirectory: "BIP39Wordlists"
            ) ?? bundle.url(
                forResource: language.resourceName,
                withExtension: "txt"
            ) {
                return url
            }
        }
        return nil
    }

    private static let candidateBundles: [Bundle] = {
        let bundles = [
            Bundle.main,
            Bundle(for: BIP39ResourceBundleMarker.self)
        ]
        return bundles.reduce(into: []) { result, bundle in
            guard !result.contains(where: { $0.bundleURL == bundle.bundleURL })
            else {
                return
            }
            result.append(bundle)
        }
    }()
}

private final class BIP39ResourceBundleMarker {}
