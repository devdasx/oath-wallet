import Foundation
import OathAezeedCore

/// Expected input failures; never include recovery words or passphrases in errors.
public enum AezeedError: Error, Equatable, Sendable {
    case invalidMnemonic, unsupportedVersion, incorrectPassphrase
}

/// Store only inside the authenticated local vault, never in SQL or telemetry.
public struct AezeedMaterial: Codable, Equatable, Sendable {
    public let entropy: Data
    public let version: UInt8
    public let birthday: UInt16
    public let passphrase: String
    public var isValid: Bool { entropy.count == 16 && version <= 1 && passphrase.utf8.count <= 4096 }
}

public enum Aezeed {
    private static let dictionary: [String: Int] = {
        guard let url = Bundle.module.url(forResource: "english", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count == 2048, Set(words).count == 2048 else { return [:] }
        return Dictionary(uniqueKeysWithValues: words.enumerated().map { ($1, $0) })
    }()

    public static func canonical(_ text: String) -> String {
        text.lowercased(with: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Cheap CRC check for format detection, never a decryption/validation claim.
    /// Accept unknown versions here so they produce an explicit unsupported error.
    public static func recognizes(_ text: String) -> Bool { (try? envelope(text)) != nil }

    private static func envelope(_ text: String) throws -> [UInt8] {
        guard text.utf8.count <= 4096 else { throw AezeedError.invalidMnemonic }
        let words = canonical(text).split(separator: " ")
        guard words.count == 24, dictionary.count == 2048 else { throw AezeedError.invalidMnemonic }
        var bytes = [UInt8](repeating: 0, count: 33)
        for (word, value) in words.enumerated() {
            guard let index = dictionary[String(value)] else { throw AezeedError.invalidMnemonic }
            for bit in 0..<11 {
                let position = word * 11 + bit
                bytes[position / 8] |= UInt8((index >> (10 - bit)) & 1) << (7 - position % 8)
            }
        }
        var crc: UInt32 = 0xffff_ffff
        for byte in bytes.prefix(29) {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0x82f63b78 : 0) }
        }
        crc ^= 0xffff_ffff
        let stored = bytes.suffix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard crc == stored else { throw AezeedError.invalidMnemonic }
        return bytes
    }

    /// scrypt/AEZ is deliberately called off the UI actor. The Go bridge bounds
    /// concurrency to one KDF and passes password UTF-8 unchanged (no NFKD).
    public static func decode(_ text: String, passphrase: String = "") throws -> AezeedMaterial {
        var encoded = try envelope(text)
        guard encoded[0] == 0 else { throw AezeedError.unsupportedVersion }
        guard passphrase.utf8.count <= 4096 else { throw AezeedError.incorrectPassphrase }
        var password = Array(passphrase.utf8)
        var output = [UInt8](repeating: 0, count: 19)
        defer {
            _ = encoded.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) }
            _ = password.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) }
            _ = output.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) }
        }
        let result = OathAezeedDecode(&encoded, encoded.count, &password, password.count, &output, output.count)
        switch result {
        case 0: return AezeedMaterial(entropy: Data(output[3..<19]), version: output[0],
                                     birthday: UInt16(output[1]) << 8 | UInt16(output[2]), passphrase: passphrase)
        case 2: throw AezeedError.unsupportedVersion
        case 3: throw AezeedError.incorrectPassphrase
        default: throw AezeedError.invalidMnemonic
        }
    }
}
