import Foundation

public enum TronDecoding {
    public static func transaction(hash: String, body: TronJSON, receipt: TronJSON, solidHeight: Int64 = .max, legacyAssetIDs: [String:String] = [:]) throws -> TronTransaction {
        guard TronIdentity.hash(hash), body["txID"].string == hash, receipt["id"].string == hash,
              let block = receipt["blockNumber"].integer, block <= Int64.max,
              let time = receipt["blockTimeStamp"].integer, time <= 9_007_199_254_740_991,
              let contracts = body["raw_data"]["contract"].array, !contracts.isEmpty else { throw TronError.incomplete }
        let results = body["ret"].array ?? []
        guard !results.isEmpty, results.allSatisfy({ $0["contractRet"].string != nil }) else { throw TronError.malformed }
        let failed = results.contains { $0["contractRet"].string != "SUCCESS" }
            || (!receipt["receipt"]["result"].isNull && receipt["receipt"]["result"].string != "SUCCESS")
        guard let owner = contracts.first?["parameter"]["value"]["owner_address"].string else { throw TronError.malformed }
        let payer = try TronIdentity.address(owner)
        var events: [TronEvent] = []
        func add(_ index: Int, _ reference: String, _ from: String, _ to: String, _ amount: TronJSON) throws {
            guard reference == "native" || TronIdentity.isToken(reference) else { throw TronError.malformed }
            events.append(.init(index: index, reference: reference, from: try TronIdentity.address(from), to: try TronIdentity.address(to), amount: try TronIdentity.quantity(amount)))
        }
        if !failed {
            for (i, contract) in contracts.enumerated() {
                let v = contract["parameter"]["value"]
                guard let from = v["owner_address"].string else { throw TronError.malformed }
                switch contract["type"].string {
                case "TransferContract":
                    guard let to = v["to_address"].string else { throw TronError.malformed }; try add(i,"native",from,to,v["amount"])
                case "TransferAssetContract":
                    guard let to = v["to_address"].string, let name = v["asset_name"].string else { throw TronError.malformed }
                    let id: String
                    if let resolved = legacyAssetIDs[name] { id = resolved }
                    else if TronIdentity.isTRC10(name) { id = name }
                    else { id = String(data: try TronIdentity.hex(name), encoding: .utf8) ?? "" }
                    try add(i,id,from,to,v["amount"])
                case "TriggerSmartContract":
                    guard let to = v["contract_address"].string else { throw TronError.malformed }
                    if !v["call_value"].isNull { try add(i,"native",from,to,v["call_value"]) }
                    if let id = v["token_id"].text, !v["call_token_value"].isNull { try add(100+i,id,from,to,v["call_token_value"]) }
                default: break // Staking, voting and permissions are retained as interactions.
                }
            }
            guard receipt["log"].isNull || receipt["log"].array != nil,
                  receipt["internal_transactions"].isNull || receipt["internal_transactions"].array != nil else { throw TronError.malformed }
            let logs = receipt["log"].array ?? []
            guard logs.count < 100_000 else { throw TronError.malformed }
            for (i, log) in logs.enumerated() {
                guard let topics = log["topics"].array else { throw TronError.malformed }
                // ERC/TRC721 Transfer has FOUR topics and is not a fungible balance.
                guard topics.count == 3, topics[0].string == "ddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef" else { continue }
                guard let address = log["address"].string, let from = topics[1].string, let to = topics[2].string, let data = log["data"].string else { throw TronError.malformed }
                try add(1_000+i,TronIdentity.address(address),from,to,.string(TronIdentity.uint256(data)))
            }
            let internals = receipt["internal_transactions"].array ?? []
            guard internals.count < 100_000 else { throw TronError.malformed }
            for (i, call) in internals.enumerated() where call["rejected"] != .bool(true) {
                guard let from = call["caller_address"].string, let to = call["transferTo_address"].string,
                      let values = call["callValueInfo"].array, values.count < 1_000 else { throw TronError.malformed }
                for (j, value) in values.enumerated() {
                    let ref = value["tokenId"].string ?? "native"
                    try add(1_000_000+i*1_000+j,ref,from,to,value["callValue"].isNull ? .number("0") : value["callValue"])
                }
            }
        }
        return .init(hash: hash, block: Int64(block), timestamp: Double(time)/1000, failed: failed, confirmed: Int64(block) <= solidHeight,
            fee: try TronIdentity.quantity(receipt["fee"].isNull ? .number("0") : receipt["fee"]), payer: payer,
            events: events, raw: try JSONEncoder().encode(TronJSON.object(["transaction": body,"receipt": receipt])))
    }
}
