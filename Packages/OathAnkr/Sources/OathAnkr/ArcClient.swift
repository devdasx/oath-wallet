import OathDiagnostics
import Foundation

/// State is read directly from mainnet. Envio provides address-filtered archive
/// discovery (including EIP-7708), not an estimated balance made from log sums.
public struct ArcClient: Sendable {
    private let transport: any AnkrTransport
    private let indexKey: String?
    private let endpoints: [URL]
    private let permits = AnkrPermits(count: 4)
    private let indexPermits = AnkrPermits(count: 2)
    public var hasIndex: Bool { indexKey != nil }
    public init(indexKey: String? = nil, transport: any AnkrTransport = AnkrHTTPTransport()) throws {
        if let indexKey, !indexKey.isEmpty {
            guard indexKey.count <= 4096, indexKey.utf8.allSatisfy({ (33...126).contains($0) }) else { throw AnkrError.configurationMissing }
            self.indexKey = indexKey
        } else { self.indexKey = nil }
        self.transport = transport
        endpoints = ["https://rpc.blockdaemon.mainnet.arc.io", "https://rpc.drpc.mainnet.arc.io", "https://rpc.mainnet.arc.io"].map { URL(string: $0)! }
    }
    private func exchange(_ request: URLRequest) async throws -> (SolanaJSON, Data) {
        for attempt in 0..<3 {
            try Task.checkCancellation()
            do {
                let (data,status) = try await transport.send(request)
                guard status == 200 else { throw AnkrError.http(status) }
                guard data.count <= 32 * 1024 * 1024 else { throw AnkrError.responseTooLarge }
                return (try JSONDecoder().decode(SolanaJSON.self, from: data), data)
            } catch { OathDiagnostics.record(error);
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                let retry: Bool
                switch error {
                case AnkrError.http(let status): retry = status == 429 || (500...599).contains(status)
                case AnkrError.transport: retry = true
                default: retry = false
                }
                if retry, attempt < 2 { try await Task.sleep(for: .milliseconds(500 * (1 << attempt))); continue }
                throw (error as? AnkrError) ?? .invalidResponse
            }
        }
        throw AnkrError.transport
    }
    static func result(_ row: SolanaJSON) throws -> SolanaJSON {
        if let code = row["error"]["code"].text.flatMap(Int.init) { throw AnkrError.rpc(code) }
        guard case .object(let object) = row, let result = object["result"], !result.isNull else { throw AnkrError.invalidResponse }
        return result
    }
    /// Every batch includes chain identity and correlates IDs, including when a
    /// fallback endpoint is used. Never route an Arc request to a test network.
    private func rpc(_ calls: [(String,[SolanaJSON])]) async throws -> ([SolanaJSON],Data) {
        guard !calls.isEmpty, calls.count < 30 else { throw AnkrError.invalidResponse }
        let checked = [("eth_chainId",[SolanaJSON]())] + calls
        let body = SolanaJSON.array(checked.enumerated().map { i, call in
            .object(["jsonrpc":.string("2.0"),"id":.number(String(i)),"method":.string(call.0),"params":.array(call.1)])
        })
        try await permits.acquire()
        do {
            var failure: AnkrError = .transport
            for endpoint in endpoints {
                do {
                    var request = URLRequest(url:endpoint); request.httpMethod = "POST"
                    request.setValue("application/json",forHTTPHeaderField:"Content-Type"); request.httpBody = try JSONEncoder().encode(body)
                    let (json,raw) = try await exchange(request)
                    guard let rows = json.array, rows.count == checked.count else { throw AnkrError.invalidResponse }
                    var ordered = [SolanaJSON?](repeating:nil,count:checked.count)
                    for row in rows {
                        guard row["jsonrpc"].string == "2.0", let id = row["id"].integer,
                              id >= 0, id < checked.count, ordered[Int(id)] == nil else { throw AnkrError.invalidResponse }
                        ordered[Int(id)] = row
                    }
                    guard try ArcIdentity.amount(Self.result(ordered[0]!)) == String(ArcIdentity.chainID) else { throw AnkrError.wrongChain }
                    await permits.release(); return (ordered.dropFirst().map { $0! },raw)
                } catch { OathDiagnostics.record(error);
                    if Task.isCancelled || error is CancellationError { throw CancellationError() }
                    failure = (error as? AnkrError) ?? .invalidResponse
                }
            }
            throw failure
        } catch { OathDiagnostics.record(error); await permits.release(); throw error }
    }
    public func head() async throws -> (height:Int64,hash:String) {
        let (rows,_) = try await rpc([("eth_getBlockByNumber",[.string("latest"),.bool(false)])])
        let block = try Self.result(rows[0]), height = try ArcIdentity.height(block["number"])
        guard let hash = block["hash"].string, AnkrQuantity.hash(hash) else { throw AnkrError.invalidResponse }
        return (height,hash.lowercased())
    }
    private static func call(_ ref:String,_ data:String,_ height:String) -> (String,[SolanaJSON]) {
        ("eth_call",[.object(["to":.string(ref),"data":.string(data)]),.string(height)])
    }
    private static func word(_ row: SolanaJSON) throws -> String {
        guard let text = try result(row).string, AnkrQuantity.hash(text) else { throw AnkrError.invalidResponse }
        return try AnkrQuantity.decimal(text)
    }
    private static func token(reference:String,rows:ArraySlice<SolanaJSON>) throws -> ArcToken {
        let values = Array(rows)
        guard values.count == 3, let decimals = Int(try word(values[2])), (0...255).contains(decimals) else { throw AnkrError.invalidResponse }
        // ERC-20 names and symbols are optional. Do not confuse a missing label
        // with a failed balance, or use the symbol as a price identity.
        let fallback = String(reference.prefix(8)) + "…" + reference.suffix(4)
        let name = (try? result(values[0]).string.flatMap { try? TronIdentity.abiString($0) }) ?? nil
        let symbol = (try? result(values[1]).string.flatMap { try? TronIdentity.abiString($0) }) ?? nil
        return try ArcToken(reference:reference,name:name ?? fallback,symbol:symbol ?? fallback,decimals:decimals)
    }
    public func inventory(owner:String, references:[String], tracked:[ArcToken] = []) async throws -> ArcInventory {
        let owner = try ArcIdentity.address(owner), anchor = try await head()
        let height = "0x" + String(anchor.height,radix:16)
        let refs = try Set((references + tracked.map(\.reference)).map(ArcIdentity.reference)).subtracting(["native"]).sorted()
        guard refs.count <= 100_000 else { throw AnkrError.responseTooLarge }
        let saved = Dictionary(tracked.map { ($0.reference,$0) },uniquingKeysWith:{ first,_ in first })
        let data = "0x70a08231" + String(repeating:"0",count:24) + owner.dropFirst(2)
        async let native = rpc([("eth_getBalance",[.string(owner),.string(height)]), Self.call(ArcIdentity.usdc,data,height)])
        let chunks = stride(from:0,to:refs.count,by:6).map { Array(refs[$0..<min($0+6,refs.count)]) }
        let gathered = try await withThrowingTaskGroup(of:([ArcHolding],Data,Bool).self) { group in
            var next = 0, holdings:[ArcHolding] = [], raw:[Data] = [], complete = true
            func enqueue() {
                guard next < chunks.count else { return }
                let chunk = chunks[next]; next += 1
                group.addTask {
                    let calls = chunk.flatMap { ref in [Self.call(ref,"0x06fdde03",height),Self.call(ref,"0x95d89b41",height),Self.call(ref,"0x313ce567",height),Self.call(ref,data,height)] }
                    let (rows,raw) = try await rpc(calls)
                    var result:[ArcHolding] = [], complete = true
                    for (i,ref) in chunk.enumerated() {
                        let offset = i*4
                        let token = try? Self.token(reference:ref,rows:rows[offset..<offset+3])
                        var amount = try? Self.word(rows[offset+3])
                        if token == nil || saved[ref].map({ $0.decimals != token?.decimals }) == true { amount = nil }
                        if let token = token ?? saved[ref] { result.append(.init(token:token,amount:amount)) }
                        if amount == nil { complete = false }
                    }
                    return (result,raw,complete)
                }
            }
            for _ in 0..<min(3,chunks.count) { enqueue() }
            for try await value in group { holdings += value.0; raw.append(value.1); complete = complete && value.2; enqueue() }
            return (holdings,raw,complete)
        }
        let (nativeRows,nativeRaw) = try await native
        let nativeAmount = try ArcIdentity.amount(Self.result(nativeRows[0]))
        let mirroredAmount = try Self.word(nativeRows[1])
        guard try ArcIdentity.erc20Units(native:nativeAmount) == mirroredAmount else { throw AnkrError.invalidResponse }
        let (check,checkRaw) = try await rpc([("eth_getBlockByNumber",[.string(height),.bool(false)])])
        guard try Self.result(check[0])["hash"].string?.lowercased() == anchor.hash else { throw AnkrError.invalidResponse }
        return .init(owner:owner,block:anchor.height,blockHash:anchor.hash,observedAt:.now,
                     holdings:[.init(token:.native,amount:nativeAmount)] + gathered.0,
                     complete:gathered.2,raw:try JSONEncoder().encode([nativeRaw,checkRaw] + gathered.1))
    }
    public func history(owner:String,from:Int64,through:Int64,known:[ArcToken] = []) async throws -> ArcHistoryPage {
        let owner = try ArcIdentity.address(owner)
        guard from >= 0, through > from, through < Int64.max else { throw AnkrError.invalidResponse }
        guard let indexKey else { throw AnkrError.configurationMissing }
        let topic = "0x" + String(repeating:"0",count:24) + owner.dropFirst(2)
        let body:SolanaJSON = .object([
            "from_block":.number(String(from)),"to_block":.number(String(through)),
            "logs":.array([.object(["topics":.array([.array([.string(ArcIdentity.transferTopic)]),.array([.string(topic)])])]),
                           .object(["topics":.array([.array([.string(ArcIdentity.transferTopic)]),.array([]),.array([.string(topic)])])])]),
            "transactions":.array([.object(["from":.array([.string(owner)])]),.object(["to":.array([.string(owner)])])]),
            "max_num_logs":.number("1000"),"max_num_transactions":.number("1000"),"join_mode":.string("Default"),
            "field_selection":.object([
                "block":.array(["number","hash","timestamp"].map(SolanaJSON.string)),
                "transaction":.array(["hash","block_number","block_hash","from","to","status","gas_used","effective_gas_price"].map(SolanaJSON.string)),
                "log":.array(["address","block_number","block_hash","transaction_hash","log_index","data","topic0","topic1","topic2","topic3"].map(SolanaJSON.string))])])
        var request = URLRequest(url:URL(string:"https://arc.hypersync.xyz/query")!); request.httpMethod = "POST"
        request.setValue("application/json",forHTTPHeaderField:"Content-Type"); request.setValue("Bearer " + indexKey,forHTTPHeaderField:"Authorization")
        request.httpBody = try JSONEncoder().encode(body)
        try await indexPermits.acquire()
        let json:SolanaJSON, raw:Data
        do { (json,raw) = try await exchange(request); await indexPermits.release() }
        catch { OathDiagnostics.record(error); await indexPermits.release(); throw error }
        let refs = try Self.logReferences(json)
        var tokens = Dictionary(known.map { ($0.reference,$0) },uniquingKeysWith:{ first,_ in first }); tokens["native"] = .native
        let missing = refs.filter { tokens[$0] == nil }.sorted()
        // Metadata reads are bounded batches. A bad contract cannot silently
        // advance the discovery cursor past an unresolved fungible transfer.
        for offset in stride(from:0,to:missing.count,by:9) {
            let chunk = Array(missing[offset..<min(offset+9,missing.count)])
            let (rows,_) = try await rpc(chunk.flatMap { ref in
                [Self.call(ref,"0x06fdde03","latest"),Self.call(ref,"0x95d89b41","latest"),Self.call(ref,"0x313ce567","latest")]
            })
            for (i,ref) in chunk.enumerated() { tokens[ref] = try Self.token(reference:ref,rows:rows[i*3..<i*3+3]) }
        }
        return try Self.decodeHistory(raw,owner:owner,from:from,through:through,tokens:tokens)
    }
    static func batches(_ json:SolanaJSON) throws -> [SolanaJSON] {
        guard let values = json["data"].array else { throw AnkrError.invalidResponse }; return values
    }
    static func logReferences(_ json:SolanaJSON) throws -> Set<String> {
        var refs:Set<String> = []
        for batch in try batches(json) {
            guard let logs = batch["logs"].array else { throw AnkrError.invalidResponse }
            for log in logs {
                guard log["topic0"].string?.lowercased() == ArcIdentity.transferTopic else { throw AnkrError.invalidResponse }
                if !log["topic3"].isNull { continue } // ERC-721, not an ERC-20 amount.
                guard let address = log["address"].string else { throw AnkrError.invalidResponse }
                refs.insert(try ArcIdentity.reference(address))
            }
        }
        return refs
    }
    public static func decodeHistory(_ raw:Data,owner:String,from:Int64,through:Int64,tokens:[String:ArcToken]) throws -> ArcHistoryPage {
        let owner = try ArcIdentity.address(owner), json = try JSONDecoder().decode(SolanaJSON.self,from:raw)
        let next = try ArcIdentity.height(json["next_block"])
        guard next > from, next <= through else { throw AnkrError.paginationLoop }
        var blocks:[Int64:SolanaJSON] = [:], transactions:[String:ArcTransaction] = [:], events:[String:ArcEvent] = [:]
        var mirrors:[String:(hash:String,from:String,to:String,amount:String)] = [:]
        let batches = try batches(json)
        for batch in batches {
            guard let rows = batch["blocks"].array else { throw AnkrError.invalidResponse }
            for row in rows {
                let height = try ArcIdentity.height(row["number"])
                guard height >= from, height < next, let hash = row["hash"].string, AnkrQuantity.hash(hash),
                      blocks[height] == nil || blocks[height] == row else { throw AnkrError.invalidResponse }
                blocks[height] = row
            }
        }
        for batch in batches {
            guard let rows = batch["transactions"].array else { throw AnkrError.invalidResponse }
            for row in rows {
                let height = try ArcIdentity.height(row["block_number"])
                guard let hash = row["hash"].string?.lowercased(), AnkrQuantity.hash(hash), let block = blocks[height],
                      row["block_hash"].string?.lowercased() == block["hash"].string?.lowercased(),
                      let sender = row["from"].string else { throw AnkrError.invalidResponse }
                let status = try ArcIdentity.amount(row["status"])
                guard status == "0" || status == "1" else { throw AnkrError.invalidResponse }
                let tx = ArcTransaction(hash:hash,block:height,timestamp:Double(try ArcIdentity.height(block["timestamp"])),
                    from:try ArcIdentity.address(sender),to:try row["to"].string.map(ArcIdentity.address),failed:status == "0",
                    fee:try AnkrQuantity.multiply(ArcIdentity.amount(row["gas_used"]),ArcIdentity.amount(row["effective_gas_price"])),raw:try JSONEncoder().encode(row))
                if let old = transactions[hash], try JSONDecoder().decode(SolanaJSON.self, from: old.raw) != row { throw AnkrError.invalidResponse }
                transactions[hash] = tx
            }
        }
        for batch in batches {
            guard let rows = batch["logs"].array else { throw AnkrError.invalidResponse }
            for row in rows {
                guard row["topic0"].string?.lowercased() == ArcIdentity.transferTopic else { throw AnkrError.invalidResponse }
                if !row["topic3"].isNull { continue }
                guard let address = row["address"].string, let hash = row["transaction_hash"].string?.lowercased(),
                      let tx = transactions[hash], !tx.failed,
                      try ArcIdentity.height(row["block_number"]) == tx.block,
                      row["block_hash"].string?.lowercased() == blocks[tx.block]?["hash"].string?.lowercased(),
                      let sender = row["topic1"].string, let recipient = row["topic2"].string,
                      AnkrQuantity.hash(sender), AnkrQuantity.hash(recipient),
                      sender.dropFirst(2).prefix(24).allSatisfy({$0 == "0"}), recipient.dropFirst(2).prefix(24).allSatisfy({$0 == "0"}),
                      let units = row["data"].string, AnkrQuantity.hash(units) else { throw AnkrError.invalidResponse }
                let senderAddress = "0x" + sender.suffix(40).lowercased(), recipientAddress = "0x" + recipient.suffix(40).lowercased()
                guard senderAddress == owner || recipientAddress == owner else { throw AnkrError.invalidResponse }
                // Ignore the USDC mirror only. Never deduplicate by amount:
                // identical transfers with different log indices are legitimate.
                if address.lowercased() == ArcIdentity.usdc {
                    let index = try ArcIdentity.height(row["log_index"])
                    mirrors[hash + ":" + String(index)] = (hash,senderAddress,recipientAddress,try AnkrQuantity.decimal(units))
                    continue
                }
                let ref = try ArcIdentity.reference(address)
                guard let token = ref == "native" ? ArcToken.native : tokens[ref], token.reference == ref else { throw AnkrError.incompleteInventory }
                let index = try ArcIdentity.height(row["log_index"]), id = hash + ":" + String(index)
                let event = ArcEvent(id:id,hash:hash,logIndex:Int(index),token:token,amount:try AnkrQuantity.decimal(units),from:senderAddress,to:recipientAddress)
                if let old = events[id], old != event { throw AnkrError.invalidResponse }
                events[id] = event
            }
        }
        // Detect an indexer silently omitting the system stream. Each positive
        // ERC-20 call must have its native counterpart, including multiplicity.
        var nativeMatches = events.values.filter { $0.token.reference == "native" }
        for mirror in mirrors.values where mirror.amount != "0" && mirror.from != mirror.to {
            let nativeAmount = try AnkrQuantity.multiply(mirror.amount,"1000000000000")
            guard let index = nativeMatches.firstIndex(where: {
                $0.hash == mirror.hash && $0.from == mirror.from && $0.to == mirror.to && $0.amount == nativeAmount
            }) else { throw AnkrError.incompleteInventory }
            nativeMatches.remove(at:index)
        }
        let relevant = Set(events.values.map(\.hash))
        return .init(fromBlock:from,nextBlock:next,
                     transactions:transactions.values.filter { relevant.contains($0.hash) || $0.from == owner || $0.to == owner }.sorted { $0.hash < $1.hash },
                     events:events.values.sorted { $0.id < $1.id },raw:raw)
    }
}
