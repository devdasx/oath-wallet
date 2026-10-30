import Foundation

/// Adapts Seistream's EVM index to the receipt-verified history pipeline.
/// The index discovers contracts; balances and decimals are read from RPC.
enum SeiIndex {
    static func parameters(_ cursor: [String: SolanaJSON], limit: Int = 50) throws -> [URLQueryItem] {
        guard Set(cursor.keys).isSubset(of: ["cursor", "offset", "type"]),
              cursor["cursor"] == nil || cursor["offset"] == nil else { throw AnkrError.invalidResponse }
        guard [10, 50].contains(limit) else { throw AnkrError.invalidResponse }
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let value = cursor["cursor"] {
            guard let text = value.string, !text.isEmpty, text.utf8.count <= 2048 else { throw AnkrError.invalidResponse }
            query.append(.init(name: "cursor", value: text))
        }
        if let value = cursor["offset"] {
            guard let offset = value.text.flatMap(Int.init), (0...100_000).contains(offset) else { throw AnkrError.invalidResponse }
            query.append(.init(name: "offset", value: String(offset)))
        }
        return query
    }
    static func token(_ row: SolanaJSON) throws -> SolanaJSON? {
        guard let type = row["tokenType"].string else { throw AnkrError.invalidResponse }
        guard type == "erc20" else {
            guard ["erc721", "erc1155", "erc404"].contains(type) else { throw AnkrError.invalidResponse }
            return nil
        }
        guard let address = row["address"].string ?? row["hash"].string else { throw AnkrError.invalidResponse }
        let reference = try IndexedEVMIdentity.address(address)
        let image = row["image"].string ?? row["iconUrl"].string
        let logo = image.flatMap { value -> String? in
            if value.hasPrefix("/api/v2/icons/") { return "https://api-v2.seistream.app" + value }
            return value.hasPrefix("https://") ? value : nil
        }
        return .object(["type": .string("ERC-20"), "address_hash": .string(reference),
            "name": row["name"], "symbol": row["symbol"], "decimals": row["decimals"],
            "icon_url": logo.map(SolanaJSON.string) ?? .null])
    }
    static func corroborateInternal(_ row: SolanaJSON, traces: SolanaJSON) throws -> Bool {
        guard let records = traces.array, records.count <= 10_000,
              let index = row["index"].text.flatMap(Int.init), records.indices.contains(index), index > 0,
              let hash = row["transaction_hash"].string?.lowercased() else { throw AnkrError.invalidResponse }
        let trace = records[index], action = trace["action"]
        func path(_ value: SolanaJSON) throws -> [String] {
            guard let steps = value["traceAddress"].array, steps.count <= 1024 else { throw AnkrError.invalidResponse }
            return try steps.map {
                guard let number = $0.integer else { throw AnkrError.invalidResponse }
                return String(number)
            }
        }
        let location = try path(trace)
        guard !location.isEmpty else { throw AnkrError.invalidResponse }
        var byPath: [String: SolanaJSON] = [:]
        for record in records {
            guard record["transactionHash"].string?.lowercased() == hash else { throw AnkrError.invalidResponse }
            let key = try path(record).joined(separator: ".")
            guard byPath.updateValue(record, forKey: key) == nil else { throw AnkrError.invalidResponse }
        }
        var success = true
        for depth in 0...location.count {
            guard let ancestor = byPath[location.prefix(depth).joined(separator: ".")] else { throw AnkrError.invalidResponse }
            if !ancestor["error"].isNull { success = false }
        }
        let sender: SolanaJSON, receiver: SolanaJSON, amount: SolanaJSON
        switch trace["type"].string {
        case "call":
            guard action["callType"].string == "call" else { throw AnkrError.invalidResponse }
            sender = action["from"]; receiver = action["to"]; amount = action["value"]
        case "create":
            sender = action["from"]; receiver = trace["result"]["address"]; amount = action["value"]
        case "suicide":
            sender = action["address"]; receiver = action["refundAddress"]; amount = action["balance"]
        default: throw AnkrError.invalidResponse
        }
        guard sender.string?.lowercased() == row["from"]["hash"].string?.lowercased(),
              (receiver.string?.lowercased() == row["to"]["hash"].string?.lowercased() || (!success && trace["type"].string == "create" && receiver.isNull)),
              try IndexedEVMIdentity.amount(amount) == IndexedEVMIdentity.amount(row["value"]) else { throw AnkrError.invalidResponse }
        return success
    }
    static func normalize(_ json: SolanaJSON, resource: String) throws -> SolanaJSON {
        guard let rows = json["items"].array, rows.count <= 50,
              case .bool(let more) = json["pagination"]["hasMore"] else { throw AnkrError.invalidResponse }
        let next: SolanaJSON
        if !more { next = .null }
        else {
            guard !rows.isEmpty else { throw AnkrError.incompleteInventory }
            if let cursor = json["pagination"]["nextCursor"].string, !cursor.isEmpty, cursor.utf8.count <= 2048 {
                next = .object(["cursor": .string(cursor)])
            } else {
                guard let offset = json["pagination"]["offset"].text.flatMap(Int.init), offset >= 0,
                      offset + rows.count <= 100_000 else { throw AnkrError.incompleteInventory }
                next = .object(["offset": .number(String(offset + rows.count))])
            }
        }
        let items = try rows.compactMap { row -> SolanaJSON? in
            if resource == "tokens" {
                guard let metadata = try token(row["token"]) else { return nil }
                return .object(["token": metadata])
            }
            let external = resource == "transactions"
            guard ["transactions", "token-transfers", "internal-transactions"].contains(resource) else { throw AnkrError.invalidResponse }
            var fields: [String: SolanaJSON] = [
                external ? "hash" : "transaction_hash": row[external ? "hash" : "txHash"],
                "block_number": row["height"], "timestamp": row["timestamp"],
                "from": .object(["hash": row["from"]]),
                "to": row["to"].isNull ? .null : .object(["hash": row["to"]]), "value": row["value"]
            ]
            if external {
                guard case .bool(let status) = row["status"] else { throw AnkrError.invalidResponse }
                fields["status"] = .string(status ? "ok" : "error")
                fields["block_hash"] = row["blockHash"]
                fields["created_contract"] = row["contractAddress"].isNull ? .null : .object(["hash": row["contractAddress"]])
            } else if resource == "token-transfers" {
                guard let metadata = try token(row["token"]) else { return nil }
                fields["token"] = metadata
                fields["total"] = .object(["value": row["value"], "decimals": metadata["decimals"]])
                fields["log_index"] = row["logIndex"]
            } else {
                guard let index = row["index"].text.flatMap(Int.init), index >= 0,
                      let type = row["callType"].string ?? row["type"].string else { throw AnkrError.invalidResponse }
                // The root belongs to the external stream. Delegate/static calls
                // carry call context but do not move a second native balance.
                if index == 0 || row["parentIndex"].text == "-1" || ["DELEGATECALL", "STATICCALL", "CALLCODE"].contains(type.uppercased()) { return nil }
                guard ["CALL", "CREATE", "CREATE2", "SELFDESTRUCT", "SUICIDE"].contains(type.uppercased()) else { throw AnkrError.invalidResponse }
                if try IndexedEVMIdentity.amount(row["value"]) == "0" { return nil }
                fields["index"] = row["index"]
                fields["success"] = .bool(row["error"].isNull && row["revertReason"].isNull)
            }
            return .object(fields)
        }
        return .object(["items": .array(items), "next_page_params": next])
    }
}
