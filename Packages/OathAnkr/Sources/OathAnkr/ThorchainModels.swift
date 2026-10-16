import Foundation

public enum ThorchainError: Error, Sendable, Equatable {
    case invalidAddress, malformed, wrongOwner, paginationLoop, incomplete, http(Int), transport, rateLimited, graphql
}
public enum ThorchainIdentity {
    /// Cosmos accounts contain 20 bytes; CosmWasm contracts can contain 32.
    /// Check the Bech32 checksum, HRP and padding, not just a thor1 prefix.
    public static func address(_ input: String) throws -> String {
        guard input == input.lowercased(), input.hasPrefix("thor1"), [43,63].contains(input.count) else { throw ThorchainError.invalidAddress }
        let alphabet = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l".utf8)
        let values = try input.utf8.dropFirst(5).map { b -> UInt32 in
            guard let n = alphabet.firstIndex(of:b) else { throw ThorchainError.invalidAddress }; return UInt32(n)
        }
        let hrp = Array("thor".utf8)
        var checksum: UInt32 = 1
        for v in hrp.map({UInt32($0 >> 5)}) + [0] + hrp.map({UInt32($0 & 31)}) + values {
            let top = checksum >> 25; checksum = ((checksum & 0x1ffffff) << 5) ^ v
            for (i,g) in [UInt32(0x3b6a57b2),0x26508e6d,0x1ea119fa,0x3d4233dd,0x2a1462b3].enumerated() where (top >> i) & 1 != 0 { checksum ^= g }
        }
        guard checksum == 1, input.count != 63 || (values[51] & 15) == 0 else { throw ThorchainError.invalidAddress }
        return input
    }
    public static func reference(_ input: String) throws -> String {
        guard !input.isEmpty, input.utf8.count <= 128,
              input.utf8.allSatisfy({(97...122).contains($0) || (65...90).contains($0) || (48...57).contains($0) || [45,46,47,95].contains($0)}) else { throw ThorchainError.malformed }
        return input == "rune" ? "native" : input
    }
    static func amount(_ input: SolanaJSON) throws -> String {
        guard let s = input.text, !s.isEmpty, s.count <= 78, s.utf8.allSatisfy({(48...57).contains($0)}) else { throw ThorchainError.malformed }
        let n = String(s.drop(while:{$0 == "0"})); return n.isEmpty ? "0" : n
    }
    public static func bankDenom(asset: String) throws -> String? {
        let value = asset.lowercased()
        if ["rune","thor.rune"].contains(value) { return "native" }
        if ["tcy","thor.tcy"].contains(value) { return "tcy" }
        // Trade assets (~) are module positions, and external L1 assets (.)
        // are not bank tokens. Never conflate them with secured assets (-).
        if value.contains("~") { return nil }
        if value.hasPrefix("thor.") || value.hasPrefix("x/") || value.contains("/") || (!value.contains(".") && value.contains("-")) { return try reference(value) }
        return nil
    }
    public static func hasProtocolDecimals(_ reference:String) -> Bool {
        if ["native","tcy","x/ruji"].contains(reference) || reference.hasPrefix("thor.") { return true }
        let chain=reference.prefix(while:{$0 != "-" && $0 != "/"})
        return ["btc","eth","bsc","avax","doge","ltc","bch","gaia","tron","xrp","base"].contains(String(chain)) && chain.count < reference.count
    }
}
public struct ThorchainToken: Codable, Sendable, Equatable {
    public let reference: String
    public let name: String
    public let symbol: String
    public let decimals: Int
    public init(reference:String,name:String,symbol:String,decimals:Int = 8) { self.reference=reference; self.name=name; self.symbol=symbol; self.decimals=decimals }
    public static let native = Self(reference:"native",name:"THORChain",symbol:"RUNE")
    public static func fallback(_ reference:String) -> Self {
        if reference == "native" { return .native }
        if reference == "tcy" { return .init(reference:reference,name:"THORChain Yield",symbol:"TCY") }
        if reference == "x/ruji" { return .init(reference:reference,name:"Rujira",symbol:"RUJI") }
        if !reference.hasPrefix("x/"), let separator = reference.firstIndex(where: { $0 == "-" || $0 == "/" }) {
            let chain = reference[..<separator].uppercased()
            let symbol = reference[reference.index(after: separator)...].split(separator:"-").first.map(String.init)?.uppercased() ?? reference
            return .init(reference:reference,name:symbol+" · "+chain+(reference[separator] == "/" ? " Synth":" Secured"),symbol:symbol)
        }
        // THORChain bank coins use 1e8 units. TokenFactory metadata overrides
        // this default when an issuer registers a different display unit.
        return .init(reference:reference,name:reference,symbol:reference.uppercased())
    }
}
public struct ThorchainHolding: Codable, Sendable, Equatable {
    public let reference:String
    public let amount:String
    public init(reference:String,amount:String) { self.reference=reference; self.amount=amount }
}
public struct ThorchainInventory: Codable, Sendable {
    public let owner:String
    public let holdings:[ThorchainHolding]
    public let observedAt:Date
    public let height:Int64?
    public init(owner:String,holdings:[ThorchainHolding],observedAt:Date = .now,height:Int64?=nil) { self.owner=owner; self.holdings=holdings; self.observedAt=observedAt;self.height=height }
}
public struct ThorchainCatalog: Codable, Sendable {
    public var tokens:[String:ThorchainToken] = [:]
    public var prices:[String:String] = [:]
    public var observedAt:Date = .now
    public init() {}
    public func token(_ reference:String) -> ThorchainToken { tokens[reference] ?? .fallback(reference) }
}
public struct ThorchainEvent: Codable, Sendable, Equatable {
    public let id:String, hash:String, reference:String, amount:String, direction:String, counterparty:String, state:String
    public let height:Int64
    public let timestamp:Double
    public let fee:String?
}
public struct ThorchainHistoryPage: Sendable {
    public let owner:String
    public let events:[ThorchainEvent]
    public let next:String?
    public let rawCount:Int
}
