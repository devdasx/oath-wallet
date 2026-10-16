import Foundation
import CryptoKit
internal import BitcoinDevKit

/// Litecoin's transparent BIP44/49/84/86 wallets. Curve operations, BIP32 and
/// scripts remain in BDK; only coin type, key versions and address encoding vary.
public enum LitecoinKeys {
    public static func wallet(seed: Data, account: UInt32 = 0) throws -> BitcoinWalletDescriptor {
        try BitcoinKeys.wallet(seed: seed, account: account, network: .litecoin)
    }
    public static func extended(_ encoded: String, account: UInt32 = 0) throws -> BitcoinWalletDescriptor {
        try BitcoinKeys.extended(encoded, account: account, network: .litecoin)
    }
    public static func singleKey(bytes: Data, compressed: Bool) throws -> BitcoinWalletDescriptor {
        try BitcoinKeys.singleKey(bytes: bytes, compressed: compressed, network: .litecoin)
    }
    public static func wif(bytes: Data, compressed: Bool) throws -> String {
        _ = try singleKey(bytes: bytes, compressed: compressed)
        return Base58Check.encode(Data([0xb0]) + bytes + (compressed ? Data([1]) : Data()))
    }

    public static func decodeImport(_ text: String) throws -> (bytes: Data, compressed: Bool, extended: String?) {
        guard !text.isEmpty, text.utf8.count <= 160 else { throw BitcoinError.invalidKey }
        let hex = text.hasPrefix("0x") || text.hasPrefix("0X") ? String(text.dropFirst(2)) : text
        if hex.count == 64, let bytes = Data(hex: hex) {
            _ = try singleKey(bytes: bytes, compressed: true); return (bytes, true, nil)
        }
        if let bytes = Data(base64Encoded: text), bytes.count == 32, bytes.base64EncodedString() == text {
            _ = try singleKey(bytes: bytes, compressed: true); return (bytes, true, nil)
        }
        if ["xprv", "yprv", "zprv", "Ltpv", "Mtpv"].contains(where: text.hasPrefix) {
            let parsed = try BitcoinKeys.normalizedExtended(text, network: .litecoin)
            guard parsed.privateKey else { throw BitcoinError.invalidKey }
            _ = try extended(text)
            let bytes = try DescriptorSecretKey.fromString(privateKey: parsed.encoded).secretBytes()
            guard bytes.count == 32 else { throw BitcoinError.invalidKey }
            return (bytes, true, text)
        }
        // Casascius-style mini keys are uncompressed, as in Electrum-LTC.
        if [22, 30].contains(text.count), text.hasPrefix("S"), text.utf8.allSatisfy(Base58Check.alphabet.contains),
           Data(SHA256.hash(data: Data((text + "?").utf8))).first == 0 {
            let bytes = Data(SHA256.hash(data: Data(text.utf8)))
            _ = try singleKey(bytes: bytes, compressed: false); return (bytes, false, nil)
        }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { throw BitcoinError.invalidKey }
        let style = parts.count == 2 ? String(parts[0]) : nil
        guard style == nil || ["p2pkh", "p2wpkh", "p2wpkh-p2sh"].contains(style!) else { throw BitcoinError.unsupportedKeyScope }
        let data = try Base58Check.decode(String(parts.last!))
        guard data.count == 33 || (data.count == 34 && data.last == 1) else { throw BitcoinError.invalidKey }
        let compressed = data.count == 34
        // Core WIF is 0xb0. Old Electrum-LTC internal exports encoded the
        // single-key SegWit script type as 0x81/0x82; multisig needs a descriptor.
        guard data.first == 0xb0 || (style == nil && compressed && [0x81, 0x82].contains(data.first!)),
              style == nil || style == "p2pkh" || compressed else { throw BitcoinError.invalidKey }
        let bytes = Data(data.dropFirst().prefix(32))
        _ = try singleKey(bytes: bytes, compressed: compressed)
        return (bytes, compressed, nil)
    }

    static func address(script: Data, type: BitcoinAddressType) throws -> String {
        switch type {
        case .legacy:
            guard script.count == 25, script.prefix(3) == Data([0x76,0xa9,0x14]), script.suffix(2) == Data([0x88,0xac]) else { throw BitcoinError.invalidAddress }
            return Base58Check.encode(Data([48]) + script.dropFirst(3).prefix(20))
        case .nestedSegwit:
            guard script.count == 23, script.prefix(2) == Data([0xa9,0x14]), script.last == 0x87 else { throw BitcoinError.invalidAddress }
            // Legacy 3... aliases have the same script and Electrum script hash.
            return Base58Check.encode(Data([50]) + script.dropFirst(2).prefix(20))
        case .nativeSegwit:
            guard script.count == 22, script.prefix(2) == Data([0,20]) else { throw BitcoinError.invalidAddress }
            return SegwitAddress.encode(hrp: "ltc", version: 0, program: script.dropFirst(2))
        case .taproot:
            guard script.count == 34, script.prefix(2) == Data([0x51,32]) else { throw BitcoinError.invalidAddress }
            return SegwitAddress.encode(hrp: "ltc", version: 1, program: script.dropFirst(2))
        }
    }
}

/// BIP173/BIP350 encoding of already-validated witness programs, never keys.
enum SegwitAddress {
    static func encode(hrp: String, version: UInt8, program: Data) -> String {
        let alphabet = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l".utf8)
        var values: [UInt8] = [version]
        var accumulator: UInt32 = 0, bits = 0
        for byte in program {
            accumulator = ((accumulator << 8) | UInt32(byte)) & 0x0fff
            bits += 8
            while bits >= 5 { bits -= 5; values.append(UInt8((accumulator >> bits) & 31)) }
        }
        if bits > 0 { values.append(UInt8((accumulator << (5 - bits)) & 31)) }
        let hrpBytes = Array(hrp.utf8)
        let expanded = hrpBytes.map { $0 >> 5 } + [0] + hrpBytes.map { $0 & 31 }
        var checksum: UInt32 = 1
        let generators: [UInt32] = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]
        for value in expanded + values + Array(repeating: 0, count: 6) {
            let top = checksum >> 25
            checksum = ((checksum & 0x1ffffff) << 5) ^ UInt32(value)
            for bit in 0..<5 where ((top >> bit) & 1) != 0 { checksum ^= generators[bit] }
        }
        checksum ^= version == 0 ? 1 : 0x2bc830a3
        let suffix = (0..<6).map { UInt8((checksum >> (5 * (5 - $0))) & 31) }
        return hrp + "1" + String(decoding: (values + suffix).map { alphabet[Int($0)] }, as: UTF8.self)
    }
}
