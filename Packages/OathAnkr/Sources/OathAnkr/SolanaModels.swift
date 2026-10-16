import Foundation

/// Lossless JSON numbers. RPC lamports and SPL amounts must never pass through Double.
public enum SolanaJSON: Codable, Sendable, Equatable {
    case object([String: SolanaJSON]), array([SolanaJSON]), string(String), number(String), bool(Bool), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(UInt64.self) { self = .number(String(v)) }
        else if let v = try? c.decode(Int64.self) { self = .number(String(v)) }
        else if let v = try? c.decode(Decimal.self) { self = .number(NSDecimalNumber(decimal: v).stringValue) }
        else if let v = try? c.decode([String: Self].self) { self = .object(v) }
        else { self = .array(try c.decode([Self].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v):
            guard let d = Decimal(string: v, locale: Locale(identifier: "en_US_POSIX")), !d.isNaN else { throw SolanaError.malformed }
            try c.encode(d)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public subscript(_ key: String) -> Self { if case .object(let v) = self { return v[key] ?? .null }; return .null }
    public var string: String? { if case .string(let v) = self { return v }; return nil }
    public var integer: UInt64? { if case .number(let v) = self { return UInt64(v) }; return nil }
    public var array: [Self]? { if case .array(let v) = self { return v }; return nil }
    public var isNull: Bool { self == .null }
}

public enum SolanaError: Error, Sendable, Equatable {
    case configuration, invalidAddress, malformed, transport, http(Int), rpc(Int), missingTransaction, wrongOwner, wrongNetwork, staleSlot, incompleteHistory, cancelled
}

/// RPC read capability only; this does not advertise or enable v1 signing.
/// jsonParsed history uses finalized balance deltas and meta.fee; receipts
/// require the returned base64 bytes to match the locally signed transaction.
enum SolanaTransactionRead {
    static let maximumVersion: SolanaJSON = .number("1")
}

public enum SolanaIdentity {
    public static let tokenProgram = "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA"
    public static let token2022Program = "TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb"
    public static let wrappedSOL = "So11111111111111111111111111111111111111112"
    public static let genesis = "5eykt4UsFv8P8NJdTREpY1vzqKqZKvdpKuc147dw2N9d"
    public static func isAddress(_ text: String) -> Bool { decodedLength(text) == 32 }
    public static func isSignature(_ text: String) -> Bool { decodedLength(text) == 64 }
    private static func decodedLength(_ text: String) -> Int? {
        guard (32...88).contains(text.utf8.count) else { return nil }
        let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz".utf8)
        var bytes: [UInt8] = []
        for c in text.utf8 {
            guard let n = alphabet.firstIndex(of: c) else { return nil }
            var carry = n
            for i in bytes.indices { carry += Int(bytes[i]) * 58; bytes[i] = UInt8(carry & 255); carry >>= 8 }
            while carry > 0 { bytes.append(UInt8(carry & 255)); carry >>= 8 }
        }
        return bytes.count + text.utf8.prefix(while: { $0 == 49 }).count
    }
}

public struct SolanaTokenAccount: Codable, Sendable, Equatable {
    public let address: String
    public let mint: String
    public let program: String
    public let amount: String
    public let decimals: Int
    public let frozen: Bool
}
public struct SolanaInventory: Codable, Sendable, Equatable {
    public let owner: String
    public let lamports: String
    public let nativeSlot: UInt64
    public let tokenSlot: UInt64
    public let token2022Slot: UInt64
    public let accounts: [SolanaTokenAccount]
    public let fetchedAt: Date
    public let raw: Data
    public var minimumSlot: UInt64 { min(nativeSlot, tokenSlot, token2022Slot) }
}
public struct SolanaSignature: Codable, Sendable, Equatable {
    public let signature: String
    public let slot: UInt64
    public let blockTime: Double?
    public let failed: Bool
}
public struct SolanaSignaturePage: Sendable {
    public let signatures: [SolanaSignature]
    /// Only an archive-backed endpoint can establish the end of history.
    public let archival: Bool
}
public struct SolanaAssetChange: Codable, Sendable, Equatable {
    public let mint: String // "native" for SOL
    public let decimals: Int
    public let amount: String
    public let direction: String
    public let counterparty: String?
    public init(mint: String, decimals: Int, amount: String, direction: String, counterparty: String? = nil) {
        self.mint = mint; self.decimals = decimals; self.amount = amount
        self.direction = direction; self.counterparty = counterparty
    }
}
public struct SolanaTransaction: Codable, Sendable, Equatable {
    public let signature: String
    public let slot: UInt64
    public let timestamp: Double?
    public let failed: Bool
    public let fee: String
    public let changes: [SolanaAssetChange]
    public let tokenAccounts: [String]
    public let raw: Data
}
