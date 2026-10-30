import Foundation
import CoreImage

@main struct CheckWalletPoster {
    static func main() async throws {
        precondition(CommandLine.arguments.count == 2)
        let resources = Bundle(path: CommandLine.arguments[1])!
        let worker = OathCustomArtworkPoster(resources: resources)
        let context = CIContext(options: [.useSoftwareRenderer: true])
        var checks = 0
        func check(_ value: Bool) { precondition(value); checks += 1 }
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let channel = (0...255).map { linear(Double($0) / 255) }
        let caption = (0...255).map { linear(0.76 + 0.24 * Double($0) / 255) }
        var maxReadingLuminance = 0.0, minCaptionContrast = Double.infinity
        func checkReading(_ image: CGImage) {
            var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
            context.render(CIImage(cgImage: image), toBitmap: &bytes, rowBytes: image.width * 4,
                           bounds: CGRect(x: 0, y: 0, width: image.width, height: image.height),
                           format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            for index in stride(from: 0, to: bytes.count, by: 4) {
                let r = Int(bytes[index]), g = Int(bytes[index + 1]), b = Int(bytes[index + 2])
                let luminance = channel[r] * 0.2126 + channel[g] * 0.7152 + channel[b] * 0.0722
                let text = caption[r] * 0.2126 + caption[g] * 0.7152 + caption[b] * 0.0722
                maxReadingLuminance = max(maxReadingLuminance, luminance)
                minCaptionContrast = min(minCaptionContrast, (text + 0.05) / (luminance + 0.05))
            }
        }
        func average(_ image: CGImage) -> [UInt8] {
            let source = CIImage(cgImage: image)
            let mean = source.applyingFilter("CIAreaAverage", parameters: ["inputExtent": CIVector(cgRect: source.extent)])
            var bytes = [UInt8](repeating: 0, count: 4)
            context.render(mean, toBitmap: &bytes, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                           format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            return bytes
        }
        for dark in [false, true] {
            var means: [UInt32: [UInt8]] = [:]
            for color: UInt32 in [0xFF0000, 0x00FF00, 0x000000, 0xFFFFFF, 0xFFFF00, 0xDF438D, 0x244DE0] {
                let result = await worker.images(rgb: color, dark: dark)
                check(result != nil)
                let image = result!
                check(image.silk.width == 512 && image.reading.width == 512)
                check(image.silk.height == 1280 && image.reading.height == 1280)
                means[color] = average(image.silk)
                let reading = average(image.reading)
                check(reading[3] == 255)
                checkReading(image.reading)
            }
            check(means[0xFF0000]![0] > means[0xFF0000]![1])
            check(means[0x00FF00]![1] > means[0x00FF00]![0])
            check(means[0xFFFFFF]![0] > means[0x000000]![0])
        }
        check(maxReadingLuminance <= 0.102)
        check(minCaptionContrast >= 4.5)
        print("Passed \(checks) host fallback-artwork checks using the app's bundled images in both appearances.")
        print(String(format: "Reading-region peak luminance %.4f; minimum 76%% white-caption contrast %.2f:1", maxReadingLuminance, minCaptionContrast))
    }
}
