import Foundation
import CryptoKit

public enum TonDecoding {
    private static func address(_ value: TonJSON, optional: Bool = false) throws -> String {
        if value.isNull && optional { return "" }
        guard let s = value["address"].string else { throw TonError.malformed }
        return try TonIdentity.raw(s)
    }
    public static func history(_ value: TonJSON, owner: String, stream: TonStream, before: Int64?, limit: Int) throws -> TonHistoryPage {
        let owner = try TonIdentity.raw(owner)
        guard let rows = value[stream == .native ? "transactions" : "operations"].array, rows.count <= limit else { throw TonError.malformed }
        var transactions: [TonTransaction] = [], seen: Set<String> = []
        var last: Int64?, head: Int64?
        for row in rows {
            let lt = try TonIdentity.lt(row["lt"])
            guard lt > 0, before == nil || lt < before!, last == nil || lt <= last! else { throw TonError.paginationLoop }
            last = lt; head = max(head ?? lt,lt)
            guard let hash = row[stream == .native ? "hash" : "transaction_hash"].string,
                  let time = row["utime"].integer, time > 0 else { throw TonError.malformed }
            let id = try TonIdentity.hash(hash)
            let tx: TonTransaction
            if stream == .native {
                guard try address(row["account"]) == owner, seen.insert(id).inserted,
                      let outgoing = row["out_msgs"].array else { throw TonError.wrongOwner }
                let failed = try !TonIdentity.bool(row["success"])
                let fee = try TonIdentity.amount(row["total_fees"])
                var events: [TonMovement] = []
                let messages = [(0,row["in_msg"])] + outgoing.enumerated().map { ($0.offset+1,$0.element) }
                for (index,message) in messages where !message.isNull {
                    guard let type = message["msg_type"].string, ["int_msg","ext_in_msg","ext_out_msg"].contains(type) else { throw TonError.malformed }
                    if type != "int_msg" { continue }
                    let from = try address(message["source"],optional:true), to = try address(message["destination"],optional:true)
                    guard from == owner || to == owner else { throw TonError.wrongOwner }
                    let amount = try TonIdentity.amount(message["value"])
                    // A failed compute phase can still credit its inbound value
                    // and charge storage fees. Preserve the actual message, and
                    // retain failure/bounce details on the transaction.
                    if amount != "0" { events.append(.init(index:index,token:.native,from:from,to:to,amount:amount)) }
                }
                if events.isEmpty { events.append(.init(index:0,token:.native,from:owner,to:owner,amount:"0")) }
                tx = .init(hash:id,lt:lt,timestamp:Double(time),failed:failed,fee:fee,events:events,raw:try JSONEncoder().encode(row))
            } else {
                guard let operation = row["operation"].string, ["transfer","mint","burn"].contains(operation) else { throw TonError.malformed }
                let from = try address(row["source"],optional:operation == "mint"), to = try address(row["destination"],optional:operation == "burn")
                guard from == owner || to == owner else { throw TonError.wrongOwner }
                let token = try TonToken.decode(row["jetton"]), amount = try TonIdentity.amount(row["amount"])
                // Independent of pagination and of provider-added metadata.
                let identity = [id,operation,token.reference,from,to].joined(separator:"|")
                guard seen.insert(identity).inserted else { throw TonError.malformed }
                let bytes = SHA256.hash(data:Data(identity.utf8)).prefix(7)
                let index = bytes.reduce(Int(0)) { ($0<<8)|Int($1) } + 1_000_000
                tx = .init(hash:id,lt:lt,timestamp:Double(time),failed:false,fee:nil,events:[.init(index:index,token:token,from:from,to:to,amount:amount)],raw:try JSONEncoder().encode(row))
            }
            transactions.append(tx)
        }
        let next: Int64?
        if stream == .jettons, !value["next_from"].isNull {
            let n = try TonIdentity.lt(value["next_from"])
            if n == 0 { next = nil }
            else {
                guard let last, n == last, before == nil || n < before! else { throw TonError.paginationLoop }; next = n
            }
        } else { next = rows.count == limit ? last : nil }
        // Jetton operations belong to multiple contracts and may share an LT.
        // Re-read the boundary LT on the next page instead of skipping siblings.
        let boundary: Int64?
        if stream == .jettons, let next {
            guard next < Int64.max else { throw TonError.malformed }
            boundary = next + 1
            guard before == nil || boundary! < before! else { throw TonError.paginationLoop }
        } else { boundary = next }
        // A missing cursor is only final on a short page; full pages continue
        // from their last LT even when an index omits next_from.
        return .init(transactions:transactions,next:boundary,head:head,raw:try JSONEncoder().encode(value))
    }
}
