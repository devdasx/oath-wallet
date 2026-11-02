import OathDiagnostics
import Foundation

/// ANKR supplies canonical state. FastNear supplies the indexed discovery and
/// incoming/outgoing history that NEAR's standard RPC cannot enumerate.
public actor NearClient {
    public let network:NearSendNetwork
    private let endpoint:URL
    private let fallback:URL?
    private let transport:any AnkrTransport
    private let permits = AnkrPermits(count:6)
    private var networkChecked = false
    private struct MetadataEntry {
        let date: Date
        let block: NearBlock
        let token: NearToken?
    }
    private var metadata:[String:MetadataEntry] = [:]
    private var metadataGates:[String:(gate:AnkrPermits, users:Int)] = [:]
    private let metadataAdmissions = AnkrPermits(count:32)
    private let now: @Sendable () -> Date
    public init(apiKey:String, transport:any AnkrTransport = AnkrHTTPTransport()) throws {
        guard !apiKey.isEmpty, apiKey.count <= 256, apiKey.utf8.allSatisfy({(48...57).contains($0)||(65...90).contains($0)||(97...122).contains($0)}) else { throw NearError.configuration }
        network = .mainnet
        endpoint = URL(string:"https://rpc.ankr.com/near")!.appendingPathComponent(apiKey)
        fallback = URL(string:"https://rpc.mainnet.near.org")!; self.transport = transport; now = { Date() }
    }
    public init(endpoint:URL, fallback:URL? = nil, network:NearSendNetwork = .mainnet, transport:any AnkrTransport = AnkrHTTPTransport(),
                now:@escaping @Sendable () -> Date = { Date() }) throws {
        guard endpoint.scheme == "https", fallback == nil || fallback?.scheme == "https" else { throw NearError.configuration }
        self.network = network; self.endpoint = endpoint; self.fallback = fallback; self.transport = transport; self.now = now
    }
    private func request(_ url:URL, body:NearJSON? = nil, indexStage:String? = nil) async throws -> Data {
        var request = URLRequest(url:url); request.timeoutInterval = 25
        request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        if let body { request.httpMethod = "POST"; request.httpBody = try JSONEncoder().encode(body) }
        return try await OathDiagnostics.$chain.withValue("near") {
            try await OathDiagnostics.$operationID.withValue(OathDiagnostics.operationID ?? UUID()) {
                try await exchange(request, indexStage:indexStage)
            }
        }
    }
    private func exchange(_ request:URLRequest, indexStage:String?) async throws -> Data {
        var attempt = 1
        while true {
            try Task.checkCancellation()
            try await permits.acquire()
            let response:(Data,Int)
            do { response = try await transport.send(request) }
            catch {
                await permits.release()
                if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                OathDiagnostics.record(error, operation:"near_read", context:[
                    "chain":"near", "stage":indexStage ?? "rpc", "host":request.url?.host ?? "",
                    "attempt":String(attempt)])
                let transient:Bool
                switch error {
                case AnkrError.transport: transient = true
                case let error as URLError: transient = [.networkConnectionLost,.timedOut,.cannotConnectToHost].contains(error.code)
                default: transient = false
                }
                if indexStage != nil, attempt == 1, transient {
                    attempt += 1
                    try await Task.sleep(for:.milliseconds(500))
                    continue
                }
                throw NearError.transport
            }
            await permits.release(); try Task.checkCancellation()
            guard response.1 == 200 else {
                // FastNear POST endpoints query history; they do not broadcast.
                // Replay the same encoded cursor/body once after a transient
                // failure. Never retry invalid data or immediately repeat 429s.
                if let indexStage {
                    OathDiagnostics.record(NearError.http(response.1), operation:"near_index_read", context:[
                        "chain":"near", "stage":indexStage, "host":request.url?.host ?? "",
                        "http_status":String(response.1), "attempt":String(attempt)])
                    if attempt == 1, [408,500,502,503,504].contains(response.1) {
                        attempt += 1
                        try await Task.sleep(for:.milliseconds(500))
                        continue
                    }
                }
                throw NearError.http(response.1)
            }
            return response.0
        }
    }
    private func rpc(_ method:String, params:NearJSON) async throws -> NearJSON {
        let body:NearJSON = .object(["jsonrpc":.string("2.0"),"id":.number("1"),"method":.string(method),"params":params])
        let data:Data
        do { data = try await request(endpoint,body:body) }
        catch { OathDiagnostics.record(error);
            let retry:Bool
            switch error { case NearError.http(let n): retry = n == 408 || n == 429 || n >= 500; case NearError.transport: retry = true; default: retry = false }
            guard retry, let fallback else { throw error }
            data = try await request(fallback,body:body)
        }
        let json = try JSONDecoder().decode(NearJSON.self,from:data)
        guard json["id"].integer == 1, json["jsonrpc"].string == "2.0" else { throw NearError.malformed }
        if !json["error"].isNull {
            let error = json["error"], code = error["code"].text.flatMap(Int.init) ?? 0
            // Older providers flatten UNKNOWN_ACCOUNT to this exact protocol
            // message. Other server/contract failures must not become zero.
            if error["cause"]["name"].string == "UNKNOWN_ACCOUNT" || error["data"]["cause"]["name"].string == "UNKNOWN_ACCOUNT" { throw NearError.accountMissing }
            if params["request_type"].string == "view_account", let id = params["account_id"].string,
               error["data"].string == "account \(id) does not exist while viewing" { throw NearError.accountMissing }
            if error["cause"]["name"].string == "CONTRACT_EXECUTION_ERROR" { throw NearError.contract }
            throw NearError.rpc(code)
        }
        guard !json["result"].isNull else { throw NearError.malformed }; return json["result"]
    }
    public func finalBlock() async throws -> NearBlock {
        if !networkChecked {
            let config = try await rpc("EXPERIMENTAL_genesis_config",params:.object([:]))
            guard config["chain_id"].string == network.rawValue else { throw NearError.wrongNetwork }; networkChecked = true
        }
        let header = try await rpc("block",params:.object(["finality":.string("final")]))["header"]
        return try .init(hash:NearIdentity.hash(header["hash"]),height:NearIdentity.height(header["height"]),timestamp:NearIdentity.timestamp(header["timestamp_nanosec"].isNull ? header["timestamp"]:header["timestamp_nanosec"]))
    }
    private func query(_ params:[String:NearJSON], block:NearBlock) async throws -> NearJSON {
        var p = params; p["block_id"] = .string(block.hash)
        let result = try await rpc("query",params:.object(p))
        guard result["block_hash"].string == block.hash, try NearIdentity.height(result["block_height"]) == block.height else { throw NearError.wrongBlock }
        return result
    }
    public func account(owner:String, block:NearBlock) async throws -> NearJSON {
        try await query(["request_type":.string("view_account"),"account_id":.string(NearIdentity.address(owner))],block:block)
    }
    public func call(contract:String, method:String, args:NearJSON = .object([:]), block:NearBlock) async throws -> NearJSON {
        let result = try await query(["request_type":.string("call_function"),"account_id":.string(NearIdentity.address(contract)),"method_name":.string(method),"args_base64":.string(try JSONEncoder().encode(args).base64EncodedString())],block:block)
        if !result["error"].isNull {
            // NEAR's legacy QueryError is a valid result envelope. Verify its
            // block first and never turn a failed required read into a balance.
            guard let message = result["error"].string, result["result"].isNull,
                  let logs = result["logs"].array, logs.allSatisfy({ $0.string != nil }) else { throw NearError.malformed }
            if method == "ft_metadata", message == "wasm execution failed with error: MethodResolveError(MethodNotFound)" {
                throw NearError.metadataUnavailable
            }
            // DiagnosticHTTP retains the sanitized original protocol failure.
            // Contract-authored panic/log text must never enter diagnostics here.
            throw NearError.contract
        }
        guard let bytes = result["result"].array, bytes.count <= 1_048_576 else { throw NearError.malformed }
        let data = try Data(bytes.map{value -> UInt8 in guard let n = value.integer, n <= 255 else { throw NearError.malformed }; return UInt8(n)})
        return try JSONDecoder().decode(NearJSON.self,from:data)
    }
    public func token(_ reference:String, block:NearBlock) async throws -> NearToken {
        // Explicit token import requires real metadata, including decimals.
        guard let value = try await tokenIfAvailable(reference, block:block) else { throw NearError.metadataUnavailable }
        return value
    }
    func tokenIfAvailable(_ reference:String, block:NearBlock) async throws -> NearToken? {
        try await OathDiagnostics.$chain.withValue("near") {
            try await OathDiagnostics.$operationID.withValue(OathDiagnostics.operationID ?? UUID()) {
                try await cachedMetadata(reference, block:block)
            }
        }
    }
    private func cachedMetadata(_ reference:String, block:NearBlock) async throws -> NearToken? {
        try Task.checkCancellation()
        let ref = try NearIdentity.reference(reference); if ref == "native" { return .native }
        // A gate per contract shares successful/absent results across inventory
        // and history without serializing unrelated token reads. The existing
        // cancellable permit queue keeps cancellation local to each caller.
        try await metadataAdmissions.acquire()
        var entry = metadataGates[ref] ?? (gate:AnkrPermits(count:1), users:0)
        entry.users += 1; metadataGates[ref] = entry
        var acquired = false
        do {
            try await entry.gate.acquire(); acquired = true
            try Task.checkCancellation()
            let value = try await loadMetadata(ref, block:block)
            await releaseMetadataGate(ref, gate:entry.gate, acquired:acquired)
            return value
        } catch {
            OathDiagnostics.record(error, operation:"token_metadata", context:["chain":"near", "stage":"metadata"])
            await releaseMetadataGate(ref, gate:entry.gate, acquired:acquired)
            throw error
        }
    }
    private func releaseMetadataGate(_ ref:String, gate:AnkrPermits, acquired:Bool) async {
        if acquired { await gate.release() }
        if let entry = metadataGates[ref] {
            metadataGates[ref] = entry.users > 1 ? (gate:entry.gate, users:entry.users-1) : nil
        }
        await metadataAdmissions.release()
    }
    private func loadMetadata(_ ref:String, block:NearBlock) async throws -> NearToken? {
        let date = now()
        metadata = metadata.filter { (0..<900).contains(date.timeIntervalSince($0.value.date)) }
        if let cached = metadata[ref], cached.block.height < block.height ||
            (cached.block.height == block.height && cached.block.hash == block.hash) { return cached.token }
        let value:NearToken?
        do { value = try NearToken.decode(await call(contract:ref,method:"ft_metadata",block:block),reference:ref) }
        catch NearError.metadataUnavailable {
            // diagnostics: optional-near-metadata-absence
            // Only exact, block-validated MethodNotFound for ft_metadata is an
            // absent optional extension. Panics, balance failures and malformed
            // metadata still throw. No amounts/decimals are synthesized.
            value = nil
        }
        try Task.checkCancellation()
        if metadata[ref].map({ $0.block.height <= block.height }) ?? true {
            metadata[ref] = .init(date:now(), block:block, token:value)
        }
        while metadata.count > 256, let oldest = metadata.min(by:{ $0.value.date < $1.value.date })?.key {
            metadata[oldest] = nil
        }
        return value
    }
    public func discovery(owner:String) async throws -> NearJSON {
        let id = try NearIdentity.address(owner)
        let raw = try await request(URL(string:"https://\(network == .mainnet ? "api":"test.api").fastnear.com/v1/account/\(id)/ft")!,indexStage:"discovery")
        let json = try JSONDecoder().decode(NearJSON.self,from:raw)
        guard json["account_id"].string == id, json["tokens"].array != nil else { throw NearError.wrongOwner }; return json
    }
    public func inventory(owner:String, at block:NearBlock? = nil, knownReferences:[String] = []) async throws -> NearInventory {
        let owner = try NearIdentity.address(owner)
        async let discovered = discovery(owner:owner)
        let block:NearBlock = if let block { block } else { try await finalBlock() }
        let state:NearJSON, exists:Bool
        do { state = try await account(owner:owner,block:block); exists = true }
        catch NearError.accountMissing { state = .object(["amount":.string("0"),"locked":.string("0"),"storage_usage":.number("0")]); exists = false }
        let discovery = try await discovered
        var indexed:[String:String] = [:], refs:Set<String> = []
        for item in discovery["tokens"].array! {
            guard let s = item["contract_id"].string else { throw NearError.malformed }
            let ref = try NearIdentity.address(s); guard refs.insert(ref).inserted else { throw NearError.malformed }
            indexed[ref] = OathDiagnostics.attempt("decode_indexed_balance", body: { try NearIdentity.amount(item["balance"]) })
        }
        for ref in knownReferences where ref != "native" { refs.insert(try NearIdentity.reference(ref)) }
        let liquid = try NearIdentity.amount(state["amount"]), locked = try NearIdentity.amount(state["locked"])
        var holdings:[NearHolding] = [.init(reference:"native",token:.native,amount:AptosIdentity.add(liquid,locked),indexedAmount:nil,failure:nil)]
        let list = refs.sorted()
        // A bounded task group replaces unsupported ANKR JSON-RPC batches.
        await withTaskGroup(of:NearHolding.self) { group in
            var next = 0
            func enqueue() {
                guard next < list.count, !Task.isCancelled else { return }; let ref = list[next]; next += 1
                let indexAmount = indexed[ref]
                group.addTask {
                    async let token = await OathDiagnostics.attemptOptional("token_metadata") { try await self.tokenIfAvailable(ref,block:block) }
                    do {
                        let balance = try await self.call(contract:ref,method:"ft_balance_of",args:.object(["account_id":.string(owner)]),block:block)
                        return .init(reference:ref,token:await token,amount:try NearIdentity.amount(balance),indexedAmount:indexAmount,failure:nil)
                    } catch { OathDiagnostics.record(error);
                        return .init(reference:ref,token:await token,amount:nil,indexedAmount:indexAmount,failure:"contractRead")
                    }
                }
            }
            for _ in 0..<6 { enqueue() }; for await value in group { holdings.append(value); enqueue() }
        }
        try Task.checkCancellation()
        return try .init(owner:owner,block:block,exists:exists,liquid:liquid,locked:locked,storageBytes:NearIdentity.height(state["storage_usage"]),holdings:holdings.sorted{$0.reference<$1.reference},observedAt:.now,raw:JSONEncoder().encode(NearJSON.object(["state":state,"discovery":discovery])))
    }
    public func history(owner:String, stream:String, before:String? = nil, limit:Int = 50) async throws -> NearHistoryPage {
        let owner = try NearIdentity.address(owner)
        guard ["transfers","transactions"].contains(stream), before == nil || before!.count <= 4096 else { throw NearError.malformed }
        var p:[String:NearJSON] = ["account_id":.string(owner),"limit":.number(String(min(100,max(1,limit)))),"desc":.bool(true)]
        if let before { p["resume_token"] = .string(before) }
        // FastNear currently publishes transfer indexing only on Mainnet. Never query the wrong network.
        guard network == .mainnet || stream == "transactions" else { throw NearError.configuration }
        let url = stream == "transfers" ? "https://transfers.main.fastnear.com/v0/transfers":"https://tx.\(self.network == .mainnet ? "main":"test").fastnear.com/v0/account"
        let raw = try await request(URL(string:url)!,body:.object(p),indexStage:stream)
        let json = try JSONDecoder().decode(NearJSON.self,from:raw)
        let page = try NearDecoding.history(json,owner:owner,stream:stream,raw:raw)
        guard page.next == nil || page.next != before && !page.ids.isEmpty else { throw NearError.paginationLoop }
        if stream == "transactions" {
            var details:[String:NearJSON] = [:]
            try await withThrowingTaskGroup(of:[String:NearJSON].self) { group in
                // These batches are independent once the index page arrives.
                // The shared permit pool bounds them together with state reads.
                for offset in stride(from:0,to:page.executions.count,by:20) {
                    let hashes = page.executions[offset..<min(offset+20,page.executions.count)].map(\.hash)
                    group.addTask {
                        let data = try await self.request(URL(string:"https://tx.\(self.network == .mainnet ? "main":"test").fastnear.com/v0/transactions")!,body:.object(["tx_hashes":.array(hashes.map{.string($0)})]),indexStage:"transaction_details")
                        guard let rows = try JSONDecoder().decode(NearJSON.self,from:data)["transactions"].array else { throw NearError.malformed }
                        var batch:[String:NearJSON] = [:]
                        for row in rows {
                            let hash = try NearIdentity.hash(row["transaction"]["hash"])
                            guard hashes.contains(hash), batch[hash] == nil else { throw NearError.malformed }; batch[hash] = row
                        }
                        guard hashes.allSatisfy({batch[$0] != nil}) else { throw NearError.malformed }
                        return batch
                    }
                }
                for try await batch in group { details.merge(batch) { first,_ in first } }
            }
            let executions = try page.executions.map { e in
                let detail = details[e.hash]!
                let outcomes = [detail["execution_outcome"]["outcome"]] + (detail["receipts"].array ?? []).map{$0["execution_outcome"]["outcome"]}
                var fee = "0"
                for outcome in outcomes { fee = AptosIdentity.add(fee,try NearIdentity.amount(outcome["tokens_burnt"])) }
                return NearExecution(owner:e.owner,hash:e.hash,blockHeight:e.blockHeight,timestamp:e.timestamp,failed:e.failed,fee:fee,raw:try JSONEncoder().encode(detail))
            }
            return .init(events:[],executions:executions,next:page.next,head:page.head,raw:raw)
        }
        let refs = Array(Set(page.events.compactMap(\.reference))).sorted()
        // Resolve metadata for assets no longer in the wallet too.
        let block = try await finalBlock()
        var tokens:[String:NearToken] = [:]
        for offset in stride(from:0,to:refs.count,by:6) {
            await withTaskGroup(of:NearToken?.self) { group in
                for ref in refs[offset..<min(offset+6,refs.count)] { group.addTask { await OathDiagnostics.attemptOptional("token", body: { try await self.tokenIfAvailable(ref,block:block) }) } }
                for await token in group { if let token { tokens[token.reference] = token } }
            }
        }
        try Task.checkCancellation()
        let events = page.events.map { e in NearEvent(id:e.id,owner:e.owner,hash:e.hash,receipt:e.receipt,reference:e.reference,token:e.reference.flatMap{tokens[$0]},amount:e.amount,counterparty:e.counterparty,blockHeight:e.blockHeight,timestamp:e.timestamp,raw:e.raw) }
        return .init(events:events,executions:[],next:page.next,head:page.head,raw:raw)
    }
}
