import Foundation
import OathDiagnostics

/// No API key or user credentials. Balance and history providers intentionally
/// remain separate: Midgard's reconstructed balances are not authoritative.
public struct ThorchainClient: Sendable {
    public static let node = URL(string:"https://gateway.liquify.com/chain/thorchain_api")!
    public static let rpc = URL(string:"https://gateway.liquify.com/chain/thorchain_rpc")!
    public static let midgard = URL(string:"https://gateway.liquify.com/chain/thorchain_midgard")!
    private let transport:any AnkrTransport
    let catalogRequests: ThorchainCatalogRequests
    public init() {
        self.init(transport: AnkrHTTPTransport(), catalogRequests: .shared)
    }
    public init(transport: any AnkrTransport) {
        // Injected transports retain isolated caches (fixtures and other hosts
        // must never populate the production process's public market cache).
        self.init(transport: transport, catalogRequests: ThorchainCatalogRequests())
    }
    init(transport: any AnkrTransport, catalogRequests: ThorchainCatalogRequests) {
        self.transport = transport
        self.catalogRequests = catalogRequests
    }
    func read(_ base:URL, path:String, query:[URLQueryItem] = [], height:Int64?=nil) async throws -> SolanaJSON {
        try await OathDiagnostics.$chain.withValue("thorchain") {
            try await OathDiagnostics.$operationID.withValue(OathDiagnostics.operationID ?? UUID()) {
                try await readRequest(base, path:path, query:query, height:height)
            }
        }
    }
    private func readRequest(_ base:URL, path:String, query:[URLQueryItem], height:Int64?) async throws -> SolanaJSON {
        var url = URLComponents(url:base.appendingPathComponent(path),resolvingAgainstBaseURL:false)!
        if !query.isEmpty { url.queryItems=query }
        var request = URLRequest(url:url.url!); request.timeoutInterval=20
        if let height { guard height>0 else {throw ThorchainError.malformed};request.setValue(String(height),forHTTPHeaderField:"x-cosmos-block-height") }
        request.setValue("OathWallet/1.0",forHTTPHeaderField:"User-Agent")
        // Liquify asks for this identifier. Sending it to public price APIs
        // bypasses PublicMarketRequests' anonymous-request admission rules.
        if base.host == Self.node.host { request.setValue("oath-wallet",forHTTPHeaderField:"x-client-id") }
        do {
            for attempt in 0..<3 {
                try Task.checkCancellation()
                let data: Data, status: Int
                do { (data,status) = try await transport.send(request) }
                catch {
                    if error is CancellationError || Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                    let transient: Bool
                    switch error {
                    case AnkrError.transport: transient = true
                    case let error as URLError: transient = [.timedOut,.networkConnectionLost,.cannotConnectToHost].contains(error.code)
                    default: transient = false
                    }
                    // Node/RPC reads are GET-only. Replay the identical request
                    // once, retaining its pinned block and pagination cursor.
                    // Share the HTTP retry budget; public price requests retain
                    // their own cooldown/fallback scheduling. No TLS policy changes.
                    guard attempt == 0, transient, base == Self.node || base == Self.rpc else { throw error }
                    OathDiagnostics.record(error,component:"ThorchainClient",operation:"read_retry",
                                           context:["stage":"transport_retry","host":base.host ?? "","attempt":"1"])
                    try await Task.sleep(for:.milliseconds(500))
                    continue
                }
                guard data.count <= 12_000_000 else { throw ThorchainError.malformed }
                // A load-balanced API can lag its advertised block briefly.
                // Retry the exact pinned request, never drop the height or mix
                // pages from different blocks. Unrelated 500s remain failures.
                // Optional decoding only classifies the known provider envelope.
                let envelope = status == 500 ? try? JSONDecoder().decode(SolanaJSON.self, from: data) : nil
                let heightLag = base == Self.node && height != nil && status == 500 &&
                    envelope?["code"].integer == 2 &&
                    envelope?["message"].string == "cannot query with height in the future; please provide a valid height: invalid height"
                let publicRateLimit = status == 429 && (PublicMarketRequests.accepts(request) || base.host == "api.rujira.network")
                if (heightLag && attempt < 2) ||
                    (attempt == 0 && [429,502,503,504].contains(status) && !publicRateLimit) {
                    OathDiagnostics.record(ThorchainError.http(status),component:"ThorchainClient",operation:"retry",
                                           context:["stage":heightLag ? "pinned_height_lag":"provider_retry"])
                    try await Task.sleep(for:.seconds(heightLag ? attempt + 1 : status == 429 ? 2:1)); continue
                }
                guard status == 200 else { throw ThorchainError.http(status) }
                return try JSONDecoder().decode(SolanaJSON.self,from:data)
            }
            throw ThorchainError.transport
        } catch {
            if error is CancellationError || Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            // Public schedulers may defer before sending. Retain that outcome
            // for fallback callers; it is not a new transport failure.
            if let deferral = error as? DiagnosticDeferral { throw deferral }
            OathDiagnostics.record(error,component:"ThorchainClient",operation:"read")
            throw (error as? ThorchainError) ?? .transport
        }
    }
    public func inventory(owner:String,height:Int64?=nil) async throws -> ThorchainInventory {
        let owner = try ThorchainIdentity.address(owner)
        var key:String?, visited:Set<String> = [], holdings:[String:String] = [:]
        for _ in 0..<100 {
            var query:[URLQueryItem] = [.init(name:"pagination.limit",value:"100")]
            if let key { query.append(.init(name:"pagination.key",value:key)) }
            let json = try await read(Self.node,path:"cosmos/bank/v1beta1/balances/"+owner,query:query,height:height)
            guard let rows=json["balances"].array else { throw ThorchainError.malformed }
            for row in rows {
                guard let denom=row["denom"].string else { throw ThorchainError.malformed }
                let ref = try ThorchainIdentity.reference(denom)
                guard holdings[ref] == nil else { throw ThorchainError.paginationLoop }
                holdings[ref] = try ThorchainIdentity.amount(row["amount"])
            }
            guard holdings.count <= 10_000 else { throw ThorchainError.incomplete }
            key = json["pagination"]["next_key"].string.flatMap{$0.isEmpty ? nil:$0}
            if key == nil {
                holdings["native"] = holdings["native"] ?? "0"
                return .init(owner:owner,holdings:holdings.sorted{$0.key<$1.key}.map{.init(reference:$0.key,amount:$0.value)},height:height)
            }
            guard visited.insert(key!).inserted else { throw ThorchainError.paginationLoop }
        }
        throw ThorchainError.incomplete
    }
    public func latestHeight(atLeast minimumHeight: Int64 = 1) async throws -> Int64 {
        guard minimumHeight > 0 else { throw ThorchainError.malformed }
        // Read from the same API service that serves pinned bank balances.
        // The independent consensus RPC can be ahead of its bank/API replicas.
        for attempt in 0..<3 {
            try Task.checkCancellation()
            let j = try await read(Self.node,path:"cosmos/base/tendermint/v1beta1/blocks/latest")["block"]["header"]
            guard j["chain_id"].string == "thorchain-1",
                  let h = j["height"].text.flatMap(Int64.init), h > 0 else { throw ThorchainError.malformed }
            if h >= minimumHeight { return h }
            // An older latest-head hint is not yet a failed refresh: gateways
            // can serve the already-committed block by its explicit height.
            // Give the head endpoint its existing bounded chance to catch up.
            if attempt < 2 { try await Task.sleep(for: .seconds(attempt + 1)) }
        }
        // A "latest" replica must not block a valid, nonregressing snapshot.
        // Verify the exact floor on the SAME API before using it. Inventory
        // still performs fresh pinned bank reads; no cached balance is relabeled
        // and no older block or synthetic height can pass this check.
        do {
            let header = try await read(Self.node, path: "cosmos/base/tendermint/v1beta1/blocks/\(minimumHeight)")["block"]["header"]
            guard header["chain_id"].string == "thorchain-1",
                  header["height"].text.flatMap(Int64.init) == minimumHeight else { throw ThorchainError.malformed }
            return minimumHeight
        } catch ThorchainError.http(404) {
            // A confirmed missing floor is the terminal consistency failure.
            // Intermediate valid but older head hints are expected recovery,
            // not three separate app errors when the pinned block is readable.
            OathDiagnostics.record(ThorchainError.staleHeight, component: "ThorchainClient", operation: "height_retry",
                context: ["chain": "thorchain", "stage": "lower_height", "attempt": "3"])
            throw ThorchainError.staleHeight
        }
    }
    public func history(owner:String, stream:String, height:Int64, lowerHeight:Int64 = 0, page:Int = 1) async throws -> ThorchainHistoryPage {
        let owner = try ThorchainIdentity.address(owner)
        guard ["transfer.sender","transfer.recipient","message.sender"].contains(stream), height > 0, lowerHeight >= 0, lowerHeight <= height, page > 0 else { throw ThorchainError.malformed }
        let query = "\(stream)='\(owner)' AND tx.height<=\(height) AND tx.height>=\(lowerHeight)"
        let q:[URLQueryItem] = [.init(name:"query",value:query),.init(name:"limit",value:"50"),.init(name:"page",value:String(page)),.init(name:"order_by",value:"ORDER_BY_DESC")]
        return try Self.decodeTransactions(await read(Self.node,path:"cosmos/tx/v1beta1/txs",query:q),owner:owner,page:page,upperHeight:height,lowerHeight:lowerHeight)
    }
    public static func decodeTransactions(_ json:SolanaJSON, owner:String, page:Int = 1, upperHeight:Int64 = .max, lowerHeight:Int64 = 0) throws -> ThorchainHistoryPage {
        _ = try ThorchainIdentity.address(owner)
        guard let txs = json["tx_responses"].array, txs.count <= 50,
              let total = json["total"].text.flatMap(Int64.init), total >= 0 else { throw ThorchainError.malformed }
        var output:[ThorchainEvent] = []
        let dateParser = ISO8601DateFormatter()
        for tx in txs {
            guard let hash = tx["txhash"].string, hash.count == 64,
                  hash.utf8.allSatisfy({(48...57).contains($0)||(65...70).contains($0)||(97...102).contains($0)}),
                  let height = tx["height"].text.flatMap(Int64.init), (lowerHeight...upperHeight).contains(height),
                  let date = tx["timestamp"].string,
                  let code = tx["code"].integer,
                  let events = tx["events"].array else { throw ThorchainError.malformed }
            dateParser.formatOptions = date.contains(".") ? [.withInternetDateTime,.withFractionalSeconds] : [.withInternetDateTime]
            guard let timestamp = dateParser.date(from:date)?.timeIntervalSince1970 else { throw ThorchainError.malformed }
            var fee:UInt64 = 0
            for event in events where event["type"].string == "transfer" {
                let attrs = event["attributes"].array ?? []
                func value(_ key:String) -> String? { attrs.first{$0["key"].string == key}?["value"].string }
                if value("recipient") == "thor1dheycdevq39qlkxs2a6wuuzyn4aqxhve4qxtxt", value("msg_index") == nil,
                   let text = value("amount"), text.hasSuffix("rune"), let n = UInt64(text.dropLast(4)) {
                    let sum = fee.addingReportingOverflow(n); guard !sum.overflow else { throw ThorchainError.malformed }; fee=sum.partialValue
                }
            }
            var belongs = false
            let startingCount=output.count
            let state = code == 0 ? "confirmed":"failed"
            for (index,event) in events.enumerated() {
                // CosmWasm application events may repeat arbitrary attribute
                // names. Only bank transfers and sender messages define this ledger.
                guard ["transfer","message"].contains(event["type"].string ?? "") else { continue }
                guard let attributes = event["attributes"].array else { throw ThorchainError.malformed }
                if event["type"].string == "message" {
                    belongs = belongs || attributes.contains { $0["key"].string == "sender" && $0["value"].string == owner }
                    continue
                }
                var attrs:[String:String] = [:]
                for a in attributes {
                    guard let key = a["key"].string, let value = a["value"].string else { throw ThorchainError.malformed }
                    guard attrs[key] == nil else { throw ThorchainError.malformed }; attrs[key] = value
                }
                if attrs["sender"] == owner || attrs["recipient"] == owner { belongs = true }
                guard event["type"].string == "transfer", let sender = attrs["sender"], let recipient = attrs["recipient"],
                      sender == owner || recipient == owner, let coins = attrs["amount"] else { continue }
                // Ante-handler reserve transfers are the network fee. A user
                // payment to reserve has msg_index and remains a real transfer.
                if recipient == "thor1dheycdevq39qlkxs2a6wuuzyn4aqxhve4qxtxt", attrs["msg_index"] == nil { continue }
                for (coinIndex,coin) in coins.split(separator:",").enumerated() {
                    let digits = coin.prefix(while:{$0.isASCII && $0.isNumber})
                    let ref = try ThorchainIdentity.reference(String(coin.dropFirst(digits.count)))
                    let amount = try ThorchainIdentity.amount(.string(String(digits)))
                    let direction = sender == owner ? (recipient == owner ? "self":"outgoing") : "incoming"
                    output.append(.init(id:hash.uppercased()+":\(index):\(coinIndex)",hash:hash.uppercased(),reference:ref,amount:amount,direction:direction,counterparty:sender == owner ? recipient:sender,state:state,height:height,timestamp:timestamp,fee:fee == 0 ? nil:String(fee)))
                }
            }
            guard belongs else { throw ThorchainError.wrongOwner }
            if output.count == startingCount {
                // A failed call or fee-only contract action still belongs in
                // the ledger, without inventing a successful token transfer.
                output.append(.init(id:hash.uppercased()+":execution",hash:hash.uppercased(),reference:"native",amount:"0",direction:"outgoing",counterparty:"",state:state,height:height,timestamp:timestamp,fee:fee == 0 ? nil:String(fee)))
            }
        }
        guard !txs.isEmpty || Int64(page-1)*50 >= total else { throw ThorchainError.incomplete }
        return .init(owner:owner,events:output,next:Int64(page)*50 < total ? String(page+1):nil,rawCount:txs.count)
    }
}
