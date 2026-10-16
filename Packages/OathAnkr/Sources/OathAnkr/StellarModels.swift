import Foundation
import CryptoKit

public typealias StellarJSON = SolanaJSON
public enum StellarError: Error, Sendable, Equatable {
    case configuration, invalidAddress, malformed, wrongNetwork, wrongOwner, paginationLoop, incompleteInventory, incompleteHistory
    case http(Int), rpc(Int), transport
}
public enum StellarIdentity {
    public static let network = "Public Global Stellar Network ; September 2015"
    public static let nativeContract = "CAS3J7GYLGXMF6TDJBBYYSE3HQ6BBSMLNUQ34T6TZMYMW2EVH34XOWMA"
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".utf8)
    private static func crc(_ bytes:[UInt8]) -> UInt16 {
        var crc:UInt16 = 0
        for byte in bytes { crc ^= UInt16(byte)<<8; for _ in 0..<8 { crc = crc & 0x8000 != 0 ? (crc &<< 1)^0x1021:crc &<< 1 } }
        return crc
    }
    static func encode(_ bytes:[UInt8], version:UInt8) -> String {
        var data = [version]+bytes; let check = crc(data); data += [UInt8(check & 255),UInt8(check>>8)]
        var buffer:UInt32 = 0, bits = 0, result:[UInt8] = []
        for byte in data { buffer = (buffer<<8)|UInt32(byte); bits += 8; while bits >= 5 { bits -= 5; result.append(alphabet[Int((buffer>>bits)&31)]) }; buffer &= (1<<bits)-1 }
        if bits > 0 { result.append(alphabet[Int((buffer<<(5-bits))&31)]) }; return String(decoding:result,as:UTF8.self)
    }
    public static func bytes(_ text:String, version:UInt8) throws -> [UInt8] {
        guard text.utf8.count == 56 else { throw StellarError.invalidAddress }
        var buffer:UInt32 = 0, bits = 0, data:[UInt8] = []
        for c in text.utf8 {
            guard let value = alphabet.firstIndex(of:c) else { throw StellarError.invalidAddress }
            buffer = (buffer<<5)|UInt32(value); bits += 5
            if bits >= 8 { bits -= 8; data.append(UInt8((buffer>>bits)&255)); buffer &= (1<<bits)-1 }
        }
        guard data.count == 35, data[0] == version, crc(Array(data.prefix(33))) == UInt16(data[33])|UInt16(data[34])<<8 else { throw StellarError.invalidAddress }
        return Array(data[1..<33])
    }
    public static func address(_ text:String) throws -> String { _ = try bytes(text,version:48); return text }
    public static func reference(_ text:String) throws -> String {
        if text == "native" || text == nativeContract { return "native" }
        _ = try bytes(text,version:16); return text
    }
    static func u32(_ n:UInt32) -> [UInt8] { [UInt8((n>>24)&255),UInt8((n>>16)&255),UInt8((n>>8)&255),UInt8(n&255)] }
    public static func contract(code:String, issuer:String, network:String = StellarIdentity.network) throws -> String {
        guard (1...12).contains(code.utf8.count), code.utf8.allSatisfy({(48...57).contains($0)||(65...90).contains($0)||(97...122).contains($0)}) else { throw StellarError.malformed }
        let size = code.utf8.count <= 4 ? 4:12
        let asset = u32(size == 4 ? 1:2)+Array(code.utf8)+Array(repeating:UInt8(0),count:size-code.utf8.count)+u32(0)+(try bytes(issuer,version:48))
        let preimage = u32(8)+Array(SHA256.hash(data:Data(network.utf8)))+u32(1)+asset
        return encode(Array(SHA256.hash(data:Data(preimage))),version:16)
    }
    public static func atomic(_ value:String, decimals:Int = 7) throws -> String {
        guard (0...255).contains(decimals), value.count <= 320 else { throw StellarError.malformed }
        let p = value.split(separator:".",omittingEmptySubsequences:false)
        guard (1...2).contains(p.count), p.allSatisfy({!$0.isEmpty && $0.utf8.allSatisfy({(48...57).contains($0)})}), p.count == 1 || p[1].count <= decimals else { throw StellarError.malformed }
        let s = String((p.joined()+String(repeating:"0",count:decimals-(p.count == 2 ? p[1].count:0))).drop(while:{$0 == "0"}))
        return try uint(s.isEmpty ? "0":s)
    }
    public static func uint(_ s:String) throws -> String {
        guard !s.isEmpty, s.count <= 39, s.utf8.allSatisfy({(48...57).contains($0)}) else { throw StellarError.malformed }
        let v = String(s.drop(while:{$0 == "0"})), r = v.isEmpty ? "0":v
        let max = "170141183460469231731687303715884105727"
        guard r.count < max.count || r.count == max.count && r <= max else { throw StellarError.malformed }; return r
    }
    public static func sum(_ a:String,_ b:String) -> String { SuiIdentity.add(a,b) }
    static func number(_ v:StellarJSON) throws -> Int64 {
        guard let text = v.text, let n = Int64(text), n >= 0 else { throw StellarError.malformed }; return n
    }
    static func hash(_ v:StellarJSON) throws -> String {
        guard let s = v.string, s.count == 64, (try? TronIdentity.hex(s)) != nil else { throw StellarError.malformed }; return s.lowercased()
    }
    static func date(_ v:StellarJSON) throws -> Double {
        guard let s = v.string, let d = ISO8601DateFormatter().date(from:s) else { throw StellarError.malformed }; return d.timeIntervalSince1970
    }
    static func ownerTopic(_ owner:String) throws -> String { Data(u32(18)+u32(0)+u32(0)+(try bytes(owner,version:48))).base64EncodedString() }
}
public struct StellarToken: Codable, Sendable, Equatable {
    public let reference:String; public let name:String; public let symbol:String; public let decimals:Int; public let logo:String?
    public let assetCode:String?; public let issuer:String?
    public init(reference:String,name:String,symbol:String,decimals:Int,logo:String?,assetCode:String? = nil,issuer:String? = nil) {
        self.reference = reference; self.name = name; self.symbol = symbol; self.decimals = decimals; self.logo = logo
        self.assetCode = assetCode; self.issuer = issuer
    }
    public static let native = Self(reference:"native",name:"Stellar",symbol:"XLM",decimals:7,logo:nil)
    public static func classic(code:String,issuer:String) throws -> Self { try .init(reference:StellarIdentity.contract(code:code,issuer:issuer),name:code,symbol:code,decimals:7,logo:nil,assetCode:code,issuer:issuer) }
}
public struct StellarLedger: Codable, Sendable { public let height:Int64; public let timestamp:Double }
public struct StellarHolding: Codable, Sendable {
    public let reference:String; public let token:StellarToken; public let amount:String; public let raw:StellarJSON
}
public struct StellarInventory: Codable, Sendable {
    public let owner:String; public let ledger:StellarLedger; public let exists:Bool; public let holdings:[StellarHolding]
    public let verified:Set<String>; public let prices:[StellarPrice]; public let observedAt:Date; public let raw:Data
}
public struct StellarPrice: Codable, Sendable, Equatable { public let reference:String; public let usd:String; public let source:String; public let fetchedAt:Date }
public struct StellarEvent: Codable, Sendable {
    public let id:String; public let hash:String; public let checkpoint:Int64; public let timestamp:Double
    public let reference:String; public let token:StellarToken?; public let amount:String; public let direction:String
    public let kind:String; public let successful:Bool; public let counterparty:String?; public let raw:StellarJSON
}
public struct StellarEventPage: Sendable {
    public let events:[StellarEvent]; public let next:String?; public let complete:Bool; public let startLedger:Int64; public let endLedger:Int64; public let raw:Data
}
