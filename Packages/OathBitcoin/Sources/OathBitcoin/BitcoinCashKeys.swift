import Foundation
import CryptoKit
internal import BitcoinDevKit

/// Bitcoin Cash P2PKH/BIP44 (coin 145), with CashAddr receive addresses.
/// BDK handles secp256k1 and BIP32; no SegWit/Taproot scripts are offered.
public enum BitcoinCashKeys {
    public static func wallet(seed: Data, account: UInt32 = 0) throws -> BitcoinWalletDescriptor {
        guard (16...64).contains(seed.count) else { throw BitcoinError.invalidKey }
        var digest = Data(HMAC<SHA512>.authenticationCode(for: seed, using: SymmetricKey(data: Data("Bitcoin seed".utf8))))
        defer { digest.resetBytes(in: 0..<digest.count) }
        let payload = Data([0x04,0x88,0xad,0xe4]) + Data(repeating: 0, count: 9) + digest.suffix(32) + Data([0]) + digest.prefix(32)
        return try extended(Base58Check.encode(payload), account: account)
    }

    public static func extended(_ encoded: String, account: UInt32 = 0) throws -> BitcoinWalletDescriptor {
        let parsed = try normalize(encoded)
        let data = parsed.data
        let depth = Int(data[4])
        let child = data[9..<13].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard depth <= 5, account < 0x8000_0000, parsed.secret || depth >= 3 else { throw BitcoinError.unsupportedKeyScope }
        switch depth {
        case 0: guard child == 0, data[5..<9].allSatisfy({ $0 == 0 }) else { throw BitcoinError.invalidKey }
        case 1: guard child == 0x8000_002c else { throw BitcoinError.unsupportedKeyScope }
        case 2: guard child == 0x8000_0091 else { throw BitcoinError.wrongNetwork }
        case 3: guard child >= 0x8000_0000 else { throw BitcoinError.unsupportedKeyScope }
        case 4: guard child <= 1 else { throw BitcoinError.unsupportedKeyScope }
        default: guard child < 0x8000_0000 else { throw BitcoinError.unsupportedKeyScope }
        }
        let path = depth == 0 ? "m/44'/145'/\(account)'" : depth == 1 ? "m/145'/\(account)'" : depth == 2 ? "m/\(account)'" : "m"
        let key: String
        if parsed.secret {
            key = try DescriptorSecretKey.fromString(privateKey: parsed.encoded).derive(path: DerivationPath(path: path)).asPublic().description
        } else { key = try DescriptorPublicKey.fromString(publicKey: parsed.encoded).description }
        let branches = try (depth == 4 ? [child] : depth == 5 ? [0] : [0,1]).map { change in
            let suffix = depth < 4 ? "/\(change)/*" : depth == 4 ? "/*" : ""
            let descriptor = try Descriptor(descriptor: "pkh(\(key)\(suffix))", networkKind: .main)
            try descriptor.sanityCheck()
            let origin = depth == 0 ? "\(path)/\(change)" : "imported\(path == "m" ? "" : "/" + path.dropFirst(2))\(depth < 4 ? "/\(change)" : "")"
            return BitcoinBranch(type: .legacy, change: change, path: origin,
                                 descriptor: descriptor.asPublic().description, isHD: depth < 5, network: .bitcoincash)
        }
        return .init(branches: branches, defaultType: .legacy, scopedImport: depth != 0)
    }

    public static func singleKey(bytes: Data, compressed: Bool) throws -> BitcoinWalletDescriptor {
        let bitcoin = try BitcoinKeys.singleKey(bytes: bytes, compressed: compressed)
        guard let legacy = bitcoin.branches.first(where: { $0.type == .legacy }) else { throw BitcoinError.invalidKey }
        return .init(branches: [.init(type: .legacy, change: 0, path: "imported", descriptor: legacy.descriptor,
                                     isHD: false, network: .bitcoincash)], defaultType: .legacy, scopedImport: false)
    }

    public static func decodeImport(_ text: String) throws -> (bytes: Data, compressed: Bool, extended: String?) {
        guard !text.isEmpty, text.utf8.count <= 128 else { throw BitcoinError.invalidKey }
        let hex = text.hasPrefix("0x") || text.hasPrefix("0X") ? String(text.dropFirst(2)) : text
        if hex.count == 64, let bytes = Data(hex: hex) {
            _ = try singleKey(bytes: bytes, compressed: true); return (bytes, true, nil)
        }
        // Strict canonical Base64 for raw 32-byte scalars; no ignored characters.
        if let bytes = Data(base64Encoded: text), bytes.count == 32, bytes.base64EncodedString() == text {
            _ = try singleKey(bytes: bytes, compressed: true); return (bytes, true, nil)
        }
        if text.hasPrefix("xprv") {
            let parsed = try normalize(text)
            guard parsed.secret else { throw BitcoinError.invalidKey }
            _ = try extended(text)
            let bytes = try DescriptorSecretKey.fromString(privateKey: parsed.encoded).secretBytes()
            guard bytes.count == 32 else { throw BitcoinError.invalidKey }
            return (bytes, true, text)
        }
        // Published Casascius mini keys, including Electron Cash's >=20-byte
        // variants, always use the uncompressed public key.
        if text.count >= 20, text.hasPrefix("S"), text.utf8.allSatisfy(Base58Check.alphabet.contains),
           Data(SHA256.hash(data: Data((text + "?").utf8))).first == 0 {
            let bytes = Data(SHA256.hash(data: Data(text.utf8)))
            _ = try singleKey(bytes: bytes, compressed: false); return (bytes, false, nil)
        }
        let wif = text.hasPrefix("p2pkh:") ? String(text.dropFirst(6)) : text
        let payload = try Base58Check.decode(wif)
        guard payload.first == 0x80, payload.count == 33 || (payload.count == 34 && payload.last == 1) else { throw BitcoinError.invalidKey }
        let bytes = Data(payload.dropFirst().prefix(32))
        _ = try singleKey(bytes: bytes, compressed: payload.count == 34)
        return (bytes, payload.count == 34, nil)
    }

    public static func wif(bytes: Data, compressed: Bool) throws -> String {
        _ = try singleKey(bytes: bytes, compressed: compressed)
        return Base58Check.encode(Data([0x80]) + bytes + (compressed ? Data([1]) : Data()))
    }

    private static func normalize(_ text: String) throws -> (data: Data, encoded: String, secret: Bool) {
        var data = try Base58Check.decode(text)
        guard data.count == 78 else { throw BitcoinError.invalidKey }
        let version = data.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let secret: Bool
        switch version {
        case 0x0488ade4: secret = true
        case 0x0488b21e: secret = false
        default: throw BitcoinError.wrongNetwork
        }
        data.replaceSubrange(0..<4, with: secret ? [0x04,0x88,0xad,0xe4] : [0x04,0x88,0xb2,0x1e])
        return (data, Base58Check.encode(data), secret)
    }
}
