import Foundation

enum BitcoinCashCashAddrEncoder {
    private static let mainnetPrefix = "bitcoincash"
    private static let alphabet = Array(
        "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
    )

    static func p2pkh(publicKeyHash: Data) -> String? {
        encode(hash: publicKeyHash, type: 0)
    }

    static func p2sh(scriptHash: Data) -> String? {
        encode(hash: scriptHash, type: 1)
    }

    private static func encode(hash: Data, type: UInt8) -> String? {
        guard hash.count == 20, type <= 15 else { return nil }

        var versionedHash = Data([type << 3])
        versionedHash.append(hash)
        let payload = convertToBase32(versionedHash)
        let checksum = checksum(prefix: mainnetPrefix, payload: payload)
        let symbols = payload + checksum
        guard symbols.allSatisfy({ Int($0) < alphabet.count }) else {
            return nil
        }
        let encoded = String(symbols.map { alphabet[Int($0)] })
        return "\(mainnetPrefix):\(encoded)"
    }

    private static func convertToBase32(_ data: Data) -> [UInt8] {
        var accumulator: UInt32 = 0
        var bitCount = 0
        var result: [UInt8] = []
        result.reserveCapacity((data.count * 8 + 4) / 5)

        for byte in data {
            accumulator = ((accumulator & 0x0fff) << 8)
                | UInt32(byte)
            bitCount += 8
            while bitCount >= 5 {
                bitCount -= 5
                result.append(
                    UInt8((accumulator >> bitCount) & 0x1f)
                )
            }
        }
        if bitCount > 0 {
            result.append(
                UInt8((accumulator << (5 - bitCount)) & 0x1f)
            )
        }
        return result
    }

    private static func checksum(
        prefix: String,
        payload: [UInt8]
    ) -> [UInt8] {
        var values = prefix.unicodeScalars.map {
            UInt8($0.value & 0x1f)
        }
        values.append(0)
        values.append(contentsOf: payload)
        values.append(contentsOf: repeatElement(0, count: 8))
        let value = polymod(values)
        return (0..<8).map { index in
            UInt8((value >> UInt64(5 * (7 - index))) & 0x1f)
        }
    }

    private static func polymod(_ values: [UInt8]) -> UInt64 {
        var checksum: UInt64 = 1
        for value in values {
            let high = checksum >> 35
            checksum = ((checksum & 0x07_ffff_ffff) << 5)
                ^ UInt64(value)
            if high & 0x01 != 0 { checksum ^= 0x98_f2bc_8e61 }
            if high & 0x02 != 0 { checksum ^= 0x79_b76d_99e2 }
            if high & 0x04 != 0 { checksum ^= 0xf3_3e5f_b3c4 }
            if high & 0x08 != 0 { checksum ^= 0xae_2eab_e2a8 }
            if high & 0x10 != 0 { checksum ^= 0x1e_4f43_e470 }
        }
        return checksum ^ 1
    }
}
