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
    private var endpoint: URL
    private let alchemyEndpoint: URL?
    private var fallbackEndpoint: URL? {
        if chain == .iotex { return URL(string: "https://babel-api.mainnet.iotex.io") }
        if chain == .zerog { return URL(string: "https://evmrpc.0g.ai") }
        if chain == .sei { return URL(string: "https://evm-rpc.sei-apis.com") }
        if chain == .chiliz { return URL(string: "https://chiliz-rpc.publicnode.com") }
        if chain == .filecoin { return URL(string: "https://api.node.glif.io/rpc/v1") }
        return chain == .celo ? URL(string: "https://forno.celo.org") : alchemyEndpoint
    }
    private let transport: any AnkrTransport
    private let filecoinArchive: FilecoinHistoryArchive
    private let permits = AnkrPermits(count: 4)
    private let indexPermits = AnkrPermits(count: 1)
    public init(chain: IndexedEVMChain, apiKey: String, alchemyAPIKey: String? = nil,
                transport: any AnkrTransport = AnkrHTTPTransport()) throws {
        guard !apiKey.isEmpty, apiKey.count <= 256, apiKey.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }) else {
            throw AnkrError.configurationMissing
        }
        self.chain = chain
        if let key = alchemyAPIKey, !key.isEmpty, ![.zerog, .iotex].contains(chain) {
            guard key.count <= 256, key.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else { throw AnkrError.configurationMissing }
            alchemyEndpoint = URL(string: "https://" + chain.rawValue + "-mainnet.g.alchemy.com/v2")!.appendingPathComponent(key)
        } else { alchemyEndpoint = nil }
        endpoint = URL(string: "https://rpc.ankr.com")!.appendingPathComponent(chain.rpcPath).appendingPathComponent(apiKey)
        self.transport = transport
        filecoinArchive = FilecoinHistoryArchive(transport: transport)
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
        if chain == .filecoin, calls.contains(where: { $0.0 == "eth_getTransactionReceipt" }) { request.timeoutInterval = 12 }
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("OathWallet/1.0", forHTTPHeaderField: "User-Agent")
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
        if chain == .iotex {
            let parts = path.split(separator: "/")
            guard parts.count == 3, parts[0] == "addresses", parts[2] == "tokens" else { throw AnkrError.invalidResponse }
            let page = try IoTeXIndex.parameters(params, history: false).page
            let response = try await iotexRead(action: "addresstokenbalance", module: "token", owner: IoTeXIdentity.ethereum(String(parts[1])), page: page)
            return .init(value: try IoTeXIndex.inventory(response.value, page: page), raw: response.raw)
        }
        if chain == .zerog {
            let parts = path.split(separator: "/")
            guard parts.count == 3, parts[0] == "addresses", parts[2] == "tokens", params.keys.allSatisfy({ $0 == "type" }) else { throw AnkrError.invalidResponse }
            let owner = try IndexedEVMIdentity.address(String(parts[1]))
            let response = try await zeroGRead(path: "token", query: [.init(name: "accountAddress", value: owner)])
            return .init(value: try ZeroGIndex.inventory(response.value), raw: response.raw)
        }
        if chain == .sei { return try await seiIndex(path: path, params: params) }
        guard chain != .monad else { throw AnkrError.configurationMissing }
        let host = chain == .filecoin ? "filecoin.blockscout.com" : chain == .chiliz ? "scan-api.chiliz.com" : chain == .celo ? "celo.blockscout.com" : "unichain.blockscout.com"
        var url = URLComponents(string: "https://" + host + "/api/v2/" + path)!
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
    private func zeroGRead(path: String, query: [URLQueryItem]) async throws -> Exchange {
        var url = URLComponents(string: "https://chainscan.0g.ai/v1/" + path)!
        url.queryItems = query
        var request = URLRequest(url: url.url!); request.timeoutInterval = 25
        request.setValue("OathWallet/1.0", forHTTPHeaderField: "User-Agent")
        try await indexPermits.acquire()
        do {
            try await Task.sleep(for: .milliseconds(220))
            let response = try await exchange(request)
            _ = try ZeroGIndex.result(response.value)
            await indexPermits.release(); return response
        } catch {
            OathDiagnostics.record(error, operation: "zerog_index", context: ["chain": "zerog", "stage": path])
            await indexPermits.release(); throw error
        }
    }
    private func zeroGHistory(owner: String, stream: IndexedEVMHistoryStream, cursor: String?, from: Double, through: Double) async throws -> Exchange {
        let params = try Self.cursor(cursor)
        let query = try ZeroGIndex.query(owner: owner, stream: stream, cursor: params, from: from, through: through)
        let response = try await zeroGRead(path: stream == .transactions ? "transaction" : "transfer", query: query)
        return .init(value: try ZeroGIndex.history(response.value, stream: stream, cursor: params), raw: response.raw)
    }
    private func seiIndex(path: String, params: [String: SolanaJSON]) async throws -> Exchange {
        let parts = path.split(separator: "/")
        guard parts.count == 3, parts[0] == "addresses" else { throw AnkrError.invalidResponse }
        let owner = try IndexedEVMIdentity.address(String(parts[1])), resource = String(parts[2])
        var url = URLComponents(string: "https://api-v2.seistream.app/api/v2/evm/accounts/" + owner + "/" + resource)!
        // Smaller history pages let recent verified entries commit before
        // an older unavailable archive record. Its durable cursor stays open.
        url.queryItems = try SeiIndex.parameters(params, limit: resource == "tokens" ? 50 : 10)
        var request = URLRequest(url: url.url!); request.timeoutInterval = 25
        request.setValue("OathWallet/1.0", forHTTPHeaderField: "User-Agent")
        try await indexPermits.acquire()
        do {
            try await Task.sleep(for: .milliseconds(220))
            let response = try await exchange(request)
            let value = try SeiIndex.normalize(response.value, resource: resource)
            await indexPermits.release()
            return .init(value: value, raw: response.raw)
        } catch {
            OathDiagnostics.record(error, operation: "sei_index", context: ["chain": "sei", "stage": resource])
            await indexPermits.release(); throw error
        }
    }
    private func zeroGTraces(_ hashes: [String]) async throws -> [String: SolanaJSON] {
        var proxy = self; proxy.endpoint = URL(string: "https://chainscan.0g.ai/evm/rpc")!
        let client = proxy
        return try await withThrowingTaskGroup(of: [(String, SolanaJSON)].self) { group in
            for offset in stride(from: 0, to: hashes.count, by: 10) {
                let batch = Array(hashes[offset..<min(offset + 10, hashes.count)])
                group.addTask {
                    let (rows, _) = try await client.rpc(batch.map { ("trace_transaction", [.string($0)]) })
                    return try zip(batch, rows).map { ($0.0, try Self.result($0.1)) }
                }
            }
            var traces: [String: SolanaJSON] = [:]
            for try await batch in group { for (hash, value) in batch { traces[hash] = value } }
            return traces
        }
    }
    private func seiTraces(_ hashes: [String]) async throws -> [String: SolanaJSON] {
        try await withThrowingTaskGroup(of: (String, SolanaJSON).self) { group in
            var next = 0, values: [String: SolanaJSON] = [:]
            func enqueue() {
                guard next < hashes.count else { return }
                let hash = hashes[next]; next += 1
                group.addTask {
                    var request = URLRequest(url: URL(string: "https://api-v2.seistream.app/api/v2/evm/transactions/" + hash + "/raw-trace")!)
                    request.timeoutInterval = 25; request.setValue("OathWallet/1.0", forHTTPHeaderField: "User-Agent")
                    let response = try await exchange(request)
                    return (hash, response.value)
                }
            }
            for _ in 0..<min(2, hashes.count) { enqueue() }
            for try await (hash, value) in group { values[hash] = value; enqueue() }
            return values
        }
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
            guard let items = response.value["items"].array, items.count <= (chain == .zerog ? 10_000 : 50) else { throw AnkrError.invalidResponse }
            raw.append(response.raw)
            for item in items {
                let value = item["token"]
                guard value["type"].string == "ERC-20", let address = value["address_hash"].string else { throw AnkrError.invalidResponse }
                let ref = try IndexedEVMIdentity.address(address)
                if ref == chain.nativeERC20 { continue }
                guard seen.insert(ref).inserted else { throw AnkrError.incompleteInventory }
                if chain != .zerog, value["decimals"].text != nil { tokens[ref] = try IndexedEVMToken.decode(value) }
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
        do { return try await inventoryFromRPC(owner: owner, tracked: tracked) }
        catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            let recoverable: Bool
            switch error {
            case AnkrError.transport: recoverable = true
            case AnkrError.rpc(13): recoverable = chain == .iotex
            case AnkrError.rpc(-32000), AnkrError.rpc(-32603): recoverable = chain == .sei || chain == .zerog || chain == .iotex
            case is HistoryAvailability: recoverable = chain == .sei || chain == .zerog || chain == .iotex
            case AnkrError.http(let status): recoverable = status == 429 || (500...599).contains(status)
            default: recoverable = false
            }
            guard recoverable, let fallbackEndpoint else { throw error }
            OathDiagnostics.record(error, operation: "inventory_rpc_recovery",
                                   context: ["chain": chain.rawValue, "stage": "inventory", "host": endpoint.host ?? ""])
            // Restart the whole snapshot on this chain's independent provider.
            // Recheck chain identity, pinned balances, decimals and block hash;
            // never merge partial results from different provider snapshots.
            // The copy shares concurrency limits; the inner call cannot recurse.
            var recovery = self
            recovery.endpoint = fallbackEndpoint
            try Task.checkCancellation()
            return try await recovery.inventoryFromRPC(owner: owner, tracked: tracked)
        }
    }
    private func inventoryFromRPC(owner: String, tracked: [IndexedEVMToken]) async throws -> IndexedEVMInventory {
        let owner = try chain == .iotex ? IoTeXIdentity.ethereum(owner) : IndexedEVMIdentity.address(owner)
        async let discovery = await OathDiagnostics.attempt("token_discovery") { try await discover(owner: owner) }
        let (head, headRaw) = try await rpc([("eth_chainId", []), ("eth_getBlockByNumber", [.string("latest"), .bool(false)])])
        guard try IndexedEVMIdentity.amount(Self.result(head[0])) == String(chain.chainID) else { throw AnkrError.wrongChain }
        let block = try Self.result(head[1]), height = try IndexedEVMIdentity.height(block["number"])
        guard let blockNumber = block["number"].string, let hash = block["hash"].string, AnkrQuantity.hash(hash) else { throw AnkrError.invalidResponse }
        let discovered = await discovery
        try Task.checkCancellation()
        var tokens = Dictionary((discovered?.0 ?? []).map { ($0.reference, $0) }, uniquingKeysWith: { first, _ in first })
        for token in tracked where token.reference != "native" && token.reference != chain.nativeERC20 {
            if let indexed = tokens[token.reference], indexed.decimals != token.decimals { throw AnkrError.invalidResponse }
            tokens[token.reference] = tokens[token.reference] ?? token
        }
        // Also re-read cached contracts absent from the index, to reconcile
        // zeroes without trusting an asynchronously updated token list.
        let list = [IndexedEVMToken.native(chain)] + tokens.values.sorted { $0.reference < $1.reference }
        // ANKR's IoTeX full node cannot read a numeric state height after its
        // tip advances (RPC 13), even by one block. Keep ANKR's chosen block,
        // but read that immutable snapshot from the official archive. Verify
        // both chain and block before accepting any archive state.
        var stateReader = self
        var stateIdentityRaw: [Data] = []
        if chain == .iotex {
            stateReader.endpoint = URL(string: "https://archive-mainnet.iotex.io")!
            let (identity, raw) = try await stateReader.rpc([
                ("eth_chainId", []), ("eth_getBlockByNumber", [.string(blockNumber), .bool(false)])])
            guard try IndexedEVMIdentity.amount(Self.result(identity[0])) == String(chain.chainID) else { throw AnkrError.wrongChain }
            let archiveBlock = try Self.result(identity[1])
            guard archiveBlock["hash"].string == hash,
                  try IndexedEVMIdentity.height(archiveBlock["number"]) == height else { throw AnkrError.invalidResponse }
            stateIdentityRaw.append(raw)
        }
        let pinnedReader = stateReader
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
                    let (rows, raw) = try await pinnedReader.rpc(calls)
                    var i = 0, holdings: [IndexedEVMHolding] = []
                    for token in chunk {
                        // Keep the native RPC error intact so an unavailable
                        // IoTeX state snapshot can restart on the official node.
                        var amount: String?
                        if chain == .iotex, token.reference == "native" { amount = try IndexedEVMIdentity.amount(Self.result(rows[i])) }
                        else { amount = OathDiagnostics.attempt("balance_call") { try IndexedEVMIdentity.amount(Self.result(rows[i])) } }
                        i += 1
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
        if chain == .iotex {
            let (check, raw) = try await pinnedReader.rpc([("eth_getBlockByNumber", [.string(blockNumber), .bool(false)])])
            let archiveBlock = try Self.result(check[0])
            guard archiveBlock["hash"].string == hash,
                  try IndexedEVMIdentity.height(archiveBlock["number"]) == height else { throw AnkrError.invalidResponse }
            stateIdentityRaw.append(raw)
        }
        // Refuse a mixed snapshot if the pinned block was reorganized while
        // batches were in flight. Cached balances remain untouched on failure.
        let (check, checkRaw) = try await rpc([("eth_getBlockByNumber", [.string(blockNumber), .bool(false)])])
        guard try Self.result(check[0])["hash"].string == hash else { throw AnkrError.invalidResponse }
        let archive = try JSONEncoder().encode(["head": [headRaw, checkRaw] + stateIdentityRaw, "index": discovered?.1 ?? [], "state": gathered.1])
        return .init(chain: chain, owner: owner, block: height, blockHash: hash, observedAt: .now,
                     holdings: gathered.0, complete: discovered?.2 == true && gathered.0.allSatisfy { $0.amount != nil }, raw: archive)
    }
    enum HistoryAvailability: DiagnosticAvailabilityError {
        case missingRPCRecord, filecoinWrappingEvidenceRequired
        var isDiagnosticAvailabilityFailure: Bool {
            // A provider's absent indexed record is availability. Missing
            // evidence needed to validate a wrapping event remains reportable.
            self == .missingRPCRecord
        }
    }

    public func history(owner: String, stream: IndexedEVMHistoryStream, cursor: String? = nil,
                        from: Double = 0, through: Double = Date().timeIntervalSince1970) async throws -> IndexedEVMHistoryPage {
        if chain == .filecoin, stream == .internalTransactions {
            // EVM receipts do not prove internal value movements. Filecoin's
            // native trace evidence also catches shifted explorer hash links.
            return try await filecoinArchiveHistory(owner: owner, stream: stream, cursor: cursor, from: from, through: through)
        }
        do { return try await verifiedHistory(owner: owner, stream: stream, cursor: cursor, from: from, through: through) }
        catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if error is HistoryAvailability, chain == .filecoin {
                OathDiagnostics.record(error, operation: "filecoin_archive_recovery", context: ["chain": "filecoin"])
                return try await filecoinArchiveHistory(owner: owner, stream: stream, cursor: cursor, from: from, through: through)
            }
            let recoverable: Bool
            switch error {
            case AnkrError.transport: recoverable = true
            case AnkrError.rpc(13): recoverable = chain == .iotex
            case AnkrError.rpc(-32000), AnkrError.rpc(-32603): recoverable = chain == .sei || chain == .zerog || chain == .iotex
            case is HistoryAvailability: recoverable = [.celo, .sei, .zerog, .iotex].contains(chain)
            case AnkrError.http(let status): recoverable = status == 429 || (500...599).contains(status)
            default: recoverable = false
            }
            guard [.celo, .chiliz, .filecoin, .sei, .zerog, .iotex].contains(chain), recoverable, let fallbackEndpoint else { throw error }
            OathDiagnostics.record(error, operation: "history_rpc_recovery", context: ["chain": chain.rawValue])
            var recovery = self; recovery.endpoint = fallbackEndpoint
            do { return try await recovery.verifiedHistory(owner: owner, stream: stream, cursor: cursor, from: from, through: through) }
            catch {
                let archiveAvailable: Bool
                switch error {
                case AnkrError.transport, is HistoryAvailability: archiveAvailable = true
                case AnkrError.http(let status): archiveAvailable = status == 429 || (500...599).contains(status)
                default: archiveAvailable = false
                }
                // Public Sei nodes may prune older hash indices or fail while
                // loading archived blocks. The configured archive provider is
                // used only after availability failures, never invalid evidence.
                let seiArchiveAvailable = archiveAvailable || (error as? AnkrError == .rpc(-32603)) || (error as? AnkrError == .rpc(-32000))
                if chain == .sei, seiArchiveAvailable, let alchemyEndpoint {
                    OathDiagnostics.record(error, operation: "sei_archive_recovery", context: ["chain": "sei"])
                    var archive = self; archive.endpoint = alchemyEndpoint
                    return try await archive.verifiedHistory(owner: owner, stream: stream, cursor: cursor, from: from, through: through)
                }
                if chain == .iotex, archiveAvailable || [AnkrError.rpc(13), .rpc(-32603), .rpc(-32000)].contains(error as? AnkrError ?? .invalidResponse) {
                    OathDiagnostics.record(error, operation: "iotex_archive_recovery", context: ["chain": "iotex"])
                    var archive = self; archive.endpoint = URL(string: "https://archive-mainnet.iotex.io")!
                    return try await archive.verifiedHistory(owner: owner, stream: stream, cursor: cursor, from: from, through: through)
                }
                guard chain == .filecoin, archiveAvailable else { throw error }
                OathDiagnostics.record(error, operation: "filecoin_archive_recovery", context: ["chain": "filecoin"])
                return try await filecoinArchiveHistory(owner: owner, stream: stream, cursor: cursor, from: from, through: through)
            }
        }
    }
    private func filecoinArchiveHistory(owner: String, stream: IndexedEVMHistoryStream, cursor: String?,
                                        from: Double, through: Double) async throws -> IndexedEVMHistoryPage {
        let owner = try IndexedEVMIdentity.address(owner)
        let response = try await indexedHistory(owner: owner, stream: stream, cursor: cursor)
        guard var document = response.value.object, var rows = document["items"]?.array, rows.count <= 50 else { throw AnkrError.invalidResponse }
        let hashes = try Set(rows.compactMap { row -> String? in
            if row["timestamp"].isNull, stream == .transactions, row["block_number"].isNull { return nil }
            guard let hash = row[stream == .transactions ? "hash" : "transaction_hash"].string, AnkrQuantity.hash(hash) else { throw AnkrError.invalidResponse }
            return hash.lowercased()
        })
        var messages = try await filecoinArchive.messages(hashes: hashes.sorted(), transferRows: stream == .transfers ? rows : [], internalRows: stream == .internalTransactions ? rows : [])
        var recoveryEvidence: [Data] = []
        var recoveredHashes: [String: String] = [:]
        if stream == .internalTransactions {
            for index in rows.indices {
                let originalHash = rows[index]["transaction_hash"].string?.lowercased() ?? ""
                if let recovered = recoveredHashes[originalHash], case .object(var fields) = rows[index] {
                    fields["transaction_hash"] = .string(recovered)
                    fields["hash_recovered_from_trace_evidence"] = .bool(true)
                    rows[index] = .object(fields)
                }
                do { _ = try FilecoinHistoryArchive.corroborate(rows: [rows[index]], messages: messages, stream: stream) }
                catch {
                    OathDiagnostics.record(error, component: "history", operation: "filecoin_trace_link_validation", context: ["chain": "filecoin"])
                    guard error as? AnkrError == .invalidResponse, recoveryEvidence.count < 50,
                          recoveredHashes[originalHash] == nil else { throw error }
                    let related = rows.filter { $0["transaction_hash"].string?.lowercased() == originalHash }
                    let recovered = try await recoverShiftedFilecoinTrace(rows[index], relatedRows: related)
                    rows[index] = recovered.row; messages[recovered.hash] = recovered.message
                    recoveredHashes[originalHash] = recovered.hash
                    recoveryEvidence.append(recovered.raw)
                    guard recoveryEvidence.reduce(0, { $0 + $1.count }) <= 32 * 1024 * 1024 else { throw AnkrError.responseTooLarge }
                }
            }
        }
        document["items"] = .array(try FilecoinHistoryArchive.corroborate(rows: rows, messages: messages, stream: stream))
        let decoded = try Self.decodeHistory(JSONEncoder().encode(SolanaJSON.object(document)), chain: chain,
            owner: owner, stream: stream, from: from, through: through)
        return .init(chain: chain, events: decoded.events, next: decoded.next,
            raw: try JSONEncoder().encode(["index": [response.raw] + recoveryEvidence, "archive": [JSONEncoder().encode(messages)]]))
    }

    private func recoverShiftedFilecoinTrace(_ row: SolanaJSON, relatedRows: [SolanaJSON] = []) async throws -> (row: SolanaJSON, hash: String, message: SolanaJSON, raw: Data) {
        let height = try IndexedEVMIdentity.height(row["block_number"]), position = try IndexedEVMIdentity.height(row["transaction_index"])
        guard position > 0, case .object(var corrected) = row else { throw AnkrError.invalidResponse }
        var params: [String: SolanaJSON] = [:]
        if position > 1 { params = ["index": .number(String(position - 2)), "block_number": .number(String(height))] }
        let block = try await index(path: "blocks/" + String(height) + "/transactions", params: params)
        guard let transactions = block.value["items"].array, transactions.count <= 50 else { throw AnkrError.invalidResponse }
        let candidates = transactions.filter { $0["position"].text == String(position - 1) && $0["block_number"].text == String(height) && $0["timestamp"] == row["timestamp"] }
        guard candidates.count == 1, let hash = candidates[0]["hash"].string?.lowercased(), AnkrQuantity.hash(hash),
              hash != row["transaction_hash"].string?.lowercased() else { throw AnkrError.invalidResponse }
        corrected["transaction_hash"] = .string(hash)
        corrected["hash_recovered_from_trace_evidence"] = .bool(true)
        let value = SolanaJSON.object(corrected)
        let related = try relatedRows.map { row -> SolanaJSON in
            guard case .object(var fields) = row else { throw AnkrError.invalidResponse }
            fields["transaction_hash"] = .string(hash); return .object(fields)
        }
        let proof = try await filecoinArchive.messages(hashes: [hash], internalRows: related.isEmpty ? [value] : related)
        _ = try FilecoinHistoryArchive.corroborate(rows: [value], messages: proof, stream: .internalTransactions)
        guard let message = proof[hash] else { throw AnkrError.invalidResponse }
        return (value, hash, message, block.raw)
    }
    private func verifiedHistory(owner: String, stream: IndexedEVMHistoryStream, cursor: String?,
                                 from: Double, through: Double) async throws -> IndexedEVMHistoryPage {
        if chain == .iotex { return try await iotexHistory(owner: owner, stream: stream, cursor: cursor, from: from, through: through) }
        let owner = try IndexedEVMIdentity.address(owner)
        let response = try await chain == .zerog
            ? zeroGHistory(owner: owner, stream: stream, cursor: cursor, from: from, through: through)
            : indexedHistory(owner: owner, stream: stream, cursor: cursor)
        // Verify indexed transactions and ERC-20 events against ANKR receipts.
        guard var document = response.value.object, let indexedRows = document["items"]?.array, indexedRows.count <= 50 else { throw AnkrError.invalidResponse }
        // Celo Blockscout synthesizes ERC-20-shaped native transfers using
        // negative log indices. They are not receipt logs. Native external and
        // internal streams already cover these movements; keep real CELO
        // contract logs (nonnegative indices) and map those to the native asset.
        let rows = indexedRows.filter { !Self.isSyntheticNativeTransfer($0, chain: chain, stream: stream) }
        let hashes = try Set(rows.compactMap { row -> String? in
            if row["timestamp"].isNull, stream == .transactions, row["block_number"].isNull { return nil }
            guard let hash = row[stream == .transactions ? "hash" : "transaction_hash"].string, AnkrQuantity.hash(hash) else { throw AnkrError.invalidResponse }
            return hash.lowercased()
        }).sorted()
        async let zeroGTraceTask: [String: SolanaJSON] = chain == .zerog && stream == .internalTransactions ? zeroGTraces(hashes) : [:]
        async let seiTraceTask: [String: SolanaJSON] = chain == .sei && stream == .internalTransactions ? seiTraces(hashes) : [:]
        let missingMetadata = stream == .transfers ? rows.filter {
            $0["token"]["decimals"].text == nil || $0["token"]["name"].string == nil || $0["token"]["symbol"].string == nil
        }.compactMap { $0["token"]["address_hash"].string } : []
        async let metadataTask = metadata(missingMetadata)
        let needsTransaction = stream == .transactions
        let size = (chain.batchLimit - 1) / (needsTransaction ? 2 : 1)
        let batches = stride(from: 0, to: hashes.count, by: size).map { Array(hashes[$0..<min($0 + size, hashes.count)]) }
        var receipts: [String: SolanaJSON] = [:], transactions: [String: SolanaJSON] = [:], receiptRaw: [Data] = []
        try await withThrowingTaskGroup(of: ([String: SolanaJSON], [String: SolanaJSON], Data).self) { group in
            // Index pages are bounded to 50 items: at most four batches.
            for batch in batches {
                group.addTask {
                    var calls = [("eth_chainId", [SolanaJSON]())]
                    for hash in batch {
                        calls.append(("eth_getTransactionReceipt", [.string(hash)]))
                        if needsTransaction { calls.append(("eth_getTransactionByHash", [.string(hash)])) }
                    }
                    let (replies, raw) = try await rpc(calls)
                    guard try IndexedEVMIdentity.amount(Self.result(replies[0])) == String(chain.chainID) else { throw AnkrError.wrongChain }
                    var found: [String: SolanaJSON] = [:], txs: [String: SolanaJSON] = [:], i = 1
                    var recoveryRaw: [Data] = []
                    for hash in batch {
                        // Lotus providers can lack older hash-index entries while
                        // the archival fallback still has the mined transaction.
                        if [.filecoin, .sei, .zerog].contains(chain) || (chain == .celo && endpoint != fallbackEndpoint), replies[i]["error"].isNull, replies[i].object?["result"] == .null {
                            throw HistoryAvailability.missingRPCRecord
                        }
                        let receipt: SolanaJSON
                        if chain == .monad || (chain == .celo && endpoint == fallbackEndpoint), replies[i]["error"].isNull, replies[i].object?["result"] == .null {
                            let heights = try Set(rows.filter {
                                $0[stream == .transactions ? "hash" : "transaction_hash"].string?.lowercased() == hash
                            }.map { try IndexedEVMIdentity.height($0["block_number"]) })
                            guard heights.count == 1, let height = heights.first else { throw AnkrError.invalidResponse }
                            let recovered = try await verifiedBlockReceipt(hash: hash, height: height)
                            receipt = recovered.0; recoveryRaw.append(recovered.1)
                            guard recoveryRaw.reduce(0, { $0 + $1.count }) <= 4 * 1024 * 1024 else { throw AnkrError.responseTooLarge }
                        } else { receipt = try Self.result(replies[i]) }
                        i += 1
                        guard receipt["transactionHash"].string?.lowercased() == hash else { throw OathDiagnostics.failure(AnkrError.invalidResponse, reason: "receipt_transaction_hash_mismatch") }
                        found[hash] = receipt
                        if needsTransaction {
                            if [.filecoin, .sei, .zerog].contains(chain) || (chain == .celo && endpoint != fallbackEndpoint), replies[i]["error"].isNull, replies[i].object?["result"] == .null {
                                throw HistoryAvailability.missingRPCRecord
                            }
                            let tx: SolanaJSON
                            if chain == .monad || (chain == .celo && endpoint == fallbackEndpoint), replies[i]["error"].isNull, replies[i].object?["result"] == .null,
                               let blockHash = receipt["blockHash"].string, AnkrQuantity.hash(blockHash) {
                                let position = try IndexedEVMIdentity.height(receipt["transactionIndex"])
                                let recovered = try await rpc([("eth_getTransactionByBlockHashAndIndex", [.string(blockHash), .string("0x" + String(position, radix: 16))])])
                                tx = try Self.result(recovered.0[0]); recoveryRaw.append(recovered.1)
                                guard recoveryRaw.reduce(0, { $0 + $1.count }) <= 4 * 1024 * 1024 else { throw AnkrError.responseTooLarge }
                                guard try IndexedEVMIdentity.height(tx["transactionIndex"]) == position,
                                      try IndexedEVMIdentity.height(tx["blockNumber"]) == IndexedEVMIdentity.height(receipt["blockNumber"]) else { throw AnkrError.invalidResponse }
                            } else { tx = try Self.result(replies[i]) }
                            i += 1
                            guard tx["hash"].string?.lowercased() == hash, tx["blockHash"] == receipt["blockHash"] else { throw OathDiagnostics.failure(AnkrError.invalidResponse, reason: "transaction_receipt_block_mismatch") }
                            txs[hash] = tx
                        }
                    }
                    return (found, txs, recoveryRaw.isEmpty ? raw : try JSONEncoder().encode([raw] + recoveryRaw))
                }
            }
            for try await (found, txs, raw) in group {
                receipts.merge(found, uniquingKeysWith: { first, _ in first })
                transactions.merge(txs, uniquingKeysWith: { first, _ in first }); receiptRaw.append(raw)
            }
        }
        let (resolvedMetadata, metadataRaw) = try await metadataTask
        let feeReferences = chain == .celo ? transactions.values.compactMap { $0["feeCurrency"].string } : []
        let (feeMetadata, feeMetadataRaw) = try await metadata(feeReferences)
        let seiTraceEvidence = try await seiTraceTask
        let zeroGTraceEvidence = try await zeroGTraceTask
        var enriched: [SolanaJSON] = []
        for row in rows {
            if row["timestamp"].isNull, stream == .transactions, row["block_number"].isNull { continue }
            guard var value = row.object, let hash = row[stream == .transactions ? "hash" : "transaction_hash"].string?.lowercased(),
                  let receipt = receipts[hash] else { throw OathDiagnostics.failure(AnkrError.invalidResponse, reason: "indexed_receipt_missing") }
            let height = try IndexedEVMIdentity.height(receipt["blockNumber"])
            if !row["block_number"].isNull, try IndexedEVMIdentity.height(row["block_number"]) != height { throw OathDiagnostics.failure(AnkrError.invalidResponse, reason: "indexed_receipt_height_mismatch") }
            if let indexedHash = row["block_hash"].string, indexedHash.lowercased() != receipt["blockHash"].string?.lowercased() { throw OathDiagnostics.failure(AnkrError.invalidResponse, reason: "indexed_block_hash_mismatch") }
            value["block_number"] = .number(String(height))
            let status = try IndexedEVMIdentity.amount(receipt["status"])
            guard status == "0" || status == "1" else { throw OathDiagnostics.failure(AnkrError.invalidResponse, reason: "receipt_status_invalid") }
            if stream == .transactions {
                guard let tx = transactions[hash],
                      tx["from"].string?.lowercased() == row["from"]["hash"].string?.lowercased(),
                      tx["to"].string?.lowercased() == row["to"]["hash"].string?.lowercased(),
                      try IndexedEVMIdentity.amount(tx["value"]) == IndexedEVMIdentity.amount(row["value"]) else { throw OathDiagnostics.failure(AnkrError.invalidResponse, reason: "indexed_transaction_fields_mismatch") }
                if tx["to"].isNull {
                    // Alchemy external transfers use an explicit null recipient
                    // for contract creation. Resolve its destination from the
                    // independently verified receipt, never from index metadata.
                    // Sei omits the receipt recipient on contract creation;
                    // the transaction must still explicitly declare a null to.
                    guard tx.object?["to"] == .null, row.object?["to"] == .null,
                          (receipt.object?["to"] == .null || (chain == .sei && receipt.object?["to"] == nil)),
                          receipt["from"].string?.lowercased() == tx["from"].string?.lowercased() else { throw OathDiagnostics.failure(AnkrError.invalidResponse, reason: "contract_creation_receipt_mismatch") }
                    if status == "1" {
                        guard let created = receipt["contractAddress"].string else { throw OathDiagnostics.failure(AnkrError.invalidResponse, reason: "created_contract_missing") }
                        let address = try IndexedEVMIdentity.address(created)
                        if let indexed = row["created_contract"]["hash"].string,
                           try IndexedEVMIdentity.address(indexed) != address { throw OathDiagnostics.failure(AnkrError.invalidResponse, reason: "created_contract_mismatch") }
                        value["created_contract"] = .object(["hash": .string(address)])
                    } else {
                        // A failed deployment creates no contract. Keep the
                        // existing failed-event representation and actual fee.
                        value["created_contract"] = .null
                    }
                }
                value["value"] = tx["value"]
                value["status"] = .string(status == "1" ? "ok" : "error")
                var fee = try AnkrQuantity.multiply(IndexedEVMIdentity.amount(receipt["gasUsed"]), IndexedEVMIdentity.amount(receipt["effectiveGasPrice"].isNull ? tx["gasPrice"] : receipt["effectiveGasPrice"]))
                if chain == .unichain, !receipt["l1Fee"].isNull { fee = try AptosIdentity.add(fee, IndexedEVMIdentity.amount(receipt["l1Fee"])) }
                if chain == .celo, !tx["feeCurrency"].isNull {
                    // Fee abstraction prices gas in another currency. Keep that
                    // evidence separately; it must never become a CELO debit.
                    value["fee"] = .null
                    value["fee_currency"] = tx["feeCurrency"]
                    value["fee_currency_amount"] = .string(fee)
                    if let ref = tx["feeCurrency"].string?.lowercased(), let token = feeMetadata[ref] {
                        value["fee_currency_token"] = .object(["type": .string("ERC-20"), "address_hash": .string(ref),
                            "name": .string(token.name), "symbol": .string(token.symbol), "decimals": .number(String(token.decimals))])
                    }
                } else {
                    value["fee"] = .object(["type": .string("actual"), "value": .string(fee)])
                }
            } else if stream == .transfers {
                guard status == "1", let logs = receipt["logs"].array else { throw AnkrError.invalidResponse }
                let log: SolanaJSON
                if chain == .zerog {
                    guard let position = row["transaction_log_index"].text.flatMap(Int.init), logs.indices.contains(position) else { throw AnkrError.invalidResponse }
                    log = logs[position]
                } else {
                    guard let found = logs.first(where: { (try? IndexedEVMIdentity.amount($0["logIndex"])) == row["log_index"].text }) else { throw AnkrError.invalidResponse }
                    log = found
                }
                if chain == .filecoin, let topics = log["topics"].array, topics.count == 2,
                   log["address"].string?.lowercased() != chain.wrappedNative,
                   ["0xe1fffcc4923d04b559f4d29a8bfc6cda04eb5b0d3c460751c2402c5c5cc9109c",
                    "0x7fcf532c15f0a6db0bd6d0e038bea71d30d808c7d98cb3bf7268a95bf5081b65"].contains(topics[0].string ?? "") {
                    throw HistoryAvailability.filecoinWrappingEvidenceRequired
                }
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
            } else {
                if chain == .zerog {
                    guard let traces = zeroGTraceEvidence[hash] else { throw AnkrError.invalidResponse }
                    value["success"] = .bool(try ZeroGTrace.corroborate(row, traces: traces, receipt: receipt))
                }
                if chain == .sei {
                    guard let traces = seiTraceEvidence[hash] else { throw AnkrError.invalidResponse }
                    value["success"] = .bool(try SeiIndex.corroborateInternal(row, traces: traces))
                }
                if status == "0" { value["success"] = .bool(false) }
            }
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
                     raw: try JSONEncoder().encode(["index": [response.raw], "receipts": receiptRaw, "metadata": metadataRaw + feeMetadataRaw, "traces": chain == .sei ? [JSONEncoder().encode(seiTraceEvidence)] : chain == .zerog ? [JSONEncoder().encode(zeroGTraceEvidence)] : []]))
    }
    /// Nodes can retain block receipts after their transaction-hash index
    /// becomes unavailable. Use ANKR on Monad and the existing Celo archive
    /// fallback for records missing from its primary provider, accepting
    /// only a unique receipt at the exact position in the canonical block.
    /// Work remains bounded by the index page's maximum of 50 transactions.
    private func verifiedBlockReceipt(hash: String, height: Int64) async throws -> (SolanaJSON, Data) {
        let number = SolanaJSON.string("0x" + String(height, radix: 16))
        let (replies, raw) = try await rpc([
            ("eth_chainId", []), ("eth_getBlockByNumber", [number, .bool(false)]),
            ("eth_getBlockReceipts", [number])
        ])
        guard try IndexedEVMIdentity.amount(Self.result(replies[0])) == String(chain.chainID) else { throw AnkrError.wrongChain }
        let block = try Self.result(replies[1])
        guard try IndexedEVMIdentity.height(block["number"]) == height,
              let blockHash = block["hash"].string, AnkrQuantity.hash(blockHash),
              let transactions = block["transactions"].array, transactions.count <= 10_000,
              let receipts = try Self.result(replies[2]).array, receipts.count <= 10_000 else { throw AnkrError.invalidResponse }
        let matches = receipts.filter { $0["transactionHash"].string?.lowercased() == hash }
        guard matches.count == 1 else { throw AnkrError.invalidResponse }
        let receipt = matches[0], position = try IndexedEVMIdentity.height(receipt["transactionIndex"])
        guard receipt["blockHash"].string?.lowercased() == blockHash.lowercased(),
              try IndexedEVMIdentity.height(receipt["blockNumber"]) == height,
              position < transactions.count, transactions[Int(position)].string?.lowercased() == hash else { throw AnkrError.invalidResponse }
        return (receipt, raw)
    }
    static func isSyntheticNativeTransfer(_ row: SolanaJSON, chain: IndexedEVMChain, stream: IndexedEVMHistoryStream) -> Bool {
        chain == .celo && stream == .transfers &&
        row["token"]["address_hash"].string?.lowercased() == chain.nativeERC20 &&
        (row["log_index"].text.flatMap(Int64.init).map { $0 < 0 } ?? false)
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
        // Nested zero-value calls do not change holdings. Top-level contract
        // interactions and failed transactions stay in the transactions stream.
        // Filecoin's unfiltered trace index can time out on dormant accounts.
        if chain == .filecoin, stream == .internalTransactions { params["include_zero_value"] = .bool(false) }
        let page = try await index(path: "addresses/" + owner + "/" + (stream == .transfers ? "token-transfers" : stream.rawValue), params: params)
        guard chain == .filecoin, stream == .internalTransactions, var document = page.value.object,
              let rows = page.value["items"].array, rows.count <= 50 else { return page }
        let missing = rows.filter { $0["transaction_hash"].isNull }
        guard !missing.isEmpty else { return page }
        OathDiagnostics.record(AnkrError.invalidResponse, component: "history", operation: "filecoin_trace_hash_recovery", context: ["chain": "filecoin"])
        let heights = try Set(missing.map { try IndexedEVMIdentity.height($0["block_number"]) })
        guard heights.count <= 8 else { throw AnkrError.responseTooLarge }
        var candidates: [SolanaJSON] = [], evidence: [Data] = [page.raw]
        for height in heights.sorted() {
            var cursor: [String: SolanaJSON] = [:], visited: Set<String> = []
            for count in 0..<10 {
                let block = try await index(path: "blocks/" + String(height) + "/transactions", params: cursor)
                guard let transactions = block.value["items"].array, transactions.count <= 50 else { throw AnkrError.invalidResponse }
                candidates += transactions; evidence.append(block.raw)
                guard evidence.reduce(0, { $0 + $1.count }) <= 32 * 1024 * 1024 else { throw AnkrError.responseTooLarge }
                guard let next = try Self.next(block.value) else { break }
                guard count < 9, visited.insert(next).inserted else { throw AnkrError.paginationLoop }
                cursor = try Self.cursor(next)
            }
        }
        var recoveredRows: [SolanaJSON] = []
        for row in rows {
            guard row["transaction_hash"].isNull else { recoveredRows.append(row); continue }
            do { recoveredRows.append(try Self.recoverFilecoinTraceHash(row, candidates: candidates)) }
            catch {
                OathDiagnostics.record(error, component: "history", operation: "filecoin_trace_parent_lookup", context: ["chain": "filecoin"])
                guard error as? AnkrError == .invalidResponse else { throw error }
                let recovered = try await recoverShiftedFilecoinTrace(row)
                recoveredRows.append(recovered.row); evidence.append(recovered.raw)
                guard evidence.reduce(0, { $0 + $1.count }) <= 32 * 1024 * 1024 else { throw AnkrError.responseTooLarge }
            }
        }
        document["items"] = .array(recoveredRows)
        return .init(value: .object(document), raw: try JSONEncoder().encode(evidence))
    }
    static func recoverFilecoinTraceHash(_ row: SolanaJSON, candidates: [SolanaJSON]) throws -> SolanaJSON {
        guard case .object(var fields) = row else { throw AnkrError.invalidResponse }
        // Some older root traces have a shifted transaction index. Recover
        // only a unique exact top-level transfer; never guess a hash by offset.
        let matches = candidates.filter { candidate in
            candidate["block_number"].text == row["block_number"].text && candidate["timestamp"] == row["timestamp"]
                && candidate["from"]["hash"].string?.lowercased() == row["from"]["hash"].string?.lowercased()
                && candidate["to"]["hash"].string?.lowercased() == row["to"]["hash"].string?.lowercased()
                && candidate["value"].text == row["value"].text
                && candidate["status"].string == (row["success"] == .bool(true) ? "ok" : "error")
        }
        guard matches.count == 1, let hash = matches[0]["hash"].string, AnkrQuantity.hash(hash) else { throw AnkrError.invalidResponse }
        fields["transaction_hash"] = .string(hash)
        fields["hash_recovered_from_block"] = .bool(true)
        return .object(fields)
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
            guard date <= last else { throw OathDiagnostics.failure(AnkrError.invalidResponse, reason: "history_timestamp_order_invalid") }; last = date
            if date < from { crossed = true; continue }
            if date > through { continue }
            guard let hash = row[stream == .transactions ? "hash" : "transaction_hash"].string,
                  AnkrQuantity.hash(hash), let sender = row["from"]["hash"].string else { throw OathDiagnostics.failure(AnkrError.invalidResponse, reason: "history_hash_or_sender_missing") }
            let receiver = row["to"]["hash"].string ?? row["created_contract"]["hash"].string ?? "0x" + String(repeating: "0", count: 40)
            let senderAddress = try IndexedEVMIdentity.address(sender), recipient = try IndexedEVMIdentity.address(receiver)
            guard senderAddress == owner || recipient == owner else { throw AnkrError.wrongAccount }
            let height = try IndexedEVMIdentity.height(row["block_number"])
            var token: IndexedEVMToken? = .native(chain)
            var amount: String, failed = false, fee: String?, index = "external"
            switch stream {
            case .transactions:
                guard ["ok", "error"].contains(row["status"].string) else { throw OathDiagnostics.failure(AnkrError.invalidResponse, reason: "indexed_status_invalid") }
                failed = row["status"].string == "error"; amount = try IndexedEVMIdentity.amount(row["value"])
                if !row["fee"]["value"].isNull { fee = try IndexedEVMIdentity.amount(row["fee"]["value"]) }
            case .transfers:
                if row["metadata_unavailable"] == .bool(true) { token = nil }
                else {
                    let decoded = try IndexedEVMToken.decode(row["token"])
                    guard row["total"]["decimals"].text == String(decoded.decimals) else { throw OathDiagnostics.failure(AnkrError.invalidResponse, reason: "transfer_decimals_mismatch") }
                    token = decoded.reference == chain.nativeERC20 ? .native(chain) : decoded
                }
                amount = try IndexedEVMIdentity.amount(row["total"]["value"])
                index = "log:" + String(try IndexedEVMIdentity.height(row["log_index"]))
            case .internalTransactions:
                guard case .bool(let success) = row["success"] else { throw OathDiagnostics.failure(AnkrError.invalidResponse, reason: "internal_transfer_status_missing") }
                failed = !success; amount = try IndexedEVMIdentity.amount(row["value"])
                // Blockscout's call index is stable within a transaction.
                index = "internal:" + String(try IndexedEVMIdentity.height(row["index"]))
                // Blockscout excludes the root frame. A nested transfer can
                // legitimately have index zero.
            }
            let id = hash.lowercased() + ":" + index
            guard ids.insert(id).inserted else { throw OathDiagnostics.failure(AnkrError.invalidResponse, reason: "duplicate_history_identity") }
            events.append(.init(id: id, hash: hash.lowercased(), block: height, timestamp: date,
                                token: token, amount: failed ? "0" : amount, from: senderAddress, to: recipient,
                                failed: failed, fee: fee, raw: try JSONEncoder().encode(row),
                                feeCurrency: row["fee_currency_token"].isNull ? nil : try IndexedEVMToken.decode(row["fee_currency_token"]),
                                feeCurrencyAmount: row["fee_currency_amount"].isNull ? nil : try IndexedEVMIdentity.amount(row["fee_currency_amount"])))
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
        // are read independently from the selected RPC at the pinned block.
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
                  let from = transfer["from"].string,
                  let timestamp = transfer["metadata"]["blockTimestamp"].string else { throw AnkrError.invalidResponse }
            _ = try IndexedEVMIdentity.address(from)
            let to = transfer["to"].string
            if let to { _ = try IndexedEVMIdentity.address(to) }
            else {
                guard stream == .transactions, direction == "out", transfer.object?["to"] == .null else { throw AnkrError.invalidResponse }
            }
            guard (direction == "out" ? from : to)?.lowercased() == owner else { throw AnkrError.wrongAccount }
            let amount = try IndexedEVMIdentity.amount(transfer["rawContract"]["value"])
            var row: [String: SolanaJSON] = ["timestamp": .string(timestamp), "block_number": transfer["blockNum"],
                "from": .object(["hash": .string(from)]), "to": to.map { .object(["hash": .string($0)]) } ?? .null]
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


private extension IndexedEVMClient {
    private func iotexRead(action: String, module: String, owner: String, page: Int, end: Int64? = nil) async throws -> Exchange {
        var url = URLComponents(string: "https://dev.iotexscan.io/api")!
        url.queryItems = [.init(name: "module", value: module), .init(name: "action", value: action),
            .init(name: "address", value: owner), .init(name: "page", value: String(page)),
            .init(name: "offset", value: String(IoTeXIndex.pageSize)), .init(name: "sort", value: "desc")]
        if let end { url.queryItems! += [.init(name: "startblock", value: "0"), .init(name: "endblock", value: String(end))] }
        var request = URLRequest(url: url.url!); request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("OathWallet/1.0", forHTTPHeaderField: "User-Agent")
        // The public index allows one request/second across clients. RPC batches
        // use a separate pool and continue while discovery waits for this slot.
        try await IoTeXIndex.permits.acquire()
        do {
            try await Task.sleep(for: .milliseconds(1050))
            let result = try await exchange(request)
            _ = try IoTeXIndex.rows(result.value)
            await IoTeXIndex.permits.release(); return result
        } catch {
            OathDiagnostics.record(error, operation: "iotex_index", context: ["chain": "iotex", "stage": action])
            await IoTeXIndex.permits.release(); throw error
        }
    }
    func iotexHistory(owner input: String, stream: IndexedEVMHistoryStream, cursor: String?, from: Double, through: Double) async throws -> IndexedEVMHistoryPage {
        let owner = try IoTeXIdentity.ethereum(input)
        let saved = try Self.cursor(cursor)
        var next: SolanaJSON, response: Exchange, end: Int64
        let (head, headRaw) = try await rpc([("eth_chainId", []), ("eth_blockNumber", [])])
        guard try IndexedEVMIdentity.amount(Self.result(head[0])) == "4689" else { throw AnkrError.wrongChain }
        end = try IndexedEVMIdentity.height(Self.result(head[1]))
        let rows: [SolanaJSON]
        if stream == .transactions {
            guard saved.isEmpty || (Set(saved.keys) == ["native_before"] && saved["native_before"]?.integer != nil) else { throw OathDiagnostics.failure(AnkrError.invalidResponse, reason: "iotex_history_validation") }
            let page = try await IoTeXNativeLogs.accountActions(owner: owner, before: saved["native_before"]?.integer, transport: transport)
            rows = page.rows; response = .init(value: .null, raw: page.raw)
            next = page.next.map { .object(["native_before": .number(String($0))]) } ?? .null
            // Native enumeration is pinned by its ascending action offset. A
            // later deposit appends after that bound instead of shifting pages.
            if let newest = rows.first { end = max(end, try IoTeXIndex.height(newest, stream: stream)) }
        } else {
            let params = try IoTeXIndex.parameters(saved, history: true)
            end = params.end ?? end
            let action = stream == .transfers ? "tokentx" : "txlistinternal"
            response = try await iotexRead(action: action, module: "account", owner: owner, page: params.page, end: end)
            rows = try IoTeXIndex.rows(response.value)
            next = rows.count == IoTeXIndex.pageSize ? .object(["page": .number(String(params.page + 1)), "endblock": .number(String(end))]) : .null
        }
        var ordered: [String] = [], heights: [String: Int64] = [:], lastHeight = end
        for row in rows {
            let hash = try IoTeXIndex.hash(row, stream: stream), height = try IoTeXIndex.height(row, stream: stream)
            guard height <= lastHeight, heights[hash] == nil || heights[hash] == height else { throw OathDiagnostics.failure(AnkrError.invalidResponse, reason: "iotex_history_validation") }
            lastHeight = height
            if heights[hash] == nil { ordered.append(hash); heights[hash] = height }
        }
        var receipts: [String: SolanaJSON] = [:], transactions: [String: SolanaJSON] = [:]
        var evidence = [headRaw, response.raw]
        let size = 14
        try await withThrowingTaskGroup(of: ([String: SolanaJSON], [String: SolanaJSON], Data).self) { group in
            for offset in stride(from: 0, to: ordered.count, by: size) {
                let hashes = Array(ordered[offset..<min(offset + size, ordered.count)])
                group.addTask {
                    var calls: [(String, [SolanaJSON])] = []
                    for hash in hashes {
                        calls += [("eth_getTransactionReceipt", [.string(hash)]), ("eth_getTransactionByHash", [.string(hash)])]

                    }
                    let (replies, raw) = try await rpc(calls)
                    var receipts: [String: SolanaJSON] = [:], txs: [String: SolanaJSON] = [:], i = 0
                    for hash in hashes {
                        if replies[i]["error"].isNull, replies[i]["result"].isNull { throw HistoryAvailability.missingRPCRecord }
                        let receipt = try Self.result(replies[i]), tx = try Self.result(replies[i + 1]); i += 2
                        guard receipt["transactionHash"].string?.lowercased() == hash, tx["hash"].string?.lowercased() == hash,
                              receipt["blockHash"] == tx["blockHash"], receipt["blockNumber"] == tx["blockNumber"] else { throw OathDiagnostics.failure(AnkrError.invalidResponse, reason: "iotex_history_validation") }
                        _ = try IoTeXIndex.succeeded(receipt)
                        receipts[hash] = receipt; txs[hash] = tx

                    }
                    return (receipts, txs, raw)
                }
            }
            for try await batch in group {
                receipts.merge(batch.0, uniquingKeysWith: { first, _ in first }); transactions.merge(batch.1, uniquingKeysWith: { first, _ in first })
                evidence.append(batch.2)
            }
        }
        let blocks = Set(heights.values).sorted()
        async let nativeTask: [(Int64, IoTeXNativeLogs, Data)] = {
            guard stream == .internalTransactions else { return [] }
            return try await withThrowingTaskGroup(of: (Int64, IoTeXNativeLogs, Data).self) { group in
                let transport = self.transport
                for height in blocks {
                    group.addTask {
                        let (logs, raw) = try await IoTeXNativeLogs.read(height: height, transport: transport)
                        return (height, logs, raw)
                    }
                }
                var results: [(Int64, IoTeXNativeLogs, Data)] = [], bytes = 0
                for try await result in group {
                    bytes += result.2.count
                    guard bytes <= 32 * 1024 * 1024 else { throw AnkrError.responseTooLarge }
                    results.append(result)
                }
                return results
            }
        }()
        let blockResults = try await withThrowingTaskGroup(of: ([Int64: SolanaJSON], Data).self) { group in
            for offset in stride(from: 0, to: blocks.count, by: chain.batchLimit) {
                let batch = Array(blocks[offset..<min(offset + chain.batchLimit, blocks.count)])
                group.addTask {
                    let (replies, raw) = try await rpc(batch.map { ("eth_getBlockByNumber", [.string("0x" + String($0, radix: 16)), .bool(false)]) })
                    var found: [Int64: SolanaJSON] = [:]
                    for (i, height) in batch.enumerated() { found[height] = try Self.result(replies[i]) }
                    return (found, raw)
                }
            }
            var found: [Int64: SolanaJSON] = [:], raw: [Data] = []
            for try await (values, data) in group { found.merge(values, uniquingKeysWith: { first, _ in first }); raw.append(data) }
            return (found, raw)
        }
        let nativeResults = try await nativeTask
        let nativeLogs = Dictionary(uniqueKeysWithValues: nativeResults.map { ($0.0, $0.1) })
        let blockData = blockResults.0
        evidence += blockResults.1 + nativeResults.map { $0.2 }
        var items: [SolanaJSON] = []
        for hash in ordered {
            guard let receipt = receipts[hash], let tx = transactions[hash], let height = heights[hash], let block = blockData[height],
                  try IndexedEVMIdentity.height(receipt["blockNumber"]) == height else { throw OathDiagnostics.failure(AnkrError.invalidResponse, reason: "iotex_history_validation") }
            var fields = try IoTeXIndex.base(hash, receipt: receipt, block: block)
            switch stream {
            case .transactions:
                fields["hash"] = .string(hash); fields["from"] = .object(["hash": tx["from"]])
                fields["to"] = tx["to"].isNull ? .null : .object(["hash": tx["to"]])
                fields["created_contract"] = receipt["contractAddress"].isNull ? .null : .object(["hash": receipt["contractAddress"]])
                fields["value"] = tx["value"]
                fields["status"] = .string(try IoTeXIndex.succeeded(receipt) ? "ok" : "error")
                let fee = try AnkrQuantity.multiply(IndexedEVMIdentity.amount(receipt["gasUsed"]), IndexedEVMIdentity.amount(receipt["effectiveGasPrice"].isNull ? tx["gasPrice"] : receipt["effectiveGasPrice"]))
                fields["fee"] = .object(["value": .string(fee)]); items.append(.object(fields))
            case .transfers:
                // Expand the complete receipt. A page can split one transaction;
                // stable receipt log IDs make that overlap safe to upsert.
                items += try IoTeXIndex.transfers(hash: hash, receipt: receipt, block: block, owner: owner)
            case .internalTransactions:
                guard let logs = nativeLogs[height] else { throw OathDiagnostics.failure(AnkrError.invalidResponse, reason: "iotex_history_validation") }
                items += try logs.movements(hash: hash, receipt: receipt, transaction: tx, block: block, owner: owner)
            }
        }
        if stream == .transfers {
            let (tokens, raw) = try await metadata(items.compactMap { $0["token"]["address_hash"].string }); evidence += raw
            items = try items.map { row in
                guard case .object(var value) = row else { throw OathDiagnostics.failure(AnkrError.invalidResponse, reason: "iotex_history_validation") }
                if let ref = row["token"]["address_hash"].string, let token = tokens[ref] {
                    value["token"] = .object(["type": .string("ERC-20"), "address_hash": .string(ref), "name": .string(token.name), "symbol": .string(token.symbol), "decimals": .number(String(token.decimals))])
                    value["total"] = .object(["value": row["total"]["value"], "decimals": .number(String(token.decimals))])
                } else { value["metadata_unavailable"] = .bool(true) }
                return .object(value)
            }
        }
        guard items.count <= 50_000, evidence.reduce(0, { $0 + $1.count }) <= 64 * 1024 * 1024 else { throw AnkrError.responseTooLarge }
        let normalized = try JSONEncoder().encode(SolanaJSON.object(["items": .array(items), "next_page_params": next]))
        let decoded = try Self.decodeHistory(normalized, chain: .iotex, owner: owner, stream: stream, from: from, through: through)
        return .init(chain: .iotex, events: decoded.events, next: decoded.next, raw: try JSONEncoder().encode(evidence))
    }
}
