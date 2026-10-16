import Foundation
import Vision

/// All payloads are public fixtures, never read from a wallet or Keychain.
/// Decode the production in-memory QR image with an independent OS decoder.
@main struct CheckPrivateKeyQR {
    static func main() throws {
        let payloads = [
            "KwDiBf89QgGbjEhKnhXJuH7LrciVrZi3qYjgd9M7rFU73sVHnoWn", // Public scalar 1 WIF.
            "0x" + String(repeating: "ab", count: 32),
            String(repeating: "ab", count: 32),
            "00" + String(repeating: "AB", count: 32),
            "ed25519-priv-0x" + String(repeating: "ab", count: 32),
            "ed25519:" + String(repeating: "123456789ABCDEFGHJKLMNPQRSTUVWXYZ", count: 3),
            String(repeating: "123456789ABCDEFGHJKLMNPQRSTUVWXYZ", count: 3),
            "suiprivkey1" + String(repeating: "qwerty", count: 9),
            "S" + String(repeating: "ABCDEF234567", count: 5)
        ]
        precondition(OathPrivateKeyQRCode.image(for: "") == nil)
        for payload in payloads {
            guard let image = OathPrivateKeyQRCode.image(for: payload) else { throw Failure.image }
            let request = VNDetectBarcodesRequest()
            request.symbologies = [.qr]
            try VNImageRequestHandler(cgImage: image).perform([request])
            guard request.results?.contains(where: { $0.payloadStringValue == payload }) == true else { throw Failure.payload }
        }
        print("Passed 10 private-key QR checks: exact in-memory payloads across export formats, empty input rejected. No wallet data or image files used.")
    }
    enum Failure: Error { case image, payload }
}
