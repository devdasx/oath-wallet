import Foundation

/// Public token-list identity only. OathAnkr owns transaction/address handling;
/// importing it here would make the image and provider packages cyclic.
/// TEP-2: validate the wrapper's flags and CRC before matching it to a raw ID.
/// https://docs.ton.org/foundations/addresses/formats
struct TonArtworkAddress {
    static func raw(_ value: String) -> String? {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count == 2 {
            guard let workchain = Int8(parts[0]), String(workchain) == parts[0],
                  parts[1].utf8.count == 64,
                  parts[1].utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { return nil }
            return String(workchain) + ":" + parts[1].lowercased()
        }
        guard value.utf8.count == 48,
              let bytes = Data(base64Encoded: value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")),
              bytes.count == 36, bytes[0] == 0x11 || bytes[0] == 0x51 else { return nil }
        // Testnet-only wrappers (0x91/0xd1) never enter the mainnet catalog.
        var crc: UInt16 = 0
        for byte in bytes.prefix(34) {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 { crc = crc & 0x8000 != 0 ? (crc &<< 1) ^ 0x1021 : crc &<< 1 }
        }
        guard bytes[34] == UInt8(crc >> 8), bytes[35] == UInt8(crc & 255) else { return nil }
        return String(Int8(bitPattern: bytes[1])) + ":" + bytes[2..<34].map { String(format: "%02x", $0) }.joined()
    }
}
