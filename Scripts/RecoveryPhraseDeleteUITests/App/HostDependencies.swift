import SwiftUI

// Only unrelated app services are stubbed. The complete shipping editor,
// token state, native field and layout are compiled directly by this target.
enum WalletTheme {
    static let primaryLabel = Color.primary
    static let secondaryLabel = Color.secondary
    static let accent = Color.accentColor
    static let danger = Color(uiColor: .systemRed)
    static let mutedSecondaryFill = Color(uiColor: .secondarySystemFill)
}
@propertyWrapper struct WalletNativeTextPrivacy: DynamicProperty {
    var wrappedValue: Bool { false }
}
extension View {
    func walletSensitiveValue() -> some View { self }
}
enum UniHaptic {
    static func action(_ action: @escaping () -> Void) -> () -> Void { action }
}
enum EnglishNumbers {
    static func integer(_ value: Int64) -> String { String(value) }
    static func localized(_ key: String, _ value: CVarArg) -> String {
        String(format: NSLocalizedString(key, comment: ""), value)
    }
}
struct RecoveryPhraseCompletion: Equatable {
    let word: String
    let suffix: String
    static func match(fragment: String, precedingWords: [String]) -> Self? { nil }
    static func isInvalidFragment(_ fragment: String, precedingWords: [String]) -> Bool { false }
    static func isInvalidWord(_ word: String) -> Bool { false }
}
struct WalletRecoveryCredential {
    enum Unused: Error { case validation }
    init(mnemonic: String) throws {
        let words = mnemonic.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words == Array(repeating: "abandon", count: 11) + ["about"] else {
            throw Unused.validation
        }
    }
}
