import Foundation

/// TON VarUInteger 16 stores up to 15 bytes. Jettons can exceed UInt64 even
/// with ordinary balances, so token arithmetic must retain all 120 bits.
public struct TonAmount: Sendable, Equatable, Comparable, Codable, LosslessStringConvertible, ExpressibleByIntegerLiteral {
    private let bytes: [UInt8] // fixed-width, big endian
    public init(_ value: UInt64) {
        bytes = Array(repeating: 0, count: 7) + (0..<8).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
    }
    public init(integerLiteral value: UInt64) { self.init(value) }
    public init?(_ text: String) { self.init(text, radix: 10) }
    init?(_ text: String, radix: Int) {
        guard [10,16].contains(radix), !text.isEmpty, text.count <= 40 else { return nil }
        var result = [UInt8](repeating: 0, count: 15)
        for byte in text.utf8 {
            let digit: Int
            switch byte {
            case 48...57: digit = Int(byte - 48)
            case 65...70: digit = Int(byte - 65 + 10)
            case 97...102: digit = Int(byte - 97 + 10)
            default: return nil
            }
            guard digit < radix else { return nil }
            var carry = digit
            for i in result.indices.reversed() {
                let n = Int(result[i]) * radix + carry
                result[i] = UInt8(n & 255); carry = n >> 8
            }
            guard carry == 0 else { return nil }
        }
        bytes = result
    }
    init(bytes: [UInt8]) { precondition(bytes.count <= 15); self.bytes = Array(repeating: 0, count: 15 - bytes.count) + bytes }
    var significantBytes: [UInt8] { Array(bytes.drop(while: { $0 == 0 })) }
    var uint64: UInt64? { bytes.prefix(7).allSatisfy { $0 == 0 } ? bytes.suffix(8).reduce(0) { ($0 << 8) | UInt64($1) } : nil }
    public var description: String {
        var decimal = "0"
        for byte in significantBytes {
            for _ in 0..<8 { decimal = StellarIdentity.sum(decimal, decimal) }
            decimal = StellarIdentity.sum(decimal, String(byte))
        }
        return decimal
    }
    public static func < (a: Self, b: Self) -> Bool { a.bytes.lexicographicallyPrecedes(b.bytes) }
    public static func - (a: Self, b: Self) -> Self {
        precondition(a >= b)
        var result = a.bytes, borrow = 0
        for i in result.indices.reversed() {
            let n = Int(a.bytes[i]) - Int(b.bytes[i]) - borrow
            result[i] = UInt8(truncatingIfNeeded: n); borrow = n < 0 ? 1 : 0
        }
        return Self(bytes: result)
    }
    public static func - (a: Self, b: UInt64) -> Self { a - Self(b) }
    public static func + (a: Self, b: UInt64) -> Self {
        let other = Self(b); var result = a.bytes, carry = 0
        for i in result.indices.reversed() {
            let n = Int(result[i]) + Int(other.bytes[i]) + carry
            result[i] = UInt8(truncatingIfNeeded: n); carry = n >> 8
        }
        precondition(carry == 0); return Self(bytes: result)
    }
    public func encode(to encoder: any Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(description) }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        // Numeric values are legacy test/journal fixtures, never floating point.
        if let text = try? c.decode(String.self), let amount = Self(text) { self = amount }
        else if let n = try? c.decode(UInt64.self) { self.init(n) }
        else { throw TonSendError.amount }
    }
}
