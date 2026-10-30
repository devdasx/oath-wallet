import Foundation
import OathDiagnostics

public actor StellarSendClient {
    public let network: StellarSendNetwork
    private let horizons: [URL], rpcEndpoints: [URL]
    private var verifiedStates: [URL:(State,Date)] = [:]
    private let transport: any AnkrTransport
    public init(network: StellarSendNetwork, apiKey: String? = nil, transport: any AnkrTransport = AnkrHTTPTransport()) throws {
        self.network=network;self.transport=transport
        if network == .mainnet, let apiKey, !apiKey.isEmpty {
            guard apiKey.count <= 256, apiKey.utf8.allSatisfy({(48...57).contains($0)||(65...90).contains($0)||(97...122).contains($0)}) else { throw StellarSendError.configuration }
            horizons=[URL(string:"https://rpc.ankr.com/http/stellar_horizon")!,network.horizon]
            rpcEndpoints=[URL(string:"https://rpc.ankr.com/stellar_soroban")!.appendingPathComponent(apiKey),network.rpc]
        } else { horizons=[network.horizon];rpcEndpoints=[network.rpc] }
    }
    private func request(_ request: URLRequest, operation: String, absent: Bool = false, acceptedStatuses: Set<Int> = [200]) async throws -> StellarJSON? {
        do {
            try Task.checkCancellation()
            let (bytes,status) = try await transport.send(request)
            guard bytes.count <= 4_000_000 else { throw StellarSendError.malformed }
            if status == 404 && absent {
                // Only Horizon's typed absence is evidence. A proxy's 404 or
                // malformed response must never release an uncertain payment.
                let value=try JSONDecoder().decode(StellarJSON.self,from:bytes)
                if value["type"].string == "https://stellar.org/horizon-errors/not_found", value["status"].integer == 404 { return nil }
                throw StellarSendError.http(404)
            }
            if !acceptedStatuses.contains(status) {
                // Parse only allowlisted result codes. Never retain provider detail,
                // request fields, envelope XDR, or arbitrary response text.
                if let value = try? JSONDecoder().decode(StellarJSON.self,from:bytes) {
                    let code = value["extras"]["result_codes"]["transaction"].string ?? "UNKNOWN"
                    let allowed = ["tx_failed","tx_bad_seq","tx_bad_auth","tx_insufficient_balance","tx_insufficient_fee","tx_too_late","tx_too_early","tx_soroban_invalid","tx_malformed","tx_no_source_account"]
                    OathDiagnostics.record(StellarSendError.http(status),component:"stellar_send",operation:operation,
                        context:["chain":"stellar","http_status":String(status),"rpc_code":allowed.contains(code) ? code:"UNKNOWN"])
                }
                throw StellarSendError.http(status)
            }
            return try JSONDecoder().decode(StellarJSON.self,from:bytes)
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            OathDiagnostics.record(error,component:"stellar_send",operation:operation,context:["chain":"stellar"]);throw error
        }
    }
    private func get(_ base: URL, _ path: String, query: [URLQueryItem] = [], absent: Bool = false) async throws -> StellarJSON? {
        var components=URLComponents(url:path.isEmpty ? base:base.appendingPathComponent(path),resolvingAgainstBaseURL:false)!
        if !query.isEmpty { components.queryItems=query }
        var req=URLRequest(url:components.url!);req.timeoutInterval=12
        return try await request(req,operation:absent ? "lookup":"ledger_state",absent:absent)
    }
    private func rpc(_ method: String, _ params: [String:StellarJSON], endpoint: URL) async throws -> StellarJSON {
        var req=URLRequest(url:endpoint);req.httpMethod="POST";req.timeoutInterval=12;req.setValue("application/json",forHTTPHeaderField:"Content-Type")
        req.httpBody=try JSONEncoder().encode(StellarJSON.object(["jsonrpc":.string("2.0"),"id":.number("1"),"method":.string(method),"params":.object(params)]))
        guard let result=try await request(req,operation:method) else { throw StellarSendError.malformed }
        if !result["error"].isNull {
            let code=Int(result["error"]["code"].text ?? "") ?? -1
            OathDiagnostics.record(StellarSendError.rpc(code),component:"stellar_send",operation:method,context:["chain":"stellar","rpc_code":String(code)])
            throw StellarSendError.rpc(code)
        }
        guard !result["result"].isNull else { throw StellarSendError.malformed };return result["result"]
    }
    private struct State: Sendable { let ledger: UInt32, oldest: UInt32, reserve: UInt64, fee: UInt32 }
    private func state(_ base: URL, fees: Bool) async throws -> State {
        async let root=get(base,"")
        async let ledgers=get(base,"ledgers",query:[.init(name:"order",value:"desc"),.init(name:"limit",value:"1")])
        async let stats=fees ? inclusionFee():nil
        let (r,l,f)=try await(root,ledgers,stats)
        guard let r, r["network_passphrase"].string == network.passphrase else { throw StellarSendError.wrongNetwork }
        guard let height=r["history_latest_ledger"].integer.flatMap(UInt32.init(exactly:)), height>0,height<UInt32.max-25,
              let oldest=r["history_elder_ledger"].integer.flatMap(UInt32.init(exactly:)),oldest>0,
              let ledger=l?["_embedded"]["records"].array?.first,
              let latest=ledger["sequence"].integer, latest>=UInt64(height),latest-UInt64(height)<=3,
              let reserve=ledger["base_reserve_in_stroops"].text.flatMap(UInt64.init),reserve>0,reserve<=100_000_000,
              let baseFee=ledger["base_fee_in_stroops"].text.flatMap(UInt64.init),baseFee>0,baseFee<=UInt64(StellarSendPlan.maximumFee),
              let close=ledger["closed_at"].string.flatMap({ISO8601DateFormatter().date(from:$0)}),(-10...60).contains(Date.now.timeIntervalSince(close)) else { throw StellarSendError.malformed }
        var fee=baseFee
        if fees {
            guard let p95=f,p95<=UInt64(StellarSendPlan.maximumFee) else { throw StellarSendError.feeTooHigh }
            fee=max(baseFee,p95)*12/10
        }
        guard fee<=UInt64(StellarSendPlan.maximumFee) else { throw StellarSendError.feeTooHigh }
        let value = State(ledger:height,oldest:oldest,reserve:reserve,fee:UInt32(fee))
        verifiedStates[base] = (value,.now)
        return value
    }
    private func inclusionFee() async throws -> UInt64 {
        for (index,endpoint) in rpcEndpoints.enumerated() {
            do {
                async let info = rpc("getNetwork",[:],endpoint:endpoint)
                async let stats = rpc("getFeeStats",[:],endpoint:endpoint)
                let (networkInfo,fees) = try await (info,stats)
                guard networkInfo["passphrase"].string == network.passphrase else { throw StellarSendError.wrongNetwork }
                // Horizon max_fee mixes contract resource fees into its sample.
                // RPC separates inclusion fees: never charge contract resources
                // again or make ordinary XLM payments inherit those costs.
                guard let classic=fees["inclusionFee"]["p95"].text.flatMap(UInt64.init),
                      let contract=fees["sorobanInclusionFee"]["p95"].text.flatMap(UInt64.init),
                      let ledger=fees["latestLedger"].integer,ledger>0 else { throw StellarSendError.malformed }
                return max(classic,contract)
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                OathDiagnostics.record(error,component:"stellar_send",operation:"inclusion_fee",context:["chain":"stellar"])
                if index == rpcEndpoints.count-1 || !Self.retryable(error) { throw error }
            }
        }
        throw StellarSendError.transport
    }
    private func account(_ base: URL, _ owner: String) async throws -> StellarJSON? {
        guard let value=try await get(base,"accounts/"+owner,absent:true) else { return nil }
        guard value["account_id"].string == owner else { throw StellarSendError.wrongOwner };return value
    }
    private static func atomic(_ row: StellarJSON, _ key: String) throws -> UInt64 {
        guard let raw=row[key].string, let n=UInt64(try StellarIdentity.atomic(raw)),n<=UInt64(Int64.max) else { throw StellarSendError.malformed };return n
    }
    private func classic(_ account: StellarJSON, reference: String) throws -> (row:StellarJSON,code:String?,issuer:String?)? {
        guard let balances=account["balances"].array else { throw StellarSendError.malformed }
        for row in balances {
            if reference == "native",row["asset_type"].string == "native" { return (row,nil,nil) }
            if let code=row["asset_code"].string,let issuer=row["asset_issuer"].string,
               try StellarIdentity.contract(code:code,issuer:issuer,network:network.passphrase) == reference { return (row,code,issuer) }
        }
        return nil
    }
    public func quote(sender: String, recipient: String, reference: String, decimals: Int, amount: String,
                      memo: StellarSendMemo = .init(), maximum: Bool = false, multisig: StellarMultisigPolicy? = nil) async throws -> StellarSendPlan {
        try await OathDiagnostics.$chain.withValue("stellar") {
            try await OathDiagnostics.$operationID.withValue(UUID()) {
                _ = try StellarIdentity.address(sender);_ = try StellarIdentity.address(recipient);_ = try StellarIdentity.reference(reference)
                guard sender != recipient, try StellarIdentity.uint(amount) == amount, amount != "0",(0...255).contains(decimals) else { throw StellarSendError.amount }
                try memo.validate()
                for (index,base) in horizons.enumerated() {
                    do { return try await prepare(base,sender:sender,recipient:recipient,reference:reference,decimals:decimals,amount:amount,memo:memo,maximum:maximum,multisig:multisig) }
                    catch {
                        if error is CancellationError || Task.isCancelled { throw CancellationError() }
                        OathDiagnostics.record(error,component:"stellar_send",operation:"prepare",context:["chain":"stellar","stage":"quote"])
                        guard index<horizons.count-1,Self.retryable(error) else { throw error }
                    }
                }
                throw StellarSendError.transport
            }
        }
    }
    public func multisigState(_ policy: StellarMultisigPolicy) async throws -> StellarMultisigState {
        try policy.validate()
        let state = try await state(horizons[0], fees: false)
        guard let current = try await account(horizons[0], policy.account) else {
            return .init(configured: false, balance: 0, reserve: UInt64(2 + policy.signers.count) * state.reserve)
        }
        let configured = policy.matches(current)
        guard configured || policy.bootstrapMatches(current), let native = try classic(current, reference: "native"),
              let sub = current["subentry_count"].integer, let sponsoring = current["num_sponsoring"].integer,
              let sponsored = current["num_sponsored"].integer,
              sub <= 1_000_000, sponsoring <= 1_000_000, sponsored <= 2 + sub + sponsoring else { throw StellarSendError.changed }
        return try .init(configured: configured, balance: Self.atomic(native.row, "balance"),
            reserve: (2 + sub + sponsoring - sponsored + UInt64(configured ? 0 : policy.signers.count)) * state.reserve)
    }
    /// Local construction only: install signers atomically, or add one trustline.
    public func configurationQuote(policy: StellarMultisigPolicy, assetCode: String? = nil, issuer: String? = nil) async throws -> StellarSendPlan {
        try await OathDiagnostics.$chain.withValue("stellar") {
            try await OathDiagnostics.$operationID.withValue(UUID()) {
                do { return try await configuration(policy: policy, assetCode: assetCode, issuer: issuer) }
                catch {
                    if error is CancellationError || Task.isCancelled { throw CancellationError() }
                    OathDiagnostics.record(error, component: "stellar_send", operation: "multisig_configuration", context: ["chain": "stellar"])
                    throw error
                }
            }
        }
    }
    private func configuration(policy: StellarMultisigPolicy, assetCode: String?, issuer: String?) async throws -> StellarSendPlan {
        try policy.validate()
        let base = horizons[0]
        async let current = account(base, policy.account)
        async let latest = state(base, fees: true)
        let (value, ledger) = try await (current, latest)
        guard let value, let native = try classic(value, reference: "native"),
              let sequence = value["sequence"].string.flatMap(Int64.init), sequence > 0, sequence < Int64.max,
              let sub = value["subentry_count"].integer, let sponsoring = value["num_sponsoring"].integer,
              let sponsored = value["num_sponsored"].integer,
              sub <= 1_000_000, sponsoring <= 1_000_000, sponsored <= 2 + sub + sponsoring else { throw StellarSendError.recipientUnfunded }
        let trust = assetCode != nil || issuer != nil
        guard trust ? policy.matches(value) : policy.bootstrapMatches(value) else { throw StellarSendError.changed }
        let reference: String
        if trust {
            guard let assetCode, let issuer, issuer != policy.account else { throw StellarSendError.malformed }
            _ = try StellarSendXDR.asset(code: assetCode, issuer: issuer)
            reference = try StellarIdentity.contract(code: assetCode, issuer: issuer, network: network.passphrase)
            guard try classic(value, reference: reference) == nil else { throw StellarSendError.changed }
        } else { reference = "native" }
        let balance = try Self.atomic(native.row, "balance"), liabilities = try Self.atomic(native.row, "selling_liabilities")
        let reserve = (2 + sub + sponsoring - sponsored + UInt64(trust ? 1 : policy.signers.count)) * ledger.reserve
        let fee = UInt64(ledger.fee) * UInt64(trust ? 1 : policy.signers.count + 1)
        guard fee <= UInt64(StellarSendPlan.maximumFee), balance >= reserve, liabilities <= balance - reserve,
              fee <= balance - reserve - liabilities else { throw StellarSendError.reserve }
        let now = Date.now
        let plan = StellarSendPlan(network: network, kind: trust ? .changeTrust : .configureMultisig,
            sender: policy.account, recipient: policy.account, reference: reference, assetCode: assetCode, issuer: issuer,
            requestedAmount: "0", amount: "0", assetBalance: String(balance), nativeBalance: balance,
            reserve: reserve, nativeLiabilities: liabilities, fee: UInt32(fee), sequence: sequence + 1,
            firstLedger: ledger.ledger, lastLedger: ledger.ledger + 25, maxTime: UInt64(now.timeIntervalSince1970) + 120,
            createdAt: now, multisig: policy)
        try plan.validate()
        return plan
    }
    private static func retryable(_ error: Error) -> Bool {
        if error is SendFeeFundingError { return false }
        guard let e=error as? StellarSendError else { return true }
        switch e { case .transport,.http,.rpc,.malformed: return true;default:return false }
    }
    private func prepare(_ base: URL,sender:String,recipient:String,reference:String,decimals:Int,amount:String,memo:StellarSendMemo,maximum:Bool,multisig:StellarMultisigPolicy?) async throws -> StellarSendPlan {
        async let source=account(base,sender)
        async let destination=account(base,recipient)
        async let state=state(base,fees:true)
        let (src,dst,s)=try await(source,destination,state)
        guard let src,let native=try classic(src,reference:"native"),
              let seq=src["sequence"].string.flatMap(Int64.init),seq>0,seq<Int64.max,
              let sub=src["subentry_count"].integer,let sponsoring=src["num_sponsoring"].integer,let sponsored=src["num_sponsored"].integer,
              sub<=1_000_000,sponsoring<=1_000_000,sponsored<=2+sub+sponsoring,
              true else { throw StellarSendError.unsupportedAccount }
        if let multisig {
            try multisig.validate()
            guard multisig.account == sender, multisig.matches(src) else { throw StellarSendError.changed }
        } else {
            guard let threshold=src["thresholds"]["med_threshold"].integer,
              let signer=src["signers"].array?.first(where:{$0["key"].string == sender && $0["type"].string == "ed25519_public_key"}),
              let weight=signer["weight"].integer,weight>0,weight>=threshold else { throw StellarSendError.unsupportedAccount }
        }
        let balance=try Self.atomic(native.row,"balance"),liabilities=try Self.atomic(native.row,"selling_liabilities")
        let reserve=(2+sub+sponsoring-sponsored)*s.reserve
        guard balance>=reserve,liabilities<=balance-reserve else { throw StellarSendError.reserve }
        guard UInt64(s.fee)<=balance-reserve-liabilities else { throw SendFeeFundingError.insufficientNativeBalance }
        let holding=try classic(src,reference:reference)
        var kind:StellarSendPlan.Kind=reference == "native" && dst == nil ? .createAccount:holding == nil ? .contract:.payment
        if reference == "native" { kind=dst == nil ? .createAccount:.payment }
        let requiresMemo = dst?["data"]["config.memo_required"].string == "MQ=="
        if kind == .contract, requiresMemo || !memo.value.isEmpty { throw StellarSendError.memoUnsupported }
        if requiresMemo, memo.value.isEmpty { throw StellarSendError.memoRequired }
        guard dst != nil || kind == .createAccount || kind == .contract else { throw StellarSendError.recipientUnfunded }
        var assetBalance=holding == nil ? amount:String(try Self.atomic(holding!.row,"balance"))
        var available=reference == "native" ? balance-reserve-liabilities-UInt64(s.fee):0
        if let holding,reference != "native" {
            guard holding.row["is_authorized"] == .bool(true),decimals == 7 else { throw StellarSendError.restricted }
            let total=try Self.atomic(holding.row,"balance"),selling=try Self.atomic(holding.row,"selling_liabilities")
            guard total>=selling else { throw StellarSendError.insufficientFunds };available=total-selling
        }
        var deliver=maximum && kind != .contract ? String(available):amount
        let now=Date.now,maxTime=UInt64(now.timeIntervalSince1970)+120
        func plan(fee:UInt32,resources:Data? = nil,auth:[Data] = []) -> StellarSendPlan {
            .init(network:network,kind:kind,sender:sender,recipient:recipient,reference:reference,assetCode:holding?.code,issuer:holding?.issuer,
                decimals:decimals,memo:memo,requestedAmount:maximum ? assetBalance:amount,amount:deliver,assetBalance:assetBalance,
                nativeBalance:balance,reserve:reserve,nativeLiabilities:liabilities,fee:fee,sequence:seq+1,firstLedger:s.ledger,lastLedger:s.ledger+25,
                maxTime:maxTime,sorobanData:resources,authorization:auth,createdAt:now,recipientReserve:kind == .createAccount ? 2*s.reserve : 0,multisig:multisig)
        }
        if kind == .contract {
            for (index,endpoint) in rpcEndpoints.enumerated() {
                do {
                    let networkInfo=try await rpc("getNetwork",[:],endpoint:endpoint)
                    guard networkInfo["passphrase"].string == network.passphrase else { throw StellarSendError.wrongNetwork }
                    // Read-only balance and decimals calls run independently.
                    let initial=plan(fee:s.fee)
                    async let bal=simulate(initial,endpoint:endpoint,function:"balance",args:[StellarSendXDR.scAddress(sender)])
                    async let scale=simulate(initial,endpoint:endpoint,function:"decimals")
                    let (b,d)=try await(bal,scale)
                    guard let raw=b["results"].array?.first?["xdr"],let scaleValue=d["results"].array?.first?["xdr"] else { throw StellarSendError.malformed }
                    assetBalance=try StellarDecoding.scAmount(raw)
                    let scaleBytes=try StellarDecoding.scBytes(scaleValue)
                    guard scaleBytes.count==8,try StellarDecoding.u32(scaleBytes,0)==3,Int(try StellarDecoding.u32(scaleBytes,4))==decimals else { throw StellarSendError.changed }
                    if maximum { deliver=assetBalance }
                    guard deliver != "0",!XrplSendAmount.less(assetBalance,deliver) else { throw StellarSendError.insufficientFunds }
                    let simulation=try await simulate(plan(fee:s.fee),endpoint:endpoint)
                    guard simulation["restorePreamble"].isNull else { throw StellarSendError.restoreRequired }
                    let cost = try Self.minimumResourceFee(simulation)
                    guard let encoded=simulation["transactionData"].string,encoded.count<=180_000,let resources=Data(base64Encoded:encoded),
                          let entries=simulation["results"].array,entries.count==1,let auth=entries[0]["auth"].array else { throw StellarSendError.malformed }
                    let bytes=try auth.map { value -> Data in guard let text=value.string,text.count<=8192,let data=Data(base64Encoded:text) else { throw StellarSendError.malformed };return data }
                    let resourceFee=try StellarSendXDR.resourceFee(resources)
                    guard resourceFee>=cost,resourceFee+UInt64(s.fee)<=UInt64(StellarSendPlan.maximumFee) else { throw StellarSendError.feeTooHigh }
                    guard resourceFee+UInt64(s.fee)<=balance-reserve-liabilities else { throw SendFeeFundingError.insufficientNativeBalance }
                    let final=plan(fee:UInt32(resourceFee)+s.fee,resources:resources,auth:bytes)
                    try final.validate();return final
                } catch {
                    if error is CancellationError || Task.isCancelled { throw CancellationError() }
                    OathDiagnostics.record(error,component:"stellar_send",operation:"simulate",context:["chain":"stellar","stage":"quote"])
                    guard index<rpcEndpoints.count-1,Self.retryable(error) else { throw error }
                }
            }
            throw StellarSendError.transport
        }
        guard let value=UInt64(deliver),value>0,value<=available else { throw StellarSendError.insufficientFunds }
        if kind == .createAccount { guard value>=2*s.reserve else { throw StellarSendError.recipientMinimum(2*s.reserve) } }
        if reference != "native",recipient != holding?.issuer {
            guard let dst,let trust=try classic(dst,reference:reference) else { throw StellarSendError.trustline }
            guard trust.row["is_authorized"] == .bool(true) else { throw StellarSendError.restricted }
            let limit=try Self.atomic(trust.row,"limit"),existing=try Self.atomic(trust.row,"balance"),buying=try Self.atomic(trust.row,"buying_liabilities")
            guard existing<=limit,buying<=limit-existing,value<=limit-existing-buying else { throw StellarSendError.trustline }
        }
        let final=plan(fee:s.fee);try final.validate();return final
    }
    /// A valid but expensive simulation must report the fee limit, not corrupt
    /// data. The existing quote boundary records this typed failure safely.
    static func minimumResourceFee(_ simulation: StellarJSON) throws -> UInt64 {
        guard let fee = simulation["minResourceFee"].text.flatMap(UInt64.init) else { throw StellarSendError.malformed }
        guard fee <= UInt64(StellarSendPlan.maximumFee) else { throw StellarSendError.feeTooHigh }
        return fee
    }
    private func simulate(_ plan:StellarSendPlan,endpoint:URL,function:String? = nil,args:[Data] = []) async throws -> StellarJSON {
        let tx=try StellarSendXDR.transaction(plan,readFunction:function,readArgs:args)
        let result=try await rpc("simulateTransaction",["transaction":.string(StellarSendXDR.envelope(tx).base64EncodedString())],endpoint:endpoint)
        guard result["error"].isNull else {
            // Contract diagnostics can contain addresses/user arguments. Record
            // the boundary without copying its untrusted error text/events.
            OathDiagnostics.record(StellarSendError.simulation,component:"stellar_send",operation:"simulate_result",context:["chain":"stellar"])
            throw StellarSendError.simulation
        }
        guard let ledger=result["latestLedger"].integer,ledger>=UInt64(plan.firstLedger),ledger<UInt64(plan.lastLedger) else { throw StellarSendError.changed }
        return result
    }
    public func submit(_ signed: StellarSignedSend,plan:StellarSendPlan,reconcileFirst:Bool = true) async throws -> StellarSendReceipt {
        try await OathDiagnostics.$chain.withValue("stellar") {
            try await OathDiagnostics.$operationID.withValue(OathDiagnostics.operationID ?? UUID()) {
                try await submitWithContext(signed,plan:plan,reconcileFirst:reconcileFirst)
            }
        }
    }
    private func submitWithContext(_ signed: StellarSignedSend,plan:StellarSendPlan,reconcileFirst:Bool) async throws -> StellarSendReceipt {
        try StellarSendCrypto.verify(signed,plan:plan);guard plan.network==network else { throw StellarSendError.wrongNetwork }
        for base in horizons {
            do {
                let s:State
                if !reconcileFirst, let cached=verifiedStates[base], (0..<15).contains(Date.now.timeIntervalSince(cached.1)) { s=cached.0 }
                else { s=try await state(base,fees:false) }
                if reconcileFirst || s.ledger>=plan.lastLedger {
                    let prior=try await receipt(signed,plan:plan,base:base,state:s)
                    if prior.outcome != .unknown || s.ledger>=plan.lastLedger { return prior }
                } else { try plan.validate() }
                if let policy = plan.multisig {
                    guard let current = try await account(base, plan.sender),
                          plan.kind == .configureMultisig ? policy.bootstrapMatches(current) : policy.matches(current) else { throw StellarSendError.changed }
                }
                var req=URLRequest(url:base.appendingPathComponent("transactions_async"));req.httpMethod="POST";req.timeoutInterval=12
                req.setValue("application/x-www-form-urlencoded",forHTTPHeaderField:"Content-Type")
                let encoded=signed.bytes.base64EncodedString().addingPercentEncoding(withAllowedCharacters:.alphanumerics)!
                req.httpBody=Data(("tx="+encoded).utf8)
                guard let reply=try await request(req,operation:"broadcast",acceptedStatuses:[201,409]),
                      reply["hash"].string == signed.hash,
                      ["PENDING","DUPLICATE"].contains(reply["tx_status"].string ?? "") else { throw StellarSendError.changed }
                // Horizon acknowledged these exact bytes. Ledger ingestion and
                // final execution belong to the durable background status worker.
                return .init(hash:signed.hash,outcome:.accepted)
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                OathDiagnostics.record(error,component:"stellar_send",operation:"submit",context:["chain":"stellar","stage":"broadcast"])
                if (error as? StellarSendError) == .wrongNetwork { throw error }
            }
        }
        return .init(hash:signed.hash,outcome:.unknown)
    }
    public func status(_ signed: StellarSignedSend,plan:StellarSendPlan) async throws -> StellarSendReceipt {
        try await OathDiagnostics.$chain.withValue("stellar") {
            try await OathDiagnostics.$operationID.withValue(OathDiagnostics.operationID ?? UUID()) {
                try await statusWithContext(signed,plan:plan)
            }
        }
    }
    private func statusWithContext(_ signed: StellarSignedSend,plan:StellarSendPlan) async throws -> StellarSendReceipt {
        try StellarSendCrypto.verify(signed,plan:plan);guard plan.network==network else { throw StellarSendError.wrongNetwork }
        for (index,base) in horizons.enumerated() {
            do { return try await receipt(signed,plan:plan,base:base,state:state(base,fees:false)) }
            catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                OathDiagnostics.record(error,component:"stellar_send",operation:"reconcile",context:["chain":"stellar"])
                if index==horizons.count-1 || !Self.retryable(error) { throw error }
            }
        }
        throw StellarSendError.transport
    }
    private func receipt(_ signed:StellarSignedSend,plan:StellarSendPlan,base:URL,state:State) async throws -> StellarSendReceipt {
        guard let r=try await get(base,"transactions/"+signed.hash,absent:true) else {
            // Only a complete retained Horizon history covering the entire
            // ledger validity interval proves absence. Local time is not proof.
            return .init(hash:signed.hash,outcome:state.ledger>=plan.lastLedger && state.oldest<=plan.firstLedger ? .expired:.unknown)
        }
        guard r["hash"].string==signed.hash,let envelope=r["envelope_xdr"].string,Data(base64Encoded:envelope)==signed.bytes,
              let fee=r["fee_charged"].text.flatMap(UInt64.init),fee<=UInt64(plan.fee),
              let ledger=r["ledger"].integer.flatMap(UInt32.init(exactly:)),ledger>=plan.firstLedger,ledger<plan.lastLedger,
              r["successful"] == .bool(true) || r["successful"] == .bool(false) else { throw StellarSendError.changed }
        if r["successful"] == .bool(false) { OathDiagnostics.record(StellarSendError.execution,component:"stellar_send",operation:"validated_failure",context:["chain":"stellar"]) }
        return .init(hash:signed.hash,outcome:r["successful"] == .bool(true) ? .confirmed:.failed,fee:fee,ledger:ledger)
    }
}
