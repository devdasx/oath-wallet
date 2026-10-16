import Foundation

public enum XrplDecoding {
    /// The metadata is authoritative. Payment.Amount/DeliverMax can exceed
    /// delivery on partial payments; swaps and fees also change ledger balances.
    public static func transaction(_ row:XrplJSON, owner:String, tokens:[String:XrplToken] = [:]) throws -> XrplTransaction {
        let owner = try XrplIdentity.address(owner), tx = row["tx_json"], meta = row["meta"]
        guard row["validated"] == .bool(true), let nodes = meta["AffectedNodes"].array,
              let result = meta["TransactionResult"].string, let sender = tx["Account"].string else { throw XrplError.malformed }
        _ = try XrplIdentity.address(sender)
        let hash = try XrplIdentity.hash(row["hash"]), fee = try XrplIdentity.uint(tx["Fee"])
        let height = try XrplIdentity.number(row["ledger_index"]), date = try XrplIdentity.number(tx["date"])
        var deltas:[String:String] = [:]
        for wrapper in nodes {
            let created = !wrapper["CreatedNode"].isNull, deleted = !wrapper["DeletedNode"].isNull
            let node = created ? wrapper["CreatedNode"]:deleted ? wrapper["DeletedNode"]:wrapper["ModifiedNode"]
            let fields = created ? node["NewFields"]:node["FinalFields"], previous = node["PreviousFields"]
            guard let type = node["LedgerEntryType"].string else { throw XrplError.malformed }
            var ref:String?, delta:String?
            if type == "AccountRoot", fields["Account"].string == owner {
                let final = try XrplIdentity.uint(fields["Balance"],max:"100000000000000000")
                let old = created ? "0":try XrplIdentity.uint(previous["Balance"].isNull ? fields["Balance"]:previous["Balance"],max:"100000000000000000")
                ref = "native"; delta = SuiIdentity.add(deleted ? "0":final,XrplIdentity.negate(old))
            } else if type == "RippleState" {
                guard let low = fields["LowLimit"]["issuer"].string, let high = fields["HighLimit"]["issuer"].string else { throw XrplError.malformed }
                if low == owner || high == owner {
                    guard let code = fields["Balance"]["currency"].string, let finalText = fields["Balance"]["value"].string else { throw XrplError.malformed }
                    ref = try XrplIdentity.reference(code+"."+(low == owner ? high:low))
                    let final = try XrplIdentity.issuedAmount(finalText)
                    let old = created ? "0":try XrplIdentity.issuedAmount(previous["Balance"]["value"].string ?? finalText)
                    let difference = SuiIdentity.add(deleted ? "0":final,XrplIdentity.negate(old))
                    delta = low == owner ? difference:XrplIdentity.negate(difference)
                }
            } else if type == "MPToken", fields["Account"].string == owner {
                guard let id = fields["MPTokenIssuanceID"].string else { throw XrplError.malformed }
                ref = try XrplIdentity.reference(id)
                let final = try XrplIdentity.uint(fields["MPTAmount"].isNull ? .string("0"):fields["MPTAmount"])
                let old = created ? "0":try XrplIdentity.uint(previous["MPTAmount"].isNull ? .string(final):previous["MPTAmount"])
                delta = SuiIdentity.add(deleted ? "0":final,XrplIdentity.negate(old))
            }
            if let ref, let delta { deltas[ref] = SuiIdentity.add(deltas[ref] ?? "0",delta) }
        }
        if sender == owner { deltas["native"] = SuiIdentity.add(deltas["native"] ?? "0",fee) }
        deltas = deltas.filter{$0.value != "0"}
        if deltas.isEmpty { deltas["native"] = "0" }
        let movements = try deltas.sorted{$0.key<$1.key}.map { ref,amount in
            let token = ref == "native" ? XrplToken.native:ref.contains(".") ? try XrplToken.issued(ref):tokens[ref]
            return XrplMovement(reference:ref,token:token,direction:amount == "0" ? "self":amount.hasPrefix("-") ? "outgoing":"incoming",amount:amount.hasPrefix("-") ? String(amount.dropFirst()):amount)
        }
        let destination = tx["Destination"].string
        let counterparty = ["Payment","AccountDelete"].contains(tx["TransactionType"].string ?? "") ? (sender == owner ? destination:destination == owner ? sender:nil):nil
        return try .init(hash:hash,checkpoint:height,timestamp:Double(date)+946684800,failed:result != "tesSUCCESS",fee:fee,owner:owner,counterparty:counterparty,movements:movements,raw:JSONEncoder().encode(row))
    }
}
