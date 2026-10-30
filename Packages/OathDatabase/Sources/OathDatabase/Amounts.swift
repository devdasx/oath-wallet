import Foundation

public enum StoreError: Error, Equatable, Sendable {
    case invalidValue(String), missingRecord, conflictingIdentity, staleSync, reservationConflict
    case invalidTransition, readOnlyWallet, invalidDatabaseLocation
}

/// Exact atomic quantities, including fixed-scale XRPL issued amounts (192 digits plus carry). Never use SQLite REAL or Double for on-chain value.
public struct AtomicAmount: Hashable, Sendable, Codable, Comparable {
    public let rawValue: String
    public init(_ rawValue: String) throws {
        guard !rawValue.isEmpty, rawValue.count <= 193,
              rawValue.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              rawValue.count == 1 || rawValue.first != "0" else {
            throw StoreError.invalidValue("atomic amount")
        }
        self.rawValue = rawValue
    }
    public static func < (a: Self, b: Self) -> Bool {
        a.rawValue.count == b.rawValue.count ? a.rawValue < b.rawValue : a.rawValue.count < b.rawValue.count
    }
    public func units(decimals: Int) throws -> String {
        guard (0...255).contains(decimals) else { throw StoreError.invalidValue("asset decimals") }
        guard decimals > 0 else { return rawValue }
        let digits = String(repeating: "0", count: max(0, decimals + 1 - rawValue.count)) + rawValue
        let split = digits.index(digits.endIndex, offsetBy: -decimals)
        return String(digits[..<split]) + "." + String(digits[split...])
    }
    public init(from decoder: any Decoder) throws {
        try self.init(decoder.singleValueContainer().decode(String.self))
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer(); try container.encode(rawValue)
    }
}

enum Validation {
    static func amount(_ value: String) throws { _ = try AtomicAmount(value) }
    static func price(_ value: String) throws {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2, parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { $0 >= 48 && $0 <= 57 } }),
              value.count <= 80, let decimal = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")),
              !decimal.isNaN, decimal >= 0 else { throw StoreError.invalidValue("price") }
    }
    static func currency(_ code: String) throws {
        guard code.utf8.count == 3, code.utf8.allSatisfy({ $0 >= 65 && $0 <= 90 }) else {
            throw StoreError.invalidValue("currency")
        }
    }
}
