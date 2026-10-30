import OathDiagnostics
import Foundation

/// GraphQL pages pinned to a checkpoint, with complete balance-change arrays.
public actor SuiClient {
    private var network: SuiSendNetwork = .mainnet
    private let endpoint: URL
    private let transport: any AnkrTransport
    private let fallback: URL?
    private let permits = AnkrPermits(count:4)
    private var tokens: [String:SuiToken] = ["native":.native]
    private var metadataExpiry: [String:Date] = [:]
    // Replica lag is scoped to the exact advertised checkpoint. Remember it
    // briefly across pages so a 28-page inventory does not repeat 28 failures.
    // No owners, queries or cursors are stored, and the set is bounded.
    private var laggingCheckpoints: [UInt64: Date] = [:]
    public init(apiKey: String, transport: any AnkrTransport = AnkrHTTPTransport()) throws {
        guard !apiKey.isEmpty, apiKey.count <= 256, apiKey.utf8.allSatisfy({(48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)}) else { throw SuiError.configuration }
        endpoint = URL(string:"https://rpc.ankr.com/premium-http/sui_graphql")!.appendingPathComponent(apiKey)
        fallback = URL(string:"https://graphql.mainnet.sui.io/graphql")!
        self.transport = transport
    }
    /// Also used for independent, same-checkpoint validation.
    public init(publicProvider: Bool, transport: any AnkrTransport = AnkrHTTPTransport()) {
        endpoint = URL(string:"https://graphql.mainnet.sui.io/graphql")!; fallback = nil; self.transport = transport
    }
    public init(network: SuiSendNetwork, transport: any AnkrTransport = AnkrHTTPTransport()) {
        self.network = network; endpoint = network.endpoint; fallback = nil; self.transport = transport
    }
    private func query(_ query: String, _ variables: [String:SuiJSON] = [:]) async throws -> (SuiJSON,Data) {
        try await permits.acquire(); defer { Task { await permits.release() } }
        let body = try JSONEncoder().encode(SuiJSON.object(["query":.string(query),"variables":.object(variables)]))
        laggingCheckpoints = laggingCheckpoints.filter { $0.value > .now }
        let checkpoint = variables["checkpoint"]?.integer
        let fallbackFirst = checkpoint.map { laggingCheckpoints[$0] != nil } ?? false
        let endpoints = fallback.map { fallbackFirst ? [$0, endpoint] : [endpoint, $0] } ?? [endpoint]
        for (index,url) in endpoints.enumerated() {
            do {
                try Task.checkCancellation()
                var request = URLRequest(url:url); request.httpMethod = "POST"; request.httpBody = body; request.timeoutInterval = 25
                request.setValue("application/json",forHTTPHeaderField:"Content-Type")
                let (data,status) = try await transport.send(request)
                guard status == 200 else { throw SuiError.http(status) }
                let envelope = try JSONDecoder().decode(SuiJSON.self,from:data)
                if let errors = envelope["errors"].array, !errors.isEmpty {
                    // Never propagate a provider's message, URL, or credential.
                    let expired = errors.contains { let m = ($0["message"].string ?? "").lowercased(); return m.contains("cursor") && (m.contains("expired") || m.contains("pruned") || m.contains("checkpoint")) }
                    if errors.contains(where:{$0["extensions"]["code"].string == "RESOURCE_EXHAUSTED"}) { throw SuiError.resourceExhausted }
                    // A load-balanced indexer may advertise a checkpoint that
                    // its next replica has not indexed yet. Retry the exact
                    // pinned query elsewhere; never lower its snapshot height.
                    if let checkpoint = variables["checkpoint"]?.integer,
                       errors.allSatisfy({ $0["message"].string == "Checkpoint \(checkpoint) in the future" }) {
                        throw SuiError.checkpointUnavailable
                    }
                    throw expired ? SuiError.cursorExpired : SuiError.graphql
                }
                let value = envelope["data"]
                guard value["chainIdentifier"].string == network.chainIdentifier else { throw SuiError.wrongNetwork }
                try Task.checkCancellation()
                if url == endpoint, let checkpoint { laggingCheckpoints[checkpoint] = nil }
                return (value,data)
            } catch { OathDiagnostics.record(error);
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                let safe = (error as? SuiError) ?? .transport
                if safe == .checkpointUnavailable, url == endpoint, fallback != nil, let checkpoint {
                    if laggingCheckpoints[checkpoint] == nil, laggingCheckpoints.count >= 32,
                       let oldest = laggingCheckpoints.min(by: { $0.value < $1.value })?.key {
                        laggingCheckpoints[oldest] = nil
                    }
                    laggingCheckpoints[checkpoint] = Date().addingTimeInterval(60)
                }
                let transient: Bool
                switch safe { case .checkpointUnavailable, .transport, .http(408), .http(429), .http(500), .http(502), .http(503), .http(504): transient = true; default: transient = false }
                if index+1 < endpoints.count && transient { continue }; throw safe
            }
        }
        throw SuiError.transport
    }
    public func checkpoint() async throws -> Int64 {
        let (value,_) = try await query("{ chainIdentifier checkpoint { sequenceNumber } }")
        return try SuiIdentity.number(value["checkpoint"]["sequenceNumber"])
    }
    public func inventory(owner: String, atCheckpoint: Int64? = nil, pageSize: Int = 50) async throws -> SuiInventory {
        let owner = try SuiIdentity.address(owner)
        let cp: Int64
        if let atCheckpoint { guard atCheckpoint >= 0 else { throw SuiError.malformed }; cp = atCheckpoint }
        else { cp = try await checkpoint() }
        let queryText = """
            query($owner:SuiAddress!, $checkpoint:UInt53!, $after:String, $size:Int!) {
              chainIdentifier
              address(address:$owner, atCheckpoint:$checkpoint) { address
                balances(first:$size, after:$after) { pageInfo { hasNextPage endCursor }
                  nodes { coinType { repr } totalBalance coinBalance addressBalance }
                }
              }
            }
            """
        var cursor: String?, cursors:Set<String> = [], seen:Set<String> = [], holdings:[SuiHolding] = [], raw:[SuiJSON] = []
        repeat {
            let (value,_) = try await query(queryText,["owner":.string(owner),"checkpoint":.number(String(cp)),"after":cursor.map(SuiJSON.string) ?? .null,"size":.number(String(min(100,max(1,pageSize))))])
            guard let returned = value["address"]["address"].string, try SuiIdentity.address(returned) == owner,
                  let rows = value["address"]["balances"]["nodes"].array else { throw SuiError.wrongOwner }
            raw.append(value)
            for row in rows {
                guard let type = row["coinType"]["repr"].string else { throw SuiError.malformed }
                let ref = try SuiIdentity.reference(type)
                guard seen.insert(ref).inserted else { throw SuiError.paginationLoop }
                let total = try SuiIdentity.amount(row["totalBalance"]), coins = try SuiIdentity.amount(row["coinBalance"]), address = try SuiIdentity.amount(row["addressBalance"])
                guard SuiIdentity.add(coins,address) == total else { throw SuiError.malformed }
                let metadata = try? SuiToken.decode(row["coinMetadata"],reference:ref)
                if let metadata { tokens[ref] = metadata }
                holdings.append(.init(reference:ref,token:metadata ?? tokens[ref],amount:total,coinBalance:coins,addressBalance:address))
            }
            let page = value["address"]["balances"]["pageInfo"]
            if try SuiIdentity.bool(page["hasNextPage"]) {
                guard !rows.isEmpty, let next = page["endCursor"].string, !next.isEmpty, cursors.insert(next).inserted else { throw SuiError.paginationLoop }; cursor = next
            } else { cursor = nil }
        } while cursor != nil
        if !seen.contains("native") { holdings.append(.init(reference:"native",token:.native,amount:"0",coinBalance:"0",addressBalance:"0")) }
        _ = await OathDiagnostics.attempt("metadata", body: { try await metadata(references:holdings.map(\.reference)) })
        try Task.checkCancellation()
        let enriched = holdings.map { h in SuiHolding(reference:h.reference,token:tokens[h.reference] ?? h.token,amount:h.amount,coinBalance:h.coinBalance,addressBalance:h.addressBalance) }
        return .init(owner:owner,holdings:enriched,checkpoint:cp,observedAt:.now,raw:try JSONEncoder().encode(SuiJSON.array(raw)))
    }
    public func metadata(references: [String]) async throws -> [String:SuiToken] {
        let refs = try Array(Set(references.map{try SuiIdentity.reference($0)})).sorted()
        let missing = refs.filter { $0 != "native" && (metadataExpiry[$0] ?? .distantPast) < .now }
        // Live providers permit 21 backing-store accesses per request. Eight
        // metadata aliases fit that budget; up to four batches run in parallel.
        await withTaskGroup(of:Void.self) { group in
            var next = 0
            func enqueue() {
                guard next < missing.count, !Task.isCancelled else { return }
                let batch = Array(missing[next..<min(next+8,missing.count)]); next += batch.count
                group.addTask { await OathDiagnostics.attempt("metadataBatch", body: { try await self.metadataBatch(batch) }) }
            }
            for _ in 0..<4 { enqueue() }; for await _ in group { enqueue() }
        }
        try Task.checkCancellation()
        return tokens.filter { refs.contains($0.key) }
    }
    private func metadataBatch(_ batch:[String]) async throws {
        let declarations = batch.indices.map { "$t\($0):String!" }.joined(separator:",")
        let fields = batch.indices.map { "t\($0):coinMetadata(coinType:$t\($0)){name symbol decimals iconUrl description}" }.joined(separator:" ")
        let vars = try Dictionary(uniqueKeysWithValues:batch.enumerated().map{("t\($0.offset)",SuiJSON.string(try SuiIdentity.coinType($0.element)))})
        let (value,_) = try await query("query(\(declarations)){chainIdentifier \(fields)}",vars)
        for (i,ref) in batch.enumerated() {
            if let token = try? SuiToken.decode(value["t\(i)"],reference:ref) { tokens[ref] = token }
            metadataExpiry[ref] = Date().addingTimeInterval(900)
        }
    }
    public func history(owner: String, before: String? = nil, beforeCheckpoint: Int64? = nil, limit: Int = 25) async throws -> SuiHistoryPage {
        let owner = try SuiIdentity.address(owner)
        let text = """
            query($owner:SuiAddress!, $before:String, $checkpoint:UInt53, $size:Int!) {
              chainIdentifier
              transactions(last:$size, before:$before, filter:{affectedAddress:$owner, beforeCheckpoint:$checkpoint}) {
                pageInfo { hasPreviousPage startCursor }
                edges { cursor node { digest sender { address } gasInput { gasSponsor { address } } transactionJson
                  effects { status timestamp checkpoint { sequenceNumber } balanceChangesJson effectsJson
                    gasEffects { gasSummary { computationCost storageCost storageRebate nonRefundableStorageFee } } }
                } }
              }
            }
            """
        let value:SuiJSON, raw:Data
        do {
            (value,raw) = try await query(text,["owner":.string(owner),"before":before.map(SuiJSON.string) ?? .null,"checkpoint":beforeCheckpoint.map{.number(String($0))} ?? .null,"size":.number(String(min(50,max(1,limit))))])
        } catch SuiError.resourceExhausted {
            guard limit > 1 else { throw SuiError.resourceExhausted }
            return try await history(owner:owner,before:before,beforeCheckpoint:beforeCheckpoint,limit:max(1,limit/2))
        }
        guard let edges = value["transactions"]["edges"].array else { throw SuiError.malformed }
        var refs:Set<String> = []
        for edge in edges {
            guard let changes = edge["node"]["effects"]["balanceChangesJson"].array else { throw SuiError.malformed }
            for change in changes where change["address"].string.flatMap({try? SuiIdentity.address($0)}) == owner {
                guard let type = change["coinType"].string else { throw SuiError.malformed }; refs.insert(try SuiIdentity.reference(type))
            }
        }
        // Missing metadata must not discard valid history. Preserve exact raw
        // amounts and types and project them when metadata becomes available.
        _ = await OathDiagnostics.attempt("metadata", body: { try await metadata(references:Array(refs)) })
        try Task.checkCancellation()
        let transactions = try edges.reversed().map { try SuiDecoding.transaction($0["node"],owner:owner,tokens:tokens) }
        guard Set(transactions.map(\.hash)).count == transactions.count else { throw SuiError.malformed }
        let page = value["transactions"]["pageInfo"]
        var next:String?
        if try SuiIdentity.bool(page["hasPreviousPage"]) {
            guard !edges.isEmpty, let cursor = page["startCursor"].string, !cursor.isEmpty, cursor != before else { throw SuiError.paginationLoop }; next = cursor
        }
        return .init(transactions:transactions,next:next,head:transactions.first?.hash,raw:raw)
    }
}
