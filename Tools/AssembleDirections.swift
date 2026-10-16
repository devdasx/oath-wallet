import AppKit
import Foundation

private struct Direction: Decodable {
    let folder: String
    let number: Int
    let name: String
    let prompt: String
}

@main
struct AssembleDirections {
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Design/Animation-Directions")
        let directions = try JSONDecoder().decode([Direction].self, from: Data(contentsOf: root.appendingPathComponent("directions.json")))
        precondition(directions.count == 10)
        var images: [[NSImage]] = []
        for direction in directions {
            let folder = root.appendingPathComponent(direction.folder)
            let pair = ["light", "dark"].map { NSImage(contentsOf: folder.appendingPathComponent("\($0).png"))! }
            images.append(pair)
            let board = bitmap(2832, 3092)
            draw(board) {
                background(board)
                label(String(format: "%02d", direction.number) + "  " + direction.name, 64, 32, 42, board)
                label("LIGHT", 64, 108, 23, board, secondary: true)
                label("DARK", 1448, 108, 23, board, secondary: true)
                picture(pair[0], 64, 160, 1320, 2868, board)
                picture(pair[1], 1448, 160, 1320, 2868, board)
            }
            try save(board, root.appendingPathComponent("\(direction.folder).png"))
        }

        let comparison = bitmap(2180, 1184)
        draw(comparison) {
            background(comparison)
            label("Oath · 10 animation directions", 64, 36, 38, comparison)
            label("Light on the left · Dark on the right · The same white Oath logo", 64, 94, 21, comparison, secondary: true)
            for (index, direction) in directions.enumerated() {
                let x = 64 + (index % 5) * 416
                let top = 166 + (index / 5) * 504
                label(String(format: "%02d", direction.number) + "  " + direction.name, x, top, 22, comparison)
                picture(images[index][0], x, top + 44, 184, 400, comparison)
                picture(images[index][1], x + 204, top + 44, 184, 400, comparison)
            }
        }
        try save(comparison, root.appendingPathComponent("00-all-directions.png"))

        for mode in 0..<2 {
            let overview = bitmap(1840, 1700)
            draw(overview) {
                background(overview)
                label("Oath · 10 animation directions", 64, 38, 36, overview)
                label(mode == 0 ? "LIGHT APPEARANCE" : "DARK APPEARANCE", 64, 96, 20, overview, secondary: true)
                for (index, direction) in directions.enumerated() {
                    let x = 64 + (index % 5) * 348
                    let top = 170 + (index / 5) * 750
                    label(String(format: "%02d", direction.number) + "  " + direction.name, x, top, 19, overview)
                    picture(images[index][mode], x, top + 42, 320, 695, overview)
                }
            }
            try save(overview, root.appendingPathComponent(mode == 0 ? "00-light-overview.png" : "00-dark-overview.png"))
        }
        print("Saved ten full-resolution comparisons and light/dark overview sheets")
    }

    private static func bitmap(_ width: Int, _ height: Int) -> NSBitmapImageRep {
        NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                         bytesPerRow: width * 4, bitsPerPixel: 32)!
    }
    private static func draw(_ bitmap: NSBitmapImageRep, body: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current?.imageInterpolation = .high
        body()
        NSGraphicsContext.restoreGraphicsState()
    }
    private static func background(_ bitmap: NSBitmapImageRep) {
        NSColor(srgbRed: 0.06, green: 0.065, blue: 0.08, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh).fill()
    }
    private static func label(_ value: String, _ x: Int, _ top: Int, _ size: CGFloat, _ bitmap: NSBitmapImageRep, secondary: Bool = false) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: secondary ? .regular : .semibold),
            .foregroundColor: secondary ? NSColor(white: 0.65, alpha: 1) : NSColor(white: 0.95, alpha: 1)
        ]
        let text = value as NSString
        text.draw(at: NSPoint(x: CGFloat(x), y: CGFloat(bitmap.pixelsHigh - top) - text.size(withAttributes: attributes).height), withAttributes: attributes)
    }
    private static func picture(_ image: NSImage, _ x: Int, _ top: Int, _ width: Int, _ height: Int, _ bitmap: NSBitmapImageRep) {
        image.draw(in: NSRect(x: x, y: bitmap.pixelsHigh - top - height, width: width, height: height), from: .zero, operation: .sourceOver, fraction: 1)
    }
    private static func save(_ bitmap: NSBitmapImageRep, _ url: URL) throws {
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
    }
}
