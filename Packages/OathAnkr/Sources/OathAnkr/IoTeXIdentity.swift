import Foundation

/// Both encodings contain the same 20-byte account, with no chain inference
/// from the key itself. Oath derives its EVM account at m/44'/60'/0'/0/0.
public enum IoTeXIdentity {
    public static func ethereum(_ value: String) throws -> String {
        if value.hasPrefix("0x") { return try IndexedEVMIdentity.address(value) }
        guard value == value.lowercased() || value == value.uppercased() else { throw AnkrError.invalidAddress }
        let address = value.lowercased()
        guard address.hasPrefix("io1"), address.utf8.count == 41 else { throw AnkrError.invalidAddress }
        let alphabet = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l".utf8)
        let words = try address.utf8.dropFirst(3).map { byte -> UInt32 in
            guard let index = alphabet.firstIndex(of: byte) else { throw AnkrError.invalidAddress }
            return UInt32(index)
        }
        var checksum: UInt32 = 1
        let hrp = Array("io".utf8)
        for word in hrp.map({ UInt32($0 >> 5) }) + [0] + hrp.map({ UInt32($0 & 31) }) + words {
            let top = checksum >> 25
            checksum = ((checksum & 0x1ffffff) << 5) ^ word
            for (i, g) in [UInt32(0x3b6a57b2),0x26508e6d,0x1ea119fa,0x3d4233dd,0x2a1462b3].enumerated() where (top >> i) & 1 != 0 { checksum ^= g }
        }
        guard checksum == 1 else { throw AnkrError.invalidAddress }
        var accumulator: UInt32 = 0, bits = 0, bytes = Data()
        for word in words.dropLast(6) {
            accumulator = (accumulator << 5) | word; bits += 5
            if bits >= 8 { bits -= 8; bytes.append(UInt8(truncatingIfNeeded: accumulator >> bits)) }
        }
        guard bits == 0, bytes.count == 20 else { throw AnkrError.invalidAddress }
        return "0x" + bytes.map { String(format: "%02x", $0) }.joined()
    }
    public static func native(_ ethereum: String) throws -> String {
        ThorchainSendCrypto.bech32(try TronIdentity.hex(IndexedEVMIdentity.address(ethereum)), prefix: "io")
    }
}
