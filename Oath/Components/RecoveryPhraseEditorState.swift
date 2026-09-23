import Foundation

/// Ephemeral state of one text input control. Each owning import screen creates
/// its own instance; nothing is persisted or shared between navigation flows.
struct RecoveryPhraseEditorState: Equatable {
    struct Word: Identifiable, Equatable {
        let id: UUID
        var value: String

        init(_ value: String) {
            id = UUID()
            self.value = value
        }
    }

    private(set) var words: [Word] = []
    private(set) var fragment = ""
    private(set) var editingID: UUID?
    private(set) var selectionRequest: UUID?
    /// The gap left by a deleted edit. Keep Delete before the untouched suffix.
    private var insertionIndex: Int?

    init(input: String = "") {
        replace(with: input, commitAll: false)
    }

    var text: String {
        var values = words.map(\.value)
        if let index = editingIndex { values[index] = fragment }
        else if !fragment.isEmpty { values.insert(fragment, at: inputPosition) }
        let value = values.filter { !$0.isEmpty }.joined(separator: " ")
        return editingID == nil && fragment.isEmpty && !value.isEmpty ? value + " " : value
    }

    var wordsBeforeFragment: [String] {
        words.prefix(inputPosition).map(\.value)
    }

    var inputPosition: Int { editingIndex ?? insertionIndex ?? words.count }

    var hasContent: Bool { !words.isEmpty || !fragment.isEmpty }

    mutating func replace(with text: String, commitAll: Bool = true) {
        words = []
        editingID = nil
        insertionIndex = nil
        fragment = ""
        updateFragment(text)
        if commitAll { finishWord() }
    }

    mutating func updateFragment(_ value: String) {
        let value = Self.normalizedInput(value)
        selectionRequest = nil
        let parts = value.split(whereSeparator: \.isWhitespace).map(String.init)
        guard value.contains(where: \.isWhitespace) else {
            fragment = value
            return
        }
        let endsWithSeparator = value.last?.isWhitespace == true
        let completed = endsWithSeparator ? parts : Array(parts.dropLast())
        let remainder = endsWithSeparator ? "" : parts.last ?? ""
        guard !completed.isEmpty else {
            fragment = remainder
            return
        }
        let insertIndex = inputPosition
        var replacements = completed.map(Word.init)
        if let index = editingIndex {
            var editedWord = words.remove(at: index)
            editedWord.value = completed[0]
            replacements[0] = editedWord
        }
        words.insert(contentsOf: replacements, at: insertIndex)
        editingID = nil
        insertionIndex = nil
        fragment = ""
        if !remainder.isEmpty && insertIndex + completed.count < words.count {
            // Pasting multiple words into a middle position must keep the suffix
            // after the edited position, rather than moving the new fragment last.
            let pending = Word(remainder)
            words.insert(pending, at: insertIndex + completed.count)
            editingID = pending.id
        }
        fragment = remainder
    }

    mutating func finishWord() {
        selectionRequest = nil
        if let index = editingIndex {
            if fragment.isEmpty { words.remove(at: index) }
            else { words[index].value = fragment }
        } else if !fragment.isEmpty {
            words.insert(Word(fragment), at: inputPosition)
        }
        editingID = nil
        insertionIndex = nil
        fragment = ""
    }

    mutating func selectSuggestion(_ word: String) {
        fragment = Self.normalizedInput(word)
        finishWord()
    }

    mutating func edit(_ id: UUID) {
        guard editingID != id, words.contains(where: { $0.id == id }) else { return }
        finishWord()
        guard let word = words.first(where: { $0.id == id }) else { return }
        editingID = id
        fragment = word.value
    }

    mutating func remove(_ id: UUID) {
        guard let index = words.firstIndex(where: { $0.id == id }) else { return }
        if editingID == id {
            editingID = nil
            fragment = ""
            selectionRequest = nil
            insertionIndex = index
        } else if let insertionIndex, index < insertionIndex {
            self.insertionIndex = insertionIndex - 1
        }
        words.remove(at: index)
        if insertionIndex == words.count { insertionIndex = nil }
    }

    mutating func clear() {
        words = []
        fragment = ""
        editingID = nil
        insertionIndex = nil
        selectionRequest = nil
    }

    /// An empty insertion point selects the preceding token. UIKit then owns
    /// the selection: typing replaces it, a caret move edits it, and Delete
    /// removes the selected token without touching any following words.
    mutating func selectPreviousWord() {
        guard fragment.isEmpty else { return }
        let previousIndex = inputPosition - 1
        guard previousIndex >= 0 else { return }
        let previousID = words[previousIndex].id
        edit(previousID)
        selectionRequest = UUID()
    }

    private var editingIndex: Int? {
        guard let editingID else { return nil }
        return words.firstIndex { $0.id == editingID }
    }

    /// Normalize only recovery input; never apply this to BIP-39 passphrases.
    /// Keep Unicode letters and combining marks for every supported word list.
    private static func normalizedInput(_ value: String) -> String {
        let normalized = value.decomposedStringWithCompatibilityMapping.lowercased()
        var result = String.UnicodeScalarView()
        for scalar in normalized.unicodeScalars {
            if CharacterSet.decimalDigits.contains(scalar) { continue }
            if CharacterSet.letters.contains(scalar)
                || CharacterSet.nonBaseCharacters.contains(scalar) {
                result.append(scalar)
            } else {
                result.append(" ")
            }
        }
        return String(result)
    }
}
