import Foundation
import Vision
import ImageIO

/// Decode the actual rendered receive screen, rather than testing the QR
/// generator against itself. Call with a screenshot and a public fixture address.
@main struct CheckReceiveQR {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else { throw CheckError.arguments }
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw CheckError.image }
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try VNImageRequestHandler(cgImage: image).perform([request])
        guard request.results?.contains(where: { $0.payloadStringValue == CommandLine.arguments[2] }) == true else {
            throw CheckError.payloadMismatch
        }
        print("Passed: rendered QR decodes to the exact expected public address.")
    }
    enum CheckError: Error { case arguments, image, payloadMismatch }
}
