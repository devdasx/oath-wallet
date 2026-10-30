import Foundation
import CryptoKit

/// Shared lossless JSON representation; atomic TRON quantities never use Double.
public typealias TronJSON = SolanaJSON
public enum TronError: Error, Sendable, Equatable {
    case nonFungible, configuration, invalidAddress, malformed, wrongNetwork, wrongOwner, transport, http(Int), rpc(Int), incomplete, paginationLoop
}
extension TronJSON {
    var text: String? { switch self { case .string(let v), .number(let v): v; default: nil } }
    var fields: [String: Self]? { if case .object(let v) = self { v } else { nil } }
}
public enum TronIdentity {
    public static let usdt = "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t"
    private static let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz".utf8)
    public static func bytes(_ address: String) throws -> Data {
        guard address.utf8.count == 34 else { throw TronError.invalidAddress }
        var bytes: [UInt8] = []
        for c in address.utf8 {
            guard let n = alphabet.firstIndex(of: c) else { throw TronError.invalidAddress }
            var carry = n
            for i in bytes.indices { carry += Int(bytes[i]) * 58; bytes[i] = UInt8(carry & 255); carry >>= 8 }
            while carry > 0 { bytes.append(UInt8(carry & 255)); carry >>= 8 }
        }
        let data = Data(bytes.reversed())
        guard data.count == 25, data.first == 0x41 else { throw TronError.invalidAddress }
        let payload = data.prefix(21)
        guard Data(SHA256.hash(data: Data(SHA256.hash(data: payload)))).prefix(4) == data.suffix(4) else { throw TronError.invalidAddress }
        return payload
    }
    public static func address(_ text: String) throws -> String {
        if text.hasPrefix("T") { _ = try bytes(text); return text }
        var data = try hex(text)
        if data.count == 32 { guard data.prefix(12).allSatisfy({ $0 == 0 }) else { throw TronError.invalidAddress }; data = Data(data.suffix(20)) }
        if data.count == 20 { data.insert(0x41, at: 0) }
        guard data.count == 21, data.first == 0x41 else { throw TronError.invalidAddress }
        data += Data(SHA256.hash(data: Data(SHA256.hash(data: data)))).prefix(4)
        var digits: [UInt8] = []
        for byte in data {
            var carry = Int(byte)
            for i in digits.indices { carry += Int(digits[i]) * 256; digits[i] = UInt8(carry % 58); carry /= 58 }
            while carry > 0 { digits.append(UInt8(carry % 58)); carry /= 58 }
        }
        return String(bytes: digits.reversed().map { alphabet[Int($0)] }, encoding: .utf8)!
    }
    public static func isAddress(_ s: String) -> Bool { (try? bytes(s)) != nil }
    public static func isToken(_ s: String) -> Bool { isAddress(s) || isTRC10(s) }
    public static func isTRC10(_ s: String) -> Bool { (7...12).contains(s.count) && s.first != "0" && s.utf8.allSatisfy { (48...57).contains($0) } }
    public static func hash(_ s: String) -> Bool { s.count == 64 && (try? hex(s))?.count == 32 }
    public static func hex(_ s: String) throws -> Data {
        let s = s.hasPrefix("0x") ? String(s.dropFirst(2)) : s
        guard s.count % 2 == 0, s.count <= 131_072 else { throw TronError.malformed }
        let chars = Array(s); var data = Data()
        for i in stride(from: 0, to: chars.count, by: 2) {
            guard let b = UInt8(String(chars[i...i+1]), radix: 16) else { throw TronError.malformed }; data.append(b)
        }
        return data
    }
    public static func callAddress(_ address: String) throws -> String { "0x" + (try bytes(address)).dropFirst().map { String(format: "%02x", $0) }.joined() }
    public static func quantity(_ value: TronJSON) throws -> String {
        guard let text = value.text, !text.isEmpty, text.count <= 78, text.utf8.allSatisfy({ (48...57).contains($0) }) else { throw TronError.malformed }
        return String(text.drop(while: { $0 == "0" })).isEmpty ? "0" : String(text.drop(while: { $0 == "0" }))
    }
    public static func uint256(_ raw: String) throws -> String {
        let bytes = try hex(raw)
        guard bytes.count == 32 else { throw TronError.malformed }
        var digits = [0]
        for byte in bytes {
            var carry = Int(byte)
            for i in digits.indices { carry += digits[i] * 256; digits[i] = carry % 10; carry /= 10 }
            while carry > 0 { digits.append(carry % 10); carry /= 10 }
        }
        return digits.reversed().map(String.init).joined()
    }
    static func clean(_ s: String, limit: Int = 256) throws -> String {
        let s = s.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "\0")))
        guard !s.isEmpty, s.count <= limit, !s.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || (0x202A...0x202E).contains($0.value) || (0x2066...0x2069).contains($0.value) }) else { throw TronError.malformed }
        return s
    }
    static func abiString(_ raw: String) throws -> String {
        let data = try hex(raw); let text: Data
        if data.count == 32 { text = data.prefix { $0 != 0 } }
        else {
            guard data.count >= 64, data.prefix(31).allSatisfy({ $0 == 0 }), data[31] == 32,
                  data[32..<60].allSatisfy({ $0 == 0 }) else { throw TronError.malformed }
            let n = data[60..<64].reduce(0) { $0 * 256 + Int($1) }
            guard (1...512).contains(n), n <= data.count - 64 else { throw TronError.malformed }; text = data.subdata(in: 64..<64+n)
        }
        guard let s = String(data: text, encoding: .utf8) else { throw TronError.malformed }; return try clean(s)
    }
}
public struct TronToken: Codable, Sendable, Equatable {
    public let reference: String
    public let name: String
    public let symbol: String
    public let decimals: Int
    public let logo: String?
    public init(reference: String, name: String, symbol: String, decimals: Int, logo: String? = nil) {
        self.reference = reference; self.name = name; self.symbol = symbol; self.decimals = decimals; self.logo = logo
    }
}
public struct TronHolding: Codable, Sendable, Equatable { public let token: TronToken; public let amount: String }
public struct TronInventory: Codable, Sendable {
    public let owner: String
    public let holdings: [TronHolding]
    public let failedReferences: [String]
    public let excludedNFTs: [String]
    public let discoveryComplete: Bool
    public let observedAt: Date
    public let raw: Data
}
public struct TronEvent: Codable, Sendable, Equatable {
    public let index: Int
    public let reference: String
    public let from: String
    public let to: String
    public let amount: String
}
public struct TronTransaction: Codable, Sendable {
    public let hash: String
    public let block: Int64
    public let timestamp: Double
    public let failed: Bool
    public let confirmed: Bool
    public let fee: String
    public let payer: String
    public let events: [TronEvent]
    public let raw: Data
}
public enum TronStream: String, Codable, Sendable, CaseIterable { case transactions, trc20, internalTransactions }
public struct TronHistoryPage: Sendable {
    public let hashes: [String]
    public let cursor: String?
    public let raw: Data
}
