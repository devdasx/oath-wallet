import Foundation

/// ChainScan uses Conflux-style field names for its EVM index. Only discovery
/// and ordering come from this index; RPC supplies balances and receipt evidence.
enum ZeroGIndex {
    static let pageSize = 50

    static func query(owner: String, stream: IndexedEVMHistoryStream, cursor: [String: SolanaJSON],
                      from: Double, through: Double) throws -> [URLQueryItem] {
        guard from.isFinite, through.isFinite, from >= 0, through >= from, through < 1e12,
              Set(cursor.keys).isSubset(of: ["height", "skip"]),
              cursor.isEmpty || (cursor["height"] != nil && cursor["skip"] != nil) else { throw AnkrError.invalidResponse }
        var query = [URLQueryItem(name: "accountAddress", value: try IndexedEVMIdentity.address(owner)),
            .init(name: "limit", value: String(pageSize)), .init(name: "sort", value: "DESC"),
            .init(name: "minTimestamp", value: String(Int64(from.rounded(.down)))),
            .init(name: "maxTimestamp", value: String(Int64(through.rounded(.up))))]
        if stream != .transactions { query.append(.init(name: "transferType", value: stream == .transfers ? "ERC20" : "CFX")) }
        if !cursor.isEmpty {
            let height = try IndexedEVMIdentity.height(cursor["height"]!)
            let skip = try IndexedEVMIdentity.height(cursor["skip"]!)
            guard skip > 0, skip <= 10_000 else { throw AnkrError.incompleteInventory }
            query += [.init(name: "maxEpochNumber", value: String(height)), .init(name: "skip", value: String(skip))]
        }
        return query
    }
    static func result(_ json: SolanaJSON) throws -> SolanaJSON {
        guard let status = json["status"].string else { throw AnkrError.invalidResponse }
        if status != "1", let code = Int(status) { throw AnkrError.rpc(code) }
        guard status == "1", !json["result"].isNull else { throw AnkrError.invalidResponse }
        return json["result"]
    }
    static func token(_ row: SolanaJSON) throws -> SolanaJSON? {
        guard let type = row["transferType"].string ?? row["tokenType"].string else { throw AnkrError.invalidResponse }
        guard type == "ERC20" else {
            guard ["ERC721", "ERC1155", "ERC3525"].contains(type) else { throw AnkrError.invalidResponse }
            return nil
        }
        guard let address = row["address"].string else { throw AnkrError.invalidResponse }
        return .object(["type": .string("ERC-20"), "address_hash": .string(try IndexedEVMIdentity.address(address)),
            "name": row["name"], "symbol": row["symbol"], "decimals": row["decimals"], "icon_url": row["iconUrl"]])
    }
    static func inventory(_ json: SolanaJSON) throws -> SolanaJSON {
        let value = try result(json)
        guard let rows = value["list"].array, rows.count <= 10_000,
              value["total"].text.flatMap(Int.init) == rows.count else { throw AnkrError.incompleteInventory }
        // This endpoint returns the entire address inventory and ignores limit/skip.
        // Check its declared total before accepting an empty or truncated response.
        return .object(["items": .array(try rows.compactMap { row in
            try token(row).map { .object(["token": $0]) }
        }), "next_page_params": .null])
    }
    static func history(_ json: SolanaJSON, stream: IndexedEVMHistoryStream,
                        cursor: [String: SolanaJSON]) throws -> SolanaJSON {
        let value = try result(json)
        guard let rows = value["list"].array, rows.count <= pageSize,
              let total = value["total"].text.flatMap(Int.init), total >= rows.count else { throw AnkrError.invalidResponse }
        let heights = try rows.map { try IndexedEVMIdentity.height($0["epochNumber"]) }
        guard zip(heights, heights.dropFirst()).allSatisfy({ $0 >= $1 }) else { throw AnkrError.invalidResponse }
        if let max = cursor["height"] {
            let limit = try IndexedEVMIdentity.height(max)
            guard heights.allSatisfy({ $0 <= limit }) else { throw AnkrError.invalidResponse }
        }
        let next: SolanaJSON
        if rows.count < pageSize {
            let skip = cursor["skip"]?.text.flatMap(Int.init) ?? 0
            guard total <= skip + rows.count else { throw AnkrError.incompleteInventory }
            next = .null
        }
        else {
            guard let height = heights.last else { throw AnkrError.invalidResponse }
            let priorSkip = cursor["height"]?.text == String(height) ? cursor["skip"]?.text.flatMap(Int.init) ?? 0 : 0
            let skip = priorSkip + heights.filter { $0 == height }.count
            guard skip <= 10_000 else { throw AnkrError.incompleteInventory }
            next = .object(["height": .number(String(height)), "skip": .number(String(skip))])
        }
        let items = try rows.compactMap { row -> SolanaJSON? in
            let external = stream == .transactions
            guard let hash = row[external ? "hash" : "transactionHash"].string, AnkrQuantity.hash(hash),
                  let seconds = row["timestamp"].text.flatMap(Double.init), seconds.isFinite, seconds >= 0, seconds < 1e12 else { throw AnkrError.invalidResponse }
            let time = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: seconds))
            var fields: [String: SolanaJSON] = [external ? "hash" : "transaction_hash": .string(hash),
                "block_number": row["epochNumber"], "timestamp": .string(time),
                "from": .object(["hash": row["from"]]), "to": row["to"].isNull ? .null : .object(["hash": row["to"]]),
                "value": row["value"]]
            if external {
                guard let status = row["status"].integer, [0, 1].contains(status) else { throw AnkrError.invalidResponse }
                fields["status"] = .string(status == 0 ? "ok" : "error")
                // List responses use "0" when the block hash is omitted. A real
                // hash, when supplied, must agree with the RPC receipt.
                if row["blockHash"].string != "0" { fields["block_hash"] = row["blockHash"] }
                fields["created_contract"] = row["contractCreated"].isNull ? .null : .object(["hash": row["contractCreated"]])
            } else if stream == .transfers {
                guard let token = try token(row["transferTokenInfo"]), let index = row["txLogIndex"].integer else { throw AnkrError.invalidResponse }
                fields["token"] = token
                fields["total"] = .object(["value": row["value"], "decimals": token["decimals"]])
                fields["log_index"] = .number(String(index))
                fields["transaction_log_index"] = .number(String(index))
            } else {
                guard let index = row["txLogIndex"].integer, let type = row["type"].string else { throw AnkrError.invalidResponse }
                // ChainScan includes the external call in the native transfer
                // endpoint. Keep it only in the transaction stream.
                if index == 0 || ["delegatecall", "staticcall", "callcode"].contains(type.lowercased()) { return nil }
                guard ["call", "create", "create2", "suicide", "selfdestruct"].contains(type.lowercased()) else { throw AnkrError.invalidResponse }
                if try IndexedEVMIdentity.amount(row["value"]) == "0" { return nil }
                fields["index"] = .number(String(index))
                fields["success"] = .bool(true)
            }
            return .object(fields)
        }
        return .object(["items": .array(items), "next_page_params": next])
    }
}
