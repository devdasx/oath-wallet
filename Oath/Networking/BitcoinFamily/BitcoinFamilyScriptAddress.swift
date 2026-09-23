import Foundation
import WalletCore

enum BitcoinFamilyScriptAddress {
    static func address(
        from script: Data,
        chain: BitcoinFamilyChain
    ) -> String? {
        let candidate: String?
        if let hash = p2pkhHash(in: script) {
            candidate = legacyAddress(
                hash: hash,
                chain: chain,
                isScriptHash: false
            )
        } else if let hash = p2shHash(in: script) {
            candidate = legacyAddress(
                hash: hash,
                chain: chain,
                isScriptHash: true
            )
        } else if let witness = witnessProgram(in: script) {
            candidate = witnessAddress(
                version: witness.version,
                program: witness.program,
                chain: chain
            )
        } else {
            candidate = nil
        }
        guard let candidate,
              chain.coin.validate(address: candidate) else {
            return nil
        }
        return candidate
    }

    private static func legacyAddress(
        hash: Data,
        chain: BitcoinFamilyChain,
        isScriptHash: Bool
    ) -> String? {
        guard hash.count == 20 else { return nil }
        if chain == .bitcoinCash {
            return isScriptHash
                ? BitcoinCashCashAddrEncoder.p2sh(scriptHash: hash)
                : BitcoinCashCashAddrEncoder.p2pkh(publicKeyHash: hash)
        }
        let prefix: UInt8 = switch (chain, isScriptHash) {
        case (.bitcoin, false): 0x00
        case (.bitcoin, true): 0x05
        case (.litecoin, false): 0x30
        case (.litecoin, true): 0x32
        case (.dogecoin, false): 0x1e
        case (.dogecoin, true): 0x16
        case (.bitcoinCash, _): 0x00
        }
        return Base58.encode(data: Data([prefix]) + hash)
    }

    private static func witnessAddress(
        version: Int,
        program: Data,
        chain: BitcoinFamilyChain
    ) -> String? {
        let humanReadablePart: String
        switch chain {
        case .bitcoin:
            humanReadablePart = "bc"
        case .litecoin:
            humanReadablePart = "ltc"
        case .bitcoinCash, .dogecoin:
            return nil
        }
        return BitcoinFamilySegwitAddressEncoder.encode(
            humanReadablePart: humanReadablePart,
            version: version,
            program: program
        )
    }

    private static func p2pkhHash(in script: Data) -> Data? {
        guard script.count == 25,
              script.starts(with: [0x76, 0xa9, 0x14]),
              script.suffix(2) == Data([0x88, 0xac]) else {
            return nil
        }
        return script.subdata(in: 3..<23)
    }

    private static func p2shHash(in script: Data) -> Data? {
        guard script.count == 23,
              script.starts(with: [0xa9, 0x14]),
              script.last == 0x87 else {
            return nil
        }
        return script.subdata(in: 2..<22)
    }

    private static func witnessProgram(
        in script: Data
    ) -> (version: Int, program: Data)? {
        guard script.count >= 4 else { return nil }
        let version: Int
        switch script[script.startIndex] {
        case 0x00:
            version = 0
        case 0x51...0x60:
            version = Int(script[script.startIndex] - 0x50)
        default:
            return nil
        }
        let length = Int(script[script.startIndex + 1])
        guard (2...40).contains(length),
              script.count == length + 2 else {
            return nil
        }
        return (version, script.subdata(in: 2..<(length + 2)))
    }
}

private enum BitcoinFamilySegwitAddressEncoder {
    private static let charset = Array(
        "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
    )

    static func encode(
        humanReadablePart: String,
        version: Int,
        program: Data
    ) -> String? {
        guard (0...16).contains(version),
              (2...40).contains(program.count),
              version != 0 || program.count == 20 || program.count == 32,
              let converted = convertBits(
                  Array(program),
                  from: 8,
                  to: 5,
                  pad: true
              ) else {
            return nil
        }
        let values = [UInt8(version)] + converted
        let constant: UInt32 = version == 0 ? 1 : 0x2bc8_30a3
        let checksum = createChecksum(
            humanReadablePart: humanReadablePart,
            values: values,
            constant: constant
        )
        return humanReadablePart + "1"
            + String((values + checksum).map { charset[Int($0)] })
    }

    private static func createChecksum(
        humanReadablePart: String,
        values: [UInt8],
        constant: UInt32
    ) -> [UInt8] {
        let expanded = humanReadablePart.utf8.map { $0 >> 5 }
            + [0]
            + humanReadablePart.utf8.map { $0 & 31 }
        let value = polymod(
            expanded + values + Array(repeating: 0, count: 6)
        ) ^ constant
        return (0..<6).map {
            UInt8((value >> UInt32(5 * (5 - $0))) & 31)
        }
    }

    private static func polymod(_ values: [UInt8]) -> UInt32 {
        let generators: [UInt32] = [
            0x3b6a_57b2,
            0x2650_8e6d,
            0x1ea1_19fa,
            0x3d42_33dd,
            0x2a14_62b3,
        ]
        return values.reduce(1) { checksum, value in
            let top = checksum >> 25
            var next = (checksum & 0x01ff_ffff) << 5 ^ UInt32(value)
            for index in 0..<5 where (top >> index) & 1 == 1 {
                next ^= generators[index]
            }
            return next
        }
    }

    private static func convertBits(
        _ values: [UInt8],
        from sourceBits: Int,
        to destinationBits: Int,
        pad: Bool
    ) -> [UInt8]? {
        var accumulator = 0
        var bits = 0
        var result: [UInt8] = []
        let maximumValue = (1 << destinationBits) - 1
        for value in values {
            guard Int(value) >> sourceBits == 0 else { return nil }
            accumulator = (accumulator << sourceBits) | Int(value)
            bits += sourceBits
            while bits >= destinationBits {
                bits -= destinationBits
                result.append(
                    UInt8((accumulator >> bits) & maximumValue)
                )
            }
        }
        if pad, bits > 0 {
            result.append(
                UInt8(
                    (accumulator << (destinationBits - bits))
                        & maximumValue
                )
            )
        } else if !pad,
                  bits >= sourceBits
                    || ((accumulator << (destinationBits - bits))
                        & maximumValue) != 0 {
            return nil
        }
        return result
    }
}
