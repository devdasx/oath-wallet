import Foundation
import P256K

enum BitcoinSilentPaymentAddressError: Error, Equatable {
    case invalidEncoding
    case unsupportedNetwork
    case unsupportedVersion
    case invalidPublicKey
}

struct BitcoinSilentPaymentAddress: Hashable, Sendable {
    static let mainnetHumanReadablePart = "sp"
    static let currentVersion: UInt8 = 0
    static let maximumEncodedLength = 1_023

    let version: UInt8
    let scanPublicKey: Data
    let spendPublicKey: Data
    let encoded: String

    init(scanPublicKey: Data, spendPublicKey: Data) throws {
        try Self.validatePublicKey(scanPublicKey)
        try Self.validatePublicKey(spendPublicKey)
        guard let encoded = BitcoinSilentPaymentBech32m.encode(
            humanReadablePart: Self.mainnetHumanReadablePart,
            version: Self.currentVersion,
            payload: scanPublicKey + spendPublicKey
        ) else {
            throw BitcoinSilentPaymentAddressError.invalidEncoding
        }
        self.version = Self.currentVersion
        self.scanPublicKey = scanPublicKey
        self.spendPublicKey = spendPublicKey
        self.encoded = encoded
    }

    init(_ value: String) throws {
        let trimmed = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard trimmed.utf8.count <= Self.maximumEncodedLength,
              let decoded = BitcoinSilentPaymentBech32m.decode(trimmed)
        else {
            throw BitcoinSilentPaymentAddressError.invalidEncoding
        }
        guard decoded.humanReadablePart
            == Self.mainnetHumanReadablePart else {
            throw BitcoinSilentPaymentAddressError.unsupportedNetwork
        }
        guard decoded.version < 31 else {
            throw BitcoinSilentPaymentAddressError.unsupportedVersion
        }
        guard decoded.payload.count >= 66,
              decoded.version != Self.currentVersion
                || decoded.payload.count == 66 else {
            throw BitcoinSilentPaymentAddressError.invalidEncoding
        }
        let scan = Data(decoded.payload.prefix(33))
        let spend = Data(decoded.payload.dropFirst(33).prefix(33))
        try Self.validatePublicKey(scan)
        try Self.validatePublicKey(spend)

        version = decoded.version
        scanPublicKey = scan
        spendPublicKey = spend
        encoded = trimmed.lowercased()
    }

    static func isValidMainnet(_ value: String) -> Bool {
        (try? Self(value)) != nil
    }

    private static func validatePublicKey(_ data: Data) throws {
        guard data.count == 33,
              data.first == 0x02 || data.first == 0x03,
              (try? P256K.Signing.PublicKey(
                  dataRepresentation: data,
                  format: .compressed
              )) != nil else {
            throw BitcoinSilentPaymentAddressError.invalidPublicKey
        }
    }
}

private enum BitcoinSilentPaymentBech32m {
    private static let charset = Array(
        "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
    )
    private static let checksumConstant: UInt32 = 0x2bc8_30a3

    struct Decoded {
        let humanReadablePart: String
        let version: UInt8
        let payload: Data
    }

    static func encode(
        humanReadablePart: String,
        version: UInt8,
        payload: Data
    ) -> String? {
        guard !humanReadablePart.isEmpty,
              humanReadablePart.utf8.allSatisfy({
                  (33...126).contains($0)
              }),
              version <= 31,
              let converted = convertBits(
                  Array(payload),
                  from: 8,
                  to: 5,
                  pad: true
              ) else {
            return nil
        }
        let hrp = humanReadablePart.lowercased()
        let values = [version] + converted
        let checksum = createChecksum(
            humanReadablePart: hrp,
            values: values
        )
        let result = hrp + "1"
            + String((values + checksum).map { charset[Int($0)] })
        return result.utf8.count <= BitcoinSilentPaymentAddress
            .maximumEncodedLength ? result : nil
    }

    static func decode(_ encoded: String) -> Decoded? {
        guard !encoded.isEmpty,
              encoded.utf8.count <= BitcoinSilentPaymentAddress
                .maximumEncodedLength,
              !isMixedCase(encoded) else {
            return nil
        }
        let normalized = encoded.lowercased()
        guard let separator = normalized.lastIndex(of: "1"),
              separator != normalized.startIndex else {
            return nil
        }
        let dataStart = normalized.index(after: separator)
        let dataCharacters = normalized[dataStart...]
        guard dataCharacters.count >= 7 else { return nil }
        let hrp = String(normalized[..<separator])
        var values: [UInt8] = []
        values.reserveCapacity(dataCharacters.count)
        for character in dataCharacters {
            guard let index = charset.firstIndex(of: character) else {
                return nil
            }
            values.append(UInt8(index))
        }
        guard polymod(expand(hrp) + values) == checksumConstant else {
            return nil
        }
        let data = Array(values.dropLast(6))
        guard let version = data.first,
              let payload = convertBits(
                  Array(data.dropFirst()),
                  from: 5,
                  to: 8,
                  pad: false
              ) else {
            return nil
        }
        return Decoded(
            humanReadablePart: hrp,
            version: version,
            payload: Data(payload)
        )
    }

    private static func createChecksum(
        humanReadablePart: String,
        values: [UInt8]
    ) -> [UInt8] {
        let value = polymod(
            expand(humanReadablePart)
                + values
                + Array(repeating: 0, count: 6)
        ) ^ checksumConstant
        return (0..<6).map {
            UInt8((value >> UInt32(5 * (5 - $0))) & 31)
        }
    }

    private static func expand(_ value: String) -> [UInt8] {
        value.utf8.map { $0 >> 5 }
            + [0]
            + value.utf8.map { $0 & 31 }
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
            var next = (checksum & 0x01ff_ffff) << 5
                ^ UInt32(value)
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
        var bitCount = 0
        var result: [UInt8] = []
        let maximumValue = (1 << destinationBits) - 1
        let maximumAccumulator = (1 << (sourceBits + destinationBits - 1))
            - 1
        for value in values {
            guard Int(value) >> sourceBits == 0 else { return nil }
            accumulator = ((accumulator << sourceBits) | Int(value))
                & maximumAccumulator
            bitCount += sourceBits
            while bitCount >= destinationBits {
                bitCount -= destinationBits
                result.append(
                    UInt8((accumulator >> bitCount) & maximumValue)
                )
            }
        }
        if pad, bitCount > 0 {
            result.append(
                UInt8(
                    (accumulator << (destinationBits - bitCount))
                        & maximumValue
                )
            )
        } else if !pad,
                  bitCount >= sourceBits
                    || ((accumulator << (destinationBits - bitCount))
                        & maximumValue) != 0 {
            return nil
        }
        return result
    }

    private static func isMixedCase(_ value: String) -> Bool {
        value != value.lowercased() && value != value.uppercased()
    }
}
