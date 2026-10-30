import Foundation

public enum SuiDecoding {
    /// Addresses with actual debits/credits in the cached effects. Preserve
    /// multiple parties; net changes do not prove pairwise transfers in a PTB.
    /// Remove only the gas payer's fee/rebate before classifying either side.
    public static func parties(_ transaction: SuiTransaction) throws -> (from: [String], to: [String]) {
        let raw = try JSONDecoder().decode(SuiJSON.self, from: transaction.raw)
        // Older/local receipts can have no cached effects yet; absence is not
        // an address, and opening a receipt must not start another RPC request.
        guard let changes = raw["effects"]["balanceChangesJson"].array else { return ([], []) }
        var deltas: [String: [String: String]] = [:]
        for change in changes {
            guard let address = change["address"].string, let type = change["coinType"].string else { throw SuiError.malformed }
            let owner = try SuiIdentity.address(address), reference = try SuiIdentity.reference(type)
            let amount = try SuiIdentity.signed(change["amount"])
            deltas[owner, default: [:]][reference] = SuiIdentity.add(deltas[owner]?[reference] ?? "0", amount)
        }
        if let address = raw["gasInput"]["gasSponsor"]["address"].string {
            let sponsor = try SuiIdentity.address(address)
            deltas[sponsor, default: [:]]["native"] = SuiIdentity.add(deltas[sponsor]?["native"] ?? "0", transaction.netGas)
        }
        let from = deltas.filter { $0.value.values.contains(where: { $0.hasPrefix("-") }) }.keys.sorted()
        let to = deltas.filter { $0.value.values.contains(where: { $0 != "0" && !$0.hasPrefix("-") }) }.keys.sorted()
        return (from, to)
    }

    public static func transaction(_ value:SuiJSON, owner:String, tokens:[String:SuiToken]) throws -> SuiTransaction {
        let owner = try SuiIdentity.address(owner), effects = value["effects"]
        guard let hash = value["digest"].string, (40...50).contains(hash.count), hash.utf8.allSatisfy({Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz".utf8).contains($0)}),
              let status = effects["status"].string, ["SUCCESS","FAILURE"].contains(status),
              let time = effects["timestamp"].string,
              let changes = effects["balanceChangesJson"].array else { throw SuiError.malformed }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
        let date = formatter.date(from:time) ?? ISO8601DateFormatter().date(from:time)
        guard let date else { throw SuiError.malformed }
        let sender = try SuiIdentity.address(value["sender"]["address"].string ?? "0x0")
        let sponsor = try value["gasInput"]["gasSponsor"]["address"].string.map(SuiIdentity.address)
        let gas = effects["gasEffects"]["gasSummary"]
        let netGas = try SuiIdentity.add(SuiIdentity.add(SuiIdentity.amount(gas["computationCost"]),SuiIdentity.amount(gas["storageCost"])),"-"+SuiIdentity.amount(gas["storageRebate"]))
        var deltas:[String:String] = [:]
        for change in changes {
            guard let address = change["address"].string, let type = change["coinType"].string else { throw SuiError.malformed }
            if try SuiIdentity.address(address) == owner {
                let ref = try SuiIdentity.reference(type), amount = try SuiIdentity.signed(change["amount"])
                deltas[ref] = SuiIdentity.add(deltas[ref] ?? "0",amount)
            }
        }
        // Net SUI includes gas and rebates. Remove only this owner's gas,
        // never a sponsor's, when projecting the transferred amount.
        if sponsor == owner { deltas["native"] = SuiIdentity.add(deltas["native"] ?? "0",netGas) }
        if deltas.isEmpty && (sender == owner || sponsor == owner) { deltas["native"] = "0" }
        let movements = deltas.sorted(by:{$0.key < $1.key}).map { ref,amount in
            SuiMovement(reference:ref,token:tokens[ref],direction:amount == "0" ? "self" : amount.hasPrefix("-") ? "outgoing" : "incoming",amount:amount.hasPrefix("-") ? String(amount.dropFirst()):amount)
        }
        return .init(hash:hash,checkpoint:try SuiIdentity.number(effects["checkpoint"]["sequenceNumber"]),timestamp:date.timeIntervalSince1970,failed:status == "FAILURE",fee:sponsor == owner ? (netGas.hasPrefix("-") ? "0":netGas):nil,netGas:netGas,sender:sender,owner:owner,movements:movements,raw:try JSONEncoder().encode(value))
    }
}
