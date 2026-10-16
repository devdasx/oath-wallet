import OathDiagnostics
import Foundation

/// ANKR validates TON mainnet state and Jetton ownership. TonAPI supplies the
/// token/history index unavailable from ANKR's working node methods.
public actor TonClient {
    private let endpoint: URL
    private let transport: any AnkrTransport
    private let nodeGate = AnkrPermits(count: 4)
    private let indexGate = AnkrPermits(count: 1)
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
        let gate = index ? indexGate : nodeGate
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
                do {
                    let (data,status) = try await transport.send(req)
                    guard status == 200 else { throw TonError.http(status) }
                    guard data.count <= 32 * 1024 * 1024 else { throw TonError.malformed }
                    let value = try JSONDecoder().decode(TonJSON.self, from: data)
                    await gate.release(); return value
                } catch { OathDiagnostics.record(error);
                    if error is CancellationError || Task.isCancelled { throw CancellationError() }
                    let retry: Bool
                    switch error { case TonError.http(let n): retry = n == 429 || n >= 500
                    case AnkrError.transport: retry = true
                    default: retry = false }
                    if retry && attempt < 2 { try await Task.sleep(for: .seconds(index ? 5 * (1 << attempt) : 1 << attempt)); continue }
                    if let error = error as? TonError { throw error }; throw TonError.transport
                }
            }
            throw TonError.transport
        } catch { OathDiagnostics.record(error); await gate.release(); throw error }
    }
    func rpc(_ method: String, _ params: [String: TonJSON] = [:]) async throws -> TonJSON {
        let value = try await request(endpoint, body: .object(["jsonrpc":.string("2.0"),"id":.number("1"),"method":.string(method),"params":.object(params)]))
        guard value["id"].text == "1", value["jsonrpc"].string == "2.0" else { throw TonError.malformed }
        if !value["error"].isNull { throw TonError.rpc(value["error"]["code"].text.flatMap(Int.init) ?? -1) }
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
    func discovery(_ owner: String) async throws -> ([TonJSON], [TonJSON], Bool) {
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
                if values.count < 1000 { return (rows,pages,true) }; offset += values.count
            } catch { OathDiagnostics.record(error); try Task.checkCancellation(); return (rows,pages,false) }
        }
        return (rows,pages,false)
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
        let (account,(rows,pages,complete)) = try await (state,tokens)
        guard ["active","uninitialized","frozen"].contains(account["state"].string ?? "") else { throw TonError.malformed }
        var holdings = [TonHolding(token: .native, wallet: nil, amount: try TonIdentity.amount(account["balance"]))]
        var failed: [String] = [], node: [String: TonJSON] = [:], prices: [TonPrice] = []
        await withTaskGroup(of: (String, TonHolding?, TonJSON?).self) { group in
            var next = 0
            func enqueue() {
                guard next < rows.count, !Task.isCancelled else { return }
                let row = rows[next]; next += 1
                group.addTask {
                    let ref = (try? TonIdentity.raw(row["jetton"]["address"].string ?? "")) ?? "invalid"
                    do { let (holding,raw) = try await self.holding(row,owner:owner); return (ref,holding,raw) }
                    catch { OathDiagnostics.record(error); return (ref,nil,nil) }
                }
            }
            for _ in 0..<4 { enqueue() }
            for await (ref,holding,raw) in group {
                if let holding, let raw { holdings.append(holding); node[ref] = raw } else { failed.append(ref) }
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
                     raw:try JSONEncoder().encode(TonJSON.object(["account":account,"index":.array(pages),"wallets":.object(node)])))
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
