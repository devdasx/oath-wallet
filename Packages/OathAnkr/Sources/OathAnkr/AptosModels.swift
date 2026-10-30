import OathArtworkSource
import Foundation

public typealias AptosJSON = SolanaJSON
public enum AptosError: Error, Sendable, Equatable {
    case configuration, invalidAddress, malformed, wrongNetwork, wrongOwner, incomplete, paginationLoop, http(Int), indexer, transport
}
public enum AptosIdentity {
    public static let coin = "0x1::aptos_coin::AptosCoin"
    public static func address(_ text: String) throws -> String {
        guard text.hasPrefix("0x"), (3...66).contains(text.count), text.dropFirst(2).utf8.allSatisfy({(48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)}) else { throw AptosError.invalidAddress }
        return "0x" + String(repeating:"0",count:66-text.count) + text.dropFirst(2).lowercased()
    }
    public static func reference(_ text: String) throws -> String {
        if text == "native" { return text }
        if !text.contains("::") {
            let value = try address(text)
            return value == (try address("0xa")) ? "native" : value
        }
        guard text.count <= 4096, text.range(of:"^[a-zA-Z0-9_:<>, ]+$",options:.regularExpression) != nil else { throw AptosError.malformed }
        let regex = try NSRegularExpression(pattern:"0x[0-9a-fA-F]+")
        var result = text.replacingOccurrences(of:" ",with:"")
        for match in regex.matches(in:result,range:NSRange(result.startIndex...,in:result)).reversed() {
            let range = Range(match.range,in:result)!
            let full = try address(String(result[range]))
            let short = String(full.dropFirst(2).drop(while:{$0 == "0"}))
            result.replaceSubrange(range,with:"0x"+(short.isEmpty ? "0" : short))
        }
        guard result.contains("::"), result.hasPrefix("0x") else { throw AptosError.malformed }
        return result == coin ? "native" : result
    }
    public static func amount(_ value: AptosJSON) throws -> String {
        guard let text=value.text, !text.isEmpty, text.count <= 78, text.utf8.allSatisfy({(48...57).contains($0)}) else { throw AptosError.malformed }
        let n=String(text.drop(while:{$0 == "0"})); return n.isEmpty ? "0" : n
    }
    static func number(_ value:AptosJSON) throws -> Int64 {
        guard let n=Int64(try amount(value)),n>=0 else {throw AptosError.malformed}; return n
    }
    static func bool(_ value:AptosJSON) throws -> Bool {
        guard case .bool(let b)=value else {throw AptosError.malformed};return b
    }
    static func add(_ lhs:String,_ rhs:String) -> String {
        let a=Array(lhs.utf8.reversed()),b=Array(rhs.utf8.reversed());var result:[UInt8]=[],carry=0
        for i in 0..<max(a.count,b.count) { let n=(i<a.count ? Int(a[i]-48):0)+(i<b.count ? Int(b[i]-48):0)+carry;result.append(UInt8(n%10)+48);carry=n/10 }
        if carry>0 {result.append(UInt8(carry)+48)};return String(bytes:result.reversed(),encoding:.utf8)!
    }
}
public struct AptosToken: Codable, Sendable, Equatable {
    public let reference:String
    public let name:String
    public let symbol:String
    public let decimals:Int
    public let logo:String?
    public let verified:Bool
    public func replacingReference(_ reference:String) -> Self {
        .init(reference:reference,name:name,symbol:symbol,decimals:decimals,logo:logo,verified:verified)
    }
    public static let native = AptosToken(reference:"native",name:"Aptos",symbol:"APT",decimals:8,logo:nil,verified:true)
    static func decode(_ value:AptosJSON,reference:String) throws -> Self {
        if reference == "native" {return .native}
        guard let d=value["decimals"].integer,d<=255,let n=value["name"].string,let s=value["symbol"].string else {throw AptosError.malformed}
        return .init(reference:reference,name:(try? TronIdentity.clean(n)) ?? "Token",symbol:(try? TronIdentity.clean(s,limit:64)) ?? "TOKEN",decimals:Int(d),logo:ArtworkSource.normalized(value["icon_uri"].string),verified:false)
    }
}
public struct AptosHolding: Codable, Sendable, Equatable { public let token:AptosToken; public let amount:String }
public struct AptosInventory: Codable, Sendable {
    public let owner:String
    public let holdings:[AptosHolding]
    public let failedReferences:[String]
    public let discoveryComplete:Bool
    public let ledgerVersion:Int64
    public let observedAt:Date
    public let raw:Data
    public var discoveryFailure:String? = nil
    public var pairedReferences:[String:String]? = nil
    /// The current request's original failure is diagnostic evidence, not
    /// persisted inventory. A restored snapshot must not invent a current error.
    public var discoveryError: AptosError? = nil
    /// Original typed token-read failures from this refresh only.
    public var holdingErrors: [AptosError] = []
    public var incompleteError: AptosError? {
        guard !discoveryComplete || !failedReferences.isEmpty else { return nil }
        guard holdingErrors.count == failedReferences.count else { return .incomplete }
        var causes = holdingErrors
        if !discoveryComplete {
            // A lagging index or unknown failure remains incomplete even if
            // a separate token read happened to encounter an outage.
            guard let discoveryError else { return .incomplete }
            causes.append(discoveryError)
        }
        return causes.first { !$0.isDiagnosticAvailabilityFailure } ?? causes.first ?? .incomplete
    }
    private enum CodingKeys: String, CodingKey {
        case owner, holdings, failedReferences, discoveryComplete, ledgerVersion
        case observedAt, raw, discoveryFailure, pairedReferences
    }
}
public struct AptosPrice: Codable, Sendable, Equatable { public let reference:String;public let usd:String;public let source:String;public let fetchedAt:Date }
public struct AptosMovement: Codable, Sendable {
    public let index:Int
    public let token:AptosToken
    public let owner:String
    public let direction:String
    public let amount:String
}
public struct AptosTransaction: Codable, Sendable {
    public let hash:String
    public let version:Int64
    public let timestamp:Double
    public let failed:Bool
    public let fee:String?
    public let sender:String
    public let events:[AptosMovement]
    public let raw:Data
}
public struct AptosHistoryPage: Sendable {
    public let transactions:[AptosTransaction]
    public let next:Int64?
    public let head:Int64?
    public let raw:Data
}
