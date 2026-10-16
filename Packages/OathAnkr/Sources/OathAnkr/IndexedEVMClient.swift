import OathDiagnostics
import Foundation

private extension SolanaJSON {
    var object: [String: SolanaJSON]? { if case .object(let value) = self { return value }; return nil }
}

/// Batched, block-pinned ANKR state reads with a separate address
/// index. No all-chain log scans or unsupported Advanced API calls.
public struct IndexedEVMClient: Sendable {
    public let chain: IndexedEVMChain
    public func canRestartHistory(after error: Error) -> Bool {
        switch error as? AnkrError {
        case .http(400), .http(422): return true
        // Alchemy page keys expire. A stored cursor rejected by its parameter
        // validator may restart once from the durable interval boundary.
        case .rpc(-32602): return chain == .monad
        default: return false
        }
    }
    private let endpoint: URL
    private let alchemyEndpoint: URL?
    private let transport: any AnkrTransport
    private let permits = AnkrPermits(count: 4)
    private let indexPermits = AnkrPermits(count: 1)
    public init(chain: IndexedEVMChain, apiKey: String, alchemyAPIKey: String? = nil,
                transport: any AnkrTransport = AnkrHTTPTransport()) throws {
        guard !apiKey.isEmpty, apiKey.count <= 256, apiKey.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }) else {
            throw AnkrError.configurationMissing
        }
        self.chain = chain
        if let key = alchemyAPIKey, !key.isEmpty {
            guard key.count <= 256, key.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else { throw AnkrError.configurationMissing }
            alchemyEndpoint = URL(string: "https://monad-mainnet.g.alchemy.com/v2")!.appendingPathComponent(key)
        } else { alchemyEndpoint = nil }
        endpoint = URL(string: "https://rpc.ankr.com")!.appendingPathComponent(chain.rpcPath).appendingPathComponent(apiKey)
        self.transport = transport
    }
    private struct Exchange: Sendable { let value: SolanaJSON; let raw: Data }
    private func exchange(_ request: URLRequest) async throws -> Exchange {
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
        guard !calls.isEmpty, calls.count <= chain.batchLimit else { throw AnkrError.invalidResponse }
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
        if let code = row["error"]["code"].text.flatMap(Int.init) {
            let error = AnkrError.rpc(code)
            OathDiagnostics.record(error, operation: "rpc_envelope", context: ["rpc_code": String(code)])
            throw error
        }
        guard case .object(let object) = row, let result = object["result"], !result.isNull else { throw AnkrError.invalidResponse }
        return result
    }
    private func index(path: String, params: [String: SolanaJSON] = [:]) async throws -> Exchange {
        guard chain == .unichain else { throw AnkrError.configurationMissing }
        var url = URLComponents(string: "https://unichain.blockscout.com/api/v2/" + path)!
        url.queryItems = try params.sorted { $0.key < $1.key }.map { key, value in
            let scalar: String?
            if value.isNull { scalar = "" }
            else if case .bool(let flag) = value { scalar = flag ? "true" : "false" }
            else { scalar = value.text }
            guard key.count <= 80, key != "apikey", key != "chainid", let text = scalar, text.count <= 1024 else { throw AnkrError.invalidResponse }
            return URLQueryItem(name: key, value: text)
        }
        var request = URLRequest(url: url.url!); request.setValue("OathWallet/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 25
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
    /// ERC-20 metadata is optional in the index. Resolve missing fields from
    /// contracts in bounded batches; decimals are never guessed.
    private func metadata(_ references: [String]) async throws -> ([String: IndexedEVMToken], [Data]) {
        let refs = Array(Set(try references.map(IndexedEVMIdentity.address))).sorted()
        let chunks = stride(from: 0, to: refs.count, by: (chain.batchLimit - 1) / 3).map { Array(refs[$0..<min($0 + (chain.batchLimit - 1) / 3, refs.count)]) }
        return try await withThrowingTaskGroup(of: ([String: IndexedEVMToken], Data).self) { group in
            var next = 0, tokens: [String: IndexedEVMToken] = [:], archive: [Data] = []
            func enqueue() {
                guard next < chunks.count else { return }
                let batch = chunks[next]; next += 1
                group.addTask {
                    let calls = batch.flatMap { ref in
                        ["0x313ce567", "0x06fdde03", "0x95d89b41"].map { selector in
                            ("eth_call", [SolanaJSON.object(["to": .string(ref), "data": .string(selector)]), .string("latest")])
                        }
                    }
                    let (rows, raw) = try await rpc([("eth_chainId", [])] + calls)
                    guard try IndexedEVMIdentity.amount(Self.result(rows[0])) == String(chain.chainID) else { throw AnkrError.wrongChain }
                    var found: [String: IndexedEVMToken] = [:]
                    for (i, ref) in batch.enumerated() {
                        let offset = 1 + i * 3
                        let token = OathDiagnostics.attempt("token_metadata") {
                            guard let decimals = Int(try IndexedEVMIdentity.amount(Self.result(rows[offset]))) else { throw AnkrError.invalidResponse }
                            // Optional ERC-20 name/symbol methods may revert or use
                            // an alternate ABI; absent labels are not app failures.
                            let name = rows[offset + 1]["result"].string.flatMap { try? TronIdentity.abiString($0) }
                            let symbol = rows[offset + 2]["result"].string.flatMap { try? TronIdentity.abiString($0) }
                            return try IndexedEVMToken(reference: ref, name: name ?? ref, symbol: symbol ?? String(ref.prefix(8)), decimals: decimals)
                        }
                        found[ref] = token
                    }
                    return (found, raw)
                }
            }
            for _ in 0..<min(4, chunks.count) { enqueue() }
            for try await (found, raw) in group {
                tokens.merge(found, uniquingKeysWith: { first, _ in first }); archive.append(raw); enqueue()
            }
            return (tokens, archive)
        }
    }
    private func discover(owner: String) async throws -> ([IndexedEVMToken], [Data], Bool) {
        if chain == .monad { return try await monadDiscovery(owner: owner) }
        var cursor: String?, visited: Set<String> = [], tokens: [String: IndexedEVMToken] = [:]
        var raw: [Data] = [], missing: [String] = [], seen: Set<String> = []
        repeat {
            var params = try Self.cursor(cursor); params["type"] = .string("ERC-20")
            let response = try await index(path: "addresses/" + owner + "/tokens", params: params)
            guard let items = response.value["items"].array, items.count <= 50 else { throw AnkrError.invalidResponse }
            raw.append(response.raw)
            for item in items {
                let value = item["token"]
                guard value["type"].string == "ERC-20", let address = value["address_hash"].string else { throw AnkrError.invalidResponse }
                let ref = try IndexedEVMIdentity.address(address)
                guard seen.insert(ref).inserted else { throw AnkrError.incompleteInventory }
                if value["decimals"].text != nil { tokens[ref] = try IndexedEVMToken.decode(value) }
                else { missing.append(ref) }
            }
            cursor = try Self.next(response.value)
            if let cursor, !visited.insert(cursor).inserted { throw AnkrError.paginationLoop }
            guard seen.count <= 100_000, raw.reduce(0, { $0 + $1.count }) <= 64 * 1024 * 1024 else { throw AnkrError.responseTooLarge }
        } while cursor != nil
        let (resolved, metadataRaw) = try await metadata(missing)
        tokens.merge(resolved, uniquingKeysWith: { first, _ in first })
        return (tokens.values.sorted { $0.reference < $1.reference }, raw + metadataRaw, tokens.count == seen.count)
    }
    public func inventory(owner: String, tracked: [IndexedEVMToken] = []) async throws -> IndexedEVMInventory {
        let owner = try IndexedEVMIdentity.address(owner)
        async let discovery = await OathDiagnostics.attempt("token_discovery") { try await discover(owner: owner) }
        let (head, headRaw) = try await rpc([("eth_chainId", []), ("eth_getBlockByNumber", [.string("latest"), .bool(false)])])
        guard try IndexedEVMIdentity.amount(Self.result(head[0])) == String(chain.chainID) else { throw AnkrError.wrongChain }
        let block = try Self.result(head[1]), height = try IndexedEVMIdentity.height(block["number"])
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
        let list = [IndexedEVMToken.native(chain)] + tokens.values.sorted { $0.reference < $1.reference }
        let chunks = stride(from: 0, to: list.count, by: chain.batchLimit / 2).map { Array(list[$0..<min($0 + chain.batchLimit / 2, list.count)]) }
        let body = "0x70a08231" + String(repeating: "0", count: 24) + owner.dropFirst(2)
        let gathered = try await withThrowingTaskGroup(of: ([IndexedEVMHolding], Data).self) { group in
            var next = 0, output: [IndexedEVMHolding] = [], raw: [Data] = []
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
                    var i = 0, holdings: [IndexedEVMHolding] = []
                    for token in chunk {
                        var amount = OathDiagnostics.attempt("balance_call") { try IndexedEVMIdentity.amount(Self.result(rows[i])) }; i += 1
                        if token.reference != "native" {
                            let decimals = OathDiagnostics.attempt("token_decimals") { try IndexedEVMIdentity.amount(Self.result(rows[i])) }; i += 1
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
        return .init(chain: chain, owner: owner, block: height, blockHash: hash, observedAt: .now,
                     holdings: gathered.0, complete: discovered?.2 == true && gathered.0.allSatisfy { $0.amount != nil }, raw: archive)
    }
    public func history(owner: String, stream: IndexedEVMHistoryStream, cursor: String? = nil,
                        from: Double = 0, through: Double = Date().timeIntervalSince1970) async throws -> IndexedEVMHistoryPage {
        let owner = try IndexedEVMIdentity.address(owner)
        let response = try await indexedHistory(owner: owner, stream: stream, cursor: cursor)
        // Verify indexed transactions and ERC-20 events against ANKR receipts.
        guard var document = response.value.object, let rows = document["items"]?.array, rows.count <= 50 else { throw AnkrError.invalidResponse }
        let hashes = try Set(rows.compactMap { row -> String? in
            if row["timestamp"].isNull, stream == .transactions, row["block_number"].isNull { return nil }
            guard let hash = row[stream == .transactions ? "hash" : "transaction_hash"].string, AnkrQuantity.hash(hash) else { throw AnkrError.invalidResponse }
            return hash.lowercased()
        }).sorted()
        let missingMetadata = stream == .transfers ? rows.filter {
            $0["token"]["decimals"].text == nil || $0["token"]["name"].string == nil || $0["token"]["symbol"].string == nil
        }.compactMap { $0["token"]["address_hash"].string } : []
        async let metadataTask = metadata(missingMetadata)
        let size = (chain.batchLimit - 1) / (stream == .transactions ? 2 : 1)
        let batches = stride(from: 0, to: hashes.count, by: size).map { Array(hashes[$0..<min($0 + size, hashes.count)]) }
        var receipts: [String: SolanaJSON] = [:], transactions: [String: SolanaJSON] = [:], receiptRaw: [Data] = []
        try await withThrowingTaskGroup(of: ([String: SolanaJSON], [String: SolanaJSON], Data).self) { group in
            // Index pages are bounded to 50 items: at most four batches.
            for batch in batches {
                group.addTask {
                    var calls = [("eth_chainId", [SolanaJSON]())]
                    for hash in batch {
                        calls.append(("eth_getTransactionReceipt", [.string(hash)]))
                        if stream == .transactions { calls.append(("eth_getTransactionByHash", [.string(hash)])) }
                    }
                    let (replies, raw) = try await rpc(calls)
                    guard try IndexedEVMIdentity.amount(Self.result(replies[0])) == String(chain.chainID) else { throw AnkrError.wrongChain }
                    var found: [String: SolanaJSON] = [:], txs: [String: SolanaJSON] = [:], i = 1
                    for hash in batch {
                        let receipt = try Self.result(replies[i]); i += 1
                        guard receipt["transactionHash"].string?.lowercased() == hash else { throw AnkrError.invalidResponse }
                        found[hash] = receipt
                        if stream == .transactions {
                            let tx = try Self.result(replies[i]); i += 1
                            guard tx["hash"].string?.lowercased() == hash, tx["blockHash"] == receipt["blockHash"] else { throw AnkrError.invalidResponse }
                            txs[hash] = tx
                        }
                    }
                    return (found, txs, raw)
                }
            }
            for try await (found, txs, raw) in group {
                receipts.merge(found, uniquingKeysWith: { first, _ in first })
                transactions.merge(txs, uniquingKeysWith: { first, _ in first }); receiptRaw.append(raw)
            }
        }
        let (resolvedMetadata, metadataRaw) = try await metadataTask
        var enriched: [SolanaJSON] = []
        for row in rows {
            if row["timestamp"].isNull, stream == .transactions, row["block_number"].isNull { continue }
            guard var value = row.object, let hash = row[stream == .transactions ? "hash" : "transaction_hash"].string?.lowercased(),
                  let receipt = receipts[hash] else { throw AnkrError.invalidResponse }
            let height = try IndexedEVMIdentity.height(receipt["blockNumber"])
            if !row["block_number"].isNull, try IndexedEVMIdentity.height(row["block_number"]) != height { throw AnkrError.invalidResponse }
            if let indexedHash = row["block_hash"].string, indexedHash.lowercased() != receipt["blockHash"].string?.lowercased() { throw AnkrError.invalidResponse }
            value["block_number"] = .number(String(height))
            let status = try IndexedEVMIdentity.amount(receipt["status"])
            guard status == "0" || status == "1" else { throw AnkrError.invalidResponse }
            if stream == .transactions {
                guard let tx = transactions[hash],
                      tx["from"].string?.lowercased() == row["from"]["hash"].string?.lowercased(),
                      tx["to"].string?.lowercased() == row["to"]["hash"].string?.lowercased(),
                      try IndexedEVMIdentity.amount(tx["value"]) == IndexedEVMIdentity.amount(row["value"]) else { throw AnkrError.invalidResponse }
                value["value"] = tx["value"]
                value["status"] = .string(status == "1" ? "ok" : "error")
                var fee = try AnkrQuantity.multiply(IndexedEVMIdentity.amount(receipt["gasUsed"]), IndexedEVMIdentity.amount(receipt["effectiveGasPrice"]))
                if chain == .unichain, !receipt["l1Fee"].isNull { fee = try AptosIdentity.add(fee, IndexedEVMIdentity.amount(receipt["l1Fee"])) }
                value["fee"] = .object(["type": .string("actual"), "value": .string(fee)])
            } else if stream == .transfers {
                guard status == "1", let logs = receipt["logs"].array,
                      let log = logs.first(where: { (try? IndexedEVMIdentity.amount($0["logIndex"])) == row["log_index"].text }) else { throw AnkrError.invalidResponse }
                try Self.verifyTransfer(row, log: log, chain: chain)
                value["log_index"] = .number(try IndexedEVMIdentity.amount(log["logIndex"]))
                if let ref = row["token"]["address_hash"].string?.lowercased(), let token = resolvedMetadata[ref] {
                    value["token"] = .object(["type": .string("ERC-20"), "address_hash": .string(ref),
                        "name": .string(token.name), "symbol": .string(token.symbol), "decimals": .number(String(token.decimals))])
                    value["total"] = .object(["value": row["total"]["value"], "decimals": .number(String(token.decimals))])
                } else if row["token"]["decimals"].text == nil {
                    // Transfer-shaped logs are not proof of an ERC-20 contract.
                    // Retain the verified raw event without inventing decimals
                    // or blocking subsequent history pages for valid assets.
                    value["metadata_unavailable"] = .bool(true)
                }
            } else if status == "0" { value["success"] = .bool(false) }
            enriched.append(.object(value))
        }
        document["items"] = .array(enriched)
        let decoded = try Self.decodeHistory(JSONEncoder().encode(SolanaJSON.object(document)), chain: chain, owner: owner, stream: stream, from: from, through: through)
        // Incoming/outgoing Alchemy pages are independently ordered. Crossing
        // the outgoing interval must still start the incoming half.
        let next: String?
        if chain == .monad, decoded.next == nil, try Self.cursor(cursor)["direction"]?.string != "in" {
            next = try JSONEncoder().encode(SolanaJSON.object(["direction": .string("in")])).base64EncodedString()
        } else { next = decoded.next }
        return .init(chain: chain, events: decoded.events, next: next,
                     raw: try JSONEncoder().encode(["index": [response.raw], "receipts": receiptRaw, "metadata": metadataRaw]))
    }
    static func verifyTransfer(_ row: SolanaJSON, log: SolanaJSON, chain: IndexedEVMChain) throws {
        guard let topics = log["topics"].array,
              log["address"].string?.lowercased() == row["token"]["address_hash"].string?.lowercased(),
              try IndexedEVMIdentity.amount(log["data"]) == IndexedEVMIdentity.amount(row["total"]["value"]) else { throw AnkrError.invalidResponse }
        let from = row["from"]["hash"].string?.lowercased(), to = row["to"]["hash"].string?.lowercased()
        if topics.count == 3, topics[0].string?.lowercased() == "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef",
           topics[1].string?.suffix(40).lowercased() == from?.dropFirst(2).lowercased(),
           topics[2].string?.suffix(40).lowercased() == to?.dropFirst(2).lowercased() { return }
        // Wrapped native currency uses WETH-style Deposit/Withdrawal, which the indexer exposes
        // as mint/burn transfers. Accept only this canonical contract/signature.
        let zero = "0x" + String(repeating: "0", count: 40)
        if log["address"].string?.lowercased() == chain.wrappedNative, topics.count == 2 {
            let account = "0x" + (topics[1].string?.suffix(40).lowercased() ?? "")
            if topics[0].string == "0xe1fffcc4923d04b559f4d29a8bfc6cda04eb5b0d3c460751c2402c5c5cc9109c", from == zero, to == account { return }
            if topics[0].string == "0x7fcf532c15f0a6db0bd6d0e038bea71d30d808c7d98cb3bf7268a95bf5081b65", from == account, to == zero { return }
        }
        throw AnkrError.invalidResponse
    }
    private func indexedHistory(owner: String, stream: IndexedEVMHistoryStream, cursor: String?) async throws -> Exchange {
        if chain == .monad { return try await monadHistory(owner: owner, stream: stream, cursor: cursor) }
        var params = try Self.cursor(cursor)
        if stream == .transfers { params["type"] = .string("ERC-20") }
        return try await index(path: "addresses/" + owner + "/" + (stream == .transfers ? "token-transfers" : stream.rawValue), params: params)
    }
    public static func decodeHistory(_ data: Data, chain: IndexedEVMChain, owner: String, stream: IndexedEVMHistoryStream,
                                     from: Double = 0, through: Double = Date().timeIntervalSince1970) throws -> IndexedEVMHistoryPage {
        let owner = try IndexedEVMIdentity.address(owner), json = try JSONDecoder().decode(SolanaJSON.self, from: data)
        guard let rows = json["items"].array, from >= 0, through >= from else { throw AnkrError.invalidResponse }
        var events: [IndexedEVMEvent] = [], crossed = false, last = Double.infinity, ids: Set<String> = []
        for row in rows {
            // Pending transactions have no ledger timestamp; they are fetched
            // again at the head after confirmation rather than advancing time.
            if row["timestamp"].isNull, stream == .transactions, row["block_number"].isNull { continue }
            let date = try IndexedEVMIdentity.timestamp(row["timestamp"])
            guard date <= last else { throw AnkrError.invalidResponse }; last = date
            if date < from { crossed = true; continue }
            if date > through { continue }
            guard let hash = row[stream == .transactions ? "hash" : "transaction_hash"].string,
                  AnkrQuantity.hash(hash), let sender = row["from"]["hash"].string else { throw AnkrError.invalidResponse }
            let receiver = row["to"]["hash"].string ?? row["created_contract"]["hash"].string ?? "0x" + String(repeating: "0", count: 40)
            let senderAddress = try IndexedEVMIdentity.address(sender), recipient = try IndexedEVMIdentity.address(receiver)
            guard senderAddress == owner || recipient == owner else { throw AnkrError.wrongAccount }
            let height = try IndexedEVMIdentity.height(row["block_number"])
            var token: IndexedEVMToken? = .native(chain)
            var amount: String, failed = false, fee: String?, index = "external"
            switch stream {
            case .transactions:
                guard ["ok", "error"].contains(row["status"].string) else { throw AnkrError.invalidResponse }
                failed = row["status"].string == "error"; amount = try IndexedEVMIdentity.amount(row["value"])
                if !row["fee"]["value"].isNull { fee = try IndexedEVMIdentity.amount(row["fee"]["value"]) }
            case .transfers:
                if row["metadata_unavailable"] == .bool(true) { token = nil }
                else {
                    let decoded = try IndexedEVMToken.decode(row["token"])
                    guard row["total"]["decimals"].text == String(decoded.decimals) else { throw AnkrError.invalidResponse }
                    token = decoded
                }
                amount = try IndexedEVMIdentity.amount(row["total"]["value"])
                index = "log:" + String(try IndexedEVMIdentity.height(row["log_index"]))
            case .internalTransactions:
                guard case .bool(let success) = row["success"] else { throw AnkrError.invalidResponse }
                failed = !success; amount = try IndexedEVMIdentity.amount(row["value"])
                // Blockscout's call index is stable within a transaction.
                index = "internal:" + String(try IndexedEVMIdentity.height(row["index"]))
                // Blockscout excludes the root frame. A nested transfer can
                // legitimately have index zero.
            }
            let id = hash.lowercased() + ":" + index
            guard ids.insert(id).inserted else { throw AnkrError.invalidResponse }
            events.append(.init(id: id, hash: hash.lowercased(), block: height, timestamp: date,
                                token: token, amount: failed ? "0" : amount, from: senderAddress, to: recipient,
                                failed: failed, fee: fee, raw: try JSONEncoder().encode(row)))
        }
        let next = try next(json)
        return .init(chain: chain, events: events, next: crossed ? nil : next, raw: data)
    }
}

private extension IndexedEVMClient {
    private func alchemy(_ method: String, params: [SolanaJSON]) async throws -> Exchange {
        guard chain == .monad, let alchemyEndpoint else { throw AnkrError.configurationMissing }
        var request = URLRequest(url: alchemyEndpoint); request.httpMethod = "POST"; request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(SolanaJSON.object(["jsonrpc": .string("2.0"), "id": .number("1"), "method": .string(method), "params": .array(params)]))
        try await indexPermits.acquire()
        do {
            let response = try await exchange(request)
            guard response.value["id"].integer == 1, response.value["jsonrpc"].string == "2.0" else { throw AnkrError.invalidResponse }
            let value = try Self.result(response.value)
            await indexPermits.release(); return .init(value: value, raw: response.raw)
        } catch { OathDiagnostics.record(error, operation: "monad_index"); await indexPermits.release(); throw error }
    }

    private func monadDiscovery(owner: String) async throws -> ([IndexedEVMToken], [Data], Bool) {
        var page: String?, visited: Set<String> = [], references: Set<String> = [], raw: [Data] = []
        repeat {
            var params: [SolanaJSON] = [.string(owner), .string("erc20")]
            if let page { params.append(.object(["pageKey": .string(page)])) }
            let response = try await alchemy("alchemy_getTokenBalances", params: params)
            guard response.value["address"].string?.lowercased() == owner,
                  let balances = response.value["tokenBalances"].array, balances.count <= 1000 else { throw AnkrError.invalidResponse }
            for balance in balances {
                guard let address = balance["contractAddress"].string else { throw AnkrError.invalidResponse }
                references.insert(try IndexedEVMIdentity.address(address))
            }
            raw.append(response.raw)
            guard references.count <= 10_000, raw.reduce(0, { $0 + $1.count }) <= 32 * 1024 * 1024 else { throw AnkrError.responseTooLarge }
            guard response.value["pageKey"].isNull || response.value["pageKey"].string != nil else { throw AnkrError.invalidResponse }
            page = response.value["pageKey"].string
            if page == "" { page = nil }
            if let page { guard page.count <= 4096, visited.insert(page).inserted else { throw AnkrError.paginationLoop } }
        } while page != nil
        // Discovery is only a contract list. Values, decimals and chain identity
        // are read independently from ANKR at the pinned inventory block.
        let (tokens, metadataRaw) = try await metadata(Array(references))
        return (tokens.values.sorted { $0.reference < $1.reference }, raw + metadataRaw, tokens.count == references.count)
    }

    private func monadHistory(owner: String, stream: IndexedEVMHistoryStream, cursor: String?) async throws -> Exchange {
        guard stream != .internalTransactions else { throw AnkrError.configurationMissing }
        let saved = try Self.cursor(cursor), direction = saved["direction"]?.string ?? "out"
        guard ["out", "in"].contains(direction), saved.keys.allSatisfy({ ["direction", "pageKey"].contains($0) }) else { throw AnkrError.invalidResponse }
        var options: [String: SolanaJSON] = ["fromBlock": .string("0x0"), "toBlock": .string("latest"),
            direction == "out" ? "fromAddress" : "toAddress": .string(owner), "order": .string("desc"),
            "maxCount": .string("0x32"), "withMetadata": .bool(true), "excludeZeroValue": .bool(false),
            "category": .array([.string(stream == .transfers ? "erc20" : "external")])]
        if let key = saved["pageKey"]?.string { guard !key.isEmpty, key.count <= 4096 else { throw AnkrError.invalidResponse }; options["pageKey"] = .string(key) }
        let response = try await alchemy("alchemy_getAssetTransfers", params: [.object(options)])
        guard let transfers = response.value["transfers"].array, transfers.count <= 50 else { throw AnkrError.invalidResponse }
        let rows = try transfers.map { transfer -> SolanaJSON in
            guard let hash = transfer["hash"].string, AnkrQuantity.hash(hash),
                  transfer["category"].string == (stream == .transfers ? "erc20" : "external"),
                  let from = transfer["from"].string, let to = transfer["to"].string,
                  let timestamp = transfer["metadata"]["blockTimestamp"].string else { throw AnkrError.invalidResponse }
            _ = try IndexedEVMIdentity.address(from); _ = try IndexedEVMIdentity.address(to)
            guard (direction == "out" ? from : to).lowercased() == owner else { throw AnkrError.wrongAccount }
            let amount = try IndexedEVMIdentity.amount(transfer["rawContract"]["value"])
            var row: [String: SolanaJSON] = ["timestamp": .string(timestamp), "block_number": transfer["blockNum"],
                "from": .object(["hash": .string(from)]), "to": .object(["hash": .string(to)])]
            if stream == .transactions { row["hash"] = .string(hash); row["value"] = .string(amount) }
            else {
                guard let ref = transfer["rawContract"]["address"].string,
                      let unique = transfer["uniqueId"].string, unique.lowercased().hasPrefix(hash.lowercased() + ":log:"),
                      let suffix = unique.split(separator: ":").last, let index = UInt64(suffix) else { throw AnkrError.invalidResponse }
                row["transaction_hash"] = .string(hash); row["log_index"] = .string(String(index))
                row["token"] = .object(["type": .string("ERC-20"), "address_hash": .string(try IndexedEVMIdentity.address(ref))])
                row["total"] = .object(["value": .string(amount)])
            }
            return .object(row)
        }
        let next: SolanaJSON
        guard response.value["pageKey"].isNull || response.value["pageKey"].string != nil else { throw AnkrError.invalidResponse }
        if let key = response.value["pageKey"].string, !key.isEmpty {
            guard key.count <= 4096, key != saved["pageKey"]?.string, !rows.isEmpty else { throw AnkrError.paginationLoop }
            next = .object(["direction": .string(direction), "pageKey": .string(key)])
        } else { next = direction == "out" ? .object(["direction": .string("in")]) : .null }
        return .init(value: .object(["items": .array(rows), "next_page_params": next]), raw: response.raw)
    }
}
