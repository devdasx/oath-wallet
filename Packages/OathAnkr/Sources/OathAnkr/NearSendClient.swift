import Foundation
import OathDiagnostics

/// Fixed-purpose NEAR transfers. Quotes never sign; retries only submit the original signed bytes.
public actor NearSendClient {
    public let network: NearSendNetwork
    private let endpoints: [URL]
    private let transport: any AnkrTransport
    private let permits=AnkrPermits(count:6)
    private var checked=Set<URL>()
    struct MultisigFinalPart { let receipt:NearSendReceipt; let returnedID:UInt32? }
    var multisigFinalParts:[String:MultisigFinalPart]=[:]
    public init(network:NearSendNetwork = .mainnet,apiKey:String?=nil,transport:any AnkrTransport = AnkrHTTPTransport()) throws {
        self.network=network; self.transport=transport
        if let apiKey {
            guard !apiKey.isEmpty, apiKey.count<=256, apiKey.utf8.allSatisfy({(48...57).contains($0)||(65...90).contains($0)||(97...122).contains($0)}),network == .mainnet else { throw NearSendError.configuration }
            endpoints=[URL(string:"https://rpc.ankr.com/near")!.appendingPathComponent(apiKey),network.endpoint]
        } else { endpoints=network == .testnet ? [URL(string:"https://test.rpc.fastnear.com")!,network.endpoint]:[network.endpoint] }
    }
    public init(network:NearSendNetwork,endpoints:[URL],transport:any AnkrTransport) throws {
        guard (1...2).contains(endpoints.count),endpoints.allSatisfy({$0.scheme=="https"}) else { throw NearSendError.configuration }
        self.network=network; self.endpoints=endpoints; self.transport=transport
    }
    private func request(_ url:URL,method:String,params:NearJSON,unknownAllowed:Bool=false) async throws -> NearJSON {
        var req=URLRequest(url:url); req.httpMethod="POST"; req.timeoutInterval=15
        req.setValue("application/json",forHTTPHeaderField:"Content-Type")
        req.httpBody=try JSONEncoder().encode(NearJSON.object(["jsonrpc":.string("2.0"),"id":.number("1"),"method":.string(method),"params":params]))
        try await permits.acquire()
        let data:Data,status:Int
        do { (data,status)=try await transport.send(req) }
        catch {
            await permits.release(); OathDiagnostics.record(error,component:"near_send",operation:method,context:["chain":"near"])
            if Task.isCancelled || error is CancellationError { throw CancellationError() }; throw NearSendError.transport
        }
        await permits.release(); try Task.checkCancellation()
        DiagnosticHTTP.response(data,status:status,request:req)
        guard status==200 else { throw NearSendError.http(status) }
        guard data.count<=4_194_304 else { throw NearSendError.malformed }
        let j=try JSONDecoder().decode(NearJSON.self,from:data)
        guard j["jsonrpc"].string=="2.0",j["id"].integer==1 else { throw NearSendError.malformed }
        if !j["error"].isNull {
            let e=j["error"],name=e["cause"]["name"].string ?? e["data"]["cause"]["name"].string ?? ""
            // Missing accounts and unknown/pending transactions are expected state, not failures.
            if method=="query",params["request_type"].string=="view_account",let owner=params["account_id"].string {
                let cause=e["cause"].isNull ? e["data"]["cause"]:e["cause"]
                if (name=="UNKNOWN_ACCOUNT" && cause["info"]["requested_account_id"].string==owner) ||
                    e["data"].string=="account \(owner) does not exist while viewing" { throw NearError.accountMissing }
            }
            if unknownAllowed && ["UNKNOWN_TRANSACTION","TIMEOUT_ERROR"].contains(name) { return .null }
            let code=Int(e["code"].text ?? "") ?? 0
            let error=NearSendError.rpc(code)
            OathDiagnostics.record(error,component:"near_send",operation:method,context:["chain":"near","rpc_code":String(code)])
            throw error
        }
        guard !j["result"].isNull || unknownAllowed else { throw NearSendError.malformed }; return j["result"]
    }
    func rpc(_ method:String,_ params:NearJSON,unknownAllowed:Bool=false) async throws -> NearJSON {
        for (index,url) in endpoints.enumerated() {
            do {
                if !checked.contains(url) {
                    // ANKR disables `status`; protocol configuration supplies the same chain
                    // identity and is available on both primary and official fallback nodes.
                    let s=try await request(url,method:"EXPERIMENTAL_protocol_config",params:.object(["finality":.string("final")]))
                    guard s["chain_id"].string==network.rawValue else { throw NearSendError.wrongNetwork }; checked.insert(url)
                }
                return try await request(url,method:method,params:params,unknownAllowed:unknownAllowed)
            } catch NearError.accountMissing { throw NearError.accountMissing }
            catch {
                OathDiagnostics.record(error,component:"near_send",operation:method,context:["chain":"near"])
                let retry:Bool
                switch error { case NearSendError.http(let n): retry=n==408 || n==429 || n>=500
                case NearSendError.transport: retry=true
                case NearSendError.rpc(let code): retry=code == -32075 || code == -32601
                default: retry=false }
                guard retry,index+1<endpoints.count else { throw error }
            }
        }
        throw NearSendError.transport
    }
    func finalBlock() async throws -> NearJSON { try await rpc("block",.object(["finality":.string("final")]))["header"] }
    func query(_ values:[String:NearJSON],block:String) async throws -> NearJSON {
        var p=values;p["block_id"] = .string(block)
        let result=try await rpc("query",.object(p))
        guard result["block_hash"].string==block else { throw NearSendError.malformed };return result
    }
    func account(_ id:String,block:String) async throws -> NearJSON { try await query(["request_type":.string("view_account"),"account_id":.string(id)],block:block) }
    func call(_ contract:String,_ method:String,_ args:[String:NearJSON]=[:],block:String) async throws -> NearJSON {
        let result=try await query(["request_type":.string("call_function"),"account_id":.string(contract),"method_name":.string(method),"args_base64":.string(try NearSendCrypto.args(args).base64EncodedString())],block:block)
        return try decodeCall(result)
    }
    private func decodeCall(_ result:NearJSON) throws -> NearJSON {
        if !result["error"].isNull { throw NearSendError.execution }
        guard let bytes=result["result"].array,bytes.count<=65_536 else { throw NearSendError.malformed }
        let data=try Data(bytes.map { v -> UInt8 in guard let n=v.integer,n<=255 else { throw NearSendError.malformed };return UInt8(n) })
        return try JSONDecoder().decode(NearJSON.self,from:data)
    }
    private func storageBalance(_ contract:String,recipient:String,block:String) async throws -> NearJSON? {
        let result=try await query(["request_type":.string("call_function"),"account_id":.string(contract),"method_name":.string("storage_balance_of"),
            "args_base64":.string(try NearSendCrypto.args(["account_id":.string(recipient)]).base64EncodedString())],block:block)
        // NEP-145 is optional for NEP-141 tokens. Only this exact missing-interface result
        // means registration is not required; contract panics/provider errors still fail.
        if result["error"].string=="wasm execution failed with error: MethodResolveError(MethodNotFound)" { return nil }
        return try decodeCall(result)
    }
    private func key(_ sender:String,_ pub:Data,block:String,multisig:NearMultisigPolicy? = nil) async throws -> NearJSON {
        let k=try await query(["request_type":.string("view_access_key"),"account_id":.string(sender),"public_key":.string(NearSendCrypto.keyString(pub))],block:block)
        guard multisig != nil || k["permission"].string=="FullAccess" else { throw NearSendError.unsupportedAccount };return k
    }
    public func quote(sender:String,recipient:String,reference:String,publicKey:Data,decimals:Int,amount:String,maximum:Bool=false,multisig:NearMultisigPolicy? = nil) async throws -> NearSendPlan {
        _ = try NearIdentity.address(sender); _ = try NearIdentity.address(recipient); _ = try NearIdentity.reference(reference)
        _ = try NearSendAmount.checked(amount)
        guard sender != recipient,publicKey.count==32,amount != "0" else { throw NearSendError.amount }
        let header=try await finalBlock(),hash=try NearIdentity.hash(header["hash"])
        var multisigContext:NearMultisigContext?
        if let multisig {
            guard sender==multisig.address,publicKey==multisig.publicKeys.first else { throw NearSendError.wrongOwner }
            let (state,nonces)=try await multisigState(multisig,block:hash)
            guard state.configured else { throw NearSendError.unsupportedAccount }
            let id=try await call(sender,"get_request_nonce",block:hash)
            guard let n=id.integer,n<UInt64(UInt32.max) else { throw NearSendError.malformed }
            multisigContext = .init(policy:multisig,stage:.transfer,requestID:UInt32(n),nonces:Array(nonces.prefix(multisig.required)))
        }
        async let stateWork=account(sender,block:hash)
        async let keyWork=key(sender,publicKey,block:hash,multisig:multisig)
        async let configWork=rpc("EXPERIMENTAL_protocol_config",.object(["block_id":.string(hash)]))
        async let priceWork=rpc("gas_price",.array([.string(hash)]))
        // Named recipients must already exist. A single native Transfer can activate a NEAR implicit account.
        var createsAccount=false
        do { _ = try await account(recipient,block:hash) }
        catch NearError.accountMissing { guard reference=="native",NearSendPlan.isImplicit(recipient) else { throw NearSendError.recipientMissing }; createsAccount=true }
        let (state,key,config,price)=try await (stateWork,keyWork,configWork,priceWork)
        guard config["chain_id"].string==network.rawValue,let nonce=key["nonce"].integer,nonce<UInt64.max,
              let height=header["height"].integer,let validity=config["transaction_validity_period"].integer else { throw NearSendError.malformed }
        let native=try NearIdentity.amount(state["amount"]),locked=try NearIdentity.amount(state["locked"])
        guard let storage=state["storage_usage"].integer,storage<=UInt64.max-32_768 else { throw NearSendError.malformed }
        let staking=try NearSendAmount.multiply(NearIdentity.amount(config["runtime_config"]["storage_amount_per_byte"]),storage + (multisig == nil ? 0:32_768))
        let reserve=XrplSendAmount.less(locked,staking) ? try NearSendAmount.subtract(staking,locked):"0"
        let runtime=config["runtime_config"],marketPrice=try NearIdentity.amount(price["gas_price"])
        // New protocol versions have a gas purchase floor independent of gas_price, and a
        // fixed account activation charge. Missing fields on older versions mean no extra charge.
        let purchaseFloor=runtime["min_gas_purchase_price"].isNull ? "0":try NearIdentity.amount(runtime["min_gas_purchase_price"])
        let ceiling=try NearSendAmount.multiply(XrplSendAmount.less(marketPrice,purchaseFloor) ? purchaseFloor:marketPrice,2)
        let creationCharge=createsAccount && !runtime["account_creation_charge"].isNull ? try NearIdentity.amount(runtime["account_creation_charge"]):"0"
        var balance=native,deposit="0"
        if reference != "native" {
            async let metadataWork=call(reference,"ft_metadata",block:hash)
            async let balanceWork=call(reference,"ft_balance_of",["account_id":.string(sender)],block:hash)
            async let registeredWork=storageBalance(reference,recipient:recipient,block:hash)
            let (metadata,tokenBalance,registered)=try await (metadataWork,balanceWork,registeredWork)
            guard try NearToken.decode(metadata,reference:reference).decimals==decimals else { throw NearSendError.metadataChanged }
            balance=try NearIdentity.amount(tokenBalance)
            if let registered, registered.isNull {
                let bounds=try await call(reference,"storage_balance_bounds",block:hash)
                deposit=try NearIdentity.amount(bounds["min"])
                guard deposit != "0",!XrplSendAmount.less(NearSendPlan.maximumStorage,deposit) else { throw NearSendError.storageUnsupported }
            } else if let registered { _ = try NearIdentity.amount(registered["total"]); _ = try NearIdentity.amount(registered["available"]) }
        } else { guard decimals==24 else { throw NearSendError.metadataChanged } }
        let gas:UInt64=reference=="native" ? 0:50_000_000_000_000,storageGas:UInt64=deposit=="0" ? 0:30_000_000_000_000
        // Calculate protocol send+execution costs, including implicit-account creation and function argument bytes.
        let costs=config["runtime_config"]["transaction_costs"],action=costs["action_creation_config"]
        func cost(_ node:NearJSON) throws -> UInt64 {
            guard let send=node["send_not_sir"].integer,let exec=node["execution"].integer,send<=1_000_000_000_000_000,exec<=1_000_000_000_000_000 else { throw NearSendError.malformed };return send+exec
        }
        var prepaid=try cost(costs["action_receipt_creation_config"])
        if reference=="native" {
            prepaid += try cost(action["transfer_cost"])
            if NearSendPlan.isImplicit(recipient) { prepaid += try cost(action["create_account_cost"])+cost(action["add_key_cost"]["full_access_cost"]) }
        } else {
            let transfer=try NearSendCrypto.args(["receiver_id":.string(recipient),"amount":.string(maximum ? balance:amount)])
            prepaid += gas + (try cost(action["function_call_cost"])) + UInt64(transfer.count+"ft_transfer".utf8.count)*(try cost(action["function_call_cost_per_byte"]))
            if deposit != "0" {
                let args=try NearSendCrypto.args(["account_id":.string(recipient),"registration_only":.bool(true)])
                prepaid += storageGas + (try cost(action["function_call_cost"])) + UInt64(args.count+"storage_deposit".utf8.count)*(try cost(action["function_call_cost_per_byte"]))
            }
        }
        if let multisig { prepaid += UInt64(multisig.required)*160_000_000_000_000+40_000_000_000_000 }
        let fee=try NearSendAmount.add(NearSendAmount.multiply(ceiling,prepaid),creationCharge)
        guard !XrplSendAmount.less(try NearSendAmount.multiply(NearSendPlan.maximumFee,UInt64(multisig == nil ? 1:multisig!.required+1)),fee) else { throw NearSendError.feeTooHigh }
        if deposit != "0" {
            let required = try NearSendAmount.add(reserve, NearSendAmount.add(deposit, NearSendAmount.add("1",fee)))
            if XrplSendAmount.less(native,required) { throw NearSendError.storageFunds }
        }
        let spendable=try NearSendAmount.subtract(native,reserve)
        guard !XrplSendAmount.less(spendable,fee) else { throw SendFeeFundingError.insufficientNativeBalance }
        let requested=maximum ? balance:amount
        guard !XrplSendAmount.less(balance,requested) else { throw NearSendError.insufficientFunds }
        var sendAmount=requested
        if reference=="native" {
            let available=try NearSendAmount.subtract(spendable,fee)
            if XrplSendAmount.less(available,sendAmount) { sendAmount=available }
        }
        let plan=NearSendPlan(network:network,sender:sender,recipient:recipient,reference:reference,publicKey:publicKey,decimals:decimals,
            requestedAmount:requested,amount:sendAmount,assetBalance:balance,nativeBalance:native,reserve:reserve,storageDeposit:deposit,fee:fee,
            gasPriceCeiling:ceiling,gas:gas,storageGas:storageGas,nonce:nonce+1,blockHash:hash,blockHeight:height,validityPeriod:validity,multisig:multisigContext)
        try plan.validate(); return plan
    }
    /// Refresh key and balance immediately before authentication; never silently mutate the reviewed intent.
    public func preflight(_ plan:NearSendPlan) async throws {
        try plan.validate();guard plan.network==network else { throw NearSendError.wrongNetwork }
        if plan.multisig != nil { try await multisigPreflight(plan);return }
        let current=try await quote(sender:plan.sender,recipient:plan.recipient,reference:plan.reference,
            publicKey:plan.publicKey,decimals:plan.decimals,amount:plan.amount)
        // Recheck all protocol costs, storage, token metadata/balance and the key immediately
        // before authorization. A changed quote never silently alters the reviewed transfer.
        guard current.nonce<=plan.nonce,current.amount==plan.amount,
              !XrplSendAmount.less(plan.fee,current.fee),
              !XrplSendAmount.less(plan.gasPriceCeiling,current.gasPriceCeiling),
              !XrplSendAmount.less(plan.storageDeposit,current.storageDeposit),
              !XrplSendAmount.less(current.nativeBalance,try NearSendAmount.add(current.reserve,plan.nativeDebit)) else { throw NearSendError.changed }
    }
    public func submit(_ signed:NearSignedSend,plan:NearSendPlan,reconcileFirst:Bool = true) async throws -> NearSendReceipt {
        try NearSendCrypto.verify(signed,plan:plan);guard plan.network==network else { throw NearSendError.wrongNetwork }
        if plan.multisig != nil { return try await multisigSubmit(signed,plan:plan,broadcast:true) }
        // The quote age limit belongs to authorization, not recovery. After a
        // restart these already-authorized bytes may still be protocol-valid.
        // Check old work first, then replay ONLY the same bytes while its block
        // hash is valid. Never refresh the nonce/hash or sign another payment.
        if reconcileFirst || Date.now.timeIntervalSince(plan.createdAt)>90 {
            let known = try await status(signed,plan:plan)
            guard known.outcome == .unknown else { return known }
            if Date.now.timeIntervalSince(plan.createdAt)>90 {
                let header = try await finalBlock()
                guard let height = header["height"].integer else { throw NearSendError.malformed }
                guard height <= plan.blockHeight + plan.validityPeriod else { return known }
            }
        } else { try plan.validate() }
        // This supported asynchronous method returns the exact transaction hash.
        // FINAL remains in status(): waiting for every execution/refund receipt
        // here kept the confirmation screen blocked after successful submission.
        let result=try await rpc("broadcast_tx_async",.array([.string(signed.bytes.base64EncodedString())]),unknownAllowed:true)
        if result.isNull { return .init(hash:signed.hash,outcome:.unknown) }
        guard result.string == signed.hash else { throw NearSendError.changed }
        return .init(hash:signed.hash,outcome:.accepted)
    }
    public func status(_ signed:NearSignedSend,plan:NearSendPlan) async throws -> NearSendReceipt {
        try NearSendCrypto.verify(signed,plan:plan);guard plan.network==network else { throw NearSendError.wrongNetwork }
        if plan.multisig != nil { return try await multisigSubmit(signed,plan:plan,broadcast:false) }
        let j=try await rpc("tx",.object(["tx_hash":.string(signed.hash),"sender_account_id":.string(plan.sender),"wait_until":.string("FINAL")]),unknownAllowed:true)
        if j.isNull {
            let h=try await finalBlock()
            if let height=h["height"].integer,height>plan.blockHeight+plan.validityPeriod {
                let k=try await key(plan.sender,plan.publicKey,block:NearIdentity.hash(h["hash"]))
                // An unchanged access-key nonce proves these bytes never executed. If the key was
                // used/deleted/replaced, keep the reservation unknown instead of guessing failure.
                if let nonce=k["nonce"].integer,nonce<plan.nonce { return .init(hash:signed.hash,outcome:.expired) }
            }
        }
        return try await receipt(j,signed:signed,plan:plan)
    }
    func receipt(_ j:NearJSON,signed:NearSignedSend,plan:NearSendPlan,expectedNonce:UInt64? = nil) async throws -> NearSendReceipt {
        guard !j.isNull else { return .init(hash:signed.hash,outcome:.unknown) }
        // Pending statuses can legitimately have no execution/transaction object yet. It is neither an
        // identity mismatch nor evidence of success; wait for canonical inclusion.
        if j["transaction"].isNull, ["NONE","INCLUDED","INCLUDED_FINAL","EXECUTED_OPTIMISTIC","EXECUTED"].contains(j["final_execution_status"].string ?? "") { return .init(hash:signed.hash,outcome:.unknown) }
        let tx=j["transaction"]
        guard tx["hash"].string==signed.hash,tx["signer_id"].string==plan.sender,tx["receiver_id"].string==plan.receiver,
              tx["public_key"].string==NearSendCrypto.keyString(signed.publicKey),tx["nonce"].integer==(expectedNonce ?? plan.nonce) else { throw NearSendError.changed }
        guard j["final_execution_status"].string=="FINAL" else { return .init(hash:signed.hash,outcome:.unknown) }
        guard let receipts=j["receipts_outcome"].array,receipts.count<=1024,!receipts.isEmpty,
              j["transaction_outcome"]["id"].string==signed.hash else { throw NearSendError.malformed }
        let outcomes=[j["transaction_outcome"]]+receipts
        let ids=try outcomes.map { try NearIdentity.hash($0["id"]) }
        guard Set(ids).count==ids.count else { throw NearSendError.malformed }
        var fee="0", graph=[String:[String]](), statuses=[String:NearJSON]()
        for o in outcomes {
            let id=try NearIdentity.hash(o["id"])
            fee=try NearSendAmount.add(fee,NearIdentity.amount(o["outcome"]["tokens_burnt"]))
            guard let children=o["outcome"]["receipt_ids"].array else { throw NearSendError.malformed }
            let childIDs=try children.map { try NearIdentity.hash($0) }
            guard Set(childIDs).count==childIDs.count,childIDs.allSatisfy(Set(ids).contains) else { throw NearSendError.malformed }
            graph[id]=childIDs;statuses[id]=o["outcome"]["status"]
        }
        var pending=[signed.hash],visited=Set<String>()
        while let id=pending.popLast() {
            guard visited.insert(id).inserted else { throw NearSendError.malformed }
            pending.append(contentsOf:graph[id] ?? [])
        }
        guard visited==Set(ids),j["transaction_outcome"]["outcome"]["executor_id"].string==plan.sender else { throw NearSendError.malformed }
        // Follow the actual execution-result chain, separately from refund receipts.
        var terminal=signed.hash,chain=Set<String>()
        while let next=statuses[terminal]?["SuccessReceiptId"].string {
            guard chain.insert(terminal).inserted,graph[terminal]?.contains(next)==true else { throw NearSendError.malformed }
            terminal=next
        }
        guard let finalStatus=statuses[terminal],finalStatus==j["status"],
              receipts.contains(where:{$0["outcome"]["executor_id"].string==plan.receiver}) else { throw NearSendError.changed }
        let failure = !finalStatus["Failure"].isNull
        guard failure || finalStatus["SuccessValue"].string != nil else { throw NearSendError.malformed }
        let includedHash=try NearIdentity.hash(j["transaction_outcome"]["block_hash"])
        let block=try await rpc("block",.object(["block_id":.string(includedHash)]))["header"]
        guard block["hash"].string==includedHash,let height=block["height"].integer,height>=plan.blockHeight else { throw NearSendError.malformed }
        if failure { OathDiagnostics.record(NearSendError.execution,component:"near_send",operation:"execution",context:["chain":"near","stage":"final"] ) }
        return .init(hash:signed.hash,outcome:failure ? .failed:.confirmed,fee:fee,block:height)
    }
}
