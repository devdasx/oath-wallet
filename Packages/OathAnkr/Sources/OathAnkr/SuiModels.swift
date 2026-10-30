import OathArtworkSource
import Foundation

public typealias SuiJSON = SolanaJSON
public enum SuiError: Error, Sendable, Equatable {
    case configuration, invalidAddress, malformed, wrongNetwork, wrongOwner, paginationLoop, cursorExpired, resourceExhausted, graphql, http(Int), transport
    case checkpointUnavailable
}
public enum SuiIdentity {
    public static let coin = "0x2::sui::SUI"
    public static let mainnet = "4btiuiMPvEENsttpZC7CZ53DruC3MAgfznDbASZ7DR6S"
    public static func address(_ text: String) throws -> String {
        guard let result = try? AptosIdentity.address(text) else { throw SuiError.invalidAddress }
        return result
    }
    /// Move identifiers are case sensitive; only hexadecimal addresses normalize.
    public static func reference(_ text: String) throws -> String {
        if text == "native" { return text }
        guard text.count <= 4096 else { throw SuiError.malformed }
        var parser = MoveTypeParser(bytes: Array(text.filter { !$0.isWhitespace }.utf8))
        let result = try parser.type(depth: 0)
        guard parser.index == parser.bytes.count, result.hasPrefix("0x") else { throw SuiError.malformed }
        return result == coin ? "native" : result
    }
    public static func coinType(_ reference: String) throws -> String {
        let ref = try self.reference(reference); return ref == "native" ? coin : ref
    }
    public static func amount(_ value: SuiJSON) throws -> String {
        guard let amount = try? AptosIdentity.amount(value) else { throw SuiError.malformed }; return amount
    }
    static func number(_ value: SuiJSON) throws -> Int64 {
        guard let n = Int64(try amount(value)) else { throw SuiError.malformed }; return n
    }
    static func bool(_ value: SuiJSON) throws -> Bool {
        guard case .bool(let b) = value else { throw SuiError.malformed }; return b
    }
    static func signed(_ value: SuiJSON) throws -> String {
        guard let text = value.text else { throw SuiError.malformed }
        let magnitude = try amount(.string(text.hasPrefix("-") ? String(text.dropFirst()) : text))
        return text.hasPrefix("-") && magnitude != "0" ? "-" + magnitude : magnitude
    }
    /// Exact signed integer arithmetic, including a negative net storage fee.
    static func add(_ a: String, _ b: String) -> String {
        let an = a.hasPrefix("-"), bn = b.hasPrefix("-")
        let x = an ? String(a.dropFirst()) : a, y = bn ? String(b.dropFirst()) : b
        if an == bn { let n = AptosIdentity.add(x,y); return an && n != "0" ? "-"+n : n }
        let larger = x.count != y.count ? x.count > y.count : x >= y
        let hi = Array((larger ? x:y).utf8.reversed()), lo = Array((larger ? y:x).utf8.reversed())
        var out: [UInt8] = [], borrow = 0
        for i in hi.indices { var n = Int(hi[i]-48) - (i < lo.count ? Int(lo[i]-48):0) - borrow; borrow = n < 0 ? 1:0; if n < 0 { n += 10 }; out.append(UInt8(n)+48) }
        let raw = String(bytes: out.reversed(),encoding:.utf8)!.drop(while:{$0 == "0"})
        let n = raw.isEmpty ? "0" : String(raw)
        return (larger ? an:bn) && n != "0" ? "-"+n : n
    }
}
private struct MoveTypeParser {
    let bytes: [UInt8]; var index = 0
    mutating func take(_ s: String) -> Bool {
        let b = Array(s.utf8); guard index+b.count <= bytes.count, Array(bytes[index..<index+b.count]) == b else { return false }; index += b.count; return true
    }
    mutating func identifier() throws -> String {
        let start = index
        guard index < bytes.count, bytes[index] == 95 || (65...90).contains(bytes[index]) || (97...122).contains(bytes[index]) else { throw SuiError.malformed }
        index += 1
        while index < bytes.count, bytes[index] == 95 || (48...57).contains(bytes[index]) || (65...90).contains(bytes[index]) || (97...122).contains(bytes[index]) { index += 1 }
        return String(bytes:bytes[start..<index],encoding:.utf8)!
    }
    mutating func type(depth: Int) throws -> String {
        guard depth < 16 else { throw SuiError.malformed }
        var result: String
        if take("0x") {
            let start = index
            while index < bytes.count, (48...57).contains(bytes[index]) || (65...70).contains(bytes[index]) || (97...102).contains(bytes[index]) { index += 1 }
            let full = try SuiIdentity.address("0x"+String(bytes:bytes[start..<index],encoding:.utf8)!)
            let short = full.dropFirst(2).drop(while:{$0 == "0"})
            guard take("::") else { throw SuiError.malformed }; let module = try identifier()
            guard take("::") else { throw SuiError.malformed }; let name = try identifier()
            result = "0x"+(short.isEmpty ? "0":String(short))+"::"+module+"::"+name
        } else {
            result = try identifier()
            guard depth > 0, ["bool","u8","u16","u32","u64","u128","u256","address","vector"].contains(result) else { throw SuiError.malformed }
        }
        if take("<") {
            guard result.contains("::") || result == "vector" else { throw SuiError.malformed }
            var args = [try type(depth:depth+1)]
            while take(",") { args.append(try type(depth:depth+1)) }
            guard take(">"), result != "vector" || args.count == 1 else { throw SuiError.malformed }
            result += "<"+args.joined(separator:",")+">"
        } else if result == "vector" { throw SuiError.malformed }
        return result
    }
}
public struct SuiToken: Codable, Sendable, Equatable {
    public let reference: String
    public let name: String
    public let symbol: String
    public let decimals: Int
    public let logo: String?
    public let description: String?
    public static let native = SuiToken(reference:"native",name:"Sui",symbol:"SUI",decimals:9,logo:nil,description:nil)
    static func decode(_ value: SuiJSON, reference: String) throws -> Self {
        if reference == "native" { return .native }
        guard let d = value["decimals"].integer, d <= 255, let name = value["name"].string, let symbol = value["symbol"].string else { throw SuiError.malformed }
        return .init(reference:reference,name:(try? TronIdentity.clean(name)) ?? "Token",symbol:(try? TronIdentity.clean(symbol,limit:64)) ?? "TOKEN",decimals:Int(d),logo:ArtworkSource.normalized(value["iconUrl"].string),description:value["description"].string)
    }
}
public struct SuiHolding: Codable, Sendable, Equatable {
    public let reference: String
    public let token: SuiToken?
    public let amount: String
    public let coinBalance: String
    public let addressBalance: String
}
public struct SuiInventory: Codable, Sendable {
    public let owner: String
    public let holdings: [SuiHolding]
    public let checkpoint: Int64
    public let observedAt: Date
    public let raw: Data
}
public struct SuiPrice: Codable, Sendable, Equatable { public let reference: String; public let usd: String; public let source: String; public let fetchedAt: Date }
public struct SuiMovement: Codable, Sendable {
    public let reference: String
    public let token: SuiToken?
    public let direction: String
    public let amount: String
}
public struct SuiTransaction: Codable, Sendable {
    public let hash: String
    public let checkpoint: Int64
    public let timestamp: Double
    public let failed: Bool
    public let fee: String?
    public let netGas: String
    public let sender: String
    public let owner: String
    public let movements: [SuiMovement]
    public let raw: Data
}
public struct SuiHistoryPage: Sendable {
    public let transactions: [SuiTransaction]
    public let next: String?
    public let head: String?
    public let raw: Data
}
