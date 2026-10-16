import AppKit
import SwiftUI

// Host-only UIKit/font bridges; the row layout and amount formatter below are
// production sources. This checks sizing, not the iOS glass renderer or font.
@MainActor enum OathSurfaceColors { static let field = NSColor.controlBackgroundColor }
extension NSColor { static var separator: NSColor { .separatorColor } }
extension Color { init(uiColor: NSColor) { self.init(nsColor: uiColor) } }
extension View {
    func oathFont(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> some View {
        font(.system(style, design: .default).weight(weight))
    }
}

@main struct CheckRefinedRows {
    @MainActor static func main() {
        let format = OathAssetAmountFormat(locale: Locale(identifier: "en_US"))
        var checks = 0
        for width: CGFloat in [320, 393, 440] {
            for rtl in [false, true] {
                for title in ["Bitcoin", "NEAR Protocol", "A very long token name that needs truncation"] {
                    for balance in ["0", "0.578460528618856998992951", "1234567890.123456789012345678", "0.000000000000000000000001"] {
                        let native = format.nativeSummary(Decimal(string: balance)!, ticker: "NEAR")
                        let row = OathRefinedListRow(title: title, subtitle: native, value: "$3.28") { size in
                            Color.blue.frame(width: size, height: size)
                        }
                        .frame(width: width)
                        .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
                        let renderer = ImageRenderer(content: row)
                        renderer.scale = 2
                        guard let image = renderer.cgImage else { preconditionFailure("Row failed to render") }
                        precondition(image.width == Int(width * 2), "Row overflows the viewport")
                        precondition(image.height == 156, "Long native balances must not add extra rows")
                        checks += 2
                    }
                }
            }
        }
        print("Passed \(checks) production row sizing checks (host fonts; no simulator)")
    }
}
