import Foundation

/// TRON REST nodes encode protobuf messages as hex; some proxies use Base64.
/// Decode before sanitizing/truncating, retaining plain-text provider responses.
enum SendTronProviderMessage {
    static func decode(_ rawValue: String) -> String {
        let raw = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.utf8.count <= 16_384 else { return rawValue }
        let hexadecimal = raw.hasPrefix("0x") || raw.hasPrefix("0X")
            ? String(raw.dropFirst(2)) : raw
        if !hexadecimal.isEmpty, hexadecimal.count.isMultiple(of: 2),
           hexadecimal.utf8.allSatisfy({
               (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
           }) {
            let bytes = Array(hexadecimal.utf8)
            let data = Data(stride(from: 0, to: bytes.count, by: 2).map {
                UInt8(String(decoding: bytes[$0...($0 + 1)], as: UTF8.self), radix: 16)!
            })
            if let text = readableText(data) { return text }
        }
        if let data = Data(base64Encoded: raw),
           let text = readableText(data) { return text }
        return rawValue
    }

    static func rejectionDescription(code: String, message: String) -> String {
        let isSignatureError = code.caseInsensitiveCompare("SIGERROR") == .orderedSame
        return WalletLocalization.string(
            isSignatureError ? "send.submit.error.tron_signature" : "send.submit.error.try_again"
        )
    }

    private static func readableText(_ data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty,
              text.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
                      || CharacterSet.whitespacesAndNewlines.contains($0)
              }) else { return nil }
        return text
    }
}
