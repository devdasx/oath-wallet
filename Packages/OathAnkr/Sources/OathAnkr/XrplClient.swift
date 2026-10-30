import OathDiagnostics
import OathArtworkSource
import Foundation

/// Standard ANKR rippled API. HTTP JSON-RPC arrays are not reliably supported;
/// bounded concurrent requests run beside server-paginated reads instead.
public actor XrplClient {
    private let endpoint:URL, fallback:URL?
    private let transport:any AnkrTransport
    private let recentHistory: Bool
    private let permits = AnkrPermits(count:6)
    public init(apiKey:String, transport:any AnkrTransport = AnkrHTTPTransport()) throws {
        guard !apiKey.isEmpty, apiKey.count <= 256, apiKey.utf8.allSatisfy({(48...57).contains($0)||(65...90).contains($0)||(97...122).contains($0)}) else { throw XrplError.configuration }
        endpoint = URL(string:"https://rpc.ankr.com/xrp_mainnet")!.appendingPathComponent(apiKey)
        fallback = URL(string:"https://xrplcluster.com")!; self.transport = transport; recentHistory = true
    }
    public init(endpoint:URL, fallback:URL? = nil, transport:any AnkrTransport = AnkrHTTPTransport()) throws {
        guard endpoint.scheme == "https", fallback == nil || fallback?.scheme == "https" else { throw XrplError.configuration }
        self.endpoint = endpoint; self.fallback = fallback; self.transport = transport; recentHistory = false
    }
    private func send(_ url:URL, method:String, params:[String:XrplJSON]) async throws -> XrplJSON {
        var p = params; p["api_version"] = .number("2")
        let body:XrplJSON = .object(["jsonrpc":.string("2.0"),"id":.number("1"),"method":.string(method),"params":.array([.object(p)])])
        var request = URLRequest(url:url); request.timeoutInterval = 25; request.httpMethod = "POST"
        request.setValue("application/json",forHTTPHeaderField:"Content-Type"); request.httpBody = try JSONEncoder().encode(body)
        try await permits.acquire()
        let response:(Data,Int)
        do { response = try await transport.send(request) }
        catch { OathDiagnostics.record(error); await permits.release(); if Task.isCancelled || error is CancellationError { throw CancellationError() }; throw XrplError.transport }
        await permits.release(); try Task.checkCancellation()
        guard response.1 == 200 else { throw XrplError.http(response.1) }
        guard let json = try? JSONDecoder().decode(XrplJSON.self,from:response.0), !json["result"].isNull else { throw XrplError.malformed }
        let value = json["result"]
        if let code = value["error"].string {
            if code == "actNotFound", value["validated"] == .bool(true), value["account"].string == params["account"]?.string,
               value["ledger_hash"].string == params["ledger_hash"]?.string { throw XrplError.accountMissing }
            // Do not copy error_message/request: some providers echo credentials.
            let known = ["actNotFound","lgrNotFound","ledgerNotFound","failedToForward","lgrIdxMalformed","lgrIdxsInvalid","noNetwork","noCurrent","tooBusy","notSynced","invalidParams","invalidMarker","insufficientHistory"]
            throw XrplError.rpc(known.contains(code) ? code:"serverError")
        }
        guard value["status"].string == "success" else { throw XrplError.malformed }
        if let hash = params["ledger_hash"]?.string {
            guard value["validated"] == .bool(true), value["ledger_hash"].string?.uppercased() == hash else { throw XrplError.wrongLedger }
        }
        if method == "account_tx" {
            let minimum = try XrplIdentity.number(value["ledger_index_min"])
            if recentHistory {
                guard minimum == (try XrplIdentity.number(params["ledger_index_min"] ?? .null)) else { throw XrplError.incompleteHistory }
            } else {
                guard minimum <= 32570 else { throw XrplError.incompleteHistory }
            }
            // Validate inside the provider boundary so a lagging/clamped reply
            // can use the fallback, preserving the exact pinned page range.
            guard value["account"].string == params["account"]?.string,
                  value["validated"] == .bool(true), value["transactions"].array != nil,
                  try XrplIdentity.number(value["ledger_index_max"]) == XrplIdentity.number(params["ledger_index_max"] ?? .null)
            else { throw XrplError.wrongLedger }
        }
        return value
    }
    private func rpc(_ method:String, _ params:[String:XrplJSON], primaryOnly: Bool = false) async throws -> XrplJSON {
        try await OathDiagnostics.$chain.withValue("xrpl") {
            try await OathDiagnostics.$operationID.withValue(OathDiagnostics.operationID ?? UUID()) {
                try await readWithRecovery(method, params, primaryOnly: primaryOnly)
            }
        }
    }
    private func readWithRecovery(_ method:String, _ params:[String:XrplJSON], primaryOnly: Bool) async throws -> XrplJSON {
        var candidates = [endpoint] + (primaryOnly ? [] : (fallback.map { [$0] } ?? []))
        var last: any Error = XrplError.transport
        // A pinned ledger can briefly be ahead of a reporting node. Try the
        // independent provider first, then wait before retrying only explicit
        // ledger-availability/forwarding failures. Never move the ledger, cursor
        // or account to manufacture a successful (possibly empty) snapshot.
        for attempt in 0..<3 {
            var delayed: [URL] = []
            for url in candidates {
                try Task.checkCancellation()
                do { return try await send(url,method:method,params:params) }
                catch XrplError.accountMissing { throw XrplError.accountMissing }
                catch {
                    if Task.isCancelled || error is CancellationError { throw CancellationError() }
                    var context = ["chain":"xrpl","method":method,"host":url.host ?? "","attempt":String(attempt+1)]
                    if case XrplError.rpc(let code) = error { context["rpc_code"] = code }
                    OathDiagnostics.record(error,component:"provider",operation:"xrpl_read",context:context)
                    last = error
                    if Self.delayedReadRetry(error,method:method,params:params) { delayed.append(url) }
                }
            }
            guard attempt < 2, !delayed.isEmpty else { throw last }
            try await Task.sleep(for:.milliseconds(500 * (attempt+1)))
            candidates = delayed
        }
        throw last
    }
    private static func delayedReadRetry(_ error: any Error, method: String, params: [String:XrplJSON]) -> Bool {
        guard case XrplError.rpc(let code) = error else { return false }
        if code == "failedToForward" { return true }
        if code == "lgrIdxMalformed" {
            // account_tx also uses this code when a valid range is temporarily
            // unavailable on the server. Retry the pinned range unchanged; an
            // invalid range or another method must not enter this recovery path.
            guard method == "account_tx",
                  let lower = params["ledger_index_min"]?.integer,
                  let upper = params["ledger_index_max"]?.integer else { return false }
            return lower > 0 && upper >= lower
        }
        return ["lgrNotFound","ledgerNotFound"].contains(code)
            && (params["ledger_hash"]?.string != nil || params["ledger_index_max"]?.integer != nil)
    }
    public func validatedLedger() async throws -> XrplLedger {
        let info = try await rpc("server_info",[:])["info"]
        guard info["network_id"].isNull || info["network_id"].integer == 0 else { throw XrplError.wrongNetwork }
        let v = try await rpc("ledger",["ledger_index":.string("validated")])
        guard v["validated"] == .bool(true), v["ledger"]["closed"] == .bool(true) else { throw XrplError.wrongLedger }
        return try .init(hash:XrplIdentity.hash(v["ledger_hash"]),height:XrplIdentity.number(v["ledger_index"]),timestamp:Double(XrplIdentity.number(v["ledger"]["close_time"]))+946684800)
    }
    private func pages(_ method:String, key:String, owner:String, ledger:XrplLedger, type:String? = nil) async throws -> (rows:[XrplJSON],raw:[XrplJSON]) {
        var p:[String:XrplJSON] = ["account":.string(owner),"ledger_hash":.string(ledger.hash),"limit":.number("400")]
        if let type { p["type"] = .string(type) }
        var rows:[XrplJSON] = [], raw:[XrplJSON] = [], seen:Set<String> = []
        while true {
            try Task.checkCancellation()
            let value = try await rpc(method,p)
            guard value["account"].string == owner, let batch = value[key].array else { throw XrplError.wrongOwner }
            rows += batch; raw.append(value)
            if value["marker"].isNull { break }
            let marker = try Self.cursor(value["marker"])
            guard seen.insert(marker).inserted else { throw XrplError.paginationLoop }
            // Empty filtered account_objects pages can legitimately have a marker.
            p["marker"] = value["marker"]
        }
        return (rows,raw)
    }
    static func cursor(_ json:XrplJSON) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(json); guard data.count <= 4096 else { throw XrplError.malformed }
        return String(decoding:data,as:UTF8.self)
    }
    public func token(_ reference:String, ledger:XrplLedger) async throws -> XrplToken {
        let ref = try XrplIdentity.reference(reference)
        if ref == "native" { return .native }
        if ref.contains(".") { return try .issued(ref) }
        let v = try await rpc("ledger_entry",["ledger_hash":.string(ledger.hash),"mpt_issuance":.string(ref)])["node"]
        guard v["LedgerEntryType"].string == "MPTokenIssuance", let issuer = v["Issuer"].string,
              v["mpt_issuance_id"].isNull || v["mpt_issuance_id"].string?.uppercased() == ref,
              try String(format:"%08llX",XrplIdentity.number(v["Sequence"])) == String(ref.prefix(8)),
              try XrplIdentity.accountBytes(issuer).map({String(format:"%02X",$0)}).joined() == String(ref.suffix(40)),
              let scale = v["AssetScale"].isNull ? UInt64(0):v["AssetScale"].integer, scale <= 255 else { throw XrplError.malformed }
        var meta:XrplJSON = .null
        if let hex = v["MPTokenMetadata"].string, hex.count <= 2048, let bytes = try? TronIdentity.hex(hex) { meta = (try? JSONDecoder().decode(XrplJSON.self,from:bytes)) ?? .null }
        let symbol = (try? TronIdentity.clean(meta["ticker"].string ?? meta["t"].string ?? "MPT",limit:64)) ?? "MPT"
        let name = (try? TronIdentity.clean(meta["name"].string ?? meta["n"].string ?? symbol)) ?? symbol
        let logo = ArtworkSource.normalized(meta["icon"].string ?? meta["i"].string)
        return .init(reference:ref,name:name,symbol:symbol,decimals:Int(scale),logo:logo)
    }
    public func inventory(owner:String, at ledger:XrplLedger? = nil) async throws -> XrplInventory {
        let owner = try XrplIdentity.address(owner)
        let ledger:XrplLedger = if let ledger { ledger } else { try await validatedLedger() }
        // Check existence before enumerating an unfunded account; errors never
        // masquerade as a successfully empty wallet.
        let state:XrplJSON
        do { state = try await rpc("account_info",["account":.string(owner),"ledger_hash":.string(ledger.hash)]) }
        catch XrplError.accountMissing {
            return .init(owner:owner,ledger:ledger,exists:false,holdings:[.init(reference:"native",token:.native,amount:"0",raw:.null)],observedAt:.now,raw:Data())
        }
        guard state["account_data"]["Account"].string == owner else { throw XrplError.wrongOwner }
        async let lines = pages("account_lines",key:"lines",owner:owner,ledger:ledger)
        async let objects = pages("account_objects",key:"account_objects",owner:owner,ledger:ledger,type:"mptoken")
        let (trust,mpts) = try await (lines,objects)
        var holdings:[XrplHolding] = [.init(reference:"native",token:.native,amount:try XrplIdentity.uint(state["account_data"]["Balance"],max:"100000000000000000"),raw:state)]
        for line in trust.rows {
            guard let currency = line["currency"].string, let issuer = line["account"].string, let balance = line["balance"].string else { throw XrplError.malformed }
            let ref = try XrplIdentity.reference(currency+"."+issuer)
            holdings.append(try .init(reference:ref,token:.issued(ref),amount:XrplIdentity.issuedAmount(balance),raw:line))
        }
        for offset in stride(from:0,to:mpts.rows.count,by:6) {
            try await withThrowingTaskGroup(of:XrplHolding.self) { group in
                for row in mpts.rows[offset..<min(offset+6,mpts.rows.count)] {
                    group.addTask {
                        guard row["LedgerEntryType"].string == "MPToken", row["Account"].string == owner, let id = row["MPTokenIssuanceID"].string else { throw XrplError.wrongOwner }
                        let ref = try XrplIdentity.reference(id), amount = try XrplIdentity.uint(row["MPTAmount"].isNull ? .string("0"):row["MPTAmount"])
                        return .init(reference:ref,token:await OathDiagnostics.attempt("token", body: { try await self.token(ref,ledger:ledger) }),amount:amount,raw:row)
                    }
                }
                for try await value in group { holdings.append(value) }
            }
        }
        try Task.checkCancellation()
        guard Set(holdings.map(\.reference)).count == holdings.count else { throw XrplError.malformed }
        return try .init(owner:owner,ledger:ledger,exists:true,holdings:holdings.sorted{$0.reference<$1.reference},observedAt:.now,raw:JSONEncoder().encode(XrplJSON.object(["account":state,"lines":.array(trust.raw),"mpts":.array(mpts.raw)])))
    }
    public func history(owner:String, before:String? = nil, upperLedger:Int64? = nil, limit:Int = 200) async throws -> XrplHistoryPage {
        let owner = try XrplIdentity.address(owner)
        let lower: Int64, upper: Int64
        if recentHistory {
            // ANKR documents a rolling XRP history window. Obtain its actual
            // contiguous range instead of requesting genesis or estimating
            // ledger heights from elapsed days. Keep all pages on that provider.
            let info = try await rpc("server_info", [:], primaryOnly: true)["info"]
            guard info["network_id"].isNull || info["network_id"].integer == 0 else { throw XrplError.wrongNetwork }
            let range = try XrplRecentHistoryRange(info["complete_ledgers"])
            lower = range.lower
            upper = upperLedger ?? range.upper
            // A saved cursor can age out while the app is closed. This is a
            // normal rolling-window transition, handled by the synchronizer.
            guard upper >= lower else { throw XrplError.historyWindowExpired }
            guard upper <= range.upper else { throw XrplError.wrongLedger }
        } else {
            lower = 32570
            upper = if let upperLedger { upperLedger } else { try await validatedLedger().height }
        }
        var p:[String:XrplJSON] = ["account":.string(owner),"ledger_index_min":.number(String(lower)),"ledger_index_max":.number(String(upper)),"binary":.bool(false),"forward":.bool(false),"limit":.number(String(min(200,max(10,limit))))]
        if let before { guard before.count <= 4096 else { throw XrplError.malformed }; p["marker"] = try JSONDecoder().decode(XrplJSON.self,from:Data(before.utf8)) }
        let value = try await rpc("account_tx",p,primaryOnly:recentHistory)
        guard value["account"].string == owner, value["validated"] == .bool(true), try XrplIdentity.number(value["ledger_index_max"]) == upper, let rows = value["transactions"].array else { throw XrplError.wrongLedger }
        var tokens:[String:XrplToken] = ["native":.native]
        let initial = try rows.map{try XrplDecoding.transaction($0,owner:owner,tokens:tokens)}
        let refs = Set(initial.flatMap(\.movements).map(\.reference)).sorted()
        let mpts = refs.filter{ $0 != "native" && !$0.contains(".") }
        if !mpts.isEmpty {
            let ledger = try await validatedLedger()
            for offset in stride(from:0,to:mpts.count,by:6) {
                await withTaskGroup(of:XrplToken?.self) { group in
                    for ref in mpts[offset..<min(offset+6,mpts.count)] { group.addTask { await OathDiagnostics.attempt("token", body: { try await self.token(ref,ledger:ledger) }) } }
                    for await token in group { if let token { tokens[token.reference] = token } }
                }
            }
        }
        try Task.checkCancellation()
        let txs = try rows.map{try XrplDecoding.transaction($0,owner:owner,tokens:tokens)}
        let next = value["marker"].isNull ? nil:try Self.cursor(value["marker"])
        guard next == nil || (next != before && !txs.isEmpty), Set(txs.map(\.hash)).count == txs.count, txs.allSatisfy({$0.checkpoint >= lower && $0.checkpoint <= upper}) else { throw XrplError.paginationLoop }
        return try .init(transactions:txs,next:next,head:txs.first?.hash,upperLedger:upper,raw:JSONEncoder().encode(value))
    }
}
