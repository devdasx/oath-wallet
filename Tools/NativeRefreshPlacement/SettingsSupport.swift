import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
typealias UIColor = NSColor
extension NSColor {
    static var label: NSColor { .labelColor }
    static var secondaryLabel: NSColor { .secondaryLabelColor }
    static var secondarySystemBackground: NSColor { .controlBackgroundColor }
}
extension Color { init(uiColor: NSColor) { self.init(nsColor: uiColor) } }
#endif

// Unrelated artwork dependencies only. Selection-row layout and checkmarks are
// extracted verbatim from production by CheckNativeRefreshPlacement.py.
struct TokenArtworkIdentity {}
struct OathWalletListIcon: View { var body: some View { EmptyView() } }
struct OathTokenLogo: View {
    let source: String?
    let symbol: String
    let size: CGFloat
    let identity: TokenArtworkIdentity?
    var body: some View { EmptyView() }
}
struct OathNetworkLogo: View {
    let asset: String
    let size: CGFloat
    var body: some View { EmptyView() }
}
enum OathSurfaceColors { static let field = UIColor.secondarySystemBackground }
enum OathOnboardingColors { static let blue = Color.blue }
extension View {
    func oathFont(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> some View {
        font(.system(style, design: .default, weight: weight))
    }
}
