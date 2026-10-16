import OathArtworkSource
import Foundation
import CryptoKit

public typealias TonJSON = SolanaJSON
public enum TonError: Error, Sendable, Equatable {
    case configuration, invalidAddress, wrongNetwork, wrongOwner, malformed, incomplete, paginationLoop, http(Int), rpc(Int), transport
}
public enum TonIdentity {
    public static let genesis = "F6OpKZKqvqeFp6CQmFomXNMfMj2EnaUSOXN+Mh+wVWk="
    public static let usdt = "0:b113a994b5024a16719f69139328eb759596c38a25f59028b146fecdc3621dfe"
    public static func raw(_ address: String) throws -> String {
        let parts = address.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count == 2 {
            guard let wc = Int8(parts[0]), String(wc) == parts[0], parts[1].count == 64,
                  let bytes = try? TronIdentity.hex(String(parts[1])), bytes.count == 32 else { throw TonError.invalidAddress }
            return String(wc) + ":" + parts[1].lowercased()
        }
        guard address.count == 48, let bytes = base64(address), bytes.count == 36,
              bytes[0] == 0x11 || bytes[0] == 0x51,
              crc16(Data(bytes.prefix(34))) == Array(bytes.suffix(2)) else { throw TonError.invalidAddress }
        return String(Int8(bitPattern: bytes[1])) + ":" + bytes[2..<34].map { String(format:"%02x",$0) }.joined()
    }
    public static func friendly(_ address: String, bounceable: Bool = true) throws -> String {
        let parts = try raw(address).split(separator:":")
        var data = Data([bounceable ? 0x11 : 0x51, UInt8(bitPattern:Int8(parts[0])!)])
        data += try TronIdentity.hex(String(parts[1])); data += crc16(data)
        return data.base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_")
    }
    public static func hash(_ text: String) throws -> String {
        if text.count == 64, let data = try? TronIdentity.hex(text), data.count == 32 { return text.lowercased() }
        guard let data = base64(text), data.count == 32 else { throw TonError.malformed }
        return data.map { String(format:"%02x",$0) }.joined()
    }
    static func base64(_ text: String) -> Data? {
        guard text.count < 1_000_000 else { return nil }
        var value=text.replacingOccurrences(of:"-",with:"+").replacingOccurrences(of:"_",with:"/")
        value += String(repeating:"=",count:(4-value.count%4)%4)
        return Data(base64Encoded:value)
    }
    static func crc16(_ data: Data) -> [UInt8] {
        var crc: UInt16 = 0
        for byte in data { crc ^= UInt16(byte)<<8; for _ in 0..<8 { crc = crc & 0x8000 != 0 ? (crc &<< 1) ^ 0x1021 : crc &<< 1 } }
        return [UInt8(crc>>8),UInt8(crc&255)]
    }
    public static func amount(_ value: TonJSON) throws -> String {
        guard let text=value.text,!text.isEmpty,text.count<=78,text.utf8.allSatisfy({(48...57).contains($0)}) else { throw TonError.malformed }
        let s=String(text.drop(while:{$0=="0"}));return s.isEmpty ? "0" : s
    }
    static func lt(_ value: TonJSON) throws -> Int64 {
        guard let text=value.text,let n=Int64(text),n>=0 else { throw TonError.malformed };return n
    }
    static func bool(_ value: TonJSON) throws -> Bool {
        guard case .bool(let value)=value else { throw TonError.malformed };return value
    }
    /// TEP-74 get_wallet_address accepts a slice containing MsgAddressInt.
    public static func addressSlice(_ owner: String) throws -> String {
        let parts=try raw(owner).split(separator:":")
        let bytes=[UInt8(bitPattern:Int8(parts[0])!)]+Array(try TronIdentity.hex(String(parts[1])))
        var bits:[UInt8]=[1,0,0] // addr_std$10, no anycast
        for byte in bytes { for shift in (0..<8).reversed() { bits.append((byte>>shift)&1) } }
        bits.append(1);while bits.count%8 != 0 { bits.append(0) }
        var cell=Data()
        for i in stride(from:0,to:bits.count,by:8) { cell.append(bits[i..<i+8].reduce(0){($0<<1)|$1}) }
        return (try TronIdentity.hex("b5ee9c72010101010024000043") + cell).base64EncodedString()
    }
    public static func walletAddress(_ result: TonJSON) throws -> String {
        guard result["exit_code"].integer == 0, let stack=result["stack"].array,stack.count==1,
              let entry=stack[0].array,entry.count==2,entry[0].string=="cell" else { throw TonError.malformed }
        // ANKR's native API decodes the returned single-cell address slice.
        let object=entry[1]["object"]
        guard object["special"] == .bool(false), object["refs"].array?.isEmpty == true,
              object["data"]["len"].integer == 267,let text=object["data"]["b64"].string,
              let data=base64(text),data.count==34 else { throw TonError.malformed }
        let bits=data.flatMap { b in (0..<8).reversed().map{(b>>$0)&1} }
        guard Array(bits.prefix(3)) == [1,0,0] else { throw TonError.malformed }
        var bytes:[UInt8]=[]
        for i in stride(from:3,to:267,by:8) { bytes.append(bits[i..<i+8].reduce(0){($0<<1)|$1}) }
        return String(Int8(bitPattern:bytes[0]))+":"+bytes.dropFirst().map{String(format:"%02x",$0)}.joined()
    }
}
public struct TonToken: Codable, Sendable, Equatable {
    public let reference: String
    public let name: String
    public let symbol: String
    public let decimals: Int
    public let logo: String?
    public let verified: Bool
    public let isBlacklisted: Bool?
    public let description: String?
    public static let native = TonToken(reference:"native",name:"Gram",symbol:"GRAM",decimals:9,logo:nil,verified:true)
    public init(reference:String,name:String,symbol:String,decimals:Int,logo:String?=nil,verified:Bool=false,description:String?=nil,isBlacklisted:Bool?=nil) {
        self.reference=reference;self.name=name;self.symbol=symbol;self.decimals=decimals;self.logo=logo;self.verified=verified;self.description=description;self.isBlacklisted=isBlacklisted
    }
    static func decode(_ value:TonJSON) throws -> Self {
        guard let ref=value["address"].string,let name=value["name"].string,let symbol=value["symbol"].string,
              let decimals=value["decimals"].integer,decimals<=255,let verification=value["verification"].string else { throw TonError.malformed }
        let logo=ArtworkSource.normalized(value["image"].string)
        return .init(reference:try TonIdentity.raw(ref),name:(try? TronIdentity.clean(name)) ?? "Jetton",symbol:(try? TronIdentity.clean(symbol,limit:64)) ?? "JETTON",decimals:Int(decimals),logo:logo,verified:verification=="whitelist",description:value["description"].string.map{String($0.prefix(8000))},isBlacklisted:verification=="blacklist")
    }
}
public struct TonPrice: Codable, Sendable, Equatable {
    public let reference:String
    public let usd:String
    public let source:String
    public let fetchedAt:Date
}
public struct TonHolding: Codable, Sendable, Equatable {
    public let token:TonToken
    public let wallet:String?
    public let amount:String
}
public struct TonInventory: Codable, Sendable {
    public let owner:String
    public let holdings:[TonHolding]
    public let prices:[TonPrice]
    public let failedReferences:[String]
    public let discoveryComplete:Bool
    public let observedAt:Date
    public let raw:Data
}
public struct TonMovement: Codable, Sendable, Equatable {
    public let index:Int
    public let token:TonToken
    public let from:String
    public let to:String
    public let amount:String
}
public struct TonTransaction: Codable, Sendable {
    public let hash:String
    public let lt:Int64
    public let timestamp:Double
    public let failed:Bool
    public let fee:String?
    public let events:[TonMovement]
    public let raw:Data
}
public enum TonStream:String,Codable,Sendable,CaseIterable { case native,jettons }
public struct TonHistoryPage:Sendable {
    public let transactions:[TonTransaction]
    public let next:Int64?
    public let head:Int64?
    public let raw:Data
}
