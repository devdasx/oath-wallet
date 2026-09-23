import Foundation
import WalletCore

enum TronUInt256Error: Error, Equatable, Sendable {
    case empty
    case invalidHex
    case invalidDecimal
    case outOfRange
    case invalidDecimals

    var diagnosticDescription: String {
        switch self {
        case .empty:
            "empty"
        case .invalidHex:
            "invalid_hex"
        case .invalidDecimal:
            "invalid_decimal"
        case .outOfRange:
            "uint256_out_of_range"
        case .invalidDecimals:
            "invalid_token_decimals"
        }
    }
}

/// An exact, nonnegative integer constrained to the complete Solidity
/// `uint256` domain. `decimalText` is the authoritative representation.
struct TronUInt256: Equatable, Sendable {
    static let maximumDecimalText =
        "115792089237316195423570985008687907853269984665640564039457584007913129639935"

    let decimalText: String

    init(decimalText: String) throws {
        self.decimalText = try TronValueParser.canonicalUInt256Decimal(
            decimalText
        )
    }

    init(hexQuantity: String) throws {
        decimalText = try TronValueParser.uint256Decimal(
            fromHexQuantity: hexQuantity
        )
    }

    var isZero: Bool {
        decimalText == "0"
    }

    var decimalDigitCount: Int {
        decimalText.count
    }

    func userUnits(decimals: Int) throws -> String {
        try TronValueParser.userUnits(
            atomicDecimalText: decimalText,
            decimals: decimals
        )
    }
}

enum TronValueParser {
    static func accountAddressData(_ value: String) -> Data? {
        let normalized = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard
            CoinType.tron.validate(address: normalized),
            let data = Base58.decode(string: normalized),
            data.count == 21,
            data.first == 0x41
        else {
            return nil
        }
        return data
    }

    static func isValidMainnetAddress(_ value: String) -> Bool {
        accountAddressData(value) != nil
    }

    static func accountHexAddress(_ base58: String) -> String? {
        guard let payload = accountAddressData(base58) else {
            return nil
        }
        return payload.hexString
    }

    static func hexAddress(_ base58: String) -> String? {
        guard let payload = accountAddressData(base58) else {
            return nil
        }
        return "0x\(payload.dropFirst().hexString)"
    }

    static func hexQuantity(_ value: String) throws -> UInt64 {
        let exact = try TronUInt256(hexQuantity: value)
        guard let result = UInt64(exact.decimalText) else {
            throw TronUInt256Error.outOfRange
        }
        return result
    }

    static func canonicalUInt256Decimal(
        _ value: String
    ) throws -> String {
        guard !value.isEmpty else {
            throw TronUInt256Error.empty
        }
        guard value.utf8.allSatisfy({ byte in
            byte >= 48 && byte <= 57
        }) else {
            throw TronUInt256Error.invalidDecimal
        }

        let canonical = String(value.drop(while: { $0 == "0" }))
        let result = canonical.isEmpty ? "0" : canonical
        let maximum = TronUInt256.maximumDecimalText
        guard
            result.count < maximum.count
                || (
                    result.count == maximum.count
                        && result.lexicographicallyPrecedes(maximum)
                )
                || result == maximum
        else {
            throw TronUInt256Error.outOfRange
        }
        return result
    }

    static func uint256Decimal(
        fromHexQuantity value: String
    ) throws -> String {
        let raw = value.tronDrop0x
        guard !raw.isEmpty else {
            throw TronUInt256Error.empty
        }
        guard raw.utf8.allSatisfy(Self.isASCIIHexDigit) else {
            throw TronUInt256Error.invalidHex
        }

        let significant = raw.drop(while: { $0 == "0" })
        guard !significant.isEmpty else {
            return "0"
        }
        guard significant.count <= 64 else {
            throw TronUInt256Error.outOfRange
        }

        var decimal = "0"
        for character in significant {
            guard let digit = character.hexDigitValue else {
                throw TronUInt256Error.invalidHex
            }
            decimal = decimalString(
                decimal,
                multipliedBy: 16,
                adding: digit
            )
        }
        return try canonicalUInt256Decimal(decimal)
    }

    static func userUnits(
        atomicDecimalText: String,
        decimals: Int
    ) throws -> String {
        guard (0...255).contains(decimals) else {
            throw TronUInt256Error.invalidDecimals
        }
        let atomic = try canonicalUInt256Decimal(atomicDecimalText)
        guard atomic != "0", decimals > 0 else {
            return atomic
        }

        let integer: String
        var fraction: String
        if atomic.count > decimals {
            let splitIndex = atomic.index(
                atomic.endIndex,
                offsetBy: -decimals
            )
            integer = String(atomic[..<splitIndex])
            fraction = String(atomic[splitIndex...])
        } else {
            integer = "0"
            fraction = String(
                repeating: "0",
                count: decimals - atomic.count
            ) + atomic
        }
        while fraction.last == "0" {
            fraction.removeLast()
        }
        return fraction.isEmpty ? integer : "\(integer).\(fraction)"
    }

    /// A bounded compatibility projection for existing price calculations and
    /// UI models. Callers must persist the original exact text instead.
    static func decimalProjection(
        exactDecimalText: String
    ) -> Decimal? {
        Decimal(
            string: exactDecimalText,
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    static func hexDecoded(_ value: String) -> String {
        var data = Data()
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2, limitedBy: value.endIndex)
                ?? value.endIndex
            guard let byte = UInt8(value[index..<next], radix: 16) else {
                return value
            }
            data.append(byte)
            index = next
        }
        return String(data: data, encoding: .utf8) ?? value
    }

    static func abiText(
        _ value: String,
        maximumLength: Int
    ) -> String? {
        guard
            maximumLength > 0,
            let data = abiData(value),
            !data.isEmpty
        else {
            return nil
        }
        let payload: Data
        if data.count == 32 {
            payload = Data(data.prefix { $0 != 0 })
        } else {
            guard
                data.count >= 64,
                let offset = abiWordInt(data.prefix(32)),
                offset.isMultiple(of: 32),
                offset <= data.count - 32,
                let length = abiWordInt(
                    data[offset..<(offset + 32)]
                ),
                length <= maximumLength * 4,
                offset + 32 <= data.count - length
            else {
                return nil
            }
            payload = Data(
                data[(offset + 32)..<(offset + 32 + length)]
            )
        }
        guard
            let decoded = String(data: payload, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !decoded.isEmpty,
            decoded.count <= maximumLength,
            decoded.unicodeScalars.allSatisfy({
                !CharacterSet.controlCharacters.contains($0)
            })
        else {
            return nil
        }
        return decoded
    }

    static func abiUInt8(_ value: String) -> Int? {
        guard
            let data = abiData(value),
            data.count == 32,
            data.dropLast().allSatisfy({ $0 == 0 }),
            let result = data.last
        else {
            return nil
        }
        return Int(result)
    }

    private static func abiData(_ value: String) -> Data? {
        let raw = value.tronDrop0x
        guard
            !raw.isEmpty,
            raw.count.isMultiple(of: 2),
            raw.count <= 8_192,
            raw.utf8.allSatisfy(Self.isASCIIHexDigit)
        else {
            return nil
        }
        var data = Data()
        data.reserveCapacity(raw.count / 2)
        var index = raw.startIndex
        while index < raw.endIndex {
            let next = raw.index(index, offsetBy: 2)
            guard let byte = UInt8(raw[index..<next], radix: 16) else {
                return nil
            }
            data.append(byte)
            index = next
        }
        return data
    }

    private static func abiWordInt<C>(_ bytes: C) -> Int?
    where C: Collection, C.Element == UInt8 {
        guard bytes.count == 32 else { return nil }
        let significant = bytes.suffix(8)
        guard bytes.dropLast(8).allSatisfy({ $0 == 0 }) else {
            return nil
        }
        var value: UInt64 = 0
        for byte in significant {
            value = (value << 8) | UInt64(byte)
        }
        return Int(exactly: value)
    }

    private static func isASCIIHexDigit(_ byte: UInt8) -> Bool {
        (byte >= 48 && byte <= 57)
            || (byte >= 65 && byte <= 70)
            || (byte >= 97 && byte <= 102)
    }

    private static func decimalString(
        _ value: String,
        multipliedBy multiplier: Int,
        adding addend: Int
    ) -> String {
        var result: [UInt8] = []
        result.reserveCapacity(value.count + 2)
        var carry = addend
        for byte in value.utf8.reversed() {
            let product = Int(byte - 48) * multiplier + carry
            result.append(UInt8(product % 10) + 48)
            carry = product / 10
        }
        while carry > 0 {
            result.append(UInt8(carry % 10) + 48)
            carry /= 10
        }
        return String(decoding: result.reversed(), as: UTF8.self)
    }
}

private extension String {
    var tronDrop0x: Substring {
        hasPrefix("0x") || hasPrefix("0X") ? dropFirst(2) : self[...]
    }
}
