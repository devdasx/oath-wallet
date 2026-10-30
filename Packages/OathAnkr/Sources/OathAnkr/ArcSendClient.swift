import Foundation
import OathDiagnostics

public actor ArcSendClient {
    public nonisolated let network:ArcSendNetwork
    private let transport:any AnkrTransport
    private let endpoints:[URL]
    private let permits=AnkrPermits(count:4)
    public init(network:ArcSendNetwork = .mainnet,transport:any AnkrTransport = AnkrHTTPTransport()) {
        self.network=network;self.transport=transport;endpoints=network.endpoints
    }
    /// Each request verifies the chain on the same provider, including fallbacks.
    /// One bounded attempt per endpoint; never turn a rejected transaction into success.
    private func rpc(_ method:String,_ params:[SolanaJSON]) async throws -> SolanaJSON {
        try await OathDiagnostics.withChain("arc") {
            try await rpcInContext(method, params)
        }
    }
    private func rpcInContext(_ method:String,_ params:[SolanaJSON]) async throws -> SolanaJSON {
        try await permits.acquire()
        do {
            var failure:Error=ArcSendError.transport
            for endpoint in endpoints {
                do {
                    try Task.checkCancellation()
                    let body:SolanaJSON = .array([
                        .object(["jsonrpc":.string("2.0"),"id":.number("0"),"method":.string("eth_chainId"),"params":.array([])]),
                        .object(["jsonrpc":.string("2.0"),"id":.number("1"),"method":.string(method),"params":.array(params)])])
                    var request=URLRequest(url:endpoint);request.httpMethod="POST";request.timeoutInterval=10
                    request.setValue("application/json",forHTTPHeaderField:"Content-Type");request.httpBody=try JSONEncoder().encode(body)
                    let (data,status)=try await transport.send(request)
                    DiagnosticHTTP.response(data,status:status,request:request)
                    guard (200...299).contains(status) else { throw ArcSendError.http(status) }
                    guard data.count<=8_388_608,let rows=try JSONDecoder().decode(SolanaJSON.self,from:data).array,rows.count==2,
                          rows.allSatisfy({$0["jsonrpc"].string=="2.0"}),
                          let chain=rows.first(where:{$0["id"].integer==0}),let result=rows.first(where:{$0["id"].integer==1}) else { throw ArcSendError.malformed }
                    guard try Self.uint(Self.result(chain))==network.chainID else { throw ArcSendError.wrongNetwork }
                    let value=try Self.result(result, feeContext: ["eth_estimateGas", "eth_sendRawTransaction"].contains(method))
                    await permits.release();return value
                } catch {
                    OathDiagnostics.record(error,component:"arc_send",operation:method,context:["chain":"arc","rpc_method":method])
                    if error is CancellationError || Task.isCancelled { throw CancellationError() }
                    // Deterministic RPC rejection must remain visible. Network/HTTP,
                    // malformed and misrouted providers may use an independent fallback.
                    if error is SendFeeFundingError { throw error }
                    if case ArcSendError.rpc = error { throw error }
                    failure=error
                }
            }
            throw failure
        } catch { await permits.release();OathDiagnostics.record(error,component:"arc_send",operation:method,context:["chain":"arc"]);throw error }
    }
    private static func result(_ j:SolanaJSON, feeContext: Bool = false) throws -> SolanaJSON {
        // JSON-RPC errors use signed codes (for example -32000). The quantity
        // accessor is intentionally unsigned and must not be used here.
        if case .number(let raw)=j["error"]["code"],let code=Int(raw) {
            OathDiagnostics.record(DiagnosticFailure(j["error"]["message"].string ?? "RPC rejected"), component:"arc_send", operation:"rpc_response", context:["chain":"arc", "rpc_code":String(code)])
            if feeContext, [-32000, -32003].contains(code), SendFeeFundingError.isEVMFundingMessage(j["error"]["message"].string) {
                throw SendFeeFundingError.insufficientNativeBalance
            }
            throw ArcSendError.rpc(code)
        }
        guard case .object(let obj)=j,let result=obj["result"],j["error"].isNull else { throw ArcSendError.malformed }
        return result // null is expected for transactions/receipts not yet visible.
    }
    static func quantity(_ j:SolanaJSON) throws -> String {
        guard let raw=j.string,raw.hasPrefix("0x") else { throw ArcSendError.malformed }
        return try ArcSendAmount.checked(AnkrQuantity.decimal(raw))
    }
    static func uint(_ j:SolanaJSON) throws -> UInt64 {
        guard let n=UInt64(try quantity(j)) else { throw ArcSendError.malformed };return n
    }
    private static func hex(_ n:UInt64)->SolanaJSON { .string("0x"+String(n,radix:16)) }
    private func block(_ tag:SolanaJSON,full:Bool=false) async throws -> SolanaJSON { try await rpc("eth_getBlockByNumber",[tag,.bool(full)]) }
    private func call(_ ref:String,_ data:String,_ tag:SolanaJSON) async throws -> SolanaJSON { try await rpc("eth_call",[.object(["to":.string(ref),"data":.string(data)]),tag]) }
    public func balance(owner:String,reference:String) async throws -> String {
        try await balance(owner:ArcIdentity.address(owner),reference:ArcIdentity.reference(reference),tag:.string("latest"))
    }
    private func balance(owner:String,reference:String,tag:SolanaJSON) async throws -> String {
        if reference == "native" { return try await Self.quantity(rpc("eth_getBalance",[.string(owner),tag])) }
        return try await Self.quantity(call(reference,"0x70a08231"+String(repeating:"0",count:24)+owner.dropFirst(2),tag))
    }
    private func decimals(_ ref:String,tag:SolanaJSON) async throws -> Int {
        if ref == "native" { return 18 }
        let n=try await Self.uint(call(ref,"0x313ce567",tag));guard n<=255 else { throw ArcSendError.metadataChanged };return Int(n)
    }
    private func transaction(_ plan:ArcSendPlan,gas:Bool=true) throws -> SolanaJSON {
        var obj:[String:SolanaJSON] = ["from":.string(plan.sender),"to":.string(plan.receiver),"value":.string(try ArcSendAmount.hex(plan.value)),
            "data":.string("0x"+TronSendCrypto.hex(try ArcSendCrypto.data(plan))),"maxFeePerGas":Self.hex(plan.maxFeePerGas),
            "maxPriorityFeePerGas":Self.hex(plan.maxPriorityFeePerGas),"nonce":Self.hex(plan.nonce),"type":.string("0x2")]
        if gas { obj["gas"]=Self.hex(plan.gasLimit) };return .object(obj)
    }
    public func quote(sender:String,recipient:String,reference:String,decimals:Int,amount:String,maximum:Bool=false) async throws -> ArcSendPlan {
        let sender=try ArcIdentity.address(sender),recipient=try ArcIdentity.address(recipient),reference=try ArcIdentity.reference(reference)
        let requested=try ArcSendAmount.checked(amount)
        guard requested != "0",sender != recipient,recipient != "0x"+String(repeating:"0",count:40) else { throw ArcSendError.amount }
        let head=try await block(.string("latest")),height=try Self.uint(head["number"]),base=try Self.uint(head["baseFeePerGas"])
        guard let hash=head["hash"].string,AnkrQuantity.hash(hash),abs(Double(try Self.uint(head["timestamp"]))-Date.now.timeIntervalSince1970)<60 else { throw ArcSendError.expired }
        let tag=Self.hex(height)
        async let nativeWork=balance(owner:sender,reference:"native",tag:tag)
        async let tokenWork:String? = reference == "native" ? nil:balance(owner:sender,reference:reference,tag:tag)
        async let decimalsWork=self.decimals(reference,tag:tag)
        async let nonceWork=rpc("eth_getTransactionCount",[.string(sender),tag])
        async let pendingWork=rpc("eth_getTransactionCount",[.string(sender),.string("pending")])
        async let priceWork=rpc("eth_gasPrice",[])
        let (native,token,actualDecimals,nonceJSON,pendingJSON,priceJSON)=try await (nativeWork,tokenWork,decimalsWork,nonceWork,pendingWork,priceWork)
        let nonce=try Self.uint(nonceJSON),pending=try Self.uint(pendingJSON),price=try Self.uint(priceJSON),asset=token ?? native
        guard actualDecimals==decimals else { throw ArcSendError.metadataChanged }
        guard nonce==pending else { throw ArcSendError.busy }
        guard base>0,base<=100_000_000_000_000,price<=100_000_000_000_000 else { throw ArcSendError.feeTooHigh }
        let tip=max(1_000_000_000,price>base ? price-base:0),ceiling=max(price,base*2+tip)
        let want=maximum ? asset:requested
        guard !ArcSendAmount.less(asset,want),want != "0" else { throw ArcSendError.insufficientFunds }
        guard native != "0" else { throw SendFeeFundingError.insufficientNativeBalance }
        let now=Date.now
        func make(_ gas:UInt64,_ value:String) -> ArcSendPlan {
            .init(network:network,sender:sender,recipient:recipient,reference:reference,decimals:decimals,requestedAmount:want,
                  amount:value,assetBalance:asset,nativeBalance:native,nonce:nonce,gasLimit:gas,maxFeePerGas:ceiling,maxPriorityFeePerGas:tip,blockHeight:height,createdAt:now)
        }
        // Zero native-value probe avoids pretending Max can spend the gas reserve.
        // It is never authorized or signed; final positive payload is simulated below.
        let probe=make(ArcSendPlan.maximumGas,reference == "native" ? "0":want)
        let estimate=try await Self.uint(rpc("eth_estimateGas",[transaction(probe,gas:false),.string("latest")]))
        guard estimate>=21_000,estimate<=ArcSendPlan.maximumGas else { throw ArcSendError.feeTooHigh }
        let gas=estimate==21_000 ? estimate:min(ArcSendPlan.maximumGas,estimate+estimate/5+1_000)
        let product=gas.multipliedReportingOverflow(by:ceiling)
        guard !product.overflow,product.partialValue<=ArcSendPlan.maximumFee else { throw ArcSendError.feeTooHigh }
        guard !ArcSendAmount.less(native,String(product.partialValue)) else { throw SendFeeFundingError.insufficientNativeBalance }
        let available=try ArcSendAmount.subtract(native,String(product.partialValue))
        let value=reference == "native" && ArcSendAmount.less(available,want) ? available:want
        let plan=make(gas,value);try plan.validate()
        try await simulate(plan)
        let check=try await block(tag)
        guard check["hash"].string==hash else { throw ArcSendError.changed }
        return plan
    }
    private func simulate(_ plan:ArcSendPlan) async throws {
        async let estimate=rpc("eth_estimateGas",[transaction(plan),.string("latest")])
        async let result=rpc("eth_call",[transaction(plan),.string("latest")])
        let (used,output)=try await (estimate,result)
        guard try Self.uint(used)<=plan.gasLimit else { throw ArcSendError.feeTooHigh }
        guard let raw=output.string,raw.hasPrefix("0x") else { throw ArcSendError.malformed }
        if plan.reference != "native",raw != "0x" {
            guard raw.count==66,try Self.quantity(output)=="1" else { throw ArcSendError.simulationFailed }
        }
    }
    public func preflight(_ plan:ArcSendPlan) async throws {
        try plan.validate();guard plan.network==network else { throw ArcSendError.wrongNetwork }
        async let simulation = simulate(plan)
        async let nonceWork=rpc("eth_getTransactionCount",[.string(plan.sender),.string("pending")])
        async let nativeWork=balance(owner:plan.sender,reference:"native")
        async let assetWork:String? = plan.reference == "native" ? nil:balance(owner:plan.sender,reference:plan.reference)
        async let decimalsWork=decimals(plan.reference,tag:.string("latest"))
        let (nonce,native,asset,decimals)=try await (nonceWork,nativeWork,assetWork,decimalsWork)
        guard try Self.uint(nonce)==plan.nonce else { throw ArcSendError.changed }
        guard decimals==plan.decimals else { throw ArcSendError.metadataChanged }
        guard !ArcSendAmount.less(native,String(plan.fee)) else { throw SendFeeFundingError.insufficientNativeBalance }
        guard !ArcSendAmount.less(asset ?? native,plan.amount),
              (try plan.reference != "native" || !ArcSendAmount.less(native,ArcSendAmount.add(plan.amount,String(plan.fee)))) else { throw ArcSendError.insufficientFunds }
        try await simulation
    }
    public func submit(_ signed:ArcSignedSend,plan:ArcSendPlan,reconcileFirst:Bool = true) async throws -> ArcSendReceipt {
        guard plan.network==network else { throw ArcSendError.wrongNetwork };try ArcSendCrypto.verify(signed,plan:plan)
        // No re-signing or nonce advancement after an ambiguous send.
        if reconcileFirst {
            let current=try await status(signed,plan:plan)
            if current.outcome != .unknown { return current }
        } else { try plan.validate() } // Only a fresh, authorized, journaled send may bypass recovery reads.
        let result=try await rpc("eth_sendRawTransaction",[.string("0x"+TronSendCrypto.hex(signed.bytes))])
        guard result.string?.lowercased()==signed.hash else { throw ArcSendError.changed }
        return .init(hash:signed.hash,outcome:.accepted)
    }
    public func status(_ signed:ArcSignedSend,plan:ArcSendPlan) async throws -> ArcSendReceipt {
        guard plan.network==network else { throw ArcSendError.wrongNetwork };try ArcSendCrypto.verify(signed,plan:plan)
        async let receiptWork=rpc("eth_getTransactionReceipt",[.string(signed.hash)])
        async let transactionWork=rpc("eth_getTransactionByHash",[.string(signed.hash)])
        let (receipt,tx)=try await (receiptWork,transactionWork)
        if !tx.isNull { try matches(tx,signed:signed,plan:plan) }
        if !receipt.isNull {
            guard !tx.isNull else { return .init(hash:signed.hash,outcome:.unknown) }
            return try await settled(receipt,tx:tx,signed:signed,plan:plan)
        }
        // A mempool entry is acceptance, never confirmation. Even after provider
        // eviction an EVM signature has no time expiry, so keep its reservation.
        let final=try await block(.string("finalized")),height=try Self.uint(final["number"])
        let consumed=try await Self.uint(rpc("eth_getTransactionCount",[.string(plan.sender),Self.hex(height)]))
        if consumed>plan.nonce {
            return try await replacement(signed,plan:plan,through:height)
        }
        return .init(hash:signed.hash,outcome:tx.isNull ? .unknown:.accepted)
    }
    private func matches(_ tx:SolanaJSON,signed:ArcSignedSend,plan:ArcSendPlan) throws {
        guard tx["hash"].string?.lowercased()==signed.hash,tx["from"].string?.lowercased()==plan.sender,
              tx["to"].string?.lowercased()==plan.receiver,try Self.uint(tx["chainId"])==network.chainID,
              try Self.uint(tx["type"])==2,try Self.uint(tx["nonce"])==plan.nonce,try Self.uint(tx["gas"])==plan.gasLimit,
              try Self.uint(tx["maxFeePerGas"])==plan.maxFeePerGas,try Self.uint(tx["maxPriorityFeePerGas"])==plan.maxPriorityFeePerGas,
              try Self.quantity(tx["value"])==plan.value,tx["input"].string?.lowercased()=="0x"+TronSendCrypto.hex(try ArcSendCrypto.data(plan)) else { throw ArcSendError.changed }
    }
    private func settled(_ receipt:SolanaJSON,tx:SolanaJSON,signed:ArcSignedSend,plan:ArcSendPlan) async throws -> ArcSendReceipt {
        let height=try Self.uint(receipt["blockNumber"])
        guard receipt["transactionHash"].string?.lowercased()==signed.hash,receipt["from"].string?.lowercased()==plan.sender,
              receipt["to"].string?.lowercased()==plan.receiver,let hash=receipt["blockHash"].string,AnkrQuantity.hash(hash),
              tx["blockHash"].string==hash,try Self.uint(tx["blockNumber"])==height else { throw ArcSendError.changed }
        async let blockWork=block(Self.hex(height))
        async let finalWork = OathDiagnostics.attemptOptional("arc_receipt_finality", body: {
            try await Self.uint(self.block(.string("finalized"))["number"])
        })
        async let headWork=block(.string("latest"))
        let (included,final,head)=try await (blockWork,finalWork,headWork)
        try Task.checkCancellation()
        guard let canonicalHash=included["hash"].string,AnkrQuantity.hash(canonicalHash),
              try Self.uint(included["number"])==height else { throw ArcSendError.changed }
        // A valid block replacing this receipt's block is a reorg, not failure.
        guard canonicalHash==hash else { return .init(hash:signed.hash,outcome:.accepted) }
        // Flashblock/preconfirmation receipts can precede a sealed block.
        guard try Self.uint(head["number"])>=height else { return .init(hash:signed.hash,outcome:.accepted) }
        let gas=try Self.uint(receipt["gasUsed"]),price=try Self.uint(receipt["effectiveGasPrice"]),status=try Self.uint(receipt["status"])
        guard gas<=plan.gasLimit,price<=plan.maxFeePerGas,status<=1 else { throw ArcSendError.malformed }
        let success=status==1
        var delivered:String?
        if success,plan.reference != "native" {
            guard let logs=receipt["logs"].array,logs.count<=10_000 else { throw ArcSendError.malformed }
            let from="0x"+String(repeating:"0",count:24)+plan.sender.dropFirst(2),to="0x"+String(repeating:"0",count:24)+plan.recipient.dropFirst(2)
            var transferred="0"
            for log in logs where log["address"].string?.lowercased()==plan.reference {
                if let topics=log["topics"].array,topics.map({$0.string?.lowercased()})==[ArcIdentity.transferTopic,from,to] {
                    transferred=try ArcSendAmount.add(transferred,Self.quantity(log["data"]))
                }
            }
            delivered=transferred
            if transferred != plan.amount {
                OathDiagnostics.record(ArcSendError.execution,component:"arc_send",operation:"verify_token_delivery",context:["chain":"arc","stage":"receipt"])
            }
        }
        if final.map({ $0 >= height }) != true {
            return .init(hash:signed.hash,outcome:.accepted,inclusion:.init(succeeded:success,
                blockHash:hash,fee:gas*price,height:height,timestamp:Double(try Self.uint(included["timestamp"])),deliveredAmount:delivered))
        }
        return .init(hash:signed.hash,outcome:success ? .confirmed:.failed,fee:gas*price,height:height,timestamp:Double(try Self.uint(included["timestamp"])),deliveredAmount:delivered)
    }
    private func replacement(_ signed:ArcSignedSend,plan:ArcSendPlan,through:UInt64) async throws -> ArcSendReceipt {
        guard through>=plan.blockHeight else { throw ArcSendError.changed }
        var low=plan.blockHeight,high=through
        // Find the first finalized block where this nonce was consumed. Bounded
        // binary search, never scan the entire chain or infer cancellation by age.
        for _ in 0..<63 {
            if low>=high { break };let mid=low+(high-low)/2
            let nonce=try await Self.uint(rpc("eth_getTransactionCount",[.string(plan.sender),Self.hex(mid)]))
            if nonce>plan.nonce { high=mid } else { low=mid+1 }
        }
        let candidate=try await block(Self.hex(low),full:true)
        guard let rows=candidate["transactions"].array,rows.count<=100_000 else { throw ArcSendError.malformed }
        for tx in rows where tx["from"].string?.lowercased()==plan.sender {
            if try Self.uint(tx["nonce"])==plan.nonce {
                guard let hash=tx["hash"].string?.lowercased(),AnkrQuantity.hash(hash) else { throw ArcSendError.malformed }
                if hash==signed.hash { return .init(hash:signed.hash,outcome:.accepted) }
                let cancelled=try tx["to"].string?.lowercased()==plan.sender && Self.quantity(tx["value"])=="0" && tx["input"].string=="0x"
                return .init(hash:signed.hash,outcome:cancelled ? .cancelled:.replaced,replacementHash:hash)
            }
        }
        // An incomplete/pruned provider cannot prove replacement.
        throw ArcSendError.malformed
    }
}
