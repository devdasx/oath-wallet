import Foundation
import CryptoKit

public typealias XrplJSON = SolanaJSON
public enum XrplError: Error, Sendable, Equatable {
    case configuration, invalidAddress, malformed, wrongNetwork, wrongOwner, wrongLedger, paginationLoop, incompleteHistory
    case accountMissing, historyWindowExpired, rpc(String), http(Int), transport
}
public enum XrplIdentity {
    // Classic issued amounts have no fixed on-chain decimals. This internal
    // scale exactly accommodates the protocol's 16-digit mantissa/exponent.
    public static let issuedScale = 96
    private static let alphabet = Array("rpshnaf39wBUDNEGHJKLM4PQRST7VWXYZ2bcdeCg65jkm8oFqi1tuvAxyz".utf8)
    public static func accountBytes(_ text:String) throws -> Data {
        guard (25...35).contains(text.utf8.count), text.first == "r" else { throw XrplError.invalidAddress }
        var bytes:[UInt8] = []
        for c in text.utf8 {
            guard let n = alphabet.firstIndex(of:c) else { throw XrplError.invalidAddress }; var carry = n
            for i in bytes.indices { carry += Int(bytes[i])*58; bytes[i] = UInt8(carry & 255); carry >>= 8 }
            while carry > 0 { bytes.append(UInt8(carry & 255)); carry >>= 8 }
        }
        let data = Data(Array(repeating:UInt8(0),count:text.utf8.prefix(while:{$0 == alphabet[0]}).count)+bytes.reversed())
        guard data.count == 25, data.first == 0,
              Data(SHA256.hash(data:Data(SHA256.hash(data:data.prefix(21))))).prefix(4) == data.suffix(4) else { throw XrplError.invalidAddress }
        return data.dropFirst().prefix(20)
    }
    public static func address(_ text:String) throws -> String { _ = try accountBytes(text); return text }
    public static func currency(_ text:String) throws -> String {
        if text.utf8.count == 3, text != "XRP", text.utf8.allSatisfy({ (33...126).contains($0) }) { return text }
        guard text.count == 40, let data = try? TronIdentity.hex(text), data.contains(where:{$0 != 0}) else { throw XrplError.malformed }
        if data.prefix(12).allSatisfy({$0 == 0}), data.suffix(5).allSatisfy({$0 == 0}),
           let code = String(data:data[12..<15],encoding:.ascii), code != "XRP", code.utf8.allSatisfy({(33...126).contains($0)}) { return code }
        return text.uppercased()
    }
    public static func reference(_ text:String) throws -> String {
        if text == "native" { return text }
        if text.count == 48, (try? TronIdentity.hex(text)) != nil { return text.uppercased() }
        guard let split = text.lastIndex(of:".") else { throw XrplError.malformed }
        return try currency(String(text[..<split]))+"."+address(String(text[text.index(after:split)...]))
    }
    static func uint(_ value:XrplJSON, max:String = "9223372036854775807") throws -> String {
        guard let s = value.text, !s.isEmpty, s.count <= 30, s.utf8.allSatisfy({(48...57).contains($0)}) else { throw XrplError.malformed }
        let n = String(s.drop(while:{$0 == "0"})), r = n.isEmpty ? "0":n
        guard r.count < max.count || r.count == max.count && r <= max else { throw XrplError.malformed }; return r
    }
    /// Signed fixed-scale integer; neither binary floating point nor Decimal
    /// can losslessly cover XRPL's complete exponent range.
    public static func issuedAmount(_ input:String) throws -> String {
        guard !input.isEmpty, input.count <= 200 else { throw XrplError.malformed }
        let negative = input.hasPrefix("-"), s = negative ? String(input.dropFirst()):input
        let exp = s.lowercased().split(separator:"e",omittingEmptySubsequences:false)
        guard (1...2).contains(exp.count), let exponent = exp.count == 2 ? Int(exp[1]):0, (-200...200).contains(exponent) else { throw XrplError.malformed }
        let parts = exp[0].split(separator:".",omittingEmptySubsequences:false)
        guard (1...2).contains(parts.count), parts.allSatisfy({!$0.isEmpty && $0.utf8.allSatisfy({(48...57).contains($0)})}) else { throw XrplError.malformed }
        var digits = String(parts.joined().drop(while:{$0 == "0"}))
        if digits.isEmpty { return "0" }
        var power = exponent-(parts.count == 2 ? parts[1].count:0)
        while digits.last == "0" { digits.removeLast(); power += 1 }
        guard digits.count <= 16, (-96...80).contains(power-(16-digits.count)), issuedScale+power >= 0 else { throw XrplError.malformed }
        return (negative ? "-":"")+digits+String(repeating:"0",count:issuedScale+power)
    }
    static func hash(_ value:XrplJSON) throws -> String {
        guard let s = value.string, s.count == 64, (try? TronIdentity.hex(s)) != nil else { throw XrplError.malformed }; return s.uppercased()
    }
    static func number(_ value:XrplJSON) throws -> Int64 { Int64(try uint(value))! }
    static func negate(_ s:String) -> String { s == "0" ? "0":s.hasPrefix("-") ? String(s.dropFirst()):"-"+s }
    static func symbol(_ ref:String) -> String {
        let code = ref.lastIndex(of:".").map{String(ref[..<$0])} ?? "TOKEN"
        if code.count == 40, let bytes = try? TronIdentity.hex(code), let text = String(data:bytes,encoding:.utf8), let clean = try? TronIdentity.clean(text,limit:40) { return clean }
        return code.count == 3 ? code:"TOKEN"
    }
}
public struct XrplToken: Codable, Sendable, Equatable {
    public let reference:String; public let name:String; public let symbol:String; public let decimals:Int; public let logo:String?
    public static let native = XrplToken(reference:"native",name:"XRP",symbol:"XRP",decimals:6,logo:nil)
    public static func issued(_ reference:String) throws -> Self {
        let ref = try XrplIdentity.reference(reference); guard ref.contains(".") else { throw XrplError.malformed }
        let symbol = XrplIdentity.symbol(ref)
        return .init(reference:ref,name:symbol,symbol:symbol,decimals:XrplIdentity.issuedScale,logo:nil)
    }
}
public struct XrplLedger: Codable, Sendable, Equatable { public let hash:String; public let height:Int64; public let timestamp:Double }
public struct XrplHolding: Codable, Sendable {
    public let reference:String; public let token:XrplToken?
    /// Signed trust-line liability is retained; never counted as a positive asset.
    public let amount:String; public let raw:XrplJSON
}
public struct XrplInventory: Codable, Sendable {
    public let owner:String; public let ledger:XrplLedger; public let exists:Bool
    public let holdings:[XrplHolding]; public let observedAt:Date; public let raw:Data
}
public struct XrplPrice: Codable, Sendable, Equatable { public let reference:String; public let usd:String; public let source:String; public let fetchedAt:Date }
public struct XrplMovement: Codable, Sendable {
    public let reference:String; public let token:XrplToken?; public let direction:String; public let amount:String
}
public struct XrplTransaction: Codable, Sendable {
    public let hash:String; public let checkpoint:Int64; public let timestamp:Double; public let failed:Bool
    public let fee:String; public let owner:String; public let counterparty:String?; public let movements:[XrplMovement]; public let raw:Data
}
public struct XrplHistoryPage: Sendable {
    public let transactions:[XrplTransaction]; public let next:String?; public let head:String?; public let upperLedger:Int64; public let raw:Data
}
