import OathAezeed
import OathBitcoin
import Foundation
import CryptoKit

/// A validated, canonical BIP-39 phrase. Intentionally neither Codable nor
/// Hashable: recovery material must never enter navigation restoration or logs.
struct OathValidatedMnemonic: Sendable {
    let phrase: String
    let language: String
    var explicitBIP39 = false
    var aezeed: AezeedMaterial? = nil
    var electrum: ElectrumSeedMaterial? = nil
}

enum OathMnemonicValidation: Equatable {
    case empty, tooLong, unavailable, mixedLanguages, checksum
    case wordCount(Int), unknownWord(Int)
    case valid(language: String)

    var isValid: Bool {
        if case .valid = self { return true }
        return false
    }
}

/// Offline BIP-39 dictionary and SHA-256 checksum verification. No seed
/// derivation, network lookup, telemetry, or persistence occurs here.
struct OathMnemonicValidator: Sendable {
    static let maximumInputLength = 4_096
    static let wordCounts: Set<Int> = [12, 15, 18, 21, 24]
    static let languages = ["english", "japanese", "korean", "spanish",
                            "chinese_simplified", "chinese_traditional", "french",
                            "italian", "czech", "portuguese"]
    static let bundled: Self? = try? load { Bundle.main.url(forResource: $0, withExtension: $1) }

    enum ResourceError: Error { case missing, invalid }
    private struct Manifest: Decodable {
        struct Entry: Decodable { let id: String; let sha256: String }
        let lists: [Entry]
    }
    private struct WordList: Sendable {
        let id: String
        let words: [String]
        let indices: [String: Int]
    }
    private let lists: [WordList]

    static func load(resource: (String, String) -> URL?) throws -> Self {
        guard let url = resource("bip39_manifest", "json") else { throw ResourceError.missing }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
        guard manifest.lists.map(\.id) == languages else { throw ResourceError.invalid }
        let lists = try manifest.lists.map { entry -> WordList in
            guard let url = resource("bip39_" + entry.id, "txt") else { throw ResourceError.missing }
            let data = try Data(contentsOf: url)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard digest == entry.sha256,
                  let text = String(data: data, encoding: .utf8) else { throw ResourceError.invalid }
            let words = text.split(whereSeparator: \.isNewline).map { normalize(String($0)) }
            guard words.count == 2_048, Set(words).count == 2_048 else { throw ResourceError.invalid }
            return WordList(id: entry.id, words: words,
                            indices: Dictionary(uniqueKeysWithValues: words.enumerated().map { ($1, $0) }))
        }
        return Self(lists: lists)
    }

    static func normalize(_ text: String) -> String {
        text.decomposedStringWithCompatibilityMapping.lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    static func words(in text: String) -> [String] {
        normalize(text).split(whereSeparator: \.isWhitespace).map(String.init)
    }

    func validate(_ text: String) -> OathMnemonicValidation {
        guard text.utf16.count <= Self.maximumInputLength else { return .tooLong }
        let words = Self.words(in: text)
        guard !words.isEmpty else { return .empty }
        guard Self.wordCounts.contains(words.count) else { return .wordCount(words.count) }
        for (index, word) in words.enumerated() where !lists.contains(where: { $0.indices[word] != nil }) {
            return .unknownWord(index + 1)
        }
        let candidates = lists.filter { list in words.allSatisfy { list.indices[$0] != nil } }
        guard !candidates.isEmpty else { return .mixedLanguages }
        for list in candidates {
            let indices = words.compactMap { list.indices[$0] }
            if Self.checksumMatches(indices) { return .valid(language: list.id) }
        }
        return .checksum
    }

    func verifiedPhrase(_ text: String, explicitBIP39: Bool = false) -> OathValidatedMnemonic? {
        guard case .valid(let language) = validate(text) else { return nil }
        return OathValidatedMnemonic(phrase: Self.words(in: text).joined(separator: " "), language: language, explicitBIP39: explicitBIP39)
    }

    private static func checksumMatches(_ indices: [Int]) -> Bool {
        let totalBits = indices.count * 11
        let entropyBits = totalBits * 32 / 33
        let checksumBits = totalBits - entropyBits
        var entropy = [UInt8](repeating: 0, count: entropyBits / 8)
        defer { _ = entropy.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        func bit(at index: Int) -> UInt8 {
            UInt8((indices[index / 11] >> (10 - index % 11)) & 1)
        }
        for index in 0..<entropyBits { entropy[index / 8] |= bit(at: index) << (7 - index % 8) }
        let checksum = SHA256.hash(data: Data(entropy)).withUnsafeBytes { $0[0] }
        for index in 0..<checksumBits {
            if bit(at: entropyBits + index) != (checksum >> (7 - index)) & 1 { return false }
        }
        return true
    }

    struct Completion: Equatable {
        let range: NSRange
        let prefix: String
    }

    /// UTF-16 ranges match UITextView, including composed CJK characters.
    static func completion(in text: String, selection: NSRange) -> Completion? {
        guard text.utf16.count <= maximumInputLength,
              selection.location != NSNotFound,
              let selected = Range(selection, in: text) else { return nil }
        var start = text.startIndex
        while start < text.endIndex {
            if text[start].isWhitespace { start = text.index(after: start); continue }
            var end = start
            while end < text.endIndex, !text[end].isWhitespace { end = text.index(after: end) }
            if selected.lowerBound > start, selected.lowerBound <= end, selected.upperBound <= end {
                return Completion(range: NSRange(start..<end, in: text),
                                  prefix: normalize(String(text[start..<selected.lowerBound])))
            }
            start = end
        }
        return nil
    }

    func suggestions(in text: String, selection: NSRange, limit: Int = 32) -> [String] {
        guard limit > 0, let context = Self.completion(in: text, selection: selection),
              let range = Range(context.range, in: text) else { return [] }
        let otherWords = Self.words(in: String(text[..<range.lowerBound]) + " " + String(text[range.upperBound...]))
        let candidates = lists.filter { list in otherWords.allSatisfy { list.indices[$0] != nil } }
        let preferred = candidates.isEmpty ? Array(lists.prefix(1)) : candidates
        var seen = Set<String>()
        var result = [String]()
        // Suggestions can help complete an accent, but validation still requires
        // the exact canonical word. A prefix alone is never accepted as a word.
        let prefix = context.prefix.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX"))
        for list in preferred {
            for word in list.words {
                let match = word.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX"))
                if match.hasPrefix(prefix), seen.insert(word).inserted {
                    result.append(word.precomposedStringWithCanonicalMapping)
                    if result.count == limit { return result }
                }
            }
            // Prefer the usual English list until the entered words or prefix
            // identify another language. Do not mix unrelated suggestions into
            // the first word merely because its prefix happens to overlap.
            if list.id == "english", !result.isEmpty, prefix == context.prefix { return result }
        }
        return result
    }

    func completing(_ word: String, in text: String, selection: NSRange) -> (text: String, selection: NSRange)? {
        guard lists.contains(where: { $0.indices[Self.normalize(word)] != nil }),
              let context = Self.completion(in: text, selection: selection),
              let range = Range(context.range, in: text) else { return nil }
        let options: String.CompareOptions = [.diacriticInsensitive]
        let locale = Locale(identifier: "en_US_POSIX")
        guard Self.normalize(word).folding(options: options, locale: locale)
            .hasPrefix(context.prefix.folding(options: options, locale: locale)) else { return nil }
        var end = range.upperBound
        // Reuse one existing separator. Preserve all later words and formatting.
        if end < text.endIndex, text[end].isWhitespace { end = text.index(after: end) }
        let replacement = word + " "
        let updated = String(text[..<range.lowerBound]) + replacement + String(text[end...])
        guard updated.utf16.count <= Self.maximumInputLength else { return nil }
        return (updated, NSRange(location: context.range.location + replacement.utf16.count, length: 0))
    }
}
