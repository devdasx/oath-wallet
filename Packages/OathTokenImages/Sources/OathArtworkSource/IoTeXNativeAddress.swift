import Foundation

/// Convert a checksummed mainnet io1 address to its exact 20-byte EVM identity.
public enum IoTeXNativeAddress {
    public static func ethereum(_ value: String) -> String? {
        guard value.utf8.count == 41, value.utf8.allSatisfy({ $0 < 128 }),
              value == value.lowercased() || value == value.uppercased() else { return nil }
        let address = value.lowercased()
        guard address.hasPrefix("io1") else { return nil }
        let alphabet = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l".utf8)
        var words = [UInt32]()
        for byte in address.utf8.dropFirst(3) {
            guard let index = alphabet.firstIndex(of: byte) else { return nil }
            words.append(UInt32(index))
        }
        let generators: [UInt32] = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]
        var checksum: UInt32 = 1
        let hrp = Array("io".utf8)
        for word in hrp.map({ UInt32($0 >> 5) }) + [0] + hrp.map({ UInt32($0 & 31) }) + words {
            let top = checksum >> 25
            checksum = ((checksum & 0x1ffffff) << 5) ^ word
            for (bit, generator) in generators.enumerated() where (top >> bit) & 1 != 0 {
                checksum ^= generator
            }
        }
        guard checksum == 1 else { return nil }
        var accumulator: UInt32 = 0
        var bits = 0
        var bytes = Data()
        for word in words.dropLast(6) {
            accumulator = (accumulator << 5) | word
            bits += 5
            if bits >= 8 {
                bits -= 8
                bytes.append(UInt8(truncatingIfNeeded: accumulator >> bits))
            }
        }
        guard bits == 0, bytes.count == 20 else { return nil }
        return "0x" + bytes.map { String(format: "%02x", $0) }.joined()
    }
}
