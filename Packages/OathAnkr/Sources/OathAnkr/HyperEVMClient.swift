import OathDiagnostics
import Foundation

private extension SolanaJSON {
    var object: [String: SolanaJSON]? { if case .object(let value) = self { return value }; return nil }
}

/// Batched, block-pinned ANKR state reads with a separate HypurrScan
/// index and optional Alchemy snapshot recovery. No all-chain log scans.
public struct HyperEVMClient: Sendable {
    private var endpoint: URL
    private let recoveryEndpoint: URL?
    private let transport: any AnkrTransport
    private let permits = AnkrPermits(count: 4)
    private let indexPermits = AnkrPermits(count: 1)
    public init(apiKey: String, alchemyAPIKey: String? = nil,
                transport: any AnkrTransport = AnkrHTTPTransport()) throws {
        guard !apiKey.isEmpty, apiKey.count <= 256, apiKey.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }) else {
            throw AnkrError.configurationMissing
        }
        endpoint = URL(string: "https://rpc.ankr.com/hyperevm")!.appendingPathComponent(apiKey)
        if let key = alchemyAPIKey, !key.isEmpty {
            guard key.count <= 256, key.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else {
                throw AnkrError.configurationMissing
            }
            recoveryEndpoint = URL(string: "https://hyperliquid-mainnet.g.alchemy.com/v2")!.appendingPathComponent(key)
        } else { recoveryEndpoint = nil }
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
        if let code = row["error"]["code"].text.flatMap(Int.init) {
            let error = AnkrError.rpc(code)
            OathDiagnostics.record(error, operation: "rpc_envelope", context: ["rpc_code": String(code), "chain": "hyperevm"])
            throw error
        }
        guard case .object(let object) = row, let result = object["result"], !result.isNull else { throw AnkrError.invalidResponse }
        return result
    }
    private func index(path: String, params: [String: SolanaJSON] = [:]) async throws -> Exchange {
        var request = URLRequest(url: URL(string: "https://trace.hypurrscan.io/api/v1/" + path)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(SolanaJSON.object(params))
        try await indexPermits.acquire()
        do {
            // Bound public index traffic independently of parallel ANKR state reads.
            try await Task.sleep(for: .milliseconds(250))
            let value = try await exchange(request)
            guard value.value["success"] == .bool(true) else { throw AnkrError.invalidResponse }
            await indexPermits.release(); return value
        } catch { OathDiagnostics.record(error, operation: "index"); await indexPermits.release(); throw error }
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
    private func metadata(_ references: [String]) async throws -> ([String: HyperEVMToken], [Data]) {
        let refs = Array(Set(try references.map(HyperEVMIdentity.address))).sorted()
        let chunks = stride(from: 0, to: refs.count, by: 9).map { Array(refs[$0..<min($0 + 9, refs.count)]) }
        return try await withThrowingTaskGroup(of: ([String: HyperEVMToken], Data).self) { group in
            var next = 0, tokens: [String: HyperEVMToken] = [:], archive: [Data] = []
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
                    guard try HyperEVMIdentity.amount(Self.result(rows[0])) == String(HyperEVMIdentity.chainID) else { throw AnkrError.wrongChain }
                    var found: [String: HyperEVMToken] = [:]
                    for (i, ref) in batch.enumerated() {
                        let offset = 1 + i * 3
                        let token = OathDiagnostics.attempt("token_metadata") {
                            guard let decimals = Int(try HyperEVMIdentity.amount(Self.result(rows[offset]))) else { throw AnkrError.invalidResponse }
                            // Optional ERC-20 name/symbol methods may revert or use
                            // an alternate ABI; absent labels are not app failures.
                            let name = rows[offset + 1]["result"].string.flatMap { try? TronIdentity.abiString($0) }
                            let symbol = rows[offset + 2]["result"].string.flatMap { try? TronIdentity.abiString($0) }
                            return try HyperEVMToken(reference: ref, name: name ?? ref, symbol: symbol ?? String(ref.prefix(8)), decimals: decimals)
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
    private func discover(owner: String) async throws -> ([HyperEVMToken], [Data], Bool) {
        let response = try await index(path: "address/tokens/indexed", params: ["address": .string(owner)])
        guard let items = response.value["balances"].array, items.count <= 100_000,
              response.value["last_aggregated_block"].integer != nil else { throw AnkrError.invalidResponse }
        var tokens: [String: HyperEVMToken] = [:], missing: [String] = [], seen: Set<String> = []
        for item in items {
            guard let address = item["token"].string else { throw AnkrError.incompleteInventory }
            let ref = try HyperEVMIdentity.address(address)
            guard seen.insert(ref).inserted else { throw AnkrError.incompleteInventory }
            if let decimals = item["decimals"].text.flatMap(Int.init),
               let name = item["name"].string, let symbol = item["symbol"].string {
                tokens[ref] = try HyperEVMToken(reference: ref, name: name, symbol: symbol, decimals: decimals)
            } else { missing.append(ref) }
        }
        let (resolved, raw) = try await metadata(missing)
        tokens.merge(resolved, uniquingKeysWith: { first, _ in first })
        // Index balances can be stale, rounded, or exponential notation. Only
        // contract identities are used; amounts come from the selected RPC.
        return (tokens.values.sorted { $0.reference < $1.reference }, [response.raw] + raw, tokens.count == seen.count)
    }
    public func inventory(owner: String, tracked: [HyperEVMToken] = []) async throws -> HyperEVMInventory {
        do { return try await inventoryFromRPC(owner: owner, tracked: tracked) }
        catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            let recoverable: Bool
            switch error {
            case AnkrError.transport: recoverable = true
            case AnkrError.http(let status): recoverable = status == 429 || (500...599).contains(status)
            default: recoverable = false
            }
            guard recoverable, let recoveryEndpoint else { throw error }
            OathDiagnostics.record(error, operation: "inventory_rpc_recovery",
                                   context: ["chain": "hyperevm", "stage": "inventory", "host": endpoint.host ?? ""])
            // Start a NEW snapshot on the independent provider, including its
            // chain ID, pinned head, contract decimals and final block-hash check.
            // Never mix partial primary balances with secondary-provider reads.
            // Copying retains the shared RPC/index concurrency limits. Calling
            // the inner operation bounds recovery to one provider switch.
            var recovery = self
            recovery.endpoint = recoveryEndpoint
            try Task.checkCancellation()
            return try await recovery.inventoryFromRPC(owner: owner, tracked: tracked)
        }
    }
    private func inventoryFromRPC(owner: String, tracked: [HyperEVMToken]) async throws -> HyperEVMInventory {
        let owner = try HyperEVMIdentity.address(owner)
        async let discovery = await OathDiagnostics.attempt("token_discovery") { try await discover(owner: owner) }
        let (head, headRaw) = try await rpc([("eth_chainId", []), ("eth_getBlockByNumber", [.string("latest"), .bool(false)])])
        guard try HyperEVMIdentity.amount(Self.result(head[0])) == String(HyperEVMIdentity.chainID) else { throw AnkrError.wrongChain }
        let block = try Self.result(head[1]), height = try HyperEVMIdentity.height(block["number"])
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
        let list = [HyperEVMToken.native] + tokens.values.sorted { $0.reference < $1.reference }
        let chunks = stride(from: 0, to: list.count, by: 15).map { Array(list[$0..<min($0 + 15, list.count)]) }
        let body = "0x70a08231" + String(repeating: "0", count: 24) + owner.dropFirst(2)
        let gathered = try await withThrowingTaskGroup(of: ([HyperEVMHolding], Data).self) { group in
            var next = 0, output: [HyperEVMHolding] = [], raw: [Data] = []
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
                    var i = 0, holdings: [HyperEVMHolding] = []
                    for token in chunk {
                        var amount = OathDiagnostics.attempt("balance_call") { try HyperEVMIdentity.amount(Self.result(rows[i])) }; i += 1
                        if token.reference != "native" {
                            let decimals = OathDiagnostics.attempt("token_decimals") { try HyperEVMIdentity.amount(Self.result(rows[i])) }; i += 1
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
                     holdings: gathered.0, complete: discovered?.2 == true && gathered.0.allSatisfy { $0.amount != nil }, raw: archive)
    }
    public func history(owner: String, stream: HyperEVMHistoryStream, cursor: String? = nil,
                        from: Double = 0, through: Double = Date().timeIntervalSince1970) async throws -> HyperEVMHistoryPage {
        let owner = try HyperEVMIdentity.address(owner)
        let response = try await indexedHistory(owner: owner, stream: stream, cursor: cursor)
        // Verify indexed transactions and ERC-20 events against ANKR receipts.
        guard var document = response.value.object, let rows = document["items"]?.array else { throw AnkrError.invalidResponse }
        let hashes = try Set(rows.compactMap { row -> String? in
            if row["timestamp"].isNull, stream == .transactions, row["block_number"].isNull { return nil }
            guard let hash = row[stream == .transactions ? "hash" : "transaction_hash"].string, AnkrQuantity.hash(hash) else { throw AnkrError.invalidResponse }
            return hash.lowercased()
        }).sorted()
        let missingMetadata = stream == .transfers ? rows.filter {
            $0["token"]["decimals"].text == nil || $0["token"]["name"].string == nil || $0["token"]["symbol"].string == nil
        }.compactMap { $0["token"]["address_hash"].string } : []
        async let metadataTask = metadata(missingMetadata)
        let size = stream == .transactions ? 14 : 29
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
                    guard try HyperEVMIdentity.amount(Self.result(replies[0])) == String(HyperEVMIdentity.chainID) else { throw AnkrError.wrongChain }
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
            let height = try HyperEVMIdentity.height(receipt["blockNumber"])
            if !row["block_number"].isNull, try HyperEVMIdentity.height(row["block_number"]) != height { throw AnkrError.invalidResponse }
            if let indexedHash = row["block_hash"].string, indexedHash.lowercased() != receipt["blockHash"].string?.lowercased() { throw AnkrError.invalidResponse }
            value["block_number"] = .number(String(height))
            let status = try HyperEVMIdentity.amount(receipt["status"])
            guard status == "0" || status == "1" else { throw AnkrError.invalidResponse }
            if stream == .transactions {
                guard let tx = transactions[hash],
                      tx["from"].string?.lowercased() == row["from"]["hash"].string?.lowercased(),
                      tx["to"].string?.lowercased() == row["to"]["hash"].string?.lowercased(),
                      try HyperEVMIdentity.amount(tx["value"]) == HyperEVMIdentity.amount(row["value"]) else { throw AnkrError.invalidResponse }
                value["value"] = tx["value"]
                value["status"] = .string(status == "1" ? "ok" : "error")
                let fee = try AnkrQuantity.multiply(HyperEVMIdentity.amount(receipt["gasUsed"]), HyperEVMIdentity.amount(receipt["effectiveGasPrice"]))
                value["fee"] = .object(["type": .string("actual"), "value": .string(fee)])
            } else if stream == .transfers {
                guard status == "1", let logs = receipt["logs"].array,
                      let localIndex = row["log_index"].text.flatMap(UInt64.init), localIndex < logs.count else { throw AnkrError.invalidResponse }
                let log = logs[Int(localIndex)]
                try Self.verifyTransfer(row, log: log)
                // HypurrScan numbers logs within the transaction. JSON-RPC
                // numbers them within the block. Persist the canonical RPC ID.
                value["log_index"] = .number(try HyperEVMIdentity.amount(log["logIndex"]))
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
        let decoded = try Self.decodeHistory(JSONEncoder().encode(SolanaJSON.object(document)), owner: owner, stream: stream, from: from, through: through)
        return .init(events: decoded.events, next: decoded.next,
                     raw: try JSONEncoder().encode(["index": [response.raw], "receipts": receiptRaw, "metadata": metadataRaw]))
    }
    static func verifyTransfer(_ row: SolanaJSON, log: SolanaJSON) throws {
        guard let topics = log["topics"].array,
              log["address"].string?.lowercased() == row["token"]["address_hash"].string?.lowercased(),
              try HyperEVMIdentity.amount(log["data"]) == HyperEVMIdentity.amount(row["total"]["value"]) else { throw AnkrError.invalidResponse }
        let from = row["from"]["hash"].string?.lowercased(), to = row["to"]["hash"].string?.lowercased()
        if topics.count == 3, topics[0].string?.lowercased() == "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef",
           topics[1].string?.suffix(40).lowercased() == from?.dropFirst(2).lowercased(),
           topics[2].string?.suffix(40).lowercased() == to?.dropFirst(2).lowercased() { return }
        // WHYPE uses WETH-style Deposit/Withdrawal, which the indexer exposes
        // as mint/burn transfers. Accept only this canonical contract/signature.
        let zero = "0x" + String(repeating: "0", count: 40)
        if log["address"].string?.lowercased() == "0x5555555555555555555555555555555555555555", topics.count == 2 {
            let account = "0x" + (topics[1].string?.suffix(40).lowercased() ?? "")
            if topics[0].string == "0xe1fffcc4923d04b559f4d29a8bfc6cda04eb5b0d3c460751c2402c5c5cc9109c", from == zero, to == account { return }
            if topics[0].string == "0x7fcf532c15f0a6db0bd6d0e038bea71d30d808c7d98cb3bf7268a95bf5081b65", from == account, to == zero { return }
        }
        throw AnkrError.invalidResponse
    }
    private func indexedHistory(owner: String, stream: HyperEVMHistoryStream, cursor: String?) async throws -> Exchange {
        let decoded = try Self.cursor(cursor)
        guard decoded.keys.allSatisfy({ $0 == "cursor" }) else { throw AnkrError.invalidResponse }
        let value = decoded["cursor"]
        var params: [String: SolanaJSON]
        let path: String
        if stream == .internalTransactions {
            path = "indexed/internal-calls"
            params = ["address": .string(owner), "limit": .number("50"), "pagination": .string("cursor"), "order": .string("desc")]
            params["cursor"] = value
        } else {
            path = stream == .transactions ? "indexed/transactions/bulk" : "indexed/erc20-transfers/bulk"
            params = ["addresses": .array([.string(owner)]), "limit": .number("50"), "order": .string("desc")]
            if let value { params["cursors"] = .object([owner: value]) }
        }
        let response = try await index(path: path, params: params)
        return Exchange(value: try Self.normalizeHistory(response.value, owner: owner, stream: stream), raw: response.raw)
    }
    /// Converts only the documented index schema; amounts, status and ERC-20
    /// logs are then independently verified by history() using ANKR receipts.
    static func normalizeHistory(_ json: SolanaJSON, owner: String, stream: HyperEVMHistoryStream) throws -> SolanaJSON {
        guard json["success"] == .bool(true) else { throw AnkrError.invalidResponse }
        let page = stream == .internalTransactions ? json : json["results"][owner]
        let key = stream == .transactions ? "transactions" : stream == .transfers ? "erc20_transfers" : "internal_calls"
        guard let items = page[key].array, items.count <= 50, case .bool(let more) = page["has_more"] else { throw AnkrError.invalidResponse }
        let next = page["next_cursor"].string
        guard !more || (next?.isEmpty == false && next!.count <= 8192), more || next == nil else { throw AnkrError.invalidResponse }
        let rows = try items.compactMap { row -> SolanaJSON? in
            // Delegate/static calls do not move HYPE. Only actual value-bearing
            // CALL/CREATE frames are financial activity, never their root call.
            if stream == .internalTransactions {
                guard let depth = row["depth"].integer, depth > 0 else { throw AnkrError.invalidResponse }
                if !["CALL", "CREATE", "CREATE2", "SELFDESTRUCT"].contains(row["call_type"].string) { return nil }
                if try HyperEVMIdentity.amount(row["value"]) == "0" { return nil }
            }
            var output: [String: SolanaJSON] = [
                "hash": row["tx_hash"], "transaction_hash": row["tx_hash"], "block_number": row["block_number"],
                "timestamp": row["timestamp"], "value": row["value"],
                "from": .object(["hash": row["from_address"]]), "to": .object(["hash": row["to_address"]])
            ]
            switch stream {
            case .transactions:
                guard case .bool(let success) = row["success"] else { throw AnkrError.invalidResponse }
                output["status"] = .string(success ? "ok" : "error")
            case .transfers:
                output["token"] = .object(["type": .string("ERC-20"), "address_hash": row["token_address"],
                    "name": row["token_name"], "symbol": row["token_symbol"], "decimals": row["token_decimals"]])
                output["total"] = .object(["value": row["value"], "decimals": row["token_decimals"]])
                output["log_index"] = row["log_index"]
            case .internalTransactions:
                output["success"] = row["success"]; output["index"] = row["call_index"]
            }
            return .object(output)
        }
        return .object(["items": .array(rows), "next_page_params": more ? .object(["cursor": .string(next!)]) : .null])
    }
    public static func decodeHistory(_ data: Data, owner: String, stream: HyperEVMHistoryStream,
                                     from: Double = 0, through: Double = Date().timeIntervalSince1970) throws -> HyperEVMHistoryPage {
        let owner = try HyperEVMIdentity.address(owner), json = try JSONDecoder().decode(SolanaJSON.self, from: data)
        guard let rows = json["items"].array, from >= 0, through >= from else { throw AnkrError.invalidResponse }
        var events: [HyperEVMEvent] = [], crossed = false, last = Double.infinity, ids: Set<String> = []
        for row in rows {
            // Pending transactions have no ledger timestamp; they are fetched
            // again at the head after confirmation rather than advancing time.
            if row["timestamp"].isNull, stream == .transactions, row["block_number"].isNull { continue }
            let date = try HyperEVMIdentity.timestamp(row["timestamp"])
            guard date <= last else { throw AnkrError.invalidResponse }; last = date
            if date < from { crossed = true; continue }
            if date > through { continue }
            guard let hash = row[stream == .transactions ? "hash" : "transaction_hash"].string,
                  AnkrQuantity.hash(hash), let sender = row["from"]["hash"].string else { throw AnkrError.invalidResponse }
            let receiver = row["to"]["hash"].string ?? row["created_contract"]["hash"].string ?? "0x" + String(repeating: "0", count: 40)
            let senderAddress = try HyperEVMIdentity.address(sender), recipient = try HyperEVMIdentity.address(receiver)
            guard senderAddress == owner || recipient == owner else { throw AnkrError.wrongAccount }
            let height = try HyperEVMIdentity.height(row["block_number"])
            var token: HyperEVMToken? = .native
            var amount: String, failed = false, fee: String?, index = "external"
            switch stream {
            case .transactions:
                guard ["ok", "error"].contains(row["status"].string) else { throw AnkrError.invalidResponse }
                failed = row["status"].string == "error"; amount = try HyperEVMIdentity.amount(row["value"])
                if !row["fee"]["value"].isNull { fee = try HyperEVMIdentity.amount(row["fee"]["value"]) }
            case .transfers:
                if row["metadata_unavailable"] == .bool(true) { token = nil }
                else {
                    let decoded = try HyperEVMToken.decode(row["token"])
                    guard row["total"]["decimals"].text == String(decoded.decimals) else { throw AnkrError.invalidResponse }
                    token = decoded
                }
                amount = try HyperEVMIdentity.amount(row["total"]["value"])
                index = "log:" + String(try HyperEVMIdentity.height(row["log_index"]))
            case .internalTransactions:
                guard case .bool(let success) = row["success"] else { throw AnkrError.invalidResponse }
                failed = !success; amount = try HyperEVMIdentity.amount(row["value"])
                // HypurrScan's call index is stable within a transaction.
                index = "internal:" + String(try HyperEVMIdentity.height(row["index"]))
                // The normalizer excludes depth-zero root calls; index zero
                // can still identify a genuine nested contract transfer.
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
