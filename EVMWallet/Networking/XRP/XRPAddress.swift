import Foundation
import WalletCore

enum XRPAddress {
    private static let rippleAlphabet = Array(
        "rpshnaf39wBUDNEGHJKLM4PQRST7VWXYZ2bcdeCg65jkm8oFqi1tuvAxyz".utf8
    )

    static func validated(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard CoinType.xrp.validate(address: trimmed) else {
            return nil
        }
        return trimmed
    }

    static func validatedClassic(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard let decoded = rippleBase58Decode(trimmed),
              decoded.count == 25,
              decoded.first == 0,
              checksumMatches(decoded),
              rippleBase58Encode(decoded) == trimmed,
              CoinType.xrp.validate(address: trimmed)
        else {
            return nil
        }
        return trimmed
    }

    /// Resolves a mainnet classic or X-address into the classic account and
    /// the single destination tag that must be used for provider preflight and
    /// signing. Conflicting or structurally malformed tag representations are
    /// rejected instead of silently choosing one.
    static func resolvedDestination(
        address: String,
        explicitTag: UInt32?
    ) -> ResolvedDestination? {
        if let classic = validatedClassic(address) {
            return ResolvedDestination(
                classicAddress: classic,
                destinationTag: explicitTag
            )
        }

        let trimmed = address.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard let decoded = rippleBase58Decode(trimmed),
              decoded.count == 35,
              decoded[0] == 0x05,
              decoded[1] == 0x44,
              checksumMatches(decoded),
              rippleBase58Encode(decoded) == trimmed,
              decoded[27..<31].allSatisfy({ $0 == 0 })
        else {
            return nil
        }

        let tag = UInt32(decoded[23])
            | (UInt32(decoded[24]) << 8)
            | (UInt32(decoded[25]) << 16)
            | (UInt32(decoded[26]) << 24)
        let embeddedTag: UInt32?
        switch decoded[22] {
        case 0:
            guard tag == 0, explicitTag == nil else { return nil }
            embeddedTag = nil
        case 1:
            guard explicitTag == nil || explicitTag == tag else {
                return nil
            }
            embeddedTag = tag
        default:
            return nil
        }

        var classicPayload = Data([0])
        classicPayload.append(decoded[2..<22])
        classicPayload.append(
            Hash.sha256SHA256(data: classicPayload).prefix(4)
        )
        guard let classic = rippleBase58Encode(classicPayload),
              validatedClassic(classic) != nil
        else {
            return nil
        }
        return ResolvedDestination(
            classicAddress: classic,
            destinationTag: embeddedTag
        )
    }

    /// Wallet Core's protobuf uses `0` as the absence sentinel for an explicit
    /// destination tag. A tagged mainnet X-address preserves the otherwise
    /// unrepresentable, but protocol-valid, destination tag `0`.
    static func signingDestination(
        classicAddress: String,
        destinationTag: UInt32?
    ) -> String? {
        guard destinationTag == 0 else { return classicAddress }
        guard let decoded = rippleBase58Decode(classicAddress),
              decoded.count == 25,
              decoded[0] == 0,
              checksumMatches(decoded)
        else {
            return nil
        }

        let accountID = decoded[1..<21]
        var payload = Data([0x05, 0x44])
        payload.append(contentsOf: accountID)
        payload.append(0x01)
        payload.append(contentsOf: [0, 0, 0, 0])
        payload.append(contentsOf: [0, 0, 0, 0])
        payload.append(Hash.sha256SHA256(data: payload).prefix(4))
        return rippleBase58Encode(payload)
    }

    private static func checksumMatches(_ decoded: Data) -> Bool {
        let payload = decoded.dropLast(4)
        return decoded.suffix(4)
            == Hash.sha256SHA256(data: Data(payload)).prefix(4)
    }

    private static func rippleBase58Decode(_ value: String) -> Data? {
        guard !value.isEmpty else { return nil }
        let indexes = Dictionary(
            uniqueKeysWithValues: rippleAlphabet.enumerated().map {
                ($0.element, $0.offset)
            }
        )
        var bytes = [UInt8](repeating: 0, count: 1)
        for character in value.utf8 {
            guard var carry = indexes[character] else { return nil }
            for index in bytes.indices.reversed() {
                let total = Int(bytes[index]) * 58 + carry
                bytes[index] = UInt8(total & 0xff)
                carry = total >> 8
            }
            while carry > 0 {
                bytes.insert(UInt8(carry & 0xff), at: 0)
                carry >>= 8
            }
        }
        let leadingZeros = value.utf8.prefix { $0 == rippleAlphabet[0] }.count
        let magnitude = bytes.drop(while: { $0 == 0 })
        return Data(repeating: 0, count: leadingZeros) + Data(magnitude)
    }

    private static func rippleBase58Encode(_ data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        var digits = [UInt8](repeating: 0, count: 1)
        for byte in data {
            var carry = Int(byte)
            for index in digits.indices.reversed() {
                let total = Int(digits[index]) * 256 + carry
                digits[index] = UInt8(total % 58)
                carry = total / 58
            }
            while carry > 0 {
                digits.insert(UInt8(carry % 58), at: 0)
                carry /= 58
            }
        }
        let leadingZeros = data.prefix { $0 == 0 }.count
        let magnitude = digits.drop(while: { $0 == 0 })
        var output = [UInt8](
            repeating: rippleAlphabet[0],
            count: leadingZeros
        )
        output.append(contentsOf: magnitude.map { rippleAlphabet[Int($0)] })
        return String(bytes: output, encoding: .ascii)
    }

    struct ResolvedDestination: Equatable, Sendable {
        let classicAddress: String
        let destinationTag: UInt32?
    }
}

enum XRPDestinationTag {
    static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return trimmed.isEmpty ? nil : trimmed
    }

    static func parsed(_ value: String?) throws -> UInt32? {
        guard let normalized = normalized(value) else {
            return nil
        }
        guard
            normalized.utf8.count <= 10,
            normalized.allSatisfy({ $0 >= "0" && $0 <= "9" }),
            let tag = UInt32(normalized)
        else {
            throw SendPaymentRequestError.invalidReference
        }
        return tag
    }

    static func acceptsEditableInput(_ value: String) -> Bool {
        value.utf8.count <= 10
            && value.allSatisfy { $0 >= "0" && $0 <= "9" }
    }
}
