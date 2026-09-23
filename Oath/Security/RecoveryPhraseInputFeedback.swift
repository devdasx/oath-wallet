import Foundation

/// Describes invalid input without copying recovery words into feedback text.
enum RecoveryPhraseInputFeedback: Equatable, Sendable {
    case unknownWord(position: Int)
    case unsupportedWordCount(Int)
    case invalidPhrase

    static func evaluate(_ phrase: String) -> Self? {
        let normalized = BIP39Mnemonic.normalizedPhrase(phrase)
        guard !normalized.isEmpty else { return nil }
        // Recognition must match import, including supported Electrum seeds.
        if (try? WalletRecoveryCredential(mnemonic: normalized)) != nil {
            return nil
        }
        if let position = BIP39Mnemonic.firstUnknownWordPosition(in: normalized) {
            return .unknownWord(position: position)
        }
        let count = normalized.split(separator: " ").count
        if !BIP39Mnemonic.permittedWordCounts.contains(count) {
            return .unsupportedWordCount(count)
        }
        return .invalidPhrase
    }

    var message: String {
        switch self {
        case let .unknownWord(position):
            EnglishNumbers.localized("import.recovery.validation.word", position)
        case let .unsupportedWordCount(count):
            EnglishNumbers.localized("import.recovery.validation.count", count)
        case .invalidPhrase:
            String(localized: "import.recovery.validation.phrase")
        }
    }
}
