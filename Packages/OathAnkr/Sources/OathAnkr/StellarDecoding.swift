import OathArtworkSource
import Foundation

public enum StellarDecoding {
    /// Only the SCVal types used by SEP-41 events are decoded. Strict bounds
    /// prevent malformed XDR from becoming fabricated amounts or identities.
    static func scBytes(_ value:StellarJSON) throws -> [UInt8] {
        guard let s = value.string, s.count <= 4096, let d = Data(base64Encoded:s) else { throw StellarError.malformed }; return Array(d)
    }
    static func u32(_ b:[UInt8],_ at:Int) throws -> UInt32 {
        guard at >= 0, at+4 <= b.count else { throw StellarError.malformed }; return b[at..<at+4].reduce(0){($0<<8)|UInt32($1)}
    }
    static func scText(_ value:StellarJSON) throws -> String {
        let b = try scBytes(value), type = try u32(b,0), length = Int(try u32(b,4))
        guard [14,15].contains(type), length <= 256, b.count == 8+((length+3)/4)*4, let s = String(bytes:b[8..<8+length],encoding:.utf8) else { throw StellarError.malformed }
        return try TronIdentity.clean(s,limit:256)
    }
    static func scAddress(_ value:StellarJSON) throws -> String {
        let b = try scBytes(value); guard try u32(b,0) == 18 else { throw StellarError.malformed }
        let kind = try u32(b,4)
        if kind == 0, b.count == 44, try u32(b,8) == 0 { return StellarIdentity.encode(Array(b[12...]),version:48) }
        if kind == 1, b.count == 40 { return StellarIdentity.encode(Array(b[8...]),version:16) }
        if kind == 2, b.count == 48 { return StellarIdentity.encode(Array(b[16...]),version:48) }
        // CAP-67 classic transfers can involve claimable balances and pools.
        // Keep these distinct from spendable account/contract addresses.
        if kind == 3, b.count == 44, try u32(b,8) == 0 { return "claimable:"+b[8...].map{String(format:"%02x",$0)}.joined() }
        if kind == 4, b.count == 40 { return "pool:"+b[8...].map{String(format:"%02x",$0)}.joined() }
        throw StellarError.malformed
    }
    static func scAmount(_ value:StellarJSON,allowNegative:Bool = false) throws -> String {
        var b = try scBytes(value)
        if try u32(b,0) == 17 {
            // CAP-67: {amount: i128, to_muxed_id: u64|bytes|string}.
            guard try u32(b,4) == 1, try u32(b,8) == 2 else { throw StellarError.malformed }
            var offset = 12, amount:[UInt8]?, keys:Set<String> = []
            for _ in 0..<2 {
                guard try u32(b,offset) == 15 else { throw StellarError.malformed }
                let size = Int(try u32(b,offset+4)), end = offset+8+((size+3)/4)*4
                guard size <= 32, end <= b.count, let key = String(bytes:b[offset+8..<offset+8+size],encoding:.utf8), keys.insert(key).inserted else { throw StellarError.malformed }
                offset = end
                let type = try u32(b,offset)
                if key == "amount", type == 10 {
                    guard offset+20 <= b.count else { throw StellarError.malformed }
                    amount = Array(b[offset..<offset+20]); offset += 20
                } else if key == "to_muxed_id", type == 5 { offset += 12 }
                else if key == "to_muxed_id", [13,14].contains(type) {
                    let length = Int(try u32(b,offset+4))
                    guard length <= 256 else { throw StellarError.malformed }
                    offset += 8+((length+3)/4)*4
                } else { throw StellarError.malformed }
            }
            guard offset == b.count, let amount else { throw StellarError.malformed }; b = amount
        }
        guard b.count == 20, try u32(b,0) == 10 else { throw StellarError.malformed }
        let negative = b[4] & 128 != 0
        guard !negative || allowNegative else { throw StellarError.malformed }
        let magnitude = negative ? b.dropFirst(4).map{~$0}:Array(b.dropFirst(4))
        // Decimal digit arithmetic also works on iOS versions without UInt128.
        var result = "0"
        for byte in magnitude {
            for _ in 0..<8 { result = StellarIdentity.sum(result,result) }
            result = StellarIdentity.sum(result,String(byte))
        }
        if negative { result = StellarIdentity.sum(result,"1") }
        return try (negative ? "-":"")+StellarIdentity.uint(result)
    }
    public static func event(_ row:StellarJSON,owner:String) throws -> StellarEvent? {
        guard let topics = row["topic"].array, !topics.isEmpty, let rawContract = row["contractId"].string,
              let id = row["id"].string, !id.isEmpty, id.count <= 128,
              row["inSuccessfulContractCall"] == .bool(true) || row["inSuccessfulContractCall"] == .bool(false) else { throw StellarError.malformed }
        let kind = try scText(topics[0])
        guard ["transfer","mint","burn","clawback","fee"].contains(kind) else { return nil }
        let reference = try StellarIdentity.reference(rawContract), successful = row["inSuccessfulContractCall"] == .bool(true)
        // Failed contract calls must never create token movements. Fee events
        // are retained because failed transactions can still charge the payer.
        guard successful || kind == "fee" else { return nil }
        var from:String?, to:String?, assetTopic:Int
        if kind == "transfer" {
            guard topics.count >= 3 else { throw StellarError.malformed }
            from = try scAddress(topics[1]); to = try scAddress(topics[2]); assetTopic = 3
        } else {
            guard topics.count >= 2 else { throw StellarError.malformed }
            // Before protocol 23, mint/clawback included the administrator
            // before the credited/debited owner. Its balance is not affected.
            let legacy = ["mint","clawback"].contains(kind) && topics.count >= 3 && (try? scAddress(topics[2])) != nil
            let index = legacy ? 2:1
            let address = try scAddress(topics[index]); if kind == "mint" { to = address } else { from = address }; assetTopic = index+1
            if legacy, from != owner, to != owner { return nil }
        }
        guard from == owner || to == owner else { throw StellarError.wrongOwner }
        var token:StellarToken? = reference == "native" ? .native:nil
        if topics.count > assetTopic, let asset = try? scText(topics[assetTopic]), asset != "native" {
            let parts = asset.split(separator:":",omittingEmptySubsequences:false)
            if parts.count == 2 {
                let classic = try StellarToken.classic(code:String(parts[0]),issuer:String(parts[1]))
                guard classic.reference == reference else { throw StellarError.malformed }; token = classic
            }
        }
        guard kind != "fee" || reference == "native" else { throw StellarError.malformed }
        let direction = from == owner && to == owner ? "self":to == owner ? "incoming":"outgoing"
        return try .init(id:id,hash:StellarIdentity.hash(row["txHash"]),checkpoint:StellarIdentity.number(row["ledger"]),timestamp:StellarIdentity.date(row["ledgerClosedAt"]),reference:reference,token:token,amount:scAmount(row["value"],allowNegative:kind == "fee"),direction:direction,kind:kind,successful:successful,counterparty:direction == "incoming" ? from:to,raw:row)
    }
    public static func classicHoldings(_ value:StellarJSON,owner:String) throws -> [StellarHolding] {
        guard value["account_id"].string == owner, let rows = value["balances"].array else { throw StellarError.wrongOwner }
        var result:[StellarHolding] = []
        for row in rows {
            let token:StellarToken
            if row["asset_type"].string == "native" { token = .native }
            else if ["credit_alphanum4","credit_alphanum12"].contains(row["asset_type"].string ?? "") {
                guard let code = row["asset_code"].string, let issuer = row["asset_issuer"].string else { throw StellarError.malformed }
                token = try .classic(code:code,issuer:issuer)
            } else if row["asset_type"].string == "liquidity_pool_shares" {
                // LP shares are positions, not SEP-41 tokens; preserve them in
                // the raw account snapshot without labelling them as XLM.
                continue
            } else { throw StellarError.malformed }
            guard let balance = row["balance"].string else { throw StellarError.malformed }
            result.append(try .init(reference:token.reference,token:token,amount:StellarIdentity.atomic(balance),raw:row))
        }
        guard result.filter({$0.reference == "native"}).count == 1, Set(result.map(\.reference)).count == result.count else { throw StellarError.malformed }
        return result
    }
    public static func indexedHolding(_ row:StellarJSON,owner:String) throws -> StellarHolding {
        guard row["blockchain"].string == "stellar_soroban", row["holderAddress"].string == owner,
              let contract = row["contractAddress"].string, let decimals = row["tokenDecimals"].integer, decimals <= 255,
              let rawAmount = row["balanceRawInteger"].text, let amount = row["balance"].text else { throw StellarError.wrongOwner }
        let ref = try StellarIdentity.reference(contract), atomic = try StellarIdentity.uint(rawAmount)
        guard try StellarIdentity.atomic(amount,decimals:Int(decimals)) == atomic else { throw StellarError.malformed }
        let token:StellarToken
        if ref == "native" { guard decimals == 7 else { throw StellarError.malformed }; token = .native }
        else {
            let name = try TronIdentity.clean(row["tokenName"].string ?? "",limit:256), symbol = try TronIdentity.clean(row["tokenSymbol"].string ?? "",limit:64)
            let parts = name.split(separator:":",omittingEmptySubsequences:false)
            let classic = parts.count == 2 && (try? StellarIdentity.address(String(parts[1]))) != nil
            if classic {
                guard try StellarIdentity.contract(code:String(parts[0]),issuer:String(parts[1])) == ref, decimals == 7 else { throw StellarError.malformed }
            }
            let logo = ArtworkSource.normalized(row["thumbnail"].string)
            token = .init(reference:ref,name:classic ? symbol:name,symbol:symbol,decimals:Int(decimals),logo:logo,assetCode:classic ? String(parts[0]):nil,issuer:classic ? String(parts[1]):nil)
        }
        return .init(reference:ref,token:token,amount:atomic,raw:row)
    }
}
