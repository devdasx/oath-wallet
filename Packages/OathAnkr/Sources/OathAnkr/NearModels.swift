import OathArtworkSource
import Foundation

public typealias NearJSON = SolanaJSON
public enum NearError: Error, Sendable, Equatable {
    case configuration, invalidAddress, malformed, wrongNetwork, wrongOwner, wrongBlock, paginationLoop
    case accountMissing, contract, rpc(Int), http(Int), transport, unsupportedBatch
}
public enum NearIdentity {
    /// NEAR named and implicit accounts are case-sensitive, lowercase identifiers.
    public static func address(_ value: String) throws -> String {
        let bytes = Array(value.utf8)
        guard (2...64).contains(bytes.count) else { throw NearError.invalidAddress }
        var separator = true
        for b in bytes {
            if (97...122).contains(b) || (48...57).contains(b) { separator = false }
            else if [UInt8(45),46,95].contains(b), !separator { separator = true }
            else { throw NearError.invalidAddress }
        }
        guard !separator else { throw NearError.invalidAddress }; return value
    }
    public static func reference(_ value: String) throws -> String { value == "native" ? value : try address(value) }
    public static func amount(_ value: NearJSON) throws -> String {
        guard let text = value.text, !text.isEmpty, text.utf8.allSatisfy({(48...57).contains($0)}) else { throw NearError.malformed }
        let n = String(text.drop(while:{$0 == "0"})), result = n.isEmpty ? "0":n
        let max = "340282366920938463463374607431768211455"
        guard result.count < max.count || result.count == max.count && result <= max else { throw NearError.malformed }
        return result
    }
    static func signed(_ value: NearJSON) throws -> String {
        guard let text = value.text else { throw NearError.malformed }
        let negative = text.hasPrefix("-"), n = try amount(.string(negative ? String(text.dropFirst()):text))
        // The transfer index documents saturation at Int128 boundaries. Reject
        // saturated values rather than displaying an apparently exact amount.
        guard n != "170141183460469231731687303715884105727", n != "170141183460469231731687303715884105728" else { throw NearError.malformed }
        return negative && n != "0" ? "-"+n:n
    }
    static func height(_ value: NearJSON) throws -> Int64 {
        guard let n = value.text.flatMap(Int64.init), n >= 0 else { throw NearError.malformed }; return n
    }
    static func hash(_ value: NearJSON) throws -> String {
        guard let s = value.string, SolanaIdentity.isAddress(s) else { throw NearError.malformed }; return s
    }
    static func timestamp(_ value: NearJSON) throws -> Double {
        let n = try height(value); return Double(n) / 1_000_000_000
    }
    static func bool(_ value: NearJSON) throws -> Bool {
        guard case .bool(let b) = value else { throw NearError.malformed }; return b
    }
}
public struct NearToken: Codable, Sendable, Equatable {
    public let reference: String
    public let name: String
    public let symbol: String
    public let decimals: Int
    public let logo: String?
    public static let native = NearToken(reference:"native",name:"NEAR Protocol",symbol:"NEAR",decimals:24,logo:nil)
    static func decode(_ json: NearJSON, reference: String) throws -> Self {
        guard json["spec"].string == "ft-1.0.0", let d = json["decimals"].integer, d <= 255,
              let name = json["name"].string, let symbol = json["symbol"].string else { throw NearError.malformed }
        return .init(reference:try NearIdentity.reference(reference),name:(try? TronIdentity.clean(name)) ?? "Token",symbol:(try? TronIdentity.clean(symbol,limit:64)) ?? "TOKEN",decimals:Int(d),logo:ArtworkSource.normalized(json["icon"].string))
    }
}
public struct NearBlock: Codable, Sendable, Equatable { public let hash:String; public let height:Int64; public let timestamp:Double }
public struct NearHolding: Codable, Sendable, Equatable {
    public let reference:String
    public let token:NearToken?
    /// Nil means the contract read failed. It must never erase a cached balance.
    public let amount:String?
    public let indexedAmount:String?
    public let failure:String?
}
public struct NearInventory: Codable, Sendable {
    public let owner:String
    public let block:NearBlock
    public let exists:Bool
    public let liquid:String
    public let locked:String
    public let storageBytes:Int64
    public let holdings:[NearHolding]
    public let observedAt:Date
    public let raw:Data
}
public struct NearPrice: Codable, Sendable, Equatable { public let reference:String; public let usd:String; public let source:String; public let fetchedAt:Date }
public struct NearEvent: Codable, Sendable {
    public let id:String
    public let owner:String
    public let hash:String?
    public let receipt:String
    public let reference:String?
    public let token:NearToken?
    public let amount:String
    public let counterparty:String?
    public let blockHeight:Int64
    public let timestamp:Double
    public let raw:Data
}
public struct NearExecution: Codable, Sendable {
    public let owner:String
    public let hash:String
    public let blockHeight:Int64
    public let timestamp:Double
    public let failed:Bool
    public let fee:String?
    public let raw:Data
}
public struct NearHistoryPage: Sendable {
    public let events:[NearEvent]
    public let executions:[NearExecution]
    public let next:String?
    public let head:String?
    public let raw:Data
    public var ids:[String] { events.isEmpty ? executions.map(\.hash):events.map(\.id) }
}
