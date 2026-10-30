import Foundation
import Vision
import ImageIO

/// Bounded photo decoding shared by the scanner and host QR tests.
enum OathScanImage {
    static func codes(in data: Data) throws -> [String] {
        guard data.count <= 32 * 1_024 * 1_024, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 3_072,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw ImageFailure.invalid }
        let request = VNDetectBarcodesRequest(); request.symbologies = [.qr]
        try VNImageRequestHandler(cgImage: image).perform([request])
        return Array(Set((request.results ?? []).compactMap(\.payloadStringValue).filter { $0.utf8.count <= 8_192 }).prefix(8))
    }
    enum ImageFailure: Error { case invalid }
}
