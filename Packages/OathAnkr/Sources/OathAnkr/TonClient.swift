import OathDiagnostics
import Foundation

/// ANKR validates TON mainnet state and Jetton ownership. TonAPI supplies the
/// token/history index unavailable from ANKR's working node methods.
public actor TonClient {
    private let endpoint: URL
    private let transport: any AnkrTransport
    private let nodeGate = AnkrPermits(count: 4)
    private let indexGate = AnkrPermits(count: 1)
    private let recoveryGate = AnkrPermits(count: 1)
    private let recoveryEndpoint = URL(string: "https://toncenter.com/api/v2/jsonRPC")!
    private var lastRecovery = Date.distantPast
    private var recoveryVerified = false
    private var lastIndex = Date.distantPast
    private var verified = false
    private let indexInterval: Double
    private var bindings: Set<String> = []
    public init(apiKey: String, transport: any AnkrTransport = AnkrHTTPTransport()) throws {
        guard !apiKey.isEmpty, apiKey.count <= 256, apiKey.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }) else { throw TonError.configuration }
        endpoint = URL(string: "https://rpc.ankr.com/ton_api_v2")!.appendingPathComponent(apiKey)
        self.transport = transport; indexInterval = 4.2
    }
    // Deterministic host fixtures need no public-provider pacing.
    init(testTransport: any AnkrTransport) {
        endpoint = URL(string: "https://rpc.ankr.com/ton_api_v2/fixture")!
        transport = testTransport; indexInterval = 0
    }
    private func request(_ url: URL, body: TonJSON? = nil, index: Bool = false) async throws -> TonJSON {
        let recovery = url == recoveryEndpoint
        let gate = index ? indexGate : recovery ? recoveryGate : nodeGate
        try await gate.acquire()
        do {
            var req = URLRequest(url: url); req.timeoutInterval = 35
            req.setValue("OathWallet/1.0", forHTTPHeaderField: "User-Agent")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let body { req.httpMethod = "POST"; req.httpBody = try JSONEncoder().encode(body) }
            for attempt in 0..<3 {
                try Task.checkCancellation()
                if index {
                    let delay = indexInterval - Date().timeIntervalSince(lastIndex)
                    if delay > 0 { try await Task.sleep(for: .seconds(delay)) }; lastIndex = .now
                }
                // Public TON Center permits one request per second. Serialize
                // all recovery reads, including retries and identity checks.
                if recovery, indexInterval > 0 {
                    let delay = 1.1 - Date().timeIntervalSince(lastRecovery)
                    if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
                    lastRecovery = .now
                }
                do {
                    let (data,status) = try await transport.send(req)
                    guard status == 200 else { throw TonError.http(status) }
                    guard data.count <= 32 * 1024 * 1024 else { throw TonError.malformed }
                    let value = try JSONDecoder().decode(TonJSON.self, from: data)
                    await gate.release(); return value
                } catch {
                    if error is CancellationError || Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                    OathDiagnostics.record(error, component: "provider", operation: "ton_read",
                        context: ["chain": "ton", "host": url.host ?? "", "attempt": String(attempt + 1)])
                    let retry: Bool
                    switch error { case TonError.http(let n): retry = n == 429 || n >= 500
                    case AnkrError.transport: retry = true
                    default: retry = false }
                    if retry && attempt < 2 { try await Task.sleep(for: .seconds(index ? 5 * (1 << attempt) : 1 << attempt)); continue }
                    if let error = error as? TonError { throw error }
                    if error is DecodingError { throw TonError.malformed }
                    if case AnkrError.transport = error { throw TonError.transport }
                    // Unknown provider/validation failures must not become an
                    // apparent transport outage eligible for node recovery.
                    throw error
                }
            }
            throw TonError.transport
        } catch { OathDiagnostics.record(error); await gate.release(); throw error }
    }
    func rpc(_ method: String, _ params: [String: TonJSON] = [:]) async throws -> TonJSON {
        do { return try await node(method, params, at: endpoint) }
        catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            let transient: Bool
            switch error {
            case TonError.transport: transient = true
            case TonError.http(let status): transient = status == 429 || (500...599).contains(status)
            default: transient = false
            }
            // Only these existing read-only methods can use recovery. Never
            // replay a submission, an invalid response or an authorization error.
            guard transient, ["getMasterchainInfo", "getAddressInformation", "getTokenData", "runGetMethod"].contains(method) else { throw error }
            OathDiagnostics.record(error, component: "provider", operation: "ton_read_recovery",
                context: ["chain": "ton", "stage": "node_read", "host": recoveryEndpoint.host!])
            if !recoveryVerified || method == "getMasterchainInfo" {
                let info = try await node("getMasterchainInfo", [:], at: recoveryEndpoint)
                guard info["init"]["root_hash"].string == TonIdentity.genesis else { throw TonError.wrongNetwork }
                try Task.checkCancellation()
                recoveryVerified = true
                if method == "getMasterchainInfo" { return info }
            }
            return try await node(method, params, at: recoveryEndpoint)
        }
    }
    private func node(_ method: String, _ params: [String: TonJSON], at url: URL) async throws -> TonJSON {
        let value = try await request(url, body: .object(["jsonrpc":.string("2.0"),"id":.number("1"),"method":.string(method),"params":.object(params)]))
        try Task.checkCancellation()
        let rpcEnvelope = value["id"].text == "1" && value["jsonrpc"].string == "2.0"
        // TON Center documents its {ok,result} envelope at /jsonRPC too.
        // Accept it only at that fixed endpoint; retain strict primary IDs.
        let legacyEnvelope = url == recoveryEndpoint && value["id"].isNull && value["jsonrpc"].isNull && value["ok"] == .bool(true)
        if !value["error"].isNull || value["ok"] == .bool(false) {
            guard rpcEnvelope || url == recoveryEndpoint && value["id"].isNull && value["jsonrpc"].isNull && value["ok"] == .bool(false) else { throw TonError.malformed }
            let code = value["error"]["code"].text.flatMap(Int.init) ?? value["code"].text.flatMap(Int.init) ?? -1
            OathDiagnostics.record(NSError(domain: "TonRPC", code: code,
                userInfo: [NSLocalizedDescriptionKey: value["error"]["message"].string ?? value["error"].string ?? "RPC rejected read"]),
                component: "provider", operation: "ton_read_envelope",
                context: ["chain": "ton", "rpc_code": String(code), "host": url.host ?? ""])
            throw TonError.rpc(code)
        }
        guard rpcEnvelope || legacyEnvelope else { throw TonError.malformed }
        guard !value["result"].isNull else { throw TonError.malformed }; return value["result"]
    }
    public func verifyNetwork() async throws {
        if verified { return }
        let info = try await rpc("getMasterchainInfo")
        guard info["init"]["root_hash"].string == TonIdentity.genesis else { throw TonError.wrongNetwork }
        verified = true
    }
    func indexed(_ path: String, params: [String: String] = [:]) async throws -> TonJSON {
        var url = URLComponents(string: "https://tonapi.io/v2/" + path)!
        url.queryItems = params.sorted { $0.key < $1.key }.map { .init(name: $0.key, value: $0.value) }
        let value = try await request(url.url!, index: true)
        guard value["error"].isNull else { throw TonError.incomplete }; return value
    }
    public func tokenDecimals(reference: String) async throws -> Int {
        let ref = try TonIdentity.raw(reference)
        try await verifyNetwork()
        let value = try await indexed("jettons/" + ref)
        let metadata = value["metadata"]
        guard let address = metadata["address"].string, try TonIdentity.raw(address) == ref,
              let decimals = metadata["decimals"].text.flatMap(Int.init), (0...255).contains(decimals) else { throw TonError.malformed }
        return decimals
    }
    func discovery(_ owner: String) async throws -> ([TonJSON], [TonJSON], Bool, TonError?) {
        var rows: [TonJSON] = [], pages: [TonJSON] = [], seen: Set<String> = []
        var offset = 0
        while offset < 100_000 {
            do {
                let page = try await indexed("accounts/"+owner+"/jettons", params: ["currencies":"usd","limit":"1000","offset":String(offset)])
                guard let values = page["balances"].array, values.count <= 1000 else { throw TonError.malformed }
                for row in values {
                    guard let text = row["jetton"]["address"].string, let ref = try? TonIdentity.raw(text), seen.insert(ref).inserted else { throw TonError.paginationLoop }
                    rows.append(row)
                }
                pages.append(page)
                if values.count < 1000 { return (rows,pages,true,nil) }; offset += values.count
            } catch {
                // A cancelled request is teardown, not an incomplete discovery
                // eligible for a partial commit after the caller has moved on.
                if error is CancellationError { throw error }
                try Task.checkCancellation()
                OathDiagnostics.record(error)
                return (rows,pages,false,error as? TonError)
            }
        }
        return (rows,pages,false,nil)
    }
    private func holding(_ row: TonJSON, owner: String) async throws -> (TonHolding, TonJSON) {
        let token = try TonToken.decode(row["jetton"])
        guard let text = row["wallet_address"]["address"].string else { throw TonError.malformed }
        let wallet = try TonIdentity.raw(text), binding = owner+":"+token.reference+":"+wallet
        // TEP-74: the master's own getter must return this wallet. Merely
        // accepting a contract which reports this owner/master allows spoofing.
        async let data = rpc("getTokenData", ["address":.string(wallet)])
        if !bindings.contains(binding) {
            let result = try await rpc("runGetMethod", ["address":.string(token.reference),"method":.string("get_wallet_address"),"stack":.array([.array([.string("tvm.Slice"),.string(try TonIdentity.addressSlice(owner))])])])
            guard try TonIdentity.walletAddress(result) == wallet else { throw TonError.wrongOwner }
            bindings.insert(binding)
        }
        let value = try await data
        guard value["contract_type"].string == "jetton_wallet", let holder = value["owner"].string,
              let master = value["jetton"].string, try TonIdentity.raw(holder) == owner,
              try TonIdentity.raw(master) == token.reference else { throw TonError.wrongOwner }
        return (.init(token: token, wallet: wallet, amount: try TonIdentity.amount(value["balance"])), value)
    }
    public func inventory(owner address: String) async throws -> TonInventory {
        let owner = try TonIdentity.raw(address); try await verifyNetwork()
        async let state = rpc("getAddressInformation", ["address":.string(owner)])
        async let tokens = discovery(owner)
        let (account,(rows,pages,complete,discoveryError)) = try await (state,tokens)
        guard ["active","uninitialized","frozen"].contains(account["state"].string ?? "") else { throw TonError.malformed }
        var holdings = [TonHolding(token: .native, wallet: nil, amount: try TonIdentity.amount(account["balance"]))]
        var failed: [String] = [], node: [String: TonJSON] = [:], prices: [TonPrice] = []
        var holdingErrors: [TonError] = []
        try await withThrowingTaskGroup(of: (String, TonHolding?, TonJSON?, TonError?).self) { group in
            var next = 0
            func enqueue() {
                guard next < rows.count, !Task.isCancelled else { return }
                let row = rows[next]; next += 1
                group.addTask {
                    let ref = (try? TonIdentity.raw(row["jetton"]["address"].string ?? "")) ?? "invalid"
                    do { let (holding,raw) = try await self.holding(row,owner:owner); return (ref,holding,raw,nil) }
                    catch {
                        if error is CancellationError { throw error }
                        try Task.checkCancellation()
                        OathDiagnostics.record(error); return (ref,nil,nil,error as? TonError)
                    }
                }
            }
            for _ in 0..<4 { enqueue() }
            for try await (ref,holding,raw,cause) in group {
                if let holding, let raw { holdings.append(holding); node[ref] = raw } else { failed.append(ref) }
                if let cause { holdingErrors.append(cause) }
                enqueue()
            }
        }
        try Task.checkCancellation()
        let found = Set(holdings.map { $0.token.reference })
        for row in rows {
            guard let ref = row["jetton"]["address"].string.flatMap({try? TonIdentity.raw($0)}), found.contains(ref),
                  let usd = TonMarkets.positive(row["price"]["prices"]["USD"]) else { continue }
            prices.append(.init(reference:ref,usd:usd,source:"TonAPI",fetchedAt:.now))
        }
        return .init(owner:owner,holdings:holdings.sorted{$0.token.reference<$1.token.reference},prices:prices,failedReferences:failed.sorted(),discoveryComplete:complete,observedAt:.now,
                     raw:try JSONEncoder().encode(TonJSON.object(["account":account,"index":.array(pages),"wallets":.object(node)])),discoveryError:discoveryError,holdingErrors:holdingErrors)
    }
    public func history(owner address: String, stream: TonStream, before: Int64? = nil, limit: Int = 100) async throws -> TonHistoryPage {
        let owner = try TonIdentity.raw(address)
        guard (1...1000).contains(limit), before == nil || before! > 0 else { throw TonError.malformed }
        var params = ["limit":String(limit)]
        if let before { params["before_lt"] = String(before) }
        let value: TonJSON
        if stream == .native { params["sort_order"] = "desc"; value = try await indexed("blockchain/accounts/"+owner+"/transactions",params:params) }
        else { value = try await indexed("accounts/"+owner+"/jettons/history",params:params) }
        do { return try TonDecoding.history(value,owner:owner,stream:stream,before:before,limit:limit) }
        catch TonError.paginationLoop {
            // A whole small page at the overlap boundary needs a wider page,
            // not a cursor that silently drops operations sharing that LT.
            if stream == .jettons, limit < 1000, let before, let rows = value["operations"].array,
               rows.count == limit, rows.allSatisfy({ (try? TonIdentity.lt($0["lt"])) == before-1 }) {
                return try await history(owner:owner,stream:stream,before:before,limit:min(1000,limit*2))
            }
            throw TonError.paginationLoop
        }
    }
    /// Contract-keyed quotes, never a symbol lookup that could price an impostor.
    public func prices(references: [String]) async throws -> [TonPrice] {
        guard !references.isEmpty, references.count <= 100 else { throw TonError.malformed }
        let refs = try references.map { $0 == "native" ? "gram" : try TonIdentity.raw($0) }
        let value = try await indexed("rates",params:["tokens":refs.joined(separator:","),"currencies":"usd"])
        guard let rates = value["rates"].fields else { throw TonError.malformed }
        var prices: [TonPrice] = []
        for (key,value) in rates {
            let ref = key.uppercased() == "GRAM" || key.uppercased() == "TON" ? "native" : try TonIdentity.raw(key)
            guard references.contains(ref), let usd = TonMarkets.positive(value["prices"]["USD"]) else { continue }
            prices.append(.init(reference:ref,usd:usd,source:"TonAPI",fetchedAt:.now))
        }
        return prices
    }
}
