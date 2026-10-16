import Foundation

@main struct CheckMnemonicImport {
    struct Vector: Decodable { let entropy: String; let mnemonic: String }

    @MainActor static func main() throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ reason: String) {
            // Reasons are fixed strings and never print recovery material.
            precondition(condition(), reason)
            checks += 1
        }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let resources = CommandLine.arguments.count > 1
            ? URL(fileURLWithPath: CommandLine.arguments[1])
            : root.appendingPathComponent("OathApp/Resources/BIP39")
        let validator = try OathMnemonicValidator.load {
            resources.appendingPathComponent($0 + "." + $1)
        }
        var vectorCount = 0
        var coveredCounts = Set<Int>()
        for file in ["BIP39Vectors", "BIP39AdditionalVectors"] {
            let data = try Data(contentsOf: root.appendingPathComponent("Tools/Fixtures/\(file).json"))
            let vectors = try JSONDecoder().decode([String: [Vector]].self, from: data)
            check(Set(vectors.keys) == Set(OathMnemonicValidator.languages), "Every official word list has independent fixtures")
            for cases in vectors.values {
                for vector in cases {
                    vectorCount += 1
                    let words = OathMnemonicValidator.words(in: vector.mnemonic)
                    coveredCounts.insert(words.count)
                    check(validator.validate(vector.mnemonic).isValid, "Independent reference phrase must validate")
                    check(validator.validate(vector.mnemonic.precomposedStringWithCanonicalMapping).isValid, "NFC input must normalize to BIP-39 NFKD")
                    check(validator.validate(vector.mnemonic.uppercased()).isValid, "Case normalization is language-independent")
                    let spaced = " \n" + words.joined(separator: "\u{3000}\t\u{00A0}") + "\r\n"
                    check(validator.validate(spaced).isValid, "Unicode separators and pasted newlines normalize")
                    check(validator.verifiedPhrase(spaced)?.phrase == words.joined(separator: " "), "The handoff contains canonical words in their original order")
                    check(words.count * 11 * 32 / 33 == vector.entropy.count * 4, "Reference entropy length and word count agree")
                }
            }
        }
        check(vectorCount == 260, "All pinned and independently generated reference vectors were read")
        check(coveredCounts == OathMnemonicValidator.wordCounts, "All five BIP-39 lengths were exercised")
        let valid = Array(repeating: "abandon", count: 11).joined(separator: " ") + " about"
        let invalidChecksum = Array(repeating: "abandon", count: 12).joined(separator: " ")
        check(validator.validate(invalidChecksum) == .checksum, "Dictionary words alone are not a valid phrase")
        check(validator.validate(valid) == .valid(language: "english"), "Duplicate words are valid when the checksum matches")
        check(validator.validate("\n \t") == .empty, "Whitespace is empty input")
        for count in 1...30 where !OathMnemonicValidator.wordCounts.contains(count) {
            check(validator.validate(Array(repeating: "abandon", count: count).joined(separator: " ")) == .wordCount(count), "Unsupported word counts are rejected")
        }
        check(validator.validate(valid.replacingOccurrences(of: "about", with: "notaword")) == .unknownWord(12), "Unknown words return their position without echoing material")
        check(validator.validate(valid.replacingOccurrences(of: "about", with: "abo")) == .unknownWord(12), "Unambiguous prefixes are still not complete words")
        check(!validator.validate(valid + ".").isValid, "Punctuation is not silently removed")
        check(!validator.validate("https://example.com/?phrase=" + valid).isValid, "QR URLs are not treated as phrases")
        check(!validator.validate("{\"phrase\":\"" + valid + "\"}").isValid, "Arbitrary structured QR payloads are rejected")
        check(validator.validate(String(repeating: "x", count: 4_097)) == .tooLong, "Oversized input fails before tokenization")
        check(validator.validate(valid.replacingOccurrences(of: "about", with: "a\u{200B}bout")) == .unknownWord(12), "Invisible characters are not silently stripped")
        check(validator.validate(valid.replacingOccurrences(of: "about", with: "あいこくしん")) == .mixedLanguages, "Words from different lists cannot be mixed")

        func cursor(_ value: String) -> NSRange { NSRange(location: value.utf16.count, length: 0) }
        check(validator.suggestions(in: "aba", selection: cursor("aba")).first == "abandon", "Prefix completion uses the actual dictionary")
        let scrollable = validator.suggestions(in: "a", selection: cursor("a"))
        check(scrollable.count == 32, "A broad prefix supplies a bounded scrollable set instead of only three words")
        check(scrollable.contains("absurd"), "Later dictionary matches remain available beyond the initial visible words")
        check(Set(scrollable).count == scrollable.count, "Scrollable completions contain no duplicates")
        check(scrollable == scrollable.sorted(), "English matches retain dictionary order")
        check(scrollable.allSatisfy { $0.hasPrefix("a") }, "Every suggestion completes the entered prefix")
        check(validator.suggestions(in: "a", selection: cursor("a"), limit: 2) == Array(scrollable.prefix(2)), "An explicit smaller limit is honored")
        check(validator.suggestions(in: "a", selection: cursor("a"), limit: 0).isEmpty, "A zero limit produces no completions")
        check(validator.suggestions(in: "abo", selection: cursor("abo")) == ["about", "above"], "Narrow results do not pad the row with unrelated words")
        for word in scrollable {
            check(validator.completing(word, in: "a", selection: cursor("a"))?.text == word + " ", "Every scrollable result is a real dictionary word that can be inserted")
        }
        check(validator.suggestions(in: "abandon ", selection: cursor("abandon ")).isEmpty, "No guessed next recovery word is offered")
        check(validator.suggestions(in: "zzzz", selection: cursor("zzzz")).isEmpty, "An unmatched prefix has no suggestions")
        check(validator.suggestions(in: "aba", selection: NSRange(location: NSNotFound, length: 0)).isEmpty, "Invalid selection is safe")
        check(validator.suggestions(in: "aba", selection: NSRange(location: 80, length: 0)).isEmpty, "Out-of-bounds selection is safe")
        let middle = "about aba ability"
        let position = NSRange(location: 9, length: 0)
        let completion = validator.completing("abandon", in: middle, selection: position)
        check(completion?.text == "about abandon ability", "Middle-word replacement preserves surrounding words")
        check(completion?.selection.location == 14, "Caret advances to the next word")
        check(validator.completing("abandon", in: "abanxxxx next", selection: NSRange(location: 4, length: 0))?.text == "abandon next", "Completion replaces the whole current token, including its suffix")
        check(validator.completing("about", in: "aba", selection: cursor("aba")) == nil, "Stale suggestions cannot replace a newly changed prefix")
        check(validator.completing("notaword", in: "not", selection: cursor("not")) == nil, "Completion never inserts unknown words")
        check(validator.suggestions(in: "あい", selection: cursor("あい")).contains("あいこくしん"), "Japanese completion works with native characters")
        check(validator.suggestions(in: "ába", selection: cursor("ába")).contains("ábaco"), "Accent composition normalizes for completion")

        let draft = OathRecoveryPhraseDraft(validator: validator)
        check(draft.submit() == nil && draft.attemptedImport, "Empty submit cannot navigate")
        draft.replace(with: invalidChecksum)
        check(draft.submit() == nil, "Invalid checksum cannot reach the import handoff")
        draft.replace(with: valid)
        check(draft.submit()?.phrase == valid, "Valid input reaches the typed handoff")
        draft.isComposing = true
        check(draft.submit() == nil, "Uncommitted keyboard composition cannot be imported")
        draft.isComposing = false
        check(!draft.receiveScan("bitcoin:unrelated") && draft.text == valid, "Unrelated QR codes preserve the current draft")
        check(!draft.receiveScan(invalidChecksum) && draft.text == valid, "Invalid QR checksums preserve the current draft")
        check(draft.receiveScan(valid.uppercased()), "Valid QR input uses the same validation path")
        draft.replace(with: String(repeating: "x", count: 4_097))
        check(draft.inputRejected && draft.submit() == nil, "Rejected oversized paste blocks importing stale text")
        draft.replace(with: "aba")
        draft.complete("abandon")
        check(draft.text == "abandon " && draft.selection.location == 8, "Suggestion tap updates input and caret together")
        draft.replace(with: "a")
        check(draft.suggestions == scrollable, "The input draft exposes the full scrollable result set")
        draft.complete("absurd")
        check(draft.text == "absurd " && draft.selection.location == 7, "Selecting a later match updates the input and caret")
        draft.clear()
        check(draft.text.isEmpty && draft.selection.location == 0 && !draft.attemptedImport && !draft.inputRejected, "Leaving the flow clears draft state")
        let missing = OathRecoveryPhraseDraft(validator: nil)
        missing.replace(with: valid)
        check(missing.validation == .unavailable && missing.submit() == nil, "Missing dictionaries fail closed")
        do {
            _ = try OathMnemonicValidator.load { _, _ in nil }
            check(false, "Missing resources must throw")
        } catch { check(true, "Missing resources are handled") }

        // A reordered, otherwise complete dictionary would validate the wrong
        // entropy. Its pinned content hash must reject it before use.
        let altered = FileManager.default.temporaryDirectory.appendingPathComponent("oath-wordlist-check-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: altered) }
        var wordList = try String(contentsOf: resources.appendingPathComponent("bip39_english.txt"), encoding: .utf8)
            .split(whereSeparator: \.isNewline).map(String.init)
        wordList.swapAt(0, 1)
        try (wordList.joined(separator: "\n") + "\n").write(to: altered, atomically: true, encoding: .utf8)
        do {
            _ = try OathMnemonicValidator.load { name, ext in
                name == "bip39_english" ? altered : resources.appendingPathComponent(name + "." + ext)
            }
            check(false, "Corrupted dictionary order must be rejected")
        } catch { check(true, "Pinned resource integrity fails closed") }

        print("Passed \(checks) host mnemonic/import checks across \(vectorCount) independent vectors, 10 word lists, and all 5 supported lengths.")
    }
}
