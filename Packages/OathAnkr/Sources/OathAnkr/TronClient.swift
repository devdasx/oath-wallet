import OathDiagnostics
import Foundation

/// ANKR mainnet node for state/receipts; TronGrid's public index for discovery.
/// No keys, credentials or secret material are sent to the index or market APIs.
public actor TronClient {
    private let network: TronSendNetwork
    private let rpc: URL
    private let node: URL
    private let transport: any AnkrTransport
    private let permits = AnkrPermits(count: 4)
    private let indexPermit = AnkrPermits(count: 1)
    private var lastIndex = Date.distantPast
    private var verified = false
    private var recoveryVerified = false
    private var solid: (height: Int64, time: Date)?
    private var metadata: [String: TronToken] = [:]
    public init(apiKey: String, network: TronSendNetwork = .mainnet, transport: any AnkrTransport = AnkrHTTPTransport()) throws {
        guard !apiKey.isEmpty, apiKey.count <= 256, apiKey.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }) else { throw TronError.configuration }
        self.network = network
        rpc = network == .nile ? network.endpoint.appendingPathComponent("jsonrpc") : URL(string: "https://rpc.ankr.com/tron_jsonrpc")!.appendingPathComponent(apiKey)
        node = network == .nile ? network.endpoint : URL(string: "https://rpc.ankr.com/premium-http/tron")!.appendingPathComponent(apiKey)
        self.transport = transport
    }
    private func request(_ url: URL, body: TronJSON? = nil, index: Bool = false) async throws -> TronJSON {
        // Recovery shares the existing public-provider budget with discovery.
        let publicRequest = index || network == .mainnet && url.host == network.endpoint.host
        let gate = publicRequest ? indexPermit : permits
        try await gate.acquire()
        do {
            var req = URLRequest(url: url)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("OathWallet/1.0", forHTTPHeaderField: "User-Agent")
            if let body { req.httpMethod = "POST"; req.httpBody = try JSONEncoder().encode(body) }
            for attempt in 0..<3 {
                try Task.checkCancellation()
                if publicRequest {
                    let delay = 1.1 - Date().timeIntervalSince(lastIndex)
                    if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
                    lastIndex = .now
                }
                do {
                    let (data, status) = try await transport.send(req)
                    guard status == 200 else { throw TronError.http(status) }
                    guard data.count <= 32 * 1024 * 1024 else { throw TronError.malformed }
                    let value = try JSONDecoder().decode(TronJSON.self, from: data)
                    guard value["Error"].isNull, value["error"].isNull, value["success"] != .bool(false) else { throw TronError.incomplete }
                    await gate.release(); return value
                } catch {
                    if error is CancellationError || Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                    OathDiagnostics.record(error, component: "provider", operation: "tron_read",
                        context: ["chain": "tron", "host": url.host ?? "", "attempt": String(attempt + 1)])
                    let retry: Bool
                    switch error { case TronError.http(let c): retry = c == 429 || c >= 500
                    case AnkrError.transport: retry = true
                    default: retry = false }
                    if retry && attempt < 2 { try await Task.sleep(for: .seconds(index ? 6 * (1 << attempt) : 1 << attempt)); continue }
                    if error is CancellationError || Task.isCancelled { throw CancellationError() }
                    if let error = error as? TronError { throw error }
                    if error is DecodingError { throw TronError.malformed }
                    if case AnkrError.transport = error { throw TronError.transport }
                    throw error
                }
            }
            throw TronError.transport
        } catch { OathDiagnostics.record(error); await gate.release(); throw error }
    }
    public func verifyNetwork() async throws {
        if verified { return }
        let result = try await batch([("eth_chainId", [])])
        guard result[0].string == (network == .mainnet ? "0x2b6653dc" : "0xcd8690dc") else { throw TronError.wrongNetwork }
        verified = true
    }
    /// Every member is matched by ID. An RPC error cannot become a zero balance.
    func batch(_ calls: [(String, [TronJSON])]) async throws -> [TronJSON] {
        do { return try await batch(calls, at: rpc) }
        catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            guard network == .mainnet, Self.canRecover(error),
                  calls.allSatisfy({ ["eth_chainId", "eth_call"].contains($0.0) }) else { throw error }
            OathDiagnostics.record(error, component: "provider", operation: "tron_read_recovery",
                context: ["chain": "tron", "stage": "rpc_read", "host": network.endpoint.host!])
            try await verifyRecoveryNetwork()
            return try await batch(calls, at: network.endpoint.appendingPathComponent("jsonrpc"))
        }
    }
    private static func canRecover(_ error: any Error) -> Bool {
        switch error {
        case TronError.transport: true
        case TronError.http(let status): status == 429 || (500...599).contains(status)
        default: false
        }
    }
    private func verifyRecoveryNetwork() async throws {
        if recoveryVerified { return }
        let identity = try await batch([("eth_chainId", [])], at: network.endpoint.appendingPathComponent("jsonrpc"))
        guard identity[0].string == "0x2b6653dc" else { throw TronError.wrongNetwork }
        let genesis = try await request(network.endpoint.appendingPathComponent("wallet/getblockbynum"), body: .object(["num": .number("0")]))
        guard genesis["blockID"].string == network.genesisID else { throw TronError.wrongNetwork }
        try Task.checkCancellation()
        recoveryVerified = true
    }
    private func batch(_ calls: [(String, [TronJSON])], at endpoint: URL) async throws -> [TronJSON] {
        guard !calls.isEmpty, calls.count <= 80 else { throw TronError.malformed }
        let body = TronJSON.array(calls.enumerated().map { i, call in
            .object(["jsonrpc": .string("2.0"), "id": .number(String(i)), "method": .string(call.0), "params": .array(call.1)])
        })
        for attempt in 0..<3 {
            let value = try await request(endpoint, body: body)
            try Task.checkCancellation()
            guard let rows = value.array, rows.count == calls.count else { throw TronError.malformed }
            var results: [Int: TronJSON] = [:]; var transient = false
            for row in rows {
                guard row["jsonrpc"].string == "2.0", let n = row["id"].integer, n < calls.count, results[Int(n)] == nil else { throw TronError.malformed }
                if !row["error"].isNull {
                    guard let code = row["error"]["code"].text.flatMap(Int.init) else { throw TronError.malformed }
                    OathDiagnostics.record(NSError(domain: "TronRPC", code: code,
                        userInfo: [NSLocalizedDescriptionKey: row["error"]["message"].string ?? "RPC rejected read"]),
                        component: "provider", operation: "tron_read_envelope",
                        context: ["chain": "tron", "rpc_code": String(code), "host": endpoint.host ?? ""])
                    if [429,-32603,-32005,-32090,-32055].contains(code) { transient = true }
                    else { throw TronError.rpc(code) }
                }
                results[Int(n)] = row["result"]
            }
            if transient {
                if attempt < 2 { try await Task.sleep(for: .seconds(1 << attempt)); continue }
                throw TronError.incomplete
            }
            return try calls.indices.map { guard let r = results[$0], !r.isNull else { throw TronError.malformed }; return r }
        }
        throw TronError.incomplete
    }
    private func post(_ method: String, _ params: [String: TronJSON]) async throws -> TronJSON {
        do { return try await request(node.appendingPathComponent(method), body: .object(params)) }
        catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            guard network == .mainnet, Self.canRecover(error),
                  ["wallet/getaccount", "wallet/getassetissuebyid", "wallet/getassetissuebyname",
                   "walletsolidity/getnowblock", "wallet/gettransactionbyid", "wallet/gettransactioninfobyid"].contains(method) else { throw error }
            OathDiagnostics.record(error, component: "provider", operation: "tron_read_recovery",
                context: ["chain": "tron", "stage": "node_read", "host": network.endpoint.host!])
            try await verifyRecoveryNetwork()
            let result = try await request(network.endpoint.appendingPathComponent(method), body: .object(params))
            try Task.checkCancellation()
            return result
        }
    }
    private func indexed(_ owner: String, path: String = "", params: [String: String] = [:]) async throws -> TronJSON {
        _ = try TronIdentity.bytes(owner)
        var url = URLComponents(string: network.endpoint.absoluteString + "/v1/accounts/" + owner + path)!
        url.queryItems = params.sorted { $0.key < $1.key }.map { .init(name: $0.key, value: $0.value) }
        let result = try await request(url.url!, index: true)
        guard result["success"] == .bool(true), result["data"].array != nil else { throw TronError.malformed }
        return result
    }
    public func token(_ reference: String) async throws -> TronToken {
        if reference == "native" { return .init(reference: reference, name: "TRON", symbol: "TRX", decimals: 6) }
        if let info = metadata[reference] { return info }
        try await verifyNetwork()
        let token: TronToken
        if TronIdentity.isTRC10(reference) {
            let data = try await post("wallet/getassetissuebyid", ["value": .string(reference)])
            guard data["id"].string == reference else { throw TronError.malformed }
            guard data["precision"].isNull || data["precision"].integer != nil else { throw TronError.malformed }
            let decimals = data["precision"].integer ?? 0
            guard decimals <= 255, let name = data["name"].string, let symbol = data["abbr"].string,
                  let n = String(data: try TronIdentity.hex(name), encoding: .utf8),
                  let s = String(data: try TronIdentity.hex(symbol), encoding: .utf8) else { throw TronError.malformed }
            token = .init(reference: reference, name: (try? TronIdentity.clean(n)) ?? "TRC-10 " + reference, symbol: (try? TronIdentity.clean(s, limit: 64)) ?? reference, decimals: Int(decimals))
        } else {
            let address = try TronIdentity.callAddress(reference)
            let calls = ["06fdde03", "95d89b41", "313ce567"].map { selector in
                ("eth_call", [TronJSON.object(["to": .string(address), "data": .string("0x" + selector)]), .string("latest")])
            }
            let data: [TronJSON]
            do { data = try await batch(calls) }
            catch { OathDiagnostics.record(error);
                try Task.checkCancellation()
                // Name/symbol are optional metadata in the fungible standard.
                // Keep usable balances when a legacy token omits either one.
                let supportsNFT = try? await batch([("eth_call",[.object(["to":.string(address),"data":.string("0x01ffc9a780ac58cd" + String(repeating:"0",count:56))]),.string("latest")])])[0]
                if let word = supportsNFT?.string, (try? TronIdentity.uint256(word)) == "1" { throw TronError.nonFungible }
                let decimals = try await batch([calls[2]])[0]
                let name = try? await batch([calls[0]])[0]
                let symbol = try? await batch([calls[1]])[0]
                data = [name ?? .null,symbol ?? .null,decimals]
            }
            let decodedDecimals = data[2].string.flatMap { try? TronIdentity.uint256($0) }.flatMap(UInt64.init)
            guard let decimals = decodedDecimals, decimals <= 255 else {
                let check = try? await batch([("eth_call",[.object(["to":.string(address),"data":.string("0x01ffc9a780ac58cd" + String(repeating:"0",count:56))]),.string("latest")])])[0]
                if let word = check?.string, (try? TronIdentity.uint256(word)) == "1" { throw TronError.nonFungible }
                throw TronError.malformed
            }
            let name = data[0].string.flatMap { try? TronIdentity.abiString($0) }
            let symbol = data[1].string.flatMap { try? TronIdentity.abiString($0) }
            token = .init(reference: reference, name: name ?? String(reference.prefix(6))+"…"+String(reference.suffix(4)), symbol: symbol ?? "TRC-20", decimals: Int(decimals))
        }
        metadata[reference] = token
        return token
    }
    public func inventory(owner: String, additionalTokens: [String] = []) async throws -> TronInventory {
        _ = try TronIdentity.bytes(owner); try await verifyNetwork()
        async let state = post("wallet/getaccount", ["address": .string(owner), "visible": .bool(true)])
        async let discovery = await OathDiagnostics.attempt("token_discovery") { try await indexed(owner) }
        let (account, index) = try await (state, discovery)
        try Task.checkCancellation()
        let entries = index?["data"].array ?? []
        guard entries.count <= 1 else { throw TronError.malformed }
        if !account["address"].isNull { guard account["address"].string == owner else { throw TronError.wrongOwner } }
        else { guard account.fields?.isEmpty == true else { throw TronError.malformed } }
        if let first = entries.first {
            guard let address = first["address"].string, try TronIdentity.address(address) == owner else { throw TronError.wrongOwner }
        }
        let native = try TronIdentity.quantity(account["balance"].isNull ? .number("0") : account["balance"])
        guard account["assetV2"].isNull || account["assetV2"].array != nil else { throw TronError.malformed }
        if let first = entries.first { guard first["trc20"].isNull || first["trc20"].array != nil else { throw TronError.malformed } }
        var known: [String: String] = [:]
        for row in account["assetV2"].array ?? [] {
            guard let id = row["key"].string, TronIdentity.isTRC10(id), known[id] == nil else { throw TronError.malformed }
            known[id] = try TronIdentity.quantity(row["value"])
        }
        var contracts = Set(additionalTokens.filter(TronIdentity.isAddress))
        for item in entries.first?["trc20"].array ?? [] {
            guard let fields = item.fields, fields.count == 1, let pair = fields.first, TronIdentity.isAddress(pair.key) else { throw TronError.malformed }
            _ = try TronIdentity.quantity(pair.value); contracts.insert(pair.key)
        }
        guard known.count + contracts.count <= 30_000 else { throw TronError.incomplete }
        // Contract amounts are verified on ANKR; the index is discovery only.
        let references = (Array(known.keys) + Array(contracts)).sorted()
        let ownerHex = String(try TronIdentity.callAddress(owner).dropFirst(2))
        var holdings = [TronHolding(token: try await token("native"), amount: native)]
        var failed: [String] = [], excludedNFTs: [String] = []
        // Twenty tokens per batch, three bounded workers, with individual isolation
        // if a malformed/reverting token causes its batch to fail.
        var balances: [String: String] = known
        let sorted = contracts.sorted()
        let batches = stride(from: 0, to: sorted.count, by: 20).map { Array(sorted[$0..<min($0+20,sorted.count)]) }
        try await withThrowingTaskGroup(of: ([String:String],[String]).self) { group in
            var next = 0
            func enqueue() {
                guard next < batches.count, !Task.isCancelled else { return }
                let chunk = batches[next]; next += 1
                group.addTask { try await self.balances(chunk, ownerHex: ownerHex) }
            }
            for _ in 0..<3 { enqueue() }
            for try await (amounts,errors) in group { balances.merge(amounts) { _,new in new }; failed += errors; enqueue() }
        }
        let quantities = balances
        await withTaskGroup(of: (String, TronHolding?, Bool).self) { group in
            var next = 0
            func enqueue() {
                guard next < references.count, !Task.isCancelled else { return }; let ref = references[next]; next += 1
                group.addTask {
                    guard let amount = quantities[ref] else { return (ref,nil,false) }
                    do { return (ref, TronHolding(token: try await self.token(ref), amount: amount),false) }
                    catch TronError.nonFungible {
                        // ERC165 positively identified an NFT. Excluding it from
                        // fungible balances is normal discovery, not app failure.
                        return (ref,nil,true)
                    } catch { OathDiagnostics.record(error); return (ref,nil,false) }
                }
            }
            for _ in 0..<4 { enqueue() }
            for await (ref, value, nft) in group { if let value { holdings.append(value) } else if nft { excludedNFTs.append(ref) } else { failed.append(ref) }; enqueue() }
        }
        try Task.checkCancellation()
        return .init(owner: owner, holdings: holdings, failedReferences: Array(Set(failed)).sorted(), excludedNFTs: excludedNFTs.sorted(), discoveryComplete: index != nil, observedAt: .now,
                     raw: try JSONEncoder().encode(TronJSON.object(["node": account, "discovery": index ?? .null])))
    }
    private func balances(_ chunk: [String], ownerHex: String) async throws -> ([String:String],[String]) {
        let calls = try chunk.map { ref in ("eth_call", [TronJSON.object(["to": .string(try TronIdentity.callAddress(ref)), "from":.string("0x" + ownerHex), "data": .string("0x70a08231" + String(repeating: "0", count: 24) + ownerHex)]), .string("latest")]) }
        var balances: [String:String] = [:], failed: [String] = []
        do {
            let values = try await batch(calls)
            for (ref,value) in zip(chunk,values) { guard let text = value.string else { throw TronError.malformed }; balances[ref] = try TronIdentity.uint256(text) }
        } catch { OathDiagnostics.record(error);
            try Task.checkCancellation()
            // A reverting or nonstandard token cannot hide healthy neighbors.
            for (ref,call) in zip(chunk,calls) {
                do { let value = try await batch([call]); guard let text = value[0].string else { throw TronError.malformed }; balances[ref] = try TronIdentity.uint256(text) }
                catch { OathDiagnostics.record(error); try Task.checkCancellation(); failed.append(ref) }
            }
        }
        return (balances,failed)
    }
    public func history(owner: String, stream: TronStream, start: Int64, end: Int64, cursor: String? = nil, limit: Int = 50, confirmedOnly: Bool = true) async throws -> TronHistoryPage {
        guard start >= 0, end >= start, (1...200).contains(limit), cursor?.count ?? 0 < 4096 else { throw TronError.malformed }
        let path: String
        switch stream { case .transactions: path = "/transactions"; case .trc20: path = "/transactions/trc20"; case .internalTransactions: path = "/internal-transactions" }
        var params = ["min_timestamp": String(start), "max_timestamp": String(end), "limit": String(limit), "order_by": "block_timestamp,desc", "only_confirmed": confirmedOnly ? "true" : "false"]
        if let cursor { params["fingerprint"] = cursor }
        let value = try await indexed(owner, path: path, params: params)
        let rows = value["data"].array!
        guard rows.count <= limit else { throw TronError.malformed }
        var hashes: [String] = []
        for row in rows {
            let key = stream == .transactions ? "txID" : stream == .trc20 ? "transaction_id" : "tx_id"
            guard let hash = row[key].string, TronIdentity.hash(hash) else { throw TronError.malformed }
            hashes.append(hash)
        }
        let next = value["meta"]["fingerprint"].string
        // An empty data page with a continuation cannot safely be treated as EOF.
        guard next != cursor || next == nil, next == nil || (!next!.isEmpty && !rows.isEmpty) else { throw TronError.paginationLoop }
        return .init(hashes: Array(Set(hashes)).sorted(), cursor: next, raw: try JSONEncoder().encode(value))
    }
    private func solidHeight() async throws -> Int64 {
        if let solid, Date().timeIntervalSince(solid.time) < 15 { return solid.height }
        let value = try await post("walletsolidity/getnowblock", [:])
        guard let height = value["block_header"]["raw_data"]["number"].integer, height <= Int64.max else { throw TronError.malformed }
        solid = (Int64(height),.now); return Int64(height)
    }
    public func transaction(_ hash: String) async throws -> TronTransaction {
        guard TronIdentity.hash(hash) else { throw TronError.malformed }; try await verifyNetwork()
        async let body = post("wallet/gettransactionbyid", ["value": .string(hash)])
        async let receipt = post("wallet/gettransactioninfobyid", ["value": .string(hash)])
        async let height = solidHeight()
        let transaction = try await body
        var legacy: [String:String] = [:]
        for contract in transaction["raw_data"]["contract"].array ?? [] where contract["type"].string == "TransferAssetContract" {
            guard let name = contract["parameter"]["value"]["asset_name"].string else { throw TronError.malformed }
            let decoded = (try? TronIdentity.hex(name)).flatMap { String(data:$0,encoding:.utf8) } ?? ""
            if !TronIdentity.isTRC10(name), !TronIdentity.isTRC10(decoded) {
                // Before TRON proposal 14, transfers used unique asset names.
                // Resolve that historic name to the canonical numeric token ID.
                let asset = try await post("wallet/getassetissuebyname", ["value":.string(name)])
                guard asset["name"].string?.lowercased() == name.lowercased(),
                      let id = asset["id"].string, TronIdentity.isTRC10(id) else { throw TronError.incomplete }
                legacy[name] = id
            }
        }
        return try await TronDecoding.transaction(hash: hash, body: transaction, receipt: receipt, solidHeight: height, legacyAssetIDs: legacy)
    }
}
