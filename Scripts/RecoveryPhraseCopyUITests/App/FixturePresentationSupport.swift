import SwiftUI

// Only unrelated presentation dependencies are substituted. The three
// production List screens, copy actions/state, and UniHaptic compile unchanged.
// No real secret protection or wallet services are installed in this test app.
enum WalletTheme {
    static let accent = Color.accentColor
    static let danger = Color.red
    static let secondaryLabel = Color(uiColor: .secondaryLabel)
    static let groupedBackground = Color(uiColor: .systemGroupedBackground)
}

enum WalletTypography {
    static func title(_ style: Font.TextStyle) -> Font { .system(style, weight: .bold) }
}

enum EnglishNumbers {
    static func integer(_ number: Int64) -> String { String(number) }
    static func localized(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: NSLocalizedString(key, comment: ""),
               locale: Locale(identifier: "en_US_POSIX"), arguments: arguments)
    }
}

struct PrimaryWalletButton: View {
    let title: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) { Text(title).frame(maxWidth: .infinity) }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
    }
}

private struct SensitiveValuesProtectedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var walletSensitiveValuesProtected: Bool {
        get { self[SensitiveValuesProtectedKey.self] }
        set { self[SensitiveValuesProtectedKey.self] = newValue }
    }
}

extension View {
    func walletSensitiveValue() -> some View { self }
}
