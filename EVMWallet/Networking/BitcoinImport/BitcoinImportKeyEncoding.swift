import Foundation
import WalletCore

enum BitcoinImportKeyEncoding {
    struct Key: Equatable, Sendable {
        let key: Data
        let compressed: Bool
    }

    /// A raw 32-byte scalar in standard Base64, with or without its final '='.
    /// Round-trip validation rejects ignored characters and nonzero padding bits.
    static func base64(_ text: String) throws -> Key {
        guard [43, 44].contains(text.utf8.count) else { throw BitcoinImportError.invalidKey }
        let padded = text.utf8.count == 43 ? text + "=" : text
        guard let key = Data(base64Encoded: padded), key.count == 32,
              key.base64EncodedString() == padded,
              PrivateKey.isValid(data: key, curve: .secp256k1) else {
            throw BitcoinImportError.invalidKey
        }
        return Key(key: key, compressed: true)
    }

    static func wif(_ text: String) throws -> Key {
        guard (51...52).contains(text.utf8.count), let data = Base58.decode(string: text),
              [33, 34].contains(data.count) else { throw BitcoinImportError.invalidKey }
        guard data.first == 0x80 else { throw BitcoinImportError.unsupportedNetwork }
        let compressed = data.count == 34
        guard !compressed || data.last == 1 else { throw BitcoinImportError.invalidKey }
        let key = Data(data[1..<33])
        guard PrivateKey.isValid(data: key, curve: .secp256k1) else { throw BitcoinImportError.invalidKey }
        return Key(key: key, compressed: compressed)
    }

    static func mini(_ text: String) throws -> Key {
        let alphabet = Set("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz".utf8)
        guard (20...64).contains(text.utf8.count), text.hasPrefix("S"),
              text.utf8.allSatisfy({ alphabet.contains($0) }),
              Hash.sha256(data: Data((text + "?").utf8)).first == 0 else { throw BitcoinImportError.invalidKey }
        let key = Hash.sha256(data: Data(text.utf8))
        guard PrivateKey.isValid(data: key, curve: .secp256k1) else { throw BitcoinImportError.invalidKey }
        return Key(key: key, compressed: false)
    }

    static func encode(_ key: Key) throws -> String {
        guard PrivateKey.isValid(data: key.key, curve: .secp256k1) else { throw BitcoinImportError.invalidKey }
        return Base58.encode(data: Data([0x80]) + key.key + (key.compressed ? Data([1]) : Data()))
    }

    static func electrumDescriptor(_ text: String) throws -> BitcoinPrivateDescriptor {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 else { throw BitcoinImportError.invalidKey }
        let key = String(parts[1])
        switch parts[0] {
        case "p2pkh": return try BitcoinPrivateDescriptor("pkh(\(key))")
        case "p2wpkh": return try BitcoinPrivateDescriptor("wpkh(\(key))")
        case "p2wpkh-p2sh": return try BitcoinPrivateDescriptor("sh(wpkh(\(key)))")
        default: throw BitcoinImportError.unsupportedScript
        }
    }
}
