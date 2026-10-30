import OathDiagnostics
import Foundation

private extension SolanaJSON {
    var object: [String: SolanaJSON]? { if case .object(let value) = self { return value }; return nil }
}

/// Batched, block-pinned state reads with Blockscout or Alchemy address history.
/// Alchemy currently exposes external/ERC-20 history, not Robinhood internals.
public struct RobinhoodClient: Sendable {
    private let endpoint: URL
    private let blockscoutKey: String?
    private let alchemy: AlchemyHistoryClient?
    public var historyStreams: [RobinhoodHistoryStream] {
        blockscoutKey == nil && alchemy != nil ? [.transactions, .transfers] : RobinhoodHistoryStream.allCases
    }
    private let transport: any AnkrTransport
    private let permits = AnkrPermits(count: 4)
    private let indexPermits = AnkrPermits(count: 1)
    public init(apiKey: String, blockscoutKey: String? = nil, alchemyAPIKey: String? = nil,
                transport: any AnkrTransport = AnkrHTTPTransport()) throws {
        guard !apiKey.isEmpty, apiKey.count <= 256, apiKey.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }) else {
            throw AnkrError.configurationMissing
        }
        if let blockscoutKey, !blockscoutKey.isEmpty {
            guard blockscoutKey.count <= 256, blockscoutKey.utf8.allSatisfy({ (33...126).contains($0) }) else { throw AnkrError.configurationMissing }
            self.blockscoutKey = blockscoutKey
        } else { self.blockscoutKey = nil }
        endpoint = URL(string: "https://rpc.ankr.com/robinhood_mainnet")!.appendingPathComponent(apiKey)
        self.transport = transport
        alchemy = try alchemyAPIKey.flatMap { $0.isEmpty ? nil : try AlchemyHistoryClient(network: .robinhood, apiKey: $0, transport: transport) }
    }
    private struct Exchange: Sendable { let value: SolanaJSON; let raw: Data }
    private func exchange(_ request: URLRequest) async throws -> Exchange {
        try await OathDiagnostics.withChain("robinhood") {
            try await exchangeInContext(request)
        }
    }
    private func exchangeInContext(_ request: URLRequest) async throws -> Exchange {
        for attempt in 0..<3 {
            try Task.checkCancellation()
            do {
                let (data, status) = try await transport.send(request)
                guard data.count <= 64 * 1024 * 1024 else { throw AnkrError.responseTooLarge }
                guard status == 200 else { throw AnkrError.http(status) }
                return Exchange(value: try JSONDecoder().decode(SolanaJSON.self, from: data), raw: data)
            } catch { OathDiagnostics.record(error);
                let retry: Bool
                switch error {
                case AnkrError.http(let code): retry = code == 429 || (500...599).contains(code)
                case AnkrError.transport: retry = true
                default: retry = false
                }
                if retry, attempt < 2 { try await Task.sleep(for: .milliseconds(500 * (1 << attempt))); continue }
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                throw (error as? AnkrError) ?? .invalidResponse
            }
        }
        throw AnkrError.transport
    }
    private func rpc(_ calls: [(String, [SolanaJSON])]) async throws -> ([SolanaJSON], Data) {
        guard !calls.isEmpty, calls.count <= 30 else { throw AnkrError.invalidResponse }
        let body = SolanaJSON.array(calls.enumerated().map { i, call in
            .object(["jsonrpc": .string("2.0"), "id": .number(String(i + 1)), "method": .string(call.0), "params": .array(call.1)])
        })
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        try await permits.acquire()
        do {
            let result = try await exchange(request)
            guard let rows = result.value.array, rows.count == calls.count else { throw AnkrError.invalidResponse }
            var ordered = [SolanaJSON?](repeating: nil, count: calls.count)
            for row in rows {
                guard row["jsonrpc"].string == "2.0", let id = row["id"].integer,
                      id > 0, id <= calls.count, ordered[Int(id - 1)] == nil else { throw AnkrError.invalidResponse }
                ordered[Int(id - 1)] = row
            }
            await permits.release()
            return (ordered.map { $0! }, result.raw)
        } catch { OathDiagnostics.record(error); await permits.release(); throw error }
    }
    private static func result(_ row: SolanaJSON) throws -> SolanaJSON {
        if let code = row["error"]["code"].text.flatMap(Int.init) { throw AnkrError.rpc(code) }
        guard case .object(let object) = row, let result = object["result"], !result.isNull else { throw AnkrError.invalidResponse }
        return result
    }
    private func index(path: String, params: [String: SolanaJSON] = [:]) async throws -> Exchange {
        guard let blockscoutKey else { throw AnkrError.configurationMissing }
        var url = URLComponents(string: "https://api.blockscout.com/4663/api/v2/" + path)!
        url.queryItems = try params.sorted { $0.key < $1.key }.map { key, value in
            let scalar: String?
            if value.isNull { scalar = "" }
            else if case .bool(let flag) = value { scalar = flag ? "true" : "false" }
            else { scalar = value.text }
            guard key.count <= 80, key != "apikey", key != "chainid", let text = scalar, text.count <= 1024 else { throw AnkrError.invalidResponse }
            return URLQueryItem(name: key, value: text)
        }
        var request = URLRequest(url: url.url!); request.setValue("Bearer " + blockscoutKey, forHTTPHeaderField: "Authorization")
        // The free indexer tier allows 5 requests/second. State batches use a
        // separate pool, so index pagination never blocks ANKR balance reads.
        try await indexPermits.acquire()
        do {
            try await Task.sleep(for: .milliseconds(220))
            let value = try await exchange(request); await indexPermits.release(); return value
        } catch { OathDiagnostics.record(error); await indexPermits.release(); throw error }
    }
    static func next(_ json: SolanaJSON) throws -> String? {
        guard case .object(let object) = json, let next = object["next_page_params"] else { throw AnkrError.invalidResponse }
        if next.isNull { return nil }
        guard case .object(let params) = next, !params.isEmpty, params.count <= 20 else { throw AnkrError.invalidResponse }
        let data = try JSONEncoder().encode(next)
        guard data.count <= 8_192 else { throw AnkrError.invalidResponse }
        return data.base64EncodedString()
    }
    private static func cursor(_ text: String?) throws -> [String: SolanaJSON] {
        guard let text else { return [:] }
        guard text.count <= 12_000, let bytes = Data(base64Encoded: text),
              case .object(let object) = try JSONDecoder().decode(SolanaJSON.self, from: bytes) else { throw AnkrError.invalidResponse }
        return object
    }
    private func discover(owner: String) async throws -> ([RobinhoodToken], [Data]) {
        if blockscoutKey == nil, let alchemy { return try await alchemyDiscovery(alchemy, owner: owner) }
        var cursor: String?, visited: Set<String> = [], tokens: [String: RobinhoodToken] = [:], raw: [Data] = []
        repeat {
            var params = try Self.cursor(cursor); params["type"] = .string("ERC-20")
            let response = try await index(path: "addresses/" + owner + "/tokens", params: params)
            guard let items = response.value["items"].array else { throw AnkrError.invalidResponse }
            raw.append(response.raw)
            for item in items {
                let token = try RobinhoodToken.decode(item["token"])
                guard tokens[token.reference] == nil else { throw AnkrError.incompleteInventory }
                tokens[token.reference] = token
            }
            cursor = try Self.next(response.value)
            if let cursor, !visited.insert(cursor).inserted { throw AnkrError.paginationLoop }
            guard tokens.count <= 100_000, raw.reduce(0, { $0 + $1.count }) <= 64 * 1024 * 1024 else { throw AnkrError.responseTooLarge }
        } while cursor != nil
        return (tokens.values.sorted { $0.reference < $1.reference }, raw)
    }
    public func inventory(owner: String, tracked: [RobinhoodToken] = []) async throws -> RobinhoodInventory {
        let owner = try RobinhoodIdentity.address(owner)
        async let discovery = await OathDiagnostics.attempt("token_discovery") { try await discover(owner: owner) }
        let (head, headRaw) = try await rpc([("eth_chainId", []), ("eth_getBlockByNumber", [.string("latest"), .bool(false)])])
        guard try RobinhoodIdentity.amount(Self.result(head[0])) == String(RobinhoodIdentity.chainID) else { throw AnkrError.wrongChain }
        let block = try Self.result(head[1]), height = try RobinhoodIdentity.height(block["number"])
        guard let blockNumber = block["number"].string, let hash = block["hash"].string, AnkrQuantity.hash(hash) else { throw AnkrError.invalidResponse }
        let discovered = await discovery
        try Task.checkCancellation()
        var tokens = Dictionary((discovered?.0 ?? []).map { ($0.reference, $0) }, uniquingKeysWith: { first, _ in first })
        for token in tracked where token.reference != "native" {
            if let indexed = tokens[token.reference], indexed.decimals != token.decimals { throw AnkrError.invalidResponse }
            tokens[token.reference] = tokens[token.reference] ?? token
        }
        // Also re-read cached contracts absent from the index, to reconcile
        // zeroes without trusting an asynchronously updated token list.
        let list = [RobinhoodToken.native] + tokens.values.sorted { $0.reference < $1.reference }
        let chunks = stride(from: 0, to: list.count, by: 15).map { Array(list[$0..<min($0 + 15, list.count)]) }
        let body = "0x70a08231" + String(repeating: "0", count: 24) + owner.dropFirst(2)
        let gathered = try await withThrowingTaskGroup(of: ([RobinhoodHolding], Data).self) { group in
            var next = 0, output: [RobinhoodHolding] = [], raw: [Data] = []
            func enqueue() {
                guard next < chunks.count else { return }
                let chunk = chunks[next]; next += 1
                group.addTask {
                    var calls: [(String, [SolanaJSON])] = []
                    for token in chunk {
                        if token.reference == "native" { calls.append(("eth_getBalance", [.string(owner), .string(blockNumber)])) }
                        else {
                            calls.append(("eth_call", [.object(["to": .string(token.reference), "data": .string(body)]), .string(blockNumber)]))
                            calls.append(("eth_call", [.object(["to": .string(token.reference), "data": .string("0x313ce567")]), .string(blockNumber)]))
                        }
                    }
                    let (rows, raw) = try await rpc(calls)
                    var i = 0, holdings: [RobinhoodHolding] = []
                    for token in chunk {
                        var amount = try? RobinhoodIdentity.amount(Self.result(rows[i])); i += 1
                        if token.reference != "native" {
                            let decimals = try? RobinhoodIdentity.amount(Self.result(rows[i])); i += 1
                            if decimals != String(token.decimals) { amount = nil }
                        }
                        holdings.append(.init(token: token, amount: amount))
                    }
                    return (holdings, raw)
                }
            }
            for _ in 0..<min(4, chunks.count) { enqueue() }
            for try await value in group { output += value.0; raw.append(value.1); enqueue() }
            return (output, raw)
        }
        guard gathered.0.first(where: { $0.token.reference == "native" })?.amount != nil else { throw AnkrError.invalidResponse }
        // Refuse a mixed snapshot if the pinned block was reorganized while
        // batches were in flight. Cached balances remain untouched on failure.
        let (check, checkRaw) = try await rpc([("eth_getBlockByNumber", [.string(blockNumber), .bool(false)])])
        guard try Self.result(check[0])["hash"].string == hash else { throw AnkrError.invalidResponse }
        let archive = try JSONEncoder().encode(["head": [headRaw, checkRaw], "index": discovered?.1 ?? [], "state": gathered.1])
        return .init(owner: owner, block: height, blockHash: hash, observedAt: .now,
                     holdings: gathered.0, complete: discovered != nil && gathered.0.allSatisfy { $0.amount != nil }, raw: archive)
    }
    public func history(owner: String, stream: RobinhoodHistoryStream, cursor: String? = nil,
                        from: Double = 0, through: Double = Date().timeIntervalSince1970) async throws -> RobinhoodHistoryPage {
        let owner = try RobinhoodIdentity.address(owner)
        var params = try Self.cursor(cursor)
        if stream == .transfers { params["type"] = .string("ERC-20") }
        let usesAlchemy = blockscoutKey == nil && alchemy != nil
        let response: Exchange
        if usesAlchemy { response = try await alchemyHistory(alchemy!, owner: owner, stream: stream, cursor: cursor) }
        else { response = try await index(path: "addresses/" + owner + "/" + (stream == .transfers ? "token-transfers" : stream.rawValue), params: params) }
        // Older Blockscout transfer responses omit block_number. Receipts
        // also independently verify indexed ERC-20 events against ANKR.
        guard var document = response.value.object, let rows = document["items"]?.array else { throw AnkrError.invalidResponse }
        let hashes = try Set(rows.compactMap { row -> String? in
            if row["timestamp"].isNull, stream == .transactions, row["block_number"].isNull { return nil }
            guard let hash = row[stream == .transactions ? "hash" : "transaction_hash"].string, AnkrQuantity.hash(hash) else { throw AnkrError.invalidResponse }
            return hash.lowercased()
        }).sorted()
        var receipts: [String: SolanaJSON] = [:], receiptRaw: [Data] = []
        for offset in stride(from: 0, to: hashes.count, by: 29) {
            let batch = Array(hashes[offset..<min(offset + 29, hashes.count)])
            let (replies, raw) = try await rpc([("eth_chainId", [])] + batch.map { ("eth_getTransactionReceipt", [.string($0)]) })
            guard try RobinhoodIdentity.amount(Self.result(replies[0])) == String(RobinhoodIdentity.chainID) else { throw AnkrError.wrongChain }
            receiptRaw.append(raw)
            for (i, hash) in batch.enumerated() {
                let receipt = try Self.result(replies[i + 1])
                guard receipt["transactionHash"].string?.lowercased() == hash else { throw AnkrError.invalidResponse }
                receipts[hash] = receipt
            }
        }
        var minedTransactions: [String: SolanaJSON] = [:]
        if usesAlchemy && stream == .transactions {
            for offset in stride(from: 0, to: hashes.count, by: 29) {
                let batch = Array(hashes[offset..<min(offset + 29, hashes.count)])
                let (replies, raw) = try await rpc([("eth_chainId", [])] + batch.map { ("eth_getTransactionByHash", [.string($0)]) })
                guard try RobinhoodIdentity.amount(Self.result(replies[0])) == String(RobinhoodIdentity.chainID) else { throw AnkrError.wrongChain }
                receiptRaw.append(raw)
                for (i, hash) in batch.enumerated() { minedTransactions[hash] = try Self.result(replies[i + 1]) }
            }
        }
        var enriched: [SolanaJSON] = []
        for row in rows {
            if row["timestamp"].isNull, stream == .transactions, row["block_number"].isNull { continue }
            guard var value = row.object, let hash = row[stream == .transactions ? "hash" : "transaction_hash"].string?.lowercased(),
                  let receipt = receipts[hash] else { throw AnkrError.invalidResponse }
            let height = try RobinhoodIdentity.height(receipt["blockNumber"])
            if !row["block_number"].isNull, try RobinhoodIdentity.height(row["block_number"]) != height { throw AnkrError.invalidResponse }
            if let indexedHash = row["block_hash"].string, indexedHash.lowercased() != receipt["blockHash"].string?.lowercased() { throw AnkrError.invalidResponse }
            value["block_number"] = .number(String(height))
            let status = try RobinhoodIdentity.amount(receipt["status"])
            guard status == "0" || status == "1" else { throw AnkrError.invalidResponse }
            if stream == .transactions {
                if usesAlchemy {
                    guard let mined = minedTransactions[hash], mined["hash"].string?.lowercased() == hash,
                          mined["blockHash"].string?.lowercased() == receipt["blockHash"].string?.lowercased(),
                          try RobinhoodIdentity.height(mined["blockNumber"]) == height,
                          mined["from"].string?.lowercased() == row["from"]["hash"].string?.lowercased(),
                          mined["to"].string?.lowercased() == row["to"]["hash"].string?.lowercased(),
                          try RobinhoodIdentity.amount(mined["value"]) == RobinhoodIdentity.amount(row["value"]) else { throw AnkrError.invalidResponse }
                }
                value["status"] = .string(status == "1" ? "ok" : "error")
                if row["to"]["hash"].isNull, let created = receipt["contractAddress"].string {
                    value["created_contract"] = .object(["hash": .string(try RobinhoodIdentity.address(created))])
                }
                let fee = try AnkrQuantity.multiply(RobinhoodIdentity.amount(receipt["gasUsed"]), RobinhoodIdentity.amount(receipt["effectiveGasPrice"]))
                value["fee"] = .object(["type": .string("actual"), "value": .string(fee)])
            } else if stream == .transfers {
                guard status == "1", let logs = receipt["logs"].array,
                      let log = logs.first(where: { (try? RobinhoodIdentity.amount($0["logIndex"])) == row["log_index"].text }),
                      let topics = log["topics"].array, topics.count == 3,
                      topics[0].string?.lowercased() == "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef",
                      log["address"].string?.lowercased() == row["token"]["address_hash"].string?.lowercased(),
                      topics[1].string?.suffix(40).lowercased() == row["from"]["hash"].string?.dropFirst(2).lowercased(),
                      topics[2].string?.suffix(40).lowercased() == row["to"]["hash"].string?.dropFirst(2).lowercased(),
                      try RobinhoodIdentity.amount(log["data"]) == RobinhoodIdentity.amount(row["total"]["value"]) else { throw AnkrError.invalidResponse }
            } else if status == "0" { value["success"] = .bool(false) }
            enriched.append(.object(value))
        }
        document["items"] = .array(enriched)
        let decoded = try Self.decodeHistory(JSONEncoder().encode(SolanaJSON.object(document)), owner: owner, stream: stream, from: from, through: through)
        // Reaching the old end of outgoing history must still visit incoming.
        var next = decoded.next
        if usesAlchemy, next == nil, try Self.cursor(cursor)["direction"]?.string != "in" {
            next = try Self.next(.object(["next_page_params": .object(["provider": .string("alchemy"), "direction": .string("in")])]))
        }
        return .init(events: decoded.events, next: next,
                     raw: try JSONEncoder().encode(["index": [response.raw], "receipts": receiptRaw]))
    }
    public static func decodeHistory(_ data: Data, owner: String, stream: RobinhoodHistoryStream,
                                     from: Double = 0, through: Double = Date().timeIntervalSince1970) throws -> RobinhoodHistoryPage {
        let owner = try RobinhoodIdentity.address(owner), json = try JSONDecoder().decode(SolanaJSON.self, from: data)
        guard let rows = json["items"].array, from >= 0, through >= from else { throw AnkrError.invalidResponse }
        var events: [RobinhoodEvent] = [], crossed = false, last = Double.infinity, ids: Set<String> = []
        for row in rows {
            // Pending transactions have no ledger timestamp; they are fetched
            // again at the head after confirmation rather than advancing time.
            if row["timestamp"].isNull, stream == .transactions, row["block_number"].isNull { continue }
            let date = try RobinhoodIdentity.timestamp(row["timestamp"])
            guard date <= last else { throw AnkrError.invalidResponse }; last = date
            if date < from { crossed = true; continue }
            if date > through { continue }
            guard let hash = row[stream == .transactions ? "hash" : "transaction_hash"].string,
                  AnkrQuantity.hash(hash), let sender = row["from"]["hash"].string else { throw AnkrError.invalidResponse }
            let receiver = row["to"]["hash"].string ?? row["created_contract"]["hash"].string ?? "0x" + String(repeating: "0", count: 40)
            let senderAddress = try RobinhoodIdentity.address(sender), recipient = try RobinhoodIdentity.address(receiver)
            guard senderAddress == owner || recipient == owner else { throw AnkrError.wrongAccount }
            let height = try RobinhoodIdentity.height(row["block_number"])
            var token = RobinhoodToken.native, amount: String, failed = false, fee: String?, index = "external"
            switch stream {
            case .transactions:
                guard ["ok", "error"].contains(row["status"].string) else { throw AnkrError.invalidResponse }
                failed = row["status"].string == "error"; amount = try RobinhoodIdentity.amount(row["value"])
                if !row["fee"]["value"].isNull { fee = try RobinhoodIdentity.amount(row["fee"]["value"]) }
            case .transfers:
                token = try RobinhoodToken.decode(row["token"])
                guard row["total"]["decimals"].text == String(token.decimals) else { throw AnkrError.invalidResponse }
                amount = try RobinhoodIdentity.amount(row["total"]["value"])
                index = "log:" + String(try RobinhoodIdentity.height(row["log_index"]))
            case .internalTransactions:
                guard case .bool(let success) = row["success"] else { throw AnkrError.invalidResponse }
                failed = !success; amount = try RobinhoodIdentity.amount(row["value"])
                // Blockscout's transaction-local index is stable across pages.
                index = "internal:" + String(try RobinhoodIdentity.height(row["index"]))
                // Blockscout omits the root call in the address internals
                // endpoint. Index zero can be a genuine contract transfer.
            }
            let id = hash.lowercased() + ":" + index
            guard ids.insert(id).inserted else { throw AnkrError.invalidResponse }
            events.append(.init(id: id, hash: hash.lowercased(), block: height, timestamp: date,
                                token: token, amount: failed ? "0" : amount, from: senderAddress, to: recipient,
                                failed: failed, fee: fee, raw: try JSONEncoder().encode(row)))
        }
        let next = try next(json)
        return .init(events: events, next: crossed ? nil : next, raw: data)
    }
}

private extension RobinhoodClient {
    func alchemyTokens(_ index: AlchemyHistoryClient, references: Set<String>) async throws -> [String: RobinhoodToken] {
        var tokens: [String: RobinhoodToken] = [:]
        let refs = references.sorted()
        for offset in stride(from: 0, to: refs.count, by: 9) {
            let chunk = Array(refs[offset..<min(offset + 9, refs.count)])
            let calls: [(String, [SolanaJSON])] = [("eth_chainId", [])] + chunk.flatMap { ref in
                ["0x313ce567", "0x06fdde03", "0x95d89b41"].map { selector in
                    ("eth_call", [.object(["to": .string(ref), "data": .string(selector)]), .string("latest")])
                }
            }
            let (rows, _) = try await rpc(calls)
            guard try RobinhoodIdentity.amount(Self.result(rows[0])) == String(RobinhoodIdentity.chainID) else { throw AnkrError.wrongChain }
            for (i, ref) in chunk.enumerated() {
                let base = 1 + i * 3
                guard let decimals = Int(try RobinhoodIdentity.amount(Self.result(rows[base]))), (0...255).contains(decimals) else { throw AnkrError.invalidResponse }
                // ERC-20 name/symbol are optional ABI metadata, not evidence of
                // identity. An absent label must not invent a balance of zero.
                let fallback = String(ref.prefix(8)) + "…" + ref.suffix(4)
                let name = try? Self.result(rows[base + 1]).string.flatMap { try? TronIdentity.abiString($0) }
                let symbol = try? Self.result(rows[base + 2]).string.flatMap { try? TronIdentity.abiString($0) }
                tokens[ref] = try RobinhoodToken(reference: ref, name: name ?? fallback, symbol: symbol ?? fallback, decimals: decimals)
            }
        }
        return tokens
    }
    func alchemyDiscovery(_ index: AlchemyHistoryClient, owner: String) async throws -> ([RobinhoodToken], [Data]) {
        var cursor: String?, visited: Set<String> = [], refs: Set<String> = [], raw: [Data] = []
        repeat {
            var params: [SolanaJSON] = [.string(owner), .string("erc20")]
            if let cursor { params.append(.object(["pageKey": .string(cursor)])) }
            let reply = try await index.request("alchemy_getTokenBalances", params)
            guard reply.value["address"].string?.lowercased() == owner,
                  let balances = reply.value["tokenBalances"].array, balances.count <= 1000 else { throw AnkrError.invalidResponse }
            for balance in balances {
                guard let address = balance["contractAddress"].string else { throw AnkrError.invalidResponse }
                refs.insert(try RobinhoodIdentity.address(address))
            }
            raw.append(reply.raw)
            guard refs.count <= 10_000, raw.reduce(0, { $0 + $1.count }) <= 32 * 1024 * 1024,
                  reply.value["pageKey"].isNull || reply.value["pageKey"].string != nil else { throw AnkrError.responseTooLarge }
            cursor = reply.value["pageKey"].string.flatMap { $0.isEmpty ? nil : $0 }
            if let cursor { guard cursor.count <= 4096, visited.insert(cursor).inserted else { throw AnkrError.paginationLoop } }
        } while cursor != nil
        let tokens = try await alchemyTokens(index, references: refs)
        return (tokens.values.sorted { $0.reference < $1.reference }, raw)
    }
    private func alchemyHistory(_ index: AlchemyHistoryClient, owner: String, stream: RobinhoodHistoryStream, cursor: String?) async throws -> Exchange {
        guard stream != .internalTransactions else { throw AnkrError.configurationMissing }
        let saved = try Self.cursor(cursor)
        // Provider-specific cursors are never forwarded to another provider.
        guard saved.isEmpty || saved["provider"]?.string == "alchemy",
              saved.keys.allSatisfy({ ["provider", "direction", "pageKey"].contains($0) }) else { throw AnkrError.http(422) }
        let direction = saved["direction"]?.string ?? "out"
        guard ["out", "in"].contains(direction), saved["pageKey"] == nil || saved["pageKey"]?.string != nil else { throw AnkrError.invalidResponse }
        let page = try await index.transfers(owner: owner, incoming: direction == "in", categories: [stream == .transactions ? "external" : "erc20"], cursor: saved["pageKey"]?.string)
        let references = try Set(page.transfers.compactMap { transfer -> String? in
            guard stream == .transfers else { return nil }
            guard let address = transfer["rawContract"]["address"].string else { throw AnkrError.invalidResponse }
            return try RobinhoodIdentity.address(address)
        })
        let tokens = try await alchemyTokens(index, references: references)
        let rows = try page.transfers.map { transfer -> SolanaJSON in
            guard let hash = transfer["hash"].string, let timestamp = transfer["metadata"]["blockTimestamp"].string else { throw AnkrError.invalidResponse }
            var row: [String: SolanaJSON] = ["timestamp": .string(timestamp), "block_number": transfer["blockNum"],
                "from": .object(["hash": transfer["from"]]), "to": .object(["hash": transfer["to"]])]
            let amount = try RobinhoodIdentity.amount(transfer["rawContract"]["value"])
            if stream == .transactions { row["hash"] = .string(hash); row["value"] = .string(amount) }
            else {
                guard let ref = transfer["rawContract"]["address"].string?.lowercased(), let token = tokens[ref],
                      let unique = transfer["uniqueId"].string, unique.lowercased().hasPrefix(hash.lowercased() + ":log:"),
                      let suffix = unique.split(separator: ":").last, let log = UInt64(suffix) else { throw AnkrError.invalidResponse }
                row["transaction_hash"] = .string(hash); row["log_index"] = .string(String(log))
                row["token"] = .object(["type": .string("ERC-20"), "address_hash": .string(ref), "name": .string(token.name), "symbol": .string(token.symbol), "decimals": .number(String(token.decimals))])
                row["total"] = .object(["value": .string(amount), "decimals": .number(String(token.decimals))])
            }
            return .object(row)
        }
        var next: SolanaJSON = .null
        if let key = page.next { next = .object(["provider": .string("alchemy"), "direction": .string(direction), "pageKey": .string(key)]) }
        else if direction == "out" { next = .object(["provider": .string("alchemy"), "direction": .string("in")]) }
        return .init(value: .object(["items": .array(rows), "next_page_params": next]), raw: page.raw)
    }
}
