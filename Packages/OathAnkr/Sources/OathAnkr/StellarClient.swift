import OathDiagnostics
import Foundation

public actor StellarClient {
    private let endpoint:URL, horizon:URL, fallback:URL?, soroban:URL?
    private let transport:any AnkrTransport
    private let permits = AnkrPermits(count:6)
    public init(apiKey:String,transport:any AnkrTransport = AnkrHTTPTransport()) throws {
        guard !apiKey.isEmpty, apiKey.count <= 256, apiKey.utf8.allSatisfy({(48...57).contains($0)||(65...90).contains($0)||(97...122).contains($0)}) else { throw StellarError.configuration }
        endpoint = URL(string:"https://rpc.ankr.com/multichain")!.appendingPathComponent(apiKey)
        soroban = URL(string:"https://rpc.ankr.com/stellar_soroban")!.appendingPathComponent(apiKey)
        horizon = URL(string:"https://rpc.ankr.com/http/stellar_horizon")!
        fallback = URL(string:"https://horizon.stellar.org")!; self.transport = transport
    }
    public init(endpoint:URL,horizon:URL,fallback:URL? = nil,soroban:URL? = nil,transport:any AnkrTransport = AnkrHTTPTransport()) throws {
        guard endpoint.scheme == "https", horizon.scheme == "https", fallback == nil || fallback?.scheme == "https", soroban == nil || soroban?.scheme == "https" else { throw StellarError.configuration }
        self.endpoint = endpoint; self.soroban = soroban; self.horizon = horizon; self.fallback = fallback; self.transport = transport
    }
    private func send(_ request:URLRequest) async throws -> StellarJSON {
        try await permits.acquire(); let response:(Data,Int)
        do { response = try await transport.send(request) }
        catch { OathDiagnostics.record(error); await permits.release(); if Task.isCancelled || error is CancellationError { throw CancellationError() }; throw StellarError.transport }
        await permits.release(); try Task.checkCancellation()
        guard response.1 == 200 else { throw StellarError.http(response.1) }
        guard let json = try? JSONDecoder().decode(StellarJSON.self,from:response.0) else { throw StellarError.malformed }; return json
    }
    private func rpc(_ method:String,_ params:[String:StellarJSON]) async throws -> StellarJSON {
        var p = params; p["blockchain"] = .string("stellar_soroban")
        var request = URLRequest(url:endpoint); request.httpMethod = "POST"; request.timeoutInterval = 30
        request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        request.httpBody = try JSONEncoder().encode(StellarJSON.object(["jsonrpc":.string("2.0"),"id":.number("1"),"method":.string(method),"params":.object(p)]))
        let result = try await send(request)
        if !result["error"].isNull { throw StellarError.rpc(Int(result["error"]["code"].text ?? "") ?? -1) }
        guard !result["result"].isNull else { throw StellarError.malformed }; return result["result"]
    }
    private func rest(_ base:URL,_ path:String) async throws -> StellarJSON {
        var request = URLRequest(url:path.isEmpty ? base:base.appendingPathComponent(path)); request.timeoutInterval = 25
        return try await send(request)
    }
    private func account(_ base:URL,owner:String) async throws -> (StellarJSON,StellarLedger) {
        let info = try await rest(base,"")
        guard info["network_passphrase"].string == StellarIdentity.network else { throw StellarError.wrongNetwork }
        let ledger = try StellarLedger(height:StellarIdentity.number(info["history_latest_ledger"]),timestamp:StellarIdentity.date(info["history_latest_ledger_closed_at"]))
        do { return (try await rest(base,"accounts/"+owner),ledger) }
        catch StellarError.http(404) { return (.null,ledger) }
    }
    private func classic(owner:String) async throws -> (StellarJSON,StellarLedger) {
        do { return try await account(horizon,owner:owner) }
        catch { OathDiagnostics.record(error);
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            guard let fallback else { throw error }; return try await account(fallback,owner:owner)
        }
    }
    private func indexed(owner:String,whitelist:Bool) async throws -> (holdings:[StellarHolding],raw:[StellarJSON],ledger:StellarLedger,prices:[StellarPrice]) {
        var page:String?, seen:Set<String> = [], holdings:[StellarHolding] = [], raw:[StellarJSON] = [], prices:[StellarPrice] = []
        var ledger:StellarLedger?, expected:Int64?
        repeat {
            try Task.checkCancellation()
            var p:[String:StellarJSON] = ["walletAddress":.string(owner),"onlyWhitelisted":.bool(whitelist),"pageSize":.number("100"),"nativeFirst":.bool(true)]
            if let page { p["pageToken"] = .string(page) }
            let v = try await rpc("stellar_getAccountBalance",p)
            guard let rows = v["assets"].array else { throw StellarError.malformed }
            let current = try StellarLedger(height:StellarIdentity.number(v["syncStatus"]["blockNumber"]),timestamp:Double(StellarIdentity.number(v["syncStatus"]["timestamp"])))
            ledger = ledger.map{ $0.height <= current.height ? $0:current } ?? current
            let total = try StellarIdentity.number(v["totalCount"])
            if let expected, expected != total { throw StellarError.incompleteInventory }; expected = total
            for row in rows {
                let item = try StellarDecoding.indexedHolding(row,owner:owner); holdings.append(item)
                if let price = TonMarkets.positive(row["tokenPrice"]) { prices.append(.init(reference:item.reference,usd:price,source:"ANKR Stellar",fetchedAt:Date(timeIntervalSince1970:current.timestamp))) }
            }
            raw.append(v)
            page = v["nextPageToken"].string.flatMap{$0.isEmpty ? nil:$0}
            if let page { guard page.count <= 8192, seen.insert(page).inserted else { throw StellarError.paginationLoop } }
        } while page != nil
        guard let ledger, expected == Int64(holdings.count), Set(holdings.map(\.reference)).count == holdings.count else { throw StellarError.incompleteInventory }
        return (holdings,raw,ledger,prices)
    }
    public func inventory(owner:String) async throws -> StellarInventory {
        let owner = try StellarIdentity.address(owner)
        async let account = classic(owner:owner)
        async let full = indexed(owner:owner,whitelist:false)
        async let verified = indexed(owner:owner,whitelist:true)
        let (classic,all,listed) = try await (account,full,verified)
        var tokens = Dictionary(uniqueKeysWithValues:all.holdings.filter{$0.reference != "native" && $0.token.assetCode == nil}.map{($0.reference,$0)})
        let trust = classic.0.isNull ? [StellarHolding(reference:"native",token:.native,amount:"0",raw:.null)]:try StellarDecoding.classicHoldings(classic.0,owner:owner)
        for item in trust {
            if let indexed = all.holdings.first(where:{$0.reference == item.reference}) { guard indexed.token.decimals == item.token.decimals else { throw StellarError.malformed } }
            // Classic balances are authoritative for SACs backed by trust lines;
            // the wrapper isn't a second asset. Contract-only tokens stay intact.
            let metadata = all.holdings.first(where:{$0.reference == item.reference})?.token ?? item.token
            tokens[item.reference] = .init(reference:item.reference,token:metadata,amount:item.amount,raw:item.raw)
        }
        let height = min(classic.1.height,all.ledger.height)
        return try .init(owner:owner,ledger:.init(height:height,timestamp:min(classic.1.timestamp,all.ledger.timestamp)),exists:!classic.0.isNull,holdings:tokens.values.sorted{$0.reference<$1.reference},verified:Set(listed.holdings.map(\.reference)),prices:all.prices,observedAt:.now,raw:JSONEncoder().encode(StellarJSON.object(["classic":classic.0,"indexed":.array(all.raw),"whitelisted":.array(listed.raw)])))
    }
    /// Read-only simulation. This envelope has no signatures and is never
    /// submitted; it calls only SEP-41 metadata functions with no arguments.
    private func simulate(_ function:String,reference:String,owner:String) async throws -> StellarJSON {
        guard ["name","symbol","decimals"].contains(function), let soroban else { throw StellarError.configuration }
        let word = StellarIdentity.u32
        let name = Array(function.utf8), padding = Array(repeating:UInt8(0),count:(4-name.count%4)%4)
        var bytes = word(2)+word(0)+(try StellarIdentity.bytes(owner,version:48))
        bytes += word(100)+Array(repeating:UInt8(0),count:8)+word(0)+word(0)+word(1)+word(0)+word(24)+word(0)+word(1)
        bytes += (try StellarIdentity.bytes(reference,version:16))+word(UInt32(name.count))+name+padding
        bytes += word(0)+word(0)+word(0)+word(0)
        var request = URLRequest(url:soroban); request.httpMethod = "POST"; request.timeoutInterval = 25
        request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        request.httpBody = try JSONEncoder().encode(StellarJSON.object(["jsonrpc":.string("2.0"),"id":.number("1"),"method":.string("simulateTransaction"),"params":.object(["transaction":.string(Data(bytes).base64EncodedString())])]))
        let reply = try await send(request), result = reply["result"]
        guard reply["error"].isNull, result["error"].isNull, let values = result["results"].array, values.count == 1 else { throw StellarError.malformed }
        return values[0]["xdr"]
    }
    public func metadata(reference:String,owner:String) async throws -> StellarToken {
        let ref = try StellarIdentity.reference(reference); _ = try StellarIdentity.address(owner)
        if ref == "native" { return .native }
        async let a = simulate("name",reference:ref,owner:owner)
        async let b = simulate("symbol",reference:ref,owner:owner)
        async let c = simulate("decimals",reference:ref,owner:owner)
        let (nameValue,symbolValue,scaleValue) = try await (a,b,c)
        let name = try StellarDecoding.scText(nameValue), symbol = try StellarDecoding.scText(symbolValue)
        let bytes = try StellarDecoding.scBytes(scaleValue)
        guard bytes.count == 8, try StellarDecoding.u32(bytes,0) == 3, try StellarDecoding.u32(bytes,4) <= 255 else { throw StellarError.malformed }
        let parts = name.split(separator:":"), scale = Int(try StellarDecoding.u32(bytes,4))
        if parts.count == 2, (try? StellarIdentity.contract(code:String(parts[0]),issuer:String(parts[1]))) == ref {
            guard scale == 7 else { throw StellarError.malformed }
            return .init(reference:ref,name:symbol,symbol:symbol,decimals:scale,logo:nil,assetCode:String(parts[0]),issuer:String(parts[1]))
        }
        return .init(reference:ref,name:name,symbol:symbol,decimals:scale,logo:nil)
    }
    public func latestLedger() async throws -> Int64 {
        // Prices and event history can be indexed at different heights. Pin
        // history to its own index, never to a price response or Horizon tip.
        let value = try await rpc("stellar_getEvents",["startLedger":.number("1"),"limit":.number("1")])
        guard let field = value.fields?["events"], field.isNull || field.array != nil else { throw StellarError.incompleteHistory }
        let height = try StellarIdentity.number(value["latestLedger"])
        guard height > 0 else { throw StellarError.incompleteHistory }
        return height
    }
    public func price(reference:String) async throws -> StellarPrice? {
        let ref = try StellarIdentity.reference(reference)
        let value = try await rpc("stellar_getTokenPrice",ref == "native" ? [:]:["contractAddress":.string(ref)])
        guard let contract = value["contractAddress"].string, try StellarIdentity.reference(contract) == ref else { throw StellarError.malformed }
        guard let usd = TonMarkets.positive(value["usdPrice"]) else { return nil }
        return try .init(reference:ref,usd:usd,source:"ANKR Stellar",fetchedAt:Date(timeIntervalSince1970:Double(StellarIdentity.number(value["syncStatus"]["timestamp"]))))
    }
    public func events(owner:String,startLedger:Int64,endLedger:Int64,cursor:String? = nil,limit:Int = 200) async throws -> StellarEventPage {
        let owner = try StellarIdentity.address(owner), topic = try StellarIdentity.ownerTopic(owner)
        guard startLedger > 0, endLedger >= startLedger, endLedger < Int64.max, (1...1000).contains(limit) else { throw StellarError.malformed }
        let topics:StellarJSON = .array([
            .array([.string("*"),.string(topic),.string("**")]),
            .array([.string("*"),.string("*"),.string(topic),.string("**")])])
        var p:[String:StellarJSON] = ["startLedger":.number(String(startLedger)),"endLedger":.number(String(endLedger+1)),
            "limit":.number(String(limit)),"filters":.array([.object(["type":.string("contract"),"topics":topics])])]
        if let cursor { guard cursor.count <= 1024 else { throw StellarError.malformed }; p["cursor"] = .string(cursor) }
        let value = try await historyResponse(p, through:endLedger)
        // ANKR uses an explicit null (not []) for an exhausted event window.
        // A missing field or an index behind our pinned end is still a failure.
        guard let field = value.fields?["events"], field.isNull || field.array != nil,
              try StellarIdentity.number(value["latestLedger"]) >= endLedger else { throw StellarError.incompleteHistory }
        let rows = field.array ?? []
        var previous = cursor
        for row in rows {
            guard let id = row["pagingToken"].string, id.count <= 128, previous == nil || id > previous!, try StellarIdentity.number(row["ledger"]) >= startLedger, try StellarIdentity.number(row["ledger"]) <= endLedger else { throw StellarError.paginationLoop }
            previous = id
        }
        // Ask for an empty terminal page: some providers return short pages.
        let next = rows.isEmpty ? cursor:previous
        guard rows.isEmpty || next != cursor else { throw StellarError.paginationLoop }
        let events = try rows.compactMap{try StellarDecoding.event($0,owner:owner)}
        return try .init(events:events,next:next,complete:rows.isEmpty,startLedger:startLedger,endLedger:endLedger,raw:JSONEncoder().encode(value))
    }

    private func historyResponse(_ params:[String:StellarJSON], through endLedger:Int64) async throws -> StellarJSON {
        for attempt in 0..<3 {
            try Task.checkCancellation()
            let value = try await rpc("stellar_getEvents",params)
            guard let field = value.fields?["events"], field.isNull || field.array != nil else { throw StellarError.incompleteHistory }
            let latest = try StellarIdentity.number(value["latestLedger"])
            if latest >= endLedger { return value }
            // A lagging replica must not finish a cursor or erase cached rows.
            // Record before retrying; no account, cursor or event data is logged.
            OathDiagnostics.record(StellarError.incompleteHistory, component:"provider", operation:"history_index_lag",
                context:["chain":"stellar","stage":"history","attempt":String(attempt+1)])
            if attempt < 2 { try await Task.sleep(for:.milliseconds(250 * (attempt+1))) }
        }
        throw StellarError.incompleteHistory
    }
}
