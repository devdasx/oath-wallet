import Foundation

enum BitcoinFamilyAtomicIntegerError: Error, Equatable, Sendable {
    case empty
    case invalidDecimalInteger
    case inputTooLong
    case invalidDecimals

    var diagnosticDescription: String {
        switch self {
        case .empty:
            "empty"
        case .invalidDecimalInteger:
            "invalid_decimal_integer"
        case .inputTooLong:
            "input_too_long"
        case .invalidDecimals:
            "invalid_decimals"
        }
    }
}

/// An exact signed base-10 integer for Bitcoin-family atomic quantities.
///
/// The canonical string is authoritative. Arithmetic never projects through
/// `Int64`, `UInt64`, binary floating point, or `Foundation.Decimal`.
struct BitcoinFamilyAtomicInteger:
    Codable,
    Comparable,
    Hashable,
    Sendable
{
    private static let maximumProviderCharacterCount = 512
    private static let maximumExactDecimalDigits = 38

    static let zero = BitcoinFamilyAtomicInteger(
        uncheckedCanonical: "0"
    )

    let decimalText: String

    init(validating value: String) throws {
        guard !value.isEmpty else {
            throw BitcoinFamilyAtomicIntegerError.empty
        }
        guard value.count <= Self.maximumProviderCharacterCount else {
            throw BitcoinFamilyAtomicIntegerError.inputTooLong
        }

        var digits = value[...]
        let isNegative = digits.first == "-"
        if isNegative {
            digits = digits.dropFirst()
        }
        guard
            !digits.isEmpty,
            digits.utf8.allSatisfy(Self.isASCIIDigit)
        else {
            throw BitcoinFamilyAtomicIntegerError.invalidDecimalInteger
        }

        let significant = digits.drop(while: { $0 == "0" })
        guard !significant.isEmpty else {
            decimalText = "0"
            return
        }
        decimalText = isNegative
            ? "-\(significant)"
            : String(significant)
    }

    init(_ value: Int64) {
        decimalText = String(value)
    }

    init(_ value: UInt64) {
        decimalText = String(value)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        do {
            if let string = try? container.decode(String.self) {
                try self.init(validating: string)
                return
            }
            if let integer = try? container.decode(Int64.self) {
                self.init(integer)
                return
            }
            if let integer = try? container.decode(UInt64.self) {
                self.init(integer)
                return
            }
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription:
                    "Bitcoin-family atomic quantity is not a valid integer."
            )
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription:
                "Bitcoin-family atomic quantity is not losslessly decodable."
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(decimalText)
    }

    var isZero: Bool {
        decimalText == "0"
    }

    var isNegative: Bool {
        decimalText.first == "-"
    }

    var isPositive: Bool {
        !isZero && !isNegative
    }

    var decimalDigitCount: Int {
        magnitudeText.count
    }

    var magnitude: BitcoinFamilyAtomicInteger {
        BitcoinFamilyAtomicInteger(
            uncheckedCanonical: magnitudeText
        )
    }

    var negated: BitcoinFamilyAtomicInteger {
        guard !isZero else { return .zero }
        return BitcoinFamilyAtomicInteger(
            uncheckedCanonical: isNegative
                ? magnitudeText
                : "-\(decimalText)"
        )
    }

    func adding(
        _ other: BitcoinFamilyAtomicInteger
    ) -> BitcoinFamilyAtomicInteger {
        if isNegative == other.isNegative {
            let magnitude = Self.addMagnitudes(
                magnitudeText,
                other.magnitudeText
            )
            return BitcoinFamilyAtomicInteger(
                uncheckedCanonical: isNegative
                    ? "-\(magnitude)"
                    : magnitude
            )
        }

        switch Self.compareMagnitudes(
            magnitudeText,
            other.magnitudeText
        ) {
        case .orderedSame:
            return .zero
        case .orderedDescending:
            let magnitude = Self.subtractMagnitudes(
                magnitudeText,
                other.magnitudeText
            )
            return BitcoinFamilyAtomicInteger(
                uncheckedCanonical: isNegative
                    ? "-\(magnitude)"
                    : magnitude
            )
        case .orderedAscending:
            let magnitude = Self.subtractMagnitudes(
                other.magnitudeText,
                magnitudeText
            )
            return BitcoinFamilyAtomicInteger(
                uncheckedCanonical: other.isNegative
                    ? "-\(magnitude)"
                    : magnitude
            )
        }
    }

    func subtracting(
        _ other: BitcoinFamilyAtomicInteger
    ) -> BitcoinFamilyAtomicInteger {
        adding(other.negated)
    }

    func userUnits(decimals: Int) throws -> String {
        guard (0...255).contains(decimals) else {
            throw BitcoinFamilyAtomicIntegerError.invalidDecimals
        }
        guard !isZero, decimals > 0 else {
            return decimalText
        }

        let atomic = magnitudeText
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
        let magnitude = fraction.isEmpty
            ? integer
            : "\(integer).\(fraction)"
        return isNegative ? "-\(magnitude)" : magnitude
    }

    /// A bounded compatibility projection for price calculations and legacy
    /// numeric UI fields. Exact text must remain the persisted authority.
    func decimalProjection(decimals: Int) -> Decimal? {
        guard decimalDigitCount <= Self.maximumExactDecimalDigits,
              let units = try? userUnits(decimals: decimals) else {
            return nil
        }
        return Decimal(
            string: units,
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    static func < (
        lhs: BitcoinFamilyAtomicInteger,
        rhs: BitcoinFamilyAtomicInteger
    ) -> Bool {
        if lhs.isNegative != rhs.isNegative {
            return lhs.isNegative
        }
        let comparison = compareMagnitudes(
            lhs.magnitudeText,
            rhs.magnitudeText
        )
        return lhs.isNegative
            ? comparison == .orderedDescending
            : comparison == .orderedAscending
    }

    private init(uncheckedCanonical value: String) {
        decimalText = value
    }

    private var magnitudeText: String {
        isNegative ? String(decimalText.dropFirst()) : decimalText
    }

    private static func addMagnitudes(
        _ lhs: String,
        _ rhs: String
    ) -> String {
        let left = Array(lhs.utf8.reversed())
        let right = Array(rhs.utf8.reversed())
        var result: [UInt8] = []
        result.reserveCapacity(max(left.count, right.count) + 1)
        var carry = 0
        for index in 0..<max(left.count, right.count) {
            let leftDigit = index < left.count
                ? Int(left[index] - 48)
                : 0
            let rightDigit = index < right.count
                ? Int(right[index] - 48)
                : 0
            let sum = leftDigit + rightDigit + carry
            result.append(UInt8(sum % 10) + 48)
            carry = sum / 10
        }
        if carry > 0 {
            result.append(UInt8(carry) + 48)
        }
        return String(decoding: result.reversed(), as: UTF8.self)
    }

    /// Subtracts `rhs` from `lhs`. The caller guarantees `lhs >= rhs`.
    private static func subtractMagnitudes(
        _ lhs: String,
        _ rhs: String
    ) -> String {
        let left = Array(lhs.utf8.reversed())
        let right = Array(rhs.utf8.reversed())
        var result: [UInt8] = []
        result.reserveCapacity(left.count)
        var borrow = 0
        for index in left.indices {
            var digit = Int(left[index] - 48) - borrow
            let subtrahend = index < right.count
                ? Int(right[index] - 48)
                : 0
            if digit < subtrahend {
                digit += 10
                borrow = 1
            } else {
                borrow = 0
            }
            result.append(UInt8(digit - subtrahend) + 48)
        }
        while result.count > 1, result.last == 48 {
            result.removeLast()
        }
        return String(decoding: result.reversed(), as: UTF8.self)
    }

    private static func compareMagnitudes(
        _ lhs: String,
        _ rhs: String
    ) -> ComparisonResult {
        if lhs.count != rhs.count {
            return lhs.count < rhs.count
                ? .orderedAscending
                : .orderedDescending
        }
        if lhs == rhs { return .orderedSame }
        return lhs.lexicographicallyPrecedes(rhs)
            ? .orderedAscending
            : .orderedDescending
    }

    private static func isASCIIDigit(_ byte: UInt8) -> Bool {
        byte >= 48 && byte <= 57
    }
}

/// Quotes JSON number tokens before `JSONDecoder` sees them, preserving the
/// provider's original base-10 lexeme instead of routing it through Decimal.
enum BitcoinFamilyLosslessJSON {
    static func preservingNumberLexemes(in data: Data) -> Data {
        let bytes = Array(data)
        var result = Data()
        result.reserveCapacity(bytes.count + 64)
        var index = 0
        var isInsideString = false
        var isEscaped = false

        while index < bytes.count {
            let byte = bytes[index]
            if isInsideString {
                result.append(byte)
                if isEscaped {
                    isEscaped = false
                } else if byte == 0x5c {
                    isEscaped = true
                } else if byte == 0x22 {
                    isInsideString = false
                }
                index += 1
                continue
            }

            if byte == 0x22 {
                isInsideString = true
                result.append(byte)
                index += 1
                continue
            }

            if (byte == 0x2d || isASCIIDigit(byte)),
               let end = numberTokenEnd(in: bytes, from: index) {
                result.append(0x22)
                result.append(contentsOf: bytes[index..<end])
                result.append(0x22)
                index = end
                continue
            }

            result.append(byte)
            index += 1
        }
        return result
    }

    private static func numberTokenEnd(
        in bytes: [UInt8],
        from start: Int
    ) -> Int? {
        var index = start
        if bytes[index] == 0x2d {
            index += 1
            guard index < bytes.count else { return nil }
        }

        if bytes[index] == 0x30 {
            index += 1
        } else {
            guard bytes[index] >= 0x31, bytes[index] <= 0x39 else {
                return nil
            }
            index += 1
            while index < bytes.count, isASCIIDigit(bytes[index]) {
                index += 1
            }
        }

        if index < bytes.count, bytes[index] == 0x2e {
            index += 1
            let fractionStart = index
            while index < bytes.count, isASCIIDigit(bytes[index]) {
                index += 1
            }
            guard index > fractionStart else { return nil }
        }

        if index < bytes.count,
           (bytes[index] == 0x65 || bytes[index] == 0x45) {
            index += 1
            if index < bytes.count,
               (bytes[index] == 0x2b || bytes[index] == 0x2d) {
                index += 1
            }
            let exponentStart = index
            while index < bytes.count, isASCIIDigit(bytes[index]) {
                index += 1
            }
            guard index > exponentStart else { return nil }
        }
        return index
    }

    private static func isASCIIDigit(_ byte: UInt8) -> Bool {
        byte >= 0x30 && byte <= 0x39
    }
}
