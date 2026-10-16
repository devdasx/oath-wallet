import AppKit
import SwiftUI

// Host rendering exercises the production layouts without booting iOS.
// swiftc OathAtmosphere/OathEmptyState.swift OathAtmosphere/OathEmptyStateLayout.swift \
//   OathAtmosphere/Home/OathHomeBodySurface.swift Tools/CheckEmptyStates.swift \
//   -o /tmp/oath-check-empty-states && /tmp/oath-check-empty-states
@MainActor enum OathSurfaceColors {
    static let groupedCanvas = NSColor.white
}
extension Color {
    init(uiColor: NSColor) { self.init(nsColor: uiColor) }
}
extension NSColor {
    static var secondarySystemBackground: NSColor { .windowBackgroundColor }
}
extension View {
    func oathFont(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> some View {
        font(.system(style, weight: weight))
    }
}

@main struct CheckEmptyStates {
    @MainActor static func main() {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            checks += 1
        }
        func image<V: View>(_ view: V) -> NSBitmapImageRep {
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            return NSBitmapImageRep(cgImage: renderer.cgImage!)
        }
        func markerRows(_ image: NSBitmapImageRep) -> [Int] {
            (0..<image.pixelsHigh).filter { y in
                let c = image.colorAt(x: image.pixelsWide / 2, y: y)!.usingColorSpace(.sRGB)!
                return c.redComponent > 0.7 && c.greenComponent < 0.4 && c.blueComponent < 0.4
            }
        }
        // Full page, recipient form, memo form, keyboard, large text overflow,
        // section footer, compact width and tablet width all use one layout.
        let cases: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (800, 0, 200, 0), (800, 260, 200, 0), (800, 380, 200, 0),
            (420, 260, 200, 0), (800, 400, 560, 0), (800, 200, 200, 80),
            (320, 220, 240, 90)
        ]
        for width: CGFloat in [320, 430, 700] {
            for rtl in [false, true] {
                for (viewport, header, content, footer) in cases {
                    let rendered = image(OathEmptyStateLayout(minimumHeight: viewport) {
                        Color.blue.frame(height: header)
                        Color.red.frame(height: content)
                        Color.green.frame(height: footer)
                    }.frame(width: width).background(.white)
                        .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight))
                    let rows = markerRows(rendered)
                    check(rows.count == Int(content), "Empty content must retain its full measured height")
                    check(rows.first! >= Int(header), "Empty content overlaps its header")
                    let above = rows.first! - Int(header)
                    let below = rendered.pixelsHigh - Int(footer) - rows.last! - 1
                    check(abs(above - below) <= 1, "Empty content is not centered in the available region")
                    check(rendered.pixelsHigh == Int(max(viewport, header + content + footer)),
                          "Overflow must grow the scroll extent; fitting content must fill the viewport")
                }
            }
        }
        let populated = image(OathEmptyStateLayout(minimumHeight: 800, centersContent: false) {
            Color.blue.frame(height: 100)
            Color.red.frame(height: 240)
        }.frame(width: 320))
        check(populated.pixelsHigh == 340, "Populated lists must retain natural scroll height")
        check(markerRows(populated).first == 100, "Populated rows must remain directly below their header")

        let empty = OathEmptyState("No saved addresses", systemImage: "person.crop.rectangle.stack.fill",
                                  description: "Saved addresses will appear here. Enter an address above to continue.")
        let renderer = ImageRenderer(content: empty)
        renderer.proposedSize = ProposedViewSize(width: 320, height: 5000)
        check(renderer.cgImage!.height < 500,
              "Content-sized sheets must measure the empty state's natural height, not an enormous proposal")
        let longText = image(OathEmptyState("No saved addresses", systemImage: "person.crop.rectangle.stack.fill",
            description: String(repeating: "Saved addresses will appear here. ", count: 30)).frame(width: 240))
        check(longText.pixelsHigh > 500, "Long descriptions must wrap vertically instead of clipping")

        // The asset page has artwork and market information above its activity.
        // Verify that the enclosing layout actually offers the remaining height
        // to the nested empty-state layout, rather than just painting background.
        let asset = image(OathHeaderScrollContent(viewportHeight: 850, fillsViewport: true) {
            Color.blue.frame(height: 240)
        } content: {
            OathEmptyStateLayout {
                Color.blue.frame(height: 80)
                Color.red.frame(height: 140)
                Color.green.frame(height: 60)
            }
        }.frame(width: 400))
        let rows = markerRows(asset)
        let activityStart = 240 + 8 + 20 + 80
        check(asset.pixelsHigh == 850, "An empty asset page must fill the viewport")
        check(abs((rows.first! - activityStart) - (850 - 60 - rows.last! - 1)) <= 1,
              "Asset activity must center below the market header and above its information action")
        print("Passed \(checks) empty-state layout checks on the Mac host; no iOS runtime used.")
    }
}
