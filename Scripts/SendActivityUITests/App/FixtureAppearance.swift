import SwiftUI

enum WalletTheme {
    static let primaryAction = Color(uiColor: .systemBlue)
    static let onAccentLabel = Color(uiColor: .white)
    static let primaryLabel = Color(uiColor: .label)
    static let secondaryLabel = Color(uiColor: .secondaryLabel)
    static let groupedSurface = Color(uiColor: .secondarySystemGroupedBackground)
    static let groupedBackground = Color(uiColor: .systemGroupedBackground)
    static let success = Color(uiColor: .systemGreen)
    static let warning = Color(uiColor: .systemOrange)
    static let danger = Color(uiColor: .systemRed)
}
enum UniHaptic {
    @MainActor static func action(_ unused: UniHaptic?, perform: @escaping () -> Void) -> () -> Void { perform }
}
enum EnglishNumbers {
    static func integer(_ value: Int64) -> String { String(value) }
    static func localized(_ key: String, _ args: CVarArg...) -> String {
        String(format: NSLocalizedString(key, comment: ""), locale: Locale(identifier: "en_US_POSIX"), arguments: args)
    }
}
enum SendBroadcastReceiptPresentation {
    static func compactIdentity(_ value: String) -> String { value }
}
extension View {
    func walletRegularGlassEffect<S: Shape>(interactive: Bool, in shape: S) -> some View {
        glassEffect(.regular.interactive(interactive), in: shape)
    }
}
struct AssetLogoView: View {
    let source: String
    let size: CGFloat
    let animatesChanges: Bool
    let diagnosticAssetIdentity: String
    var body: some View { Circle().fill(WalletTheme.secondaryLabel).frame(width: size, height: size) }
}
struct WalletLogoStatusBadge: View {
    let color: Color
    let systemSymbol: String
    let size: CGFloat
    var body: some View {
        Image(systemName: systemSymbol).font(.caption.bold())
            .foregroundStyle(color).frame(width: size, height: size)
            .background(WalletTheme.groupedSurface, in: Circle())
    }
}

struct WalletCloseButton: View {
    let action: () -> Void
    var body: some View { Button(role: .close, action: action) }
}
