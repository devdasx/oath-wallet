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
        // Home moves populated asset rows outside the header cell so the native
        // list can reuse them. SwiftUI removes the false branch entirely: the
        // layout has ONE child, not a second zero-sized placeholder.
        for showsContent in [false, true] {
            let rendered = image(OathEmptyStateLayout(centersContent: false) {
                Color.blue.frame(height: 58)
                if showsContent {
                    Color.red.frame(height: 140)
                }
            }.frame(width: 400))
            check(rendered.pixelsHigh == (showsContent ? 198 : 58),
                  "A conditional section must measure its existing children without indexing an absent child")
            check(markerRows(rendered).count == (showsContent ? 140 : 0),
                  "Conditional section content must appear only when present")
        }
        let noChildren = image(VStack(spacing: 0) {
            OathEmptyStateLayout(centersContent: false) { EmptyView() }
            Color.red.frame(height: 1)
        }.frame(width: 400))
        check(noChildren.pixelsHigh == 1, "An empty layout must safely measure and place zero children")

        // Optional header/body content must preserve the native stack's insets.
        let emptyHeader = image(OathHeaderScrollContent(viewportHeight: 850) {
            EmptyView()
        } content: {
            Color.red.frame(height: 72)
        }.frame(width: 400))
        check(emptyHeader.pixelsHigh == 100, "An absent header must preserve the enclosing layout's content slot")
        check(markerRows(emptyHeader).first == 28, "Content must retain the shared surface inset without a header")
        let emptyBody = image(OathHeaderScrollContent(viewportHeight: 850) {
            Color.blue.frame(height: 280)
        } content: {
            EmptyView()
        }.frame(width: 400))
        check(emptyBody.pixelsHigh == 308, "An absent body must preserve the enclosing layout's header slot")

        // Native List reorders/reuses cells as they leave and reenter the
        // viewport. The header must not paint a viewport-sized white rectangle
        // over a later cell, regardless of which cell is composited last.
        let rowBehindHeader = image(ZStack(alignment: .top) {
            Color.green.frame(height: 850)
            OathHeaderScrollContent(viewportHeight: 850) {
                Color.blue.frame(height: 280)
            } content: {
                Color.clear.frame(height: 58)
            }
        }.frame(width: 400))
        let exposedRow = rowBehindHeader.colorAt(x: 200, y: 550)!.usingColorSpace(.sRGB)!
        check(exposedRow.greenComponent > 0.4 && exposedRow.redComponent < 0.3,
              "A header cell must not paint over asset rows outside its measured bounds")

        // Exercise the same nested layout and conditional body as Home during
        // loading, populated startup, filtering to empty, and clearing filters.
        for (isEmpty, prepared) in [(true, false), (false, true), (true, true), (false, true)] {
            let rendered = image(VStack(spacing: 0) {
                OathHeaderScrollContent(viewportHeight: 850, fillsViewport: isEmpty) {
                    Color.blue.frame(height: 280)
                } content: {
                    OathEmptyStateLayout(centersContent: isEmpty) {
                        Color.blue.frame(height: 58)
                        if isEmpty || !prepared {
                            Color.red.frame(height: 140)
                        }
                    }
                }
                if prepared && !isEmpty {
                    Color.red.frame(height: 72)
                }
            }.frame(width: 400))
            check(rendered.pixelsHigh == (isEmpty ? 850 : 438),
                  "Home must retain its viewport when empty and its natural header height when populated")
            if prepared && !isEmpty {
                check(markerRows(rendered).first == 366,
                      "Native asset rows must start immediately after the section header")
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
