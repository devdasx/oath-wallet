import AppKit
import SwiftUI

// Host-only bridges let ImageRenderer exercise the production SwiftUI layout.
// These declarations are not included in the iOS target.
@MainActor enum OathSurfaceColors {
    static var groupedCanvas = NSColor(srgbRed: 244.0 / 255, green: 244.0 / 255, blue: 244.0 / 255, alpha: 1)
}
extension Color {
    init(uiColor: NSColor) { self.init(nsColor: uiColor) }
}

@main struct CheckFadingSurface {
    @MainActor static func main() throws {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            precondition(value(), message)
            checks += 1
        }
        func pixel(_ image: NSBitmapImageRep, x: CGFloat, y: CGFloat) -> [Int] {
            let color = image.colorAt(x: Int(x * 2), y: Int(y * 2))!.usingColorSpace(.sRGB)!
            return [color.redComponent, color.greenComponent, color.blueComponent].map { Int(($0 * 255).rounded()) }
        }
        for dark in [false, true] {
            let neutral = (dark ? 21.0 : 244.0) / 255
            OathSurfaceColors.groupedCanvas = NSColor(srgbRed: neutral, green: neutral, blue: neutral, alpha: 1)
            let reference = ImageRenderer(content: Color(uiColor: OathSurfaceColors.groupedCanvas).frame(width: 10, height: 10))
            reference.scale = 2
            let expected = pixel(NSBitmapImageRep(cgImage: reference.cgImage!), x: 4, y: 4)
            for width: CGFloat in [320, 440, 760] {
                for contentHeight: CGFloat in [0, 600, 2400] {
                    let marker = dark ? Color.white : Color.black
                    // A short section explicitly fills its viewport; it must
                    // not rely on paint overflowing the native row's bounds.
                    let view = OathHeaderScrollContent(viewportHeight: 850, fillsViewport: true) {
                        VStack(spacing: 0) {
                            Color.clear.frame(height: 240)
                            marker.frame(height: 56).padding(.horizontal, 24)
                            Color.clear.frame(height: 8)
                        }
                    } content: {
                        Color.clear.frame(height: contentHeight)
                            .overlay(alignment: .top) {
                                if contentHeight > 0 {
                                    Color(red: 1, green: 0, blue: 0).frame(height: 2).padding(.horizontal, 20)
                                }
                            }
                    }
                    .frame(width: width, height: 850, alignment: .top)
                    .background(Color(red: 0.03, green: 0.3, blue: 0.4))
                    .environment(\.colorScheme, dark ? .dark : .light)
                    let renderer = ImageRenderer(content: view)
                    renderer.scale = 2
                    let image = NSBitmapImageRep(cgImage: renderer.cgImage!)
                    for y: CGFloat in [260, 270, 274, 282, 290] {
                        let actual = pixel(image, x: 70, y: y)
                        check(actual.allSatisfy { abs($0 - (dark ? 255 : 0)) <= 1 }, "Canvas painted over a foreground control")
                    }
                    // The old 32-point overlap tinted the backdrop beneath
                    // native glass even when opaque foreground checks passed.
                    let artwork = pixel(image, x: 4, y: 100)
                    for y: CGFloat in [260, 272, 282] {
                        check(pixel(image, x: 4, y: y) == artwork,
                              "The panel must not change the backdrop behind the actions")
                    }
                    let start: CGFloat = 312
                    for y in [start + 26, start + 50, start + 112, start + 212, 840] {
                        check(zip(pixel(image, x: 4, y: y), expected).allSatisfy { abs($0 - $1) <= 2 },
                              "Canvas must stay opaque below its rounded corners: dark=\(dark), width=\(width), height=\(contentHeight), y=\(y)")
                    }
                    check(zip(pixel(image, x: width / 2, y: start + 1), expected).allSatisfy { abs($0 - $1) <= 2 },
                          "The top edge must be opaque between the corners")
                    let leftCorner = pixel(image, x: 4, y: start + 1)
                    let rightCorner = pixel(image, x: width - 4.5, y: start + 1)
                    check(zip(leftCorner, rightCorner).allSatisfy { abs($0 - $1) <= 2 },
                          "The two top corners must have the same radius")
                    check(zip(leftCorner, expected).contains { abs($0 - $1) > 30 },
                          "The artwork must remain visible outside the rounded panel")
                    check(pixel(image, x: width / 2, y: start - 3) == artwork,
                          "The section must not cast a shadow outside its cell")
                    if contentHeight > 0 {
                        let content = pixel(image, x: 70, y: start + 20)
                        check(content[0] > 240 && content[1] < 60 && content[2] < 60,
                              "Content must start 20 points below the panel: dark=\(dark), width=\(width), height=\(contentHeight), pixel=\(content)")
                    }
                }
                // The viewport below a short list and the area uncovered by
                // bottom bounce stay opaque. Only the real header/corners
                // reveal artwork, even when its anchor moves above the screen.
                for displacement: CGFloat in [0, -500, 90] {
                    let view = VStack(spacing: 0) {
                        OathHeaderScrollContent(viewportHeight: 850) {
                            Color.clear.frame(height: 280)
                        } content: {
                            Color.clear.frame(height: 58)
                        }
                        Color(uiColor: OathSurfaceColors.groupedCanvas).frame(height: 72)
                    }
                    .offset(y: displacement)
                    .frame(width: width, height: 850, alignment: .top)
                    .modifier(OathHeaderScrollBackground { Color.blue })
                    .environment(\.colorScheme, dark ? .dark : .light)
                    let renderer = ImageRenderer(content: view)
                    renderer.scale = 2
                    let image = NSBitmapImageRep(cgImage: renderer.cgImage!)
                    for y: CGFloat in [700, 800, 840] {
                        check(zip(pixel(image, x: width / 2, y: y), expected).allSatisfy { abs($0 - $1) <= 2 },
                              "Short lists and bottom bounce must not expose artwork: offset=\(displacement)")
                    }
                    if displacement >= 0 {
                        let header = pixel(image, x: width / 2, y: 100)
                        check(header[2] > 200 && header[0] < 20,
                              "Opaque list canvas must preserve the visible header artwork")
                        for y: CGFloat in [367, 370, 375] {
                            check(zip(pixel(image, x: width / 2, y: y + displacement), expected).allSatisfy { abs($0 - $1) <= 2 },
                                  "Header and next row must meet without a shadow seam")
                        }
                    } else {
                        check(zip(pixel(image, x: width / 2, y: 100), expected).allSatisfy { abs($0 - $1) <= 2 },
                              "An offscreen header must not expose any artwork")
                    }
                }
            }
        }
        print("Passed \(checks) rounded home/asset surface and inset checks on the Mac host (not an iOS visual check)")
    }
}
