import OathDiagnostics
import Foundation

/// Aptos uses REST, not Ethereum JSON-RPC batching. Independent node reads
/// are bounded to four; GraphQL batches account inventory/history server-side.
public actor AptosClient {
    private let endpoint:URL
    private let transport:any AnkrTransport
    private let nodeGate=AnkrPermits(count:4)
    private let indexGate=AnkrPermits(count:1)
    private let indexerKey:String?
    private let indexInterval:Double
    private var lastIndex=Date.distantPast
    private var indexRetryAt=Date.distantPast
    public init(apiKey:String,indexerKey:String?=nil,transport:any AnkrTransport=AnkrHTTPTransport()) throws {
        guard !apiKey.isEmpty,apiKey.count<=256,apiKey.utf8.allSatisfy({(48...57).contains($0)||(65...90).contains($0)||(97...122).contains($0)}) else {throw AptosError.configuration}
        endpoint=URL(string:"https://rpc.ankr.com/premium-http/aptos")!.appendingPathComponent(apiKey).appendingPathComponent("v1")
        self.transport=transport;self.indexerKey=indexerKey;indexInterval=1
    }
    init(testTransport:any AnkrTransport) {
        endpoint=URL(string:"https://rpc.ankr.com/premium-http/aptos/fixture/v1")!;transport=testTransport;indexerKey=nil;indexInterval=0
    }
    private func request(_ url:URL,body:AptosJSON?=nil,index:Bool=false,attempts:Int=3) async throws -> AptosJSON {
        let gate=index ? indexGate:nodeGate
        try await gate.acquire()
        do {
            if index,Date()<indexRetryAt {throw AptosError.http(429)}
            var request=URLRequest(url:url);request.timeoutInterval=30
            request.setValue("application/json",forHTTPHeaderField:"Content-Type")
            request.setValue("OathWallet/1.0",forHTTPHeaderField:"User-Agent")
            if index,let indexerKey {request.setValue("Bearer "+indexerKey,forHTTPHeaderField:"Authorization")}
            if let body {request.httpMethod="POST";request.httpBody=try JSONEncoder().encode(body)}
            for attempt in 0..<attempts {
                try Task.checkCancellation()
                if index {let delay=indexInterval-Date().timeIntervalSince(lastIndex);if delay>0 {try await Task.sleep(for:.seconds(delay))};lastIndex = .now}
                do {
                    let (data,status)=try await transport.send(request)
                    // An indexer timeout can consume the public compute quota.
                    // Do not amplify it with immediate expensive retries.
                    if index,status==429 || status==408 {indexRetryAt=Date().addingTimeInterval(300)}
                    guard status==200 else {throw AptosError.http(status)}
                    guard data.count<=32*1024*1024 else {throw AptosError.malformed}
                    let value=try JSONDecoder().decode(AptosJSON.self,from:data)
                    if index,!value["errors"].isNull {throw AptosError.indexer}
                    await gate.release();return value
                } catch { OathDiagnostics.record(error);
                    if Task.isCancelled || error is CancellationError {throw CancellationError()}
                    let retry:Bool
                    switch error {case AptosError.http(let n):retry=(!index && n==408) || n>=500
                    case AnkrError.transport:retry=true
                    default:retry=false}
                    if retry,attempt<attempts-1 {try await Task.sleep(for:.seconds(1<<attempt));continue}
                    if let e=error as? AptosError {throw e};throw AptosError.transport
                }
            }
            throw AptosError.transport
        } catch { OathDiagnostics.record(error);await gate.release();throw error}
    }
    func node(_ path:String,version:Int64?=nil,body:AptosJSON?=nil) async throws -> AptosJSON {
        let archive=URL(string:"https://archive.mainnet.aptoslabs.com/v1")!
        let official=URL(string:"https://api.mainnet.aptoslabs.com/v1")!
        // Receipt hydration is historical by definition. Query the archive
        // first instead of making every refresh rediscover ANKR's pruning.
        // Current balances and view calls still prefer ANKR. All destinations
        // are fixed mainnet hosts; credentials never cross provider boundaries.
        let historical=path.hasPrefix("transactions/by_version/")
        var providers=historical ? [archive,endpoint,official]:[endpoint,official,archive]
        var last:AptosError = .transport
        var archiveUnavailable = false, sawPruned = false
        while !providers.isEmpty {
            let base=providers.removeFirst()
            var url=URLComponents(url:base.appendingPathComponent(path),resolvingAgainstBaseURL:false)!
            if let version {url.queryItems=[.init(name:"ledger_version",value:String(version))]}
            do {return try await request(url.url!,body:body,attempts:1)}
            catch AptosError.http(let status) where [404,408,410,429].contains(status) || status>=500 {
                last = .http(status)
                if base == archive, status == 408 || status >= 500 { archiveUnavailable = true }
                if base != archive, status == 410 { sawPruned = true }
                if status==410,let i=providers.firstIndex(of:archive) {
                    providers.remove(at:i);providers.insert(archive,at:0)
                }
            } catch AptosError.transport {
                // Original transport failure is recorded by request().
                last = .transport
                if base == archive { archiveUnavailable = true }
            }
            try Task.checkCancellation()
        }
        if historical, archiveUnavailable, sawPruned {
            // The live report sequence was archive 502 -> two pruned nodes 410.
            // Those nodes cannot recover old receipts. Give the transient archive
            // failure one bounded retry instead of ending as misleading pruning.
            // 429 is deliberately excluded: respect the provider's rate limit.
            try await Task.sleep(for: .milliseconds(250))
            var url = URLComponents(url: archive.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
            if let version { url.queryItems = [.init(name: "ledger_version", value: String(version))] }
            return try await request(url.url!, body: body, attempts: 1)
        }
        throw last
    }
    func view(_ function:String,types:[String]=[],args:[String],version:Int64) async throws -> AptosJSON {
        let result=try await node("view",version:version,body:.object(["function":.string(function),"type_arguments":.array(types.map{.string($0)}),"arguments":.array(args.map{.string($0)})]))
        guard let array=result.array,array.count==1 else {throw AptosError.malformed};return array[0]
    }
    func indexed(_ query:String,variables:[String:AptosJSON]=[:]) async throws -> AptosJSON {
        let value=try await request(URL(string:"https://api.mainnet.aptoslabs.com/v1/graphql")!,body:.object(["query":.string(query),"variables":.object(variables)]),index:true)
        guard !value["data"].isNull else {throw AptosError.indexer};return value["data"]
    }
    public func ledgerVersion() async throws -> Int64 {
        let info=try await node("");guard info["chain_id"].integer==1 else {throw AptosError.wrongNetwork}
        return try AptosIdentity.number(info["ledger_version"])
    }
    static let metadataFields="asset_type name symbol decimals icon_uri"
    func discovery(owner:String) async throws -> ([AptosJSON],[AptosJSON],Int64) {
        let state=try await indexed("{ledger_infos {chain_id} processor_status(where:{processor:{_eq:\"fungible_asset_processor\"}}) {last_success_version}}")
        guard state["ledger_infos"].array?.first?["chain_id"].integer==1,let processor=state["processor_status"].array?.first else {throw AptosError.wrongNetwork}
        let version=try AptosIdentity.number(processor["last_success_version"])
        var rows:[AptosJSON]=[],pages:[AptosJSON]=[],after="",afterType="",seen:Set<String>=[]
        while rows.count<100_000 {
            let page=try await indexed("""
                query($owner:String!,$after:String!,$afterType:String!) {current_fungible_asset_balances(where:{owner_address:{_eq:$owner},amount:{_gt:"0"},_or:[{asset_type:{_gt:$afterType}},{asset_type:{_eq:$afterType},storage_id:{_gt:$after}}]},order_by:[{asset_type:asc},{storage_id:asc}],limit:100) {
                owner_address storage_id asset_type asset_type_v1 asset_type_v2 amount amount_v1 amount_v2 is_primary is_frozen last_transaction_version metadata {\(Self.metadataFields)} }}
                """,variables:["owner":.string(owner),"after":.string(after),"afterType":.string(afterType)])
            guard let batch=page["current_fungible_asset_balances"].array,batch.count<=100 else {throw AptosError.malformed}
            for row in batch {
                guard let storage=row["storage_id"].string,let type=row["asset_type"].string,
                      (type>afterType || (type==afterType && storage>after)),seen.insert(storage).inserted,
                      let address=row["owner_address"].string,try AptosIdentity.address(address)==owner else {throw AptosError.wrongOwner}
                after=storage;afterType=type;rows.append(row)
            }
            pages.append(page)
            if batch.count<100 {return (rows,pages,version)}
        }
        throw AptosError.incomplete
    }
    /// Balance of a Coin includes its paired primary FA. Secondary stores are
    /// added separately, never the indexer's already combined amount again.
    func holding(_ rows:[AptosJSON],owner:String,version:Int64) async throws -> AptosHolding {
        guard let first=rows.first,let type=rows.compactMap({$0["asset_type_v1"].string}).first ?? first["asset_type"].string else {throw AptosError.malformed}
        let ref=try AptosIdentity.reference(type),token=try AptosToken.decode(first["metadata"],reference:ref)
        let result:AptosJSON
        if type.contains("::") {result=try await view("0x1::coin::balance",types:[type],args:[owner],version:version)}
        else {result=try await view("0x1::primary_fungible_store::balance",types:["0x1::fungible_asset::Metadata"],args:[owner,type],version:version)}
        var amount=try AptosIdentity.amount(result)
        for row in rows where row["is_primary"] == .bool(false) && !row["amount_v2"].isNull && !row["asset_type_v2"].isNull {
            guard let store=row["storage_id"].string,let fa=row["asset_type_v2"].string else {throw AptosError.malformed}
            async let holder=view("0x1::object::owner",types:["0x1::fungible_asset::FungibleStore"],args:[store],version:version)
            async let metadata=view("0x1::fungible_asset::store_metadata",types:["0x1::fungible_asset::FungibleStore"],args:[store],version:version)
            async let balance=view("0x1::dispatchable_fungible_asset::derived_balance",types:["0x1::fungible_asset::FungibleStore"],args:[store],version:version)
            let (h,m,b)=try await (holder,metadata,balance)
            guard let address=h.string,try AptosIdentity.address(address)==owner,
                  let met=m["inner"].string,try AptosIdentity.address(met)==AptosIdentity.address(fa) else {throw AptosError.wrongOwner}
            amount=AptosIdentity.add(amount,try AptosIdentity.amount(b))
        }
        return .init(token:token,amount:amount)
    }
    public func inventory(owner address:String) async throws -> AptosInventory {
        let owner=try AptosIdentity.address(address)
        async let ledger=ledgerVersion()
        let discovery:([AptosJSON],[AptosJSON],Int64)?
        let failure:String?
        do {discovery=try await self.discovery(owner:owner);failure=nil}
        catch { OathDiagnostics.record(error);
            try Task.checkCancellation()
            discovery=nil
            failure=(error as? AptosError).map{String(describing:$0)} ?? "transport"
        }
        let version=try await ledger
        let snapshot=min(version,discovery?.2 ?? version)
        let native=try await view("0x1::coin::balance",types:[AptosIdentity.coin],args:[owner],version:snapshot)
        var holdings=[AptosHolding(token:.native,amount:try AptosIdentity.amount(native))],failed:[String]=[]
        var groups:[String:[AptosJSON]]=[:],paired:[String:String]=[:]
        for row in discovery?.0 ?? [] {
            if let v1=row["asset_type_v1"].string,let v2=row["asset_type_v2"].string {
                paired[try AptosIdentity.reference(v2)] = try AptosIdentity.reference(v1)
            }
        }
        for row in discovery?.0 ?? [] {
            guard let type=row["asset_type"].string,let ref=try? AptosIdentity.reference(type) else {throw AptosError.malformed}
            groups[paired[ref] ?? ref,default:[]].append(row)
        }
        let jobs=groups.filter { ref,rows in
            ref != "native" || rows.contains{$0["is_primary"] == .bool(false) && !$0["amount_v2"].isNull}
        }.sorted{$0.key<$1.key}
        await withTaskGroup(of:(String,AptosHolding?).self) {group in
            var next=0
            func enqueue() {guard next<jobs.count,!Task.isCancelled else {return};let (ref,rows)=jobs[next];next+=1
                group.addTask {do{return (ref,try await self.holding(rows,owner:owner,version:snapshot))}catch{ OathDiagnostics.record(error);return (ref,nil)}}
            }
            for _ in 0..<4 {enqueue()}
            for await (ref,holding) in group {
                if let holding {holdings.removeAll{$0.token.reference==ref};holdings.append(holding)}else{failed.append(ref)}
                enqueue()
            }
        }
        try Task.checkCancellation()
        // Indexer failure does not block a valid node-native balance. Missing
        // tokens may be zeroed only after complete, sufficiently current discovery.
        return .init(owner:owner,holdings:holdings.sorted{$0.token.reference<$1.token.reference},failedReferences:failed,discoveryComplete:discovery != nil && snapshot>=version-100_000,ledgerVersion:snapshot,observedAt:.now,raw:try JSONEncoder().encode(AptosJSON.array(discovery?.1 ?? [])),discoveryFailure:failure,pairedReferences:paired)
    }
    public func history(owner address:String,before:Int64?=nil,limit:Int=25) async throws -> AptosHistoryPage {
        let owner=try AptosIdentity.address(address)
        guard (1...100).contains(limit),before == nil || before!>0 else {throw AptosError.malformed}
        let page=try await indexed("""
            query($owner:String!,$before:bigint!,$limit:Int!) {account_transactions(where:{account_address:{_eq:$owner},transaction_version:{_lt:$before}},order_by:{transaction_version:desc},limit:$limit) {
            account_address transaction_version fungible_asset_activities(where:{owner_address:{_eq:$owner}}) {asset_type owner_address amount event_index type is_gas_fee is_transaction_success transaction_timestamp metadata {\(Self.metadataFields)}} }}
            """,variables:["owner":.string(owner),"before":.string(String(before ?? Int64.max)),"limit":.number(String(limit))])
        guard let rows=page["account_transactions"].array,rows.count<=limit else {throw AptosError.malformed}
        let versions=try rows.map{try AptosIdentity.number($0["transaction_version"])}
        guard Set(versions).count==versions.count,versions==versions.sorted(by:>),versions.allSatisfy({$0<(before ?? Int64.max)}) else {throw AptosError.paginationLoop}
        var transactions:[AptosTransaction]=[]
        try await withThrowingTaskGroup(of:AptosTransaction.self) {group in
            var next=0
            func enqueue() {guard next<rows.count else{return};let row=rows[next];next+=1
                group.addTask {let v=try AptosIdentity.number(row["transaction_version"]);let tx=try await self.node("transactions/by_version/"+String(v));return try AptosDecoding.transaction(row:row,detail:tx,owner:owner)}
            }
            for _ in 0..<4 {enqueue()};for try await tx in group {transactions.append(tx);enqueue()}
        }
        return .init(transactions:transactions.sorted{$0.version>$1.version},next:rows.count==limit ? versions.last:nil,head:versions.first,raw:try JSONEncoder().encode(page))
    }
}
