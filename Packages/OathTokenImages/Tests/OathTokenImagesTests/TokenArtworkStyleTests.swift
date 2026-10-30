import XCTest
import CoreGraphics
import ImageIO
import SwiftUI
@testable import OathTokenImages
#if os(macOS)
import AppKit
#endif

final class TokenArtworkStyleTests: XCTestCase, @unchecked Sendable {
    private func svg(_ body: String, width: Int = 64, height: Int = 64) throws -> ArtworkImage {
        try ArtworkImage.decode(Data("<svg xmlns='http://www.w3.org/2000/svg' width='\(width)' height='\(height)'>\(body)</svg>".utf8))
    }
    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")))
    }
    func testCircularBackgroundExtendsBrandColorWithoutAveragingWhiteMark() throws {
        let image = try svg("<circle cx='32' cy='32' r='31' fill='#0066cc'/><path d='M26 12h12v40H26z' fill='white'/>")
        XCTAssertEqual(image.backgroundColor.red, 0, accuracy: 0.02)
        XCTAssertEqual(image.backgroundColor.green, 0.4, accuracy: 0.02)
        XCTAssertEqual(image.backgroundColor.blue, 0.8, accuracy: 0.02)
    }
    func testTransparentMonochromeSymbolsKeepContrast() throws {
        let colors: [(String, TokenArtworkColor)] = [
            ("#000000", .init(red: 0, green: 0, blue: 0)),
            ("#ffffff", .init(red: 1, green: 1, blue: 1)),
            ("#0066cc", .init(red: 0, green: 0.4, blue: 0.8)),
            ("#00cc66", .init(red: 0, green: 0.8, blue: 0.4))
        ]
        for (hex, foreground) in colors {
            let image = try svg("<path d='M28 8h8v48h-8z' fill='\(hex)'/>")
            XCTAssertGreaterThanOrEqual(foreground.contrast(with: image.backgroundColor), 2.99, hex)
        }
    }
    func testOpaqueWhiteCanvasRemainsWhite() throws {
        let image = try svg("<path d='M0 0h64v64H0z' fill='white'/><circle cx='32' cy='32' r='15' fill='#0066cc'/>")
        XCTAssertEqual(image.backgroundColor.red, 1, accuracy: 0.001)
        XCTAssertEqual(image.backgroundColor.green, 1, accuracy: 0.001)
        XCTAssertEqual(image.backgroundColor.blue, 1, accuracy: 0.001)
    }
    func testEmptyArtworkUsesNeutralWithoutInventingBrandColor() throws {
        XCTAssertEqual(try svg("").backgroundColor, .neutral)
    }
    func testGoldenGradientDoesNotGetMistakenForMonochrome() throws {
        let image = try svg("""
            <defs><linearGradient id='g' x2='0' y2='1'><stop stop-color='#ffad00'/><stop offset='1' stop-color='#ffcf55'/></linearGradient></defs>
            <circle cx='32' cy='32' r='32' fill='url(#g)'/><path d='M26 12h12v40H26z' fill='white'/>
            """)
        XCTAssertGreaterThan(image.backgroundColor.red, 0.95)
        XCTAssertGreaterThan(image.backgroundColor.green, 0.55)
        XCTAssertLessThan(image.backgroundColor.blue, 0.5)
    }
    func testProviderWhiteCornersDoNotVoteAsTheBadgeBackground() throws {
        let image = try svg("<path d='M0 0h64v64H0z' fill='white'/><circle cx='32' cy='32' r='32' fill='#26a17b'/><path d='M26 12h12v40H26z' fill='white'/>")
        XCTAssertEqual(image.backgroundColor.red, 38.0 / 255, accuracy: 0.02)
        XCTAssertEqual(image.backgroundColor.green, 161.0 / 255, accuracy: 0.02)
        XCTAssertEqual(image.backgroundColor.blue, 123.0 / 255, accuracy: 0.02)
    }
    func testWideArtworkKeepsAspectRatioDuringSampling() throws {
        let image = try svg("<path d='M0 0h128v32H0z' fill='#0066cc'/><path d='M48 0h32v32H48z' fill='white'/>", width: 128, height: 32)
        XCTAssertEqual(image.backgroundColor.blue, 0.8, accuracy: 0.02)
        guard case .vector(let vector, _) = image else { return XCTFail("Vector should be retained") }
        XCTAssertEqual(vector.size, CGSize(width: 128, height: 32))
    }
    func testPremultipliedEdgesDoNotTurnBackgroundBlack() throws {
        let color = TokenArtworkPalette.analyze(size: CGSize(width: 64, height: 64)) { context, rect in
            context.setFillColor(CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         components: [0, 0.4, 0.8, 0.5])!)
            context.fill(rect)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 20, y: 16, width: 8, height: 16))
        }
        XCTAssertEqual(color.green, 0.4, accuracy: 0.015)
        XCTAssertEqual(color.blue, 0.8, accuracy: 0.015)
    }
    func testRasterAndSVGChooseSameColor() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8,
            bytesPerRow: 256, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     components: [0.8, 0.2, 0.4, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let raster = try ArtworkImage.decode(data as Data)
        let vector = try svg("<path d='M0 0h64v64H0z' fill='#cc3366'/>")
        XCTAssertEqual(raster.backgroundColor.red, vector.backgroundColor.red, accuracy: 0.01)
        XCTAssertEqual(raster.backgroundColor.green, vector.backgroundColor.green, accuracy: 0.01)
        XCTAssertEqual(raster.backgroundColor.blue, vector.backgroundColor.blue, accuracy: 0.01)
    }
    func testRealTokenFixturesRetainBrandColors() throws {
        let usdc = try ArtworkImage.decode(fixture("aptos-usdc.svg")).backgroundColor
        let usdt = try ArtworkImage.decode(fixture("aptos-usdt.svg")).backgroundColor
        XCTAssertGreaterThan(usdc.blue, usdc.red + 0.2)
        XCTAssertGreaterThan(usdt.green, usdt.red + 0.15)
        let first = try ArtworkImage.decode(fixture("aptos-usd1.png"))
        let second = try ArtworkImage.decode(fixture("aptos-usd1.png"))
        XCTAssertEqual(first.backgroundColor, second.backgroundColor)
    }
    func testPalettePersistsThroughExistingOfflineCache() async throws {
        let data = try fixture("aptos-usdc.svg")
        let uri = "data:image/svg+xml;base64," + data.base64EncodedString()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = await ArtworkLoader(directory: directory).image(for: [uri])
        let offline = await ArtworkLoader(directory: directory).cached(for: [uri])
        XCTAssertNotNil(first)
        XCTAssertEqual(first?.backgroundColor, offline?.backgroundColor)
        guard case .vector = offline else { return XCTFail("Cached SVG must remain vector") }
    }

    #if os(macOS)
    @MainActor func testNativeRoundedRenderingPreservesCenterAndAntialiasesCorners() throws {
        let image = try svg("<circle cx='32' cy='32' r='31' fill='#0066cc'/><path d='M26 12h12v40H26z' fill='white'/>")
        for size: CGFloat in [15.2, 38, 72] {
            let renderer = ImageRenderer(content: TokenArtworkView(image, size: size))
            renderer.scale = 3
            let output = try XCTUnwrap(renderer.cgImage)
            let context = try XCTUnwrap(CGContext(data: nil, width: output.width, height: output.height,
                bitsPerComponent: 8, bytesPerRow: output.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(output, in: CGRect(x: 0, y: 0, width: output.width, height: output.height))
            let p = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
            XCTAssertEqual(p[3], 0, "Outside rounded corner must be transparent")
            let center = (output.height / 2 * output.width + output.width / 2) * 4
            XCTAssertGreaterThan(p[center], 245, "Original white symbol must survive")
            XCTAssertEqual(p[center + 3], 255)
            let top = (output.width / 2) * 4
            XCTAssertGreaterThan(p[top + 2], 170, "Square edge uses sampled blue background")
            XCTAssertTrue((0..<(output.width * output.height)).contains { p[$0 * 4 + 3] > 0 && p[$0 * 4 + 3] < 255 })
        }
    }
    #endif
}
