import Foundation

public enum NearDecoding {
    public static func history(_ json:NearJSON, owner:String, stream:String, raw:Data) throws -> NearHistoryPage {
        let owner = try NearIdentity.address(owner)
        guard ["transactions","transfers"].contains(stream), let rows = json[stream == "transfers" ? "transfers":"account_txs"].array else { throw NearError.malformed }
        let next:String?
        if json["resume_token"].isNull { next = nil }
        else { guard let s = json["resume_token"].string, !s.isEmpty, s.count <= 4096 else { throw NearError.malformed }; next = s }
        var events:[NearEvent] = [], executions:[NearExecution] = []
        for row in rows {
            guard row["account_id"].string == owner else { throw NearError.wrongOwner }
            if stream == "transactions" {
                executions.append(try .init(owner:owner,hash:NearIdentity.hash(row["transaction_hash"]),blockHeight:NearIdentity.height(row["tx_block_height"]),timestamp:NearIdentity.timestamp(row["tx_block_timestamp"]),failed:!NearIdentity.bool(row["is_success"]),fee:nil,raw:JSONEncoder().encode(row)))
                continue
            }
            let reference:String?
            guard let type = row["asset_type"].string, let asset = row["asset_id"].string else { throw NearError.malformed }
            if type == "Near", ["native:near","near"].contains(asset) { reference = "native" }
            else if type == "Ft", asset.hasPrefix("nep141:") { reference = try NearIdentity.address(String(asset.dropFirst(7))) }
            else if type == "Ft", !asset.contains(":") { reference = try NearIdentity.address(asset) }
            else { reference = nil } // Preserve newer standards without inventing their decimals.
            let height = try NearIdentity.height(row["block_height"]), index = try NearIdentity.height(row["transfer_index"])
            let receipt = try NearIdentity.hash(row["receipt_id"])
            let hash = row["transaction_id"].isNull ? nil:try NearIdentity.hash(row["transaction_id"])
            let counterparty = row["other_account_id"].isNull ? nil:try NearIdentity.address(row["other_account_id"].string ?? "")
            events.append(try .init(id:"\(height):\(index)",owner:owner,hash:hash,receipt:receipt,reference:reference,token:reference == "native" ? .native:nil,amount:NearIdentity.signed(row["amount"]),counterparty:counterparty,blockHeight:height,timestamp:NearIdentity.timestamp(row["block_timestamp"]),raw:JSONEncoder().encode(row)))
        }
        let ids = stream == "transfers" ? events.map(\.id):executions.map(\.hash)
        guard Set(ids).count == ids.count, next == nil || !ids.isEmpty else { throw NearError.paginationLoop }
        return .init(events:events,executions:executions,next:next,head:ids.first,raw:raw)
    }
}
