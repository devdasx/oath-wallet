import Foundation
import OathDiagnostics

/// REST-only transaction operations, independent of the eventually-consistent indexer.
/// Every fallback verifies chain identity; replay always uses the same signed bytes.
public actor AptosSendClient {
    private struct IntrinsicGasRejection: Error {}
    public nonisolated let network: AptosSendNetwork
    private let endpoints: [URL]
    private let transport: any AnkrTransport
    private let permits=AnkrPermits(count:4)
    private var verifiedAt=[URL:Date]()
    private var nextPublicRequest=Date.distantPast
    public init(network:AptosSendNetwork = .mainnet,apiKey:String?=nil,transport:any AnkrTransport = AnkrHTTPTransport()) throws {
        self.network=network;self.transport=transport
        if let apiKey {
            guard network == .mainnet,!apiKey.isEmpty,apiKey.count<=256,apiKey.utf8.allSatisfy({(48...57).contains($0)||(65...90).contains($0)||(97...122).contains($0)}) else { throw AptosSendError.configuration }
            endpoints=[URL(string:"https://rpc.ankr.com/premium-http/aptos")!.appendingPathComponent(apiKey).appendingPathComponent("v1"),network.endpoint]
        } else { endpoints=[network.endpoint] }
    }
    private func request(_ base:URL,_ path:String,body:Data?=nil,bcs:Bool=false,query:[URLQueryItem]=[],missing:Bool=false,operation:String) async throws -> AptosJSON {
        var url=URLComponents(url:base.appendingPathComponent(path),resolvingAgainstBaseURL:false)!
        if !query.isEmpty { url.queryItems=query }
        var req=URLRequest(url:url.url!);req.timeoutInterval=15
        if let body { req.httpMethod="POST";req.httpBody=body }
        req.setValue(bcs ? "application/x.aptos.signed_transaction+bcs":"application/json",forHTTPHeaderField:"Content-Type")
        req.setValue("application/json",forHTTPHeaderField:"Accept")
        try await permits.acquire()
        let data:Data,status:Int
        do {
            // Public fallback/testnet endpoints have a shared unauthenticated
            // quota. Bound starts as well as in-flight requests; custom test
            // transports remain deterministic and do not incur wall-clock waits.
            if base.host?.hasSuffix("aptoslabs.com") == true,transport is AnkrHTTPTransport {
                let now=Date.now,start=max(now,nextPublicRequest)
                nextPublicRequest=start.addingTimeInterval(0.5)
                if start>now { try await Task.sleep(for:.seconds(start.timeIntervalSince(now))) }
            }
            (data,status)=try await transport.send(req)
        }
        catch {
            await permits.release();OathDiagnostics.record(error,component:"aptos_send",operation:operation,context:["chain":"aptos"])
            if Task.isCancelled || error is CancellationError { throw CancellationError() };throw AptosSendError.transport
        }
        await permits.release();try Task.checkCancellation()
        guard data.count<=4_194_304 else { throw AptosSendError.malformed }
        // A freshly submitted transaction can be absent from a node. This is
        // expected pending state, never evidence of failure or safe cancellation.
        if missing,status==404,
           let j=try? JSONDecoder().decode(AptosJSON.self,from:data),j["error_code"].string=="transaction_not_found" { return .null }
        DiagnosticHTTP.response(data,status:status,request:req)
        guard (200...299).contains(status) else {
            // Only the typed VM validation code identifies a fee shortage;
            // never infer it from an HTTP status or arbitrary Move abort text.
            if status == 400, let envelope = try? JSONDecoder().decode(AptosJSON.self, from: data),
               envelope["error_code"].string == "vm_error", let code = try? Self.uint(envelope["vm_error_code"]) {
                if code == 5 { throw SendFeeFundingError.insufficientNativeBalance }
                if code == 14, operation == "simulate" { throw IntrinsicGasRejection() }
            }
            throw AptosSendError.http(status)
        }
        return try JSONDecoder().decode(AptosJSON.self,from:data)
    }
    private func node(_ path:String,body:Data?=nil,bcs:Bool=false,query:[URLQueryItem]=[],missing:Bool=false,operation:String) async throws -> AptosJSON {
        let historyRead = path.hasPrefix("transactions/by_hash/") || (path.hasPrefix("accounts/") && path.hasSuffix("/transactions"))
        let providers = endpoints + (network == .mainnet && historyRead ? [URL(string:"https://archive.mainnet.aptoslabs.com/v1")!]:[])
        for (i,url) in providers.enumerated() {
            for attempt in 0..<2 {
                do {
                    if path.isEmpty || Date.now.timeIntervalSince(verifiedAt[url] ?? .distantPast)>30 {
                        let ledger=try await request(url,"",operation:"ledger")
                        guard ledger["chain_id"].integer==UInt64(network.chainID) else { throw AptosSendError.wrongNetwork }
                        verifiedAt[url] = .now
                        if path.isEmpty { return ledger }
                    }
                    let result=try await request(url,path,body:body,bcs:bcs,query:query,missing:missing,operation:operation)
                    if result.isNull,missing,i+1<providers.count { break }
                    return result
                } catch {
                    OathDiagnostics.record(error,component:"aptos_send",operation:operation,context:["chain":"aptos"])
                    let retry:Bool
                    switch error { case AptosSendError.http(let code):retry=[408,429].contains(code)||code>=500||(historyRead && code==410)
                    case AptosSendError.transport:retry=true
                    default:retry=false }
                    guard retry else { throw error }
                    if i+1<providers.count { break } // Prefer the independent fallback immediately.
                    if error as? AptosSendError == .http(429),attempt==0 {
                        try await Task.sleep(for:.seconds(2));continue
                    }
                    throw error
                }
            }
        }
        throw AptosSendError.transport
    }
    private func view(_ function:String,types:[String]=[],args:[String]=[],version:UInt64?=nil) async throws -> AptosJSON {
        let body=try JSONEncoder().encode(AptosJSON.object(["function":.string(function),"type_arguments":.array(types.map(AptosJSON.string)),"arguments":.array(args.map(AptosJSON.string))]))
        let j=try await node("view",body:body,query:version.map { [.init(name:"ledger_version",value:String($0))] } ?? [],operation:"view")
        guard let rows=j.array,rows.count==1 else { throw AptosSendError.malformed };return rows[0]
    }
    static func uint(_ value:AptosJSON) throws -> UInt64 {
        guard let s=value.text,let n=UInt64(s),String(n)==s else { throw AptosSendError.malformed };return n
    }
    private func account(_ sender:String,version:UInt64?=nil) async throws -> AptosJSON {
        try await node("accounts/"+sender,query:version.map { [.init(name:"ledger_version",value:String($0))] } ?? [],operation:"account")
    }
    public func balance(owner:String,reference:String,version:UInt64?=nil) async throws -> UInt64 {
        let owner=try AptosIdentity.address(owner),reference=try AptosIdentity.reference(reference)
        if reference=="native" || reference.contains("::") { return try await Self.uint(view("0x1::coin::balance",types:[reference=="native" ? AptosIdentity.coin:reference],args:[owner],version:version)) }
        return try await Self.uint(view("0x1::primary_fungible_store::balance",types:["0x1::fungible_asset::Metadata"],args:[owner,reference],version:version))
    }
    private func decimals(_ reference:String,version:UInt64) async throws -> Int {
        if reference=="native" { return 8 }
        let value:UInt64
        if reference.contains("::") {
            _ = try AptosBCS.typeTag(reference)
            value=try await Self.uint(view("0x1::coin::decimals",types:[reference],version:version))
        } else {
            value=try await Self.uint(view("0x1::fungible_asset::decimals",types:["0x1::fungible_asset::Metadata"],args:[reference],version:version))
        }
        guard value<=255 else { throw AptosSendError.malformed };return Int(value)
    }
    /// Read-only metadata for token discovery; no wallet or signing material.
    public func tokenDecimals(reference: String) async throws -> Int {
        let ref = try AptosIdentity.reference(reference)
        let ledger = try await node("", operation: "token_metadata")
        return try await decimals(ref, version: Self.uint(ledger["ledger_version"]))
    }
    /// Shared by editable amount validation and the transaction boundary.
    /// Inventory totals may sum multiple stores; a single Move transfer still
    /// accepts only a positive u64. Never clamp or round the user's intent.
    public nonisolated static func validatedAmount(_ amount: String) throws -> UInt64 {
        guard let value = UInt64(amount), String(value) == amount, value > 0 else { throw AptosSendError.amount }
        return value
    }
    public func quote(sender:String,recipient:String,reference:String,publicKey:Data,decimals:Int,amount:String,maximum:Bool=false,multisig:AptosMultisigPolicy?=nil) async throws -> AptosSendPlan {
        let sender=try AptosIdentity.address(sender),recipient=try AptosIdentity.address(recipient),reference=try AptosIdentity.reference(reference)
        let requested = try Self.validatedAmount(amount)
        guard sender != recipient else { throw AptosSendError.sameRecipient }
        if let multisig { try multisig.validate(); guard multisig.bytes == publicKey, multisig.address == sender else { throw AptosSendError.wrongOwner } }
        else { guard try AptosSendCrypto.address(publicKey:publicKey)==sender else { throw AptosSendError.wrongOwner } }
        let ledger=try await node("",operation:"ledger"),version=try Self.uint(ledger["ledger_version"])
        let time=try Self.uint(ledger["ledger_timestamp"])/1_000_000
        guard abs(Double(time)-Date.now.timeIntervalSince1970)<60 else { throw AptosSendError.expired }
        async let stateWork=account(sender,version:version)
        async let nativeWork=balance(owner:sender,reference:"native",version:version)
        async let tokenWork:UInt64? = reference == "native" ? nil:balance(owner:sender,reference:reference,version:version)
        async let decimalsWork=self.decimals(reference,version:version)
        async let priceWork=node("estimate_gas_price",operation:"gas_price")
        let (state,native,token,actualDecimals,price)=try await (stateWork,nativeWork,tokenWork,decimalsWork,priceWork)
        let asset=token ?? native
        guard actualDecimals==decimals else { throw AptosSendError.metadataChanged }
        guard let auth=state["authentication_key"].string,try AptosIdentity.address(auth)==sender else { throw AptosSendError.wrongOwner }
        let sequence=try Self.uint(state["sequence_number"]),unitPrice=try Self.uint(price["gas_estimate"])
        guard unitPrice>0,unitPrice<=AptosSendPlan.feeLimit else { throw AptosSendError.feeTooHigh }
        guard requested<=asset || maximum else { throw AptosSendError.insufficientFunds }
        let requestedAmount=maximum ? asset:requested
        var gas=min(AptosSendPlan.gasLimit,min(AptosSendPlan.feeLimit,native)/unitPrice)
        guard gas>0 else { throw SendFeeFundingError.insufficientNativeBalance }
        let now=Date.now
        func make(_ gas:UInt64, probe:Bool=false) throws -> AptosSendPlan {
            let ceiling=gas*unitPrice
            guard native>=ceiling else { throw SendFeeFundingError.insufficientNativeBalance }
            let value=reference=="native" ? (probe ? 0:min(requestedAmount,native-ceiling)):requestedAmount
            return .init(network:network,sender:sender,recipient:recipient,reference:reference,publicKey:publicKey,decimals:decimals,
                         requestedAmount:requestedAmount,amount:value,assetBalance:asset,nativeBalance:native,sequence:sequence,
                         gasUnitPrice:unitPrice,maxGasAmount:gas,expiration:time+300,createdAt:now,multisig:multisig)
        }
        // A zero-APT probe lets a small balance cover gas without reserving an
        // arbitrary fraction of it. It is never signed or submitted. The exact,
        // positive final amount is validated and simulated below.
        var plan=try make(gas,probe:true)
        let used=try await simulate(plan)
        gas=min(AptosSendPlan.gasLimit,max(used+100,used+used/3))
        guard gas<=AptosSendPlan.feeLimit/unitPrice else { throw AptosSendError.feeTooHigh }
        guard gas<=native/unitPrice else { throw SendFeeFundingError.insufficientNativeBalance }
        plan=try make(gas);try plan.validate()
        _ = try await simulate(plan)
        return plan
    }
    private func simulate(_ plan:AptosSendPlan) async throws -> UInt64 {
        let bytes=try AptosSendCrypto.raw(plan)+AptosSendCrypto.simulationAuthenticator(plan)
        let j: AptosJSON
        do { j = try await node("transactions/simulate",body:bytes,bcs:true,operation:"simulate") }
        catch let error as IntrinsicGasRejection {
            OathDiagnostics.record(error, component:"aptos_send", operation:"simulate_gas", context:["chain":"aptos", "rpc_code":"14"])
            // The REST/node boundary has already recorded this rejection.
            // Resolve the budget cause from the pinned plan, not HTTP text.
            throw Self.simulationFailure(status:"MAX_GAS_UNITS_BELOW_MIN_TRANSACTION_GAS_UNITS",plan:plan)
        }
        guard let rows=j.array,rows.count==1 else { throw AptosSendError.malformed }
        let tx=rows[0]
        try matches(tx,plan:plan,signature:nil)
        guard tx["success"] == .bool(true) else {
            OathDiagnostics.record(DiagnosticFailure(tx["vm_status"].string ?? "Aptos simulation failed"),component:"aptos_send",operation:"simulate",context:["chain":"aptos","stage":"simulation"])
            throw Self.simulationFailure(status: tx["vm_status"].string, plan: plan)
        }
        let used=try Self.uint(tx["gas_used"])
        guard used>0,used<=plan.maxGasAmount else { throw AptosSendError.feeTooHigh };return used
    }
    static func simulationFailure(status: String?, plan: AptosSendPlan) -> any Error {
        let status = status?.trimmingCharacters(in: .whitespacesAndNewlines)
        if status == "INSUFFICIENT_BALANCE_FOR_TRANSACTION_FEE" {
            return SendFeeFundingError.insufficientNativeBalance
        }
        if ["OUT_OF_GAS", "Out of gas", "MAX_GAS_UNITS_BELOW_MIN_TRANSACTION_GAS_UNITS"].contains(status ?? "") {
            // Only call this a funding problem when the probe actually used
            // all affordable gas. A configured gas/fee cap is a different error.
            let affordable = plan.nativeBalance / max(1, plan.gasUnitPrice)
            let ceiling = min(AptosSendPlan.gasLimit, AptosSendPlan.feeLimit / max(1, plan.gasUnitPrice))
            if plan.maxGasAmount == affordable, affordable < ceiling {
                return SendFeeFundingError.insufficientNativeBalance
            }
            return AptosSendError.feeTooHigh
        }
        return AptosSendError.simulationFailed
    }
    public func preflight(_ plan:AptosSendPlan) async throws {
        try plan.validate();guard plan.network==network else { throw AptosSendError.wrongNetwork }
        async let simulation = simulate(plan)
        async let stateWork=account(plan.sender)
        async let nativeWork=balance(owner:plan.sender,reference:"native")
        async let assetWork:UInt64? = plan.reference == "native" ? nil:balance(owner:plan.sender,reference:plan.reference)
        let (state,native,token)=try await (stateWork,nativeWork,assetWork)
        let asset=token ?? native
        guard try Self.uint(state["sequence_number"])==plan.sequence,let auth=state["authentication_key"].string,
              try AptosIdentity.address(auth)==plan.sender else { throw AptosSendError.changed }
        guard native>=plan.fee else { throw SendFeeFundingError.insufficientNativeBalance }
        guard asset>=plan.amount,plan.reference != "native" || plan.amount<=native-plan.fee else { throw AptosSendError.insufficientFunds }
        _ = try await simulation
    }
    public func submit(_ signed:AptosSignedSend,plan:AptosSendPlan,reconcileFirst:Bool = true) async throws -> AptosSendReceipt {
        guard plan.network==network else { throw AptosSendError.wrongNetwork };try AptosSendCrypto.verify(signed,plan:plan)
        if reconcileFirst {
            let current=try await status(signed,plan:plan)
            if current.outcome != .unknown { return current }
        } else { try plan.validate() } // Only a fresh, authorized, journaled send may bypass recovery reads.
        let response=try await node("transactions",body:signed.bytes,bcs:true,operation:"broadcast")
        guard response["hash"].string==signed.hash else { throw AptosSendError.changed }
        if response["type"].string=="user_transaction" { return try receipt(response,signed:signed,plan:plan) }
        // POST /transactions returns an untagged PendingTransaction object;
        // GET /transactions/by_hash returns the tagged transaction union.
        guard response["type"].isNull || response["type"].string=="pending_transaction" else { throw AptosSendError.malformed }
        try matches(response,plan:plan,signature:signed)
        return .init(hash:signed.hash,outcome:.accepted)
    }
    public func status(_ signed:AptosSignedSend,plan:AptosSendPlan) async throws -> AptosSendReceipt {
        guard plan.network==network else { throw AptosSendError.wrongNetwork };try AptosSendCrypto.verify(signed,plan:plan)
        let tx=try await node("transactions/by_hash/"+signed.hash,missing:true,operation:"status")
        if !tx.isNull {
            guard tx["hash"].string==signed.hash else { throw AptosSendError.changed }
            if tx["type"].string=="pending_transaction" { try matches(tx,plan:plan,signature:signed);return .init(hash:signed.hash,outcome:.accepted) }
            return try receipt(tx,signed:signed,plan:plan)
        }
        let ledger=try await node("",operation:"ledger"),version=try Self.uint(ledger["ledger_version"])
        let state=try await account(plan.sender,version:version)
        // A consumed sequence requires the actual committed competing transaction.
        // Pruning or an unavailable archive remains unknown, never a guessed failure.
        if try Self.uint(state["sequence_number"])>plan.sequence {
            let rows=try await node("accounts/"+plan.sender+"/transactions",query:[.init(name:"start",value:String(plan.sequence)),.init(name:"limit",value:"1")],operation:"sequence_status")
            if let other=rows.array?.first,other["type"].string=="user_transaction",
               let sender=other["sender"].string,try AptosIdentity.address(sender)==plan.sender,
               try Self.uint(other["sequence_number"])==plan.sequence,try Self.uint(other["version"])<=version,
               let hash=other["hash"].string,Self.validHash(hash) {
                if hash==signed.hash { return try receipt(other,signed:signed,plan:plan) }
                return .init(hash:signed.hash,outcome:.replaced,replacementHash:hash)
            }
            return .init(hash:signed.hash,outcome:.unknown)
        }
        if try Self.uint(ledger["ledger_timestamp"])/1_000_000>plan.expiration { return .init(hash:signed.hash,outcome:.expired) }
        return .init(hash:signed.hash,outcome:.unknown)
    }
    static func validHash(_ text:String) -> Bool { text.hasPrefix("0x") && text.count==66 && (try? TronIdentity.hex(text))?.count==32 }
    private func matches(_ tx:AptosJSON,plan:AptosSendPlan,signature:AptosSignedSend?) throws {
        guard let sender=tx["sender"].string,try AptosIdentity.address(sender)==plan.sender,
              try Self.uint(tx["sequence_number"])==plan.sequence,try Self.uint(tx["max_gas_amount"])==plan.maxGasAmount,
              try Self.uint(tx["gas_unit_price"])==plan.gasUnitPrice,try Self.uint(tx["expiration_timestamp_secs"])==plan.expiration else { throw AptosSendError.changed }
        let expected=AptosSendCrypto.payload(plan),actual=tx["payload"]
        guard actual["type"]==expected["type"],actual["function"]==expected["function"],
              let actualTypes=actual["type_arguments"].array, let expectedTypes=expected["type_arguments"].array,
              try actualTypes.map({ try AptosIdentity.reference($0.string ?? "") }) == expectedTypes.map({ try AptosIdentity.reference($0.string ?? "") }),let args=actual["arguments"].array,let wanted=expected["arguments"].array,args.count==wanted.count else { throw AptosSendError.changed }
        for i in args.indices {
            if i==args.count-1 || (wanted.count==4 && i==2) { guard try Self.uint(args[i])==plan.amount else { throw AptosSendError.changed } }
            else {
                // REST renders Object<Metadata> as {"inner": address}, although
                // the BCS entry argument is the same 32-byte object address.
                let isMetadata = i==0 && plan.reference != "native" && !plan.reference.contains("::")
                let value = isMetadata ? (args[i].string ?? args[i]["inner"].string) : args[i].string
                guard let a=value,let b=wanted[i].string,try AptosIdentity.address(a)==AptosIdentity.address(b) else { throw AptosSendError.changed }
            }
        }
        if let signature {
            let auth=tx["signature"]
            if let policy = plan.multisig { try AptosSendCrypto.verifyMultisigResponse(auth, signed: signature, policy: policy); return }
            guard auth["type"].string=="ed25519_signature",let p=auth["public_key"].string,let s=auth["signature"].string,
                  try TronIdentity.hex(p)==signature.publicKey,try TronIdentity.hex(s)==signature.signature else { throw AptosSendError.signing }
        }
    }
    private func receipt(_ tx:AptosJSON,signed:AptosSignedSend,plan:AptosSendPlan) throws -> AptosSendReceipt {
        guard tx["type"].string=="user_transaction",tx["hash"].string==signed.hash,
              case .bool(let success)=tx["success"] else { throw AptosSendError.malformed }
        try matches(tx,plan:plan,signature:signed)
        let used=try Self.uint(tx["gas_used"]),version=try Self.uint(tx["version"]),timestamp=try Self.uint(tx["timestamp"])
        guard used<=plan.maxGasAmount,version<=UInt64(Int64.max),timestamp>0 else { throw AptosSendError.malformed }
        return .init(hash:signed.hash,outcome:success ? .confirmed:.failed,fee:used*plan.gasUnitPrice,version:version,timestamp:Double(timestamp)/1_000_000)
    }
}
