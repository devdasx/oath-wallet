import Foundation

// MARK: - Random data generation

extension Data {

    public static func randomBytes(count: Int) -> Data {
        var buffer = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &buffer)
        guard status == errSecSuccess else {
            fatalError("Failed to generate secure random data of size \(count).")
        }
        return Data(buffer)
    }
}

// MARK: - Hexadecimal string conversion

extension Data {

    public enum HexDecodingError: Error {
        case oddLength
        case invalidCharacter
    }

    /// Legacy nonthrowing conversion. Malformed input produces empty data.
    /// Key constructors use validatingHex to distinguish malformed input.
    public init(hex: String) {
        self = (try? Data(validatingHex: hex)) ?? Data()
    }

    public init(validatingHex hex: String) throws {
        let body = hex.hasPrefix("0x") || hex.hasPrefix("0X") ? hex.dropFirst(2) : hex[...]
        let input = Array(body.utf8)
        guard input.count.isMultiple(of: 2) else { throw HexDecodingError.oddLength }
        var output = Data(capacity: input.count / 2)
        for index in stride(from: 0, to: input.count, by: 2) {
            guard let high = Self.hexNibble(input[index]), let low = Self.hexNibble(input[index + 1]) else {
                throw HexDecodingError.invalidCharacter
            }
            output.append((high << 4) | low)
        }
        self = output
    }

    private static func hexNibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: return byte - 48
        case 65...70: return byte - 55
        case 97...102: return byte - 87
        default: return nil
        }
    }

    public func toHexString() -> String {
        return map({ String(format: "%02x", $0) }).joined()
    }

    public init?(base64url: String) {
        var base64 = base64url
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        if base64.count % 4 != 0 {
            base64.append(String(repeating: "=", count: 4 - base64.count % 4))
        }
        self.init(base64Encoded: base64)
    }
}
