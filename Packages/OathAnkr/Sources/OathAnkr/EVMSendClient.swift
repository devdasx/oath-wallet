import Foundation
import OathDiagnostics

public actor EVMSendClient {
    public nonisolated let network:EVMSendNetwork
    private let transport:any AnkrTransport
    private let endpoints:[URL]
    private let permits=AnkrPermits(count:4)
    private var verifiedEndpoints:[URL:Date] = [:]
    public init(network:EVMSendNetwork,endpoints:[URL],transport:any AnkrTransport = AnkrHTTPTransport()) throws {
        guard !endpoints.isEmpty,endpoints.count<=4,endpoints.allSatisfy({$0.scheme=="https" && $0.host != nil}) else { throw EVMSendError.configuration }
        self.network=network;self.transport=transport;self.endpoints=endpoints
    }
    /// Each request verifies the chain on the same provider, including fallbacks.
    /// One bounded attempt per endpoint; never turn a rejected transaction into success.
    private func rpc(_ method:String,_ params:[SolanaJSON], optionalContractProbe: Bool = false) async throws -> SolanaJSON {
        try await permits.acquire()
        do {
            var failure:Error=EVMSendError.transport
            for endpoint in endpoints {
                do {
                    try Task.checkCancellation()
                    if method == "eth_sendRawTransaction", verifiedEndpoints[endpoint].map({ (0..<30).contains(Date.now.timeIntervalSince($0)) }) != true {
                        let check:SolanaJSON = .object(["jsonrpc":.string("2.0"),"id":.number("0"),"method":.string("eth_chainId"),"params":.array([])])
                        var request=URLRequest(url:endpoint);request.httpMethod="POST";request.timeoutInterval=10
                        request.setValue("application/json",forHTTPHeaderField:"Content-Type");request.httpBody=try JSONEncoder().encode(check)
                        let (data,status)=try await transport.send(request)
                        DiagnosticHTTP.response(data,status:status,request:request)
                        guard (200...299).contains(status) else { throw EVMSendError.http(status) }
                        let reply=try JSONDecoder().decode(SolanaJSON.self,from:data)
                        guard reply["id"].integer==0,reply["jsonrpc"].string=="2.0",try Self.uint(result(reply))==network.chainID else { throw EVMSendError.wrongNetwork }
                    }
                    let body:SolanaJSON = .array([
                        .object(["jsonrpc":.string("2.0"),"id":.number("0"),"method":.string("eth_chainId"),"params":.array([])]),
                        .object(["jsonrpc":.string("2.0"),"id":.number("1"),"method":.string(method),"params":.array(params)])])
                    var request=URLRequest(url:endpoint);request.httpMethod="POST";request.timeoutInterval=10
                    request.setValue("application/json",forHTTPHeaderField:"Content-Type");request.httpBody=try JSONEncoder().encode(body)
                    let (data,status)=try await transport.send(request)
                    DiagnosticHTTP.response(data,status:status,request:request)
                    guard (200...299).contains(status) else { throw EVMSendError.http(status) }
                    guard data.count<=8_388_608,let rows=try JSONDecoder().decode(SolanaJSON.self,from:data).array,rows.count==2,
                          rows.allSatisfy({$0["jsonrpc"].string=="2.0"}),
                          let chain=rows.first(where:{$0["id"].integer==0}),let result=rows.first(where:{$0["id"].integer==1}) else { throw EVMSendError.malformed }
                    guard try Self.uint(self.result(chain))==network.chainID else { throw EVMSendError.wrongNetwork }
                    verifiedEndpoints[endpoint] = .now
                    let value=try self.result(result, optionalContractProbe: optionalContractProbe)
                    await permits.release();return value
                } catch {
                    verifiedEndpoints.removeValue(forKey:endpoint)
                    OathDiagnostics.record(error,component:"evm_send",operation:method,context:["chain":network.rawValue,"rpc_method":method])
                    if error is CancellationError || Task.isCancelled { throw CancellationError() }
                    // Deterministic RPC rejection must remain visible. Network/HTTP,
                    // malformed and misrouted providers may use an independent fallback.
                    if case EVMSendError.rpc(let code) = error, code != -32601 && code != -32004 { throw error }
                    failure=error
                }
            }
            throw failure
        } catch { await permits.release();OathDiagnostics.record(error,component:"evm_send",operation:method,context:["chain":network.rawValue]);throw error }
    }
    private func result(_ j:SolanaJSON, optionalContractProbe: Bool = false) throws -> SolanaJSON {
        // JSON-RPC errors use signed codes (for example -32000). The quantity
        // accessor is intentionally unsigned and must not be used here.
        if case .number(let raw)=j["error"]["code"],let code=Int(raw) {
            // An absent optional ERC-20 method is expected discovery, not a
            // failed transaction. Transport and other provider errors still
            // pass through shared diagnostics; no metadata is fabricated.
            if optionalContractProbe, [3, -32000, -32015].contains(code),
               j["error"]["message"].string?.lowercased().contains("revert") == true { return .null }
            OathDiagnostics.record(DiagnosticFailure(j["error"]["message"].string ?? "RPC rejected"),component:"evm_send",operation:"rpc_response",context:["chain":network.rawValue,"rpc_code":String(code)])
            throw EVMSendError.rpc(code)
        }
        guard case .object(let obj)=j,let result=obj["result"],j["error"].isNull else { throw EVMSendError.malformed }
        return result // null is expected for transactions/receipts not yet visible.
    }
    static func quantity(_ j:SolanaJSON) throws -> String {
        guard let raw=j.string,raw.hasPrefix("0x") else { throw EVMSendError.malformed }
        return try EVMSendAmount.checked(AnkrQuantity.decimal(raw))
    }
    static func uint(_ j:SolanaJSON) throws -> UInt64 {
        guard let n=UInt64(try quantity(j)) else { throw EVMSendError.malformed };return n
    }
    private static func hex(_ n:UInt64)->SolanaJSON { .string("0x"+String(n,radix:16)) }
    private func block(_ tag:SolanaJSON,full:Bool=false) async throws -> SolanaJSON { try await rpc("eth_getBlockByNumber",[tag,.bool(full)]) }
    private func call(_ ref:String,_ data:String,_ tag:SolanaJSON) async throws -> SolanaJSON { try await rpc("eth_call",[.object(["to":.string(ref),"data":.string(data)]),tag]) }
    public func balance(owner:String,reference:String) async throws -> String {
        try await balance(owner:EVMSendIdentity.address(owner),reference:EVMSendIdentity.reference(reference),tag:.string("latest"))
    }
    private func balance(owner:String,reference:String,tag:SolanaJSON) async throws -> String {
        if reference == "native" { return try await Self.quantity(rpc("eth_getBalance",[.string(owner),tag])) }
        return try await Self.quantity(call(reference,"0x70a08231"+String(repeating:"0",count:24)+owner.dropFirst(2),tag))
    }
    public func balancesAfter(_ plan:EVMSendPlan,minimumHeight:UInt64) async throws -> (native:String,asset:String,height:UInt64) {
        guard plan.network==network else { throw EVMSendError.wrongNetwork }
        let head=try await block(.string("latest")),height=try Self.uint(head["number"])
        guard height>=minimumHeight,height<=UInt64(Int64.max),let hash=head["hash"].string,AnkrQuantity.hash(hash) else { throw EVMSendError.changed }
        // Pin the read to one post-receipt block wherever historical state is
        // supported. HyperEVM exposes only latest state.
        let tag=network == .hyperevm ? SolanaJSON.string("latest"):Self.hex(height)
        async let nativeWork=balance(owner:plan.sender,reference:"native",tag:tag)
        async let tokenWork:String? = plan.reference == "native" ? nil:balance(owner:plan.sender,reference:plan.reference,tag:tag)
        let (native,token)=try await (nativeWork,tokenWork)
        guard try await block(Self.hex(height))["hash"].string==hash else { throw EVMSendError.changed }
        return (native,token ?? native,height)
    }
    private func decimals(_ ref:String,tag:SolanaJSON) async throws -> Int {
        if ref == "native" { return 18 }
        let n=try await Self.uint(call(ref,"0x313ce567",tag));guard n<=255 else { throw EVMSendError.metadataChanged };return Int(n)
    }
    /// Supports ERC-20 and NFT names without requiring a balance, decimals(), or
    /// totalSupply(). Each optional field is independent; one missing method must
    /// not discard another field that the contract does expose.
    public func permissionIdentity(address: String) async throws -> ContractIdentity? {
        let address = try EVMSendIdentity.address(address)
        func probe(_ selector: String) async throws -> SolanaJSON {
            do {
                return try await DiagnosticHTTP.$optionalEVMMetadataProbe.withValue(true) {
                    try await rpc("eth_call", [.object(["to": .string(address), "data": .string(selector)]), .string("latest")], optionalContractProbe: true)
                }
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                OathDiagnostics.record(error, component: "permissions", operation: "identity_field", context: ["chain": network.rawValue])
                return .null
            }
        }
        async let n = probe("0x06fdde03")
        async let s = probe("0x95d89b41")
        async let d = probe("0x313ce567")
        let (nameValue, symbolValue, decimalsValue) = try await (n, s, d)
        let symbol = ContractIdentity.abiText(symbolValue.string)
        guard let name = ContractIdentity.abiText(nameValue.string) ?? symbol else { return nil }
        // Invalid optional decimal responses remain unknown, never assumed 18.
        let decimals = (try? Self.uint(decimalsValue)).flatMap { $0 <= 255 ? Int($0) : nil }
        return try .init(network: network.rawValue, address: address, name: name, symbol: symbol, decimals: decimals, source: .onChain)
    }
    public func walletConnectApprovalToken(_ request: WalletConnectEVMRequest) async throws -> WalletConnectApprovalToken? {
        let action = WalletConnectEVMAction(request)
        guard request.chainID == network.chainID, action.kind == .approval,
              let spender = action.fields.first(where: { $0.label == .spender })?.value else { return nil }
        let ownerWord = String(repeating: "0", count: 24) + request.sender.dropFirst(2)
        let spenderWord = String(repeating: "0", count: 24) + spender.dropFirst(2)
        func probe(_ data: String) async throws -> String? {
            let result = try await DiagnosticHTTP.$optionalEVMMetadataProbe.withValue(true) {
                try await rpc("eth_call", [.object(["to": .string(request.recipient), "data": .string(data)]), .string("latest")], optionalContractProbe: true)
            }
            guard let hex = result.string, hex.count == 66 else { return nil }
            return try EVMSendAmount.checked(AnkrQuantity.decimal(hex))
        }
        async let decimalWork = probe("0x313ce567")
        async let balanceWork = probe("0x70a08231" + ownerWord)
        async let allowanceWork = probe("0xdd62ed3e" + ownerWord + spenderWord)
        async let nftWork = probe("0x01ffc9a780ac58cd" + String(repeating: "0", count: 56))
        let (rawDecimals, balance, allowance, nft) = try await (decimalWork, balanceWork, allowanceWork, nftWork)
        guard let rawDecimals, let decimals = Int(rawDecimals), (0...36).contains(decimals),
              let balance, let allowance, nft == nil || nft == "0" else { return nil }
        return .init(contract: request.recipient, decimals: decimals, balance: balance, allowance: allowance)
    }
    private func transaction(_ plan:EVMSendPlan,gas:Bool=true) throws -> SolanaJSON {
        var obj:[String:SolanaJSON] = ["from":.string(plan.sender),"to":.string(plan.receiver),"value":.string(try EVMSendAmount.hex(plan.value)),
            "data":.string("0x"+TronSendCrypto.hex(try EVMSendCrypto.data(plan))),"nonce":Self.hex(plan.nonce)]
        if plan.legacy { obj["gasPrice"]=Self.hex(plan.maxFeePerGas) }
        else { obj["maxFeePerGas"]=Self.hex(plan.maxFeePerGas);obj["maxPriorityFeePerGas"]=Self.hex(plan.maxPriorityFeePerGas);obj["type"] = .string("0x2") }
        if plan.removal?.kind == .delegation {
            // Estimate the complete type-4 envelope, including L1 data charges.
            // This tuple is unexecutable: EIP-7702 rejects nonce UInt64.max.
            // Nonzero signature bytes conservatively model the signed payload;
            // no wallet authorization is created before user authentication.
            obj["type"] = .string("0x4")
            obj["authorizationList"] = .array([.object(["chainId":Self.hex(plan.network.chainID),"address":.string(EVMPermissionRemoval.zero),"nonce":Self.hex(UInt64.max),"yParity":.string("0x1"),"r":.string("0x"+String(repeating:"7f",count:32)),"s":.string("0x"+String(repeating:"7f",count:32))])])
        }
        if gas { obj["gas"]=Self.hex(plan.gasLimit) };return .object(obj)
    }
    public func quote(sender:String,recipient:String,reference:String,decimals:Int,amount:String,maximum:Bool=false,removal:EVMPermissionRemoval?=nil,request:WalletConnectEVMRequest?=nil) async throws -> EVMSendPlan {
        let sender=try EVMSendIdentity.address(sender),recipient=try EVMSendIdentity.address(recipient),reference=try EVMSendIdentity.reference(reference)
        let requested=try EVMSendAmount.checked(amount)
        if let request {
            guard request.chainID==network.chainID,request.sender==sender,request.recipient==recipient,request.value==requested,
                  reference=="native",decimals==18,!maximum,removal==nil else { throw EVMSendError.changed }
            try request.call.validate()
        }
        if let removal {
            try removal.validate()
            guard reference=="native",decimals==18,amount=="0",!maximum,recipient==removal.contract else { throw PermissionError.changed }
            guard try await permissionState(owner:sender,removal:removal)==removal.expected else { throw PermissionError.changed }
        }
        guard (requested != "0" || removal != nil || request != nil),(sender != recipient || removal?.kind == .delegation || request != nil),recipient != "0x"+String(repeating:"0",count:40) else { throw EVMSendError.amount }
        let head=try await block(.string("latest")),height=try Self.uint(head["number"])
        guard let hash=head["hash"].string,AnkrQuantity.hash(hash),abs(Double(try Self.uint(head["timestamp"]))-Date.now.timeIntervalSince1970)<60 else { throw EVMSendError.expired }
        let tag=SolanaJSON.string(network.stateTag)
        let hasBaseFee = !head["baseFeePerGas"].isNull
        let legacy=request?.legacy ?? !hasBaseFee
        guard legacy || hasBaseFee else { throw EVMSendError.wrongNetwork }
        let base=hasBaseFee ? try Self.uint(head["baseFeePerGas"]) : 0
        async let nativeWork=balance(owner:sender,reference:"native",tag:tag)
        async let tokenWork:String? = reference == "native" ? nil:balance(owner:sender,reference:reference,tag:tag)
        async let decimalsWork=self.decimals(reference,tag:tag)
        async let nonceWork=rpc("eth_getTransactionCount",[.string(sender),tag])
        async let pendingWork=rpc("eth_getTransactionCount",[.string(sender),.string(network.nonceTag)])
        async let priceWork=rpc("eth_gasPrice",[])
        let (native,token,actualDecimals,nonceJSON,pendingJSON,priceJSON)=try await (nativeWork,tokenWork,decimalsWork,nonceWork,pendingWork,priceWork)
        let nonce=try Self.uint(nonceJSON),pending=try Self.uint(pendingJSON),price=try Self.uint(priceJSON),asset=token ?? native
        guard actualDecimals==decimals else { throw EVMSendError.metadataChanged }
        if removal?.kind == .delegation { guard !legacy,recipient==sender,nonce<UInt64.max-1,try await rpc("eth_getCode",[.string(EVMPermissionRemoval.zero),.string("latest")]).string=="0x" else {throw PermissionError.unsupported} }
        guard nonce==pending else { throw EVMSendError.busy }
        guard request?.nonce == nil || request?.nonce == nonce else { throw EVMSendError.changed }
        guard base<=100_000_000_000_000,price>0,price<=100_000_000_000_000 else { throw EVMSendError.feeTooHigh }
        var tip=legacy ? 0 : (price>base ? price-base:0)
        var ceiling=legacy ? (request?.gasPrice ?? price) : (request?.maxFeePerGas ?? max(price,base*2+tip))
        tip = legacy ? 0 : (request?.maxPriorityFeePerGas ?? min(tip,ceiling))
        guard ceiling>=base,ceiling>0,ceiling<=100_000_000_000_000,tip<=ceiling else { throw EVMSendError.feeTooHigh }
        let want=maximum ? asset:requested
        guard !EVMSendAmount.less(asset,want),(want != "0" || removal != nil || request != nil) else { throw EVMSendError.insufficientFunds }
        let now=Date.now
        func make(_ gas:UInt64,_ value:String,_ extra:UInt64=0) -> EVMSendPlan {
            .init(network:network,sender:sender,recipient:recipient,reference:reference,decimals:decimals,requestedAmount:want,
                  amount:value,assetBalance:asset,nativeBalance:native,nonce:nonce,gasLimit:gas,maxFeePerGas:ceiling,maxPriorityFeePerGas:tip,blockHeight:height,createdAt:now,legacy:legacy,extraFee:extra,removal:removal,call:request?.call)
        }
        // Max needs a provisional value before its gas reserve is known. An
        // ordinary payment must estimate with the actual value: a payable
        // recipient can reject zero or take a different execution path.
        // Neither probe is signed; the final positive payload is simulated below.
        let probe=make(EVMSendPlan.maximumGas,reference == "native" && (maximum || want==native) ? "0":want)
        let estimate:UInt64
        if network == .linea && removal?.kind != .delegation {
            // Linea computes a calldata-dependent priority fee. Supplying the
            // provisional eth_gasPrice cap makes the node reject its own higher
            // recommendation before it can return an estimate.
            let payload:SolanaJSON = .object(["from":.string(sender),"to":.string(probe.receiver),
                "value":.string(try EVMSendAmount.hex(reference == "native" && !maximum ? want:probe.value)),
                "data":.string("0x"+TronSendCrypto.hex(try EVMSendCrypto.data(probe)))])
            let line = try await rpc("linea_estimateGas",[payload])
            estimate=try Self.uint(line["gasLimit"])
            let base=try Self.uint(line["baseFeePerGas"]),priority=try Self.uint(line["priorityFeePerGas"])
            guard base<=100_000_000_000_000,priority<=100_000_000_000_000 else { throw EVMSendError.feeTooHigh }
            if request?.gasPrice != nil || request?.maxFeePerGas != nil {
                guard ceiling>=base+priority,(legacy || tip>=priority) else { throw EVMSendError.feeTooHigh }
            } else { tip=priority;ceiling=max(ceiling,base*2+priority) }
        } else { estimate=try await Self.uint(rpc("eth_estimateGas",[transaction(probe,gas:false),.string("latest")])) }
        guard estimate>=21_000,estimate<=network.maximumGas else { throw EVMSendError.feeTooHigh }
        let intrinsic=removal?.kind == .delegation ? max(46_000,estimate):estimate
        guard intrinsic<=network.maximumGas else {throw EVMSendError.feeTooHigh}
        let gas=request?.gas ?? (intrinsic==21_000 ? intrinsic:min(network.maximumGas,intrinsic+intrinsic/5+1_000))
        guard gas>=intrinsic,gas<=network.maximumGas else { throw EVMSendError.feeTooHigh }
        let product=gas.multipliedReportingOverflow(by:ceiling)
        guard !product.overflow,product.partialValue<=EVMSendPlan.maximumFee else { throw EVMSendError.feeTooHigh }
        let extra=try await extraFee(make(gas,want))
        let total=product.partialValue.addingReportingOverflow(extra)
        guard !total.overflow,total.partialValue<=EVMSendPlan.maximumFee else { throw EVMSendError.feeTooHigh }
        let available=try EVMSendAmount.subtract(native,String(total.partialValue))
        if request != nil,EVMSendAmount.less(available,want) { throw EVMSendError.insufficientFunds }
        let value=reference == "native" && EVMSendAmount.less(available,want) ? available:want
        let plan=make(gas,value,extra);try plan.validate()
        try await simulate(plan)
        let check=try await block(Self.hex(height))
        guard check["hash"].string==hash else { throw EVMSendError.changed }
        return plan
    }
    private static func selector(_ signature:String) -> Data { Data(TronSendCrypto.keccak(Data(signature.utf8)).prefix(4)) }
    private func oracleUInt(_ oracle:String,_ signature:String,_ value:UInt64,_ tag:SolanaJSON = .string("latest")) async throws -> UInt64 {
        let data=Self.selector(signature)+(try TronSendCrypto.uint256(String(value)))
        return try await Self.uint(call(oracle,"0x"+TronSendCrypto.hex(data),tag))
    }
    private func extraFee(_ plan:EVMSendPlan,buffer:Bool=true) async throws -> UInt64 {
        guard let oracle=network.oracle else { return 0 }
        let bytes=try EVMSendCrypto.unsignedBytes(plan)
        let l1:UInt64,operatorFee:UInt64
        if network.opStack {
            async let dataCost=oracleUInt(oracle,"getL1FeeUpperBound(uint256)",UInt64(bytes.count))
            async let execution=oracleUInt(oracle,"getOperatorFee(uint256)",plan.gasLimit)
            (l1,operatorFee)=try await (dataCost,execution)
        } else {
            let padding=(32-bytes.count%32)%32
            let data=try Self.selector("getL1Fee(bytes)")+TronSendCrypto.uint256("32")+TronSendCrypto.uint256(String(bytes.count))+bytes+Data(repeating:0,count:padding)
            l1=try await Self.uint(call(oracle,"0x"+TronSendCrypto.hex(data),.string("latest")));operatorFee=0
        }
        let sum=l1.addingReportingOverflow(operatorFee)
        let reserve=sum.partialValue.multipliedReportingOverflow(by:buffer ? 2:1)
        guard !sum.overflow,!reserve.overflow,reserve.partialValue<=EVMSendPlan.maximumFee else { throw EVMSendError.feeTooHigh }
        return reserve.partialValue
    }
    private func actualFee(_ receipt:SolanaJSON,gas:UInt64,price:UInt64,height:UInt64) async throws -> UInt64 {
        let execution=gas.multipliedReportingOverflow(by:price)
        var extra:UInt64=0
        if network.oracle != nil {
            extra=try Self.uint(receipt["l1Fee"])
            if network.opStack,let oracle=network.oracle {
                let op=try await oracleUInt(oracle,"getOperatorFee(uint256)",gas,Self.hex(height))
                let sum=extra.addingReportingOverflow(op);guard !sum.overflow else { throw EVMSendError.malformed };extra=sum.partialValue
            }
        }
        let total=execution.partialValue.addingReportingOverflow(extra)
        guard !execution.overflow,!total.overflow else { throw EVMSendError.malformed }
        return total.partialValue
    }
    private func simulate(_ plan:EVMSendPlan) async throws {
        async let estimate=rpc("eth_estimateGas",[transaction(plan),.string("latest")])
        async let result=rpc("eth_call",[transaction(plan),.string("latest")])
        let (used,output)=try await (estimate,result)
        guard try Self.uint(used)<=plan.gasLimit else { throw EVMSendError.feeTooHigh }
        guard let raw=output.string,raw.hasPrefix("0x") else { throw EVMSendError.malformed }
        let tokenCall = plan.call.map { ["095ea7b3","a9059cbb","23b872dd"].contains(TronSendCrypto.hex($0.bytes.prefix(4))) } ?? false
        if plan.reference != "native" || plan.removal?.kind == .token || tokenCall,raw != "0x" {
            guard raw.count==66,try Self.quantity(output)=="1" else { throw EVMSendError.simulationFailed }
        }
    }
    public func preflight(_ plan:EVMSendPlan) async throws {
        try plan.validate();guard plan.network==network else { throw EVMSendError.wrongNetwork }
        if let removal=plan.removal {
            guard try await permissionState(owner:plan.sender,removal:removal)==removal.expected else { throw EVMSendError.changed }
        }
        async let nonceWork=rpc("eth_getTransactionCount",[.string(plan.sender),.string(network.nonceTag)])
        async let latestNonceWork=rpc("eth_getTransactionCount",[.string(plan.sender),.string(network.stateTag)])
        async let nativeWork=balance(owner:plan.sender,reference:"native")
        async let assetWork:String? = plan.reference == "native" ? nil:balance(owner:plan.sender,reference:plan.reference)
        async let decimalsWork=decimals(plan.reference,tag:.string("latest"))
        let (nonce,latestNonce,native,asset,decimals)=try await (nonceWork,latestNonceWork,nativeWork,assetWork,decimalsWork)
        guard try Self.uint(nonce)==plan.nonce else { throw EVMSendError.changed }
        // A pending predecessor (including one removed by a reorg) must not be
        // treated as mined just because the mempool advertises the next nonce.
        guard try Self.uint(latestNonce)==plan.nonce else { throw EVMSendError.busy }
        guard decimals==plan.decimals else { throw EVMSendError.metadataChanged }
        guard !EVMSendAmount.less(asset ?? native,plan.amount),!EVMSendAmount.less(native,String(plan.fee)),
              (try plan.reference != "native" || !EVMSendAmount.less(native,EVMSendAmount.add(plan.amount,String(plan.fee)))) else { throw EVMSendError.insufficientFunds }
        async let simulation:Void=simulate(plan)
        let currentExtra=try await extraFee(plan,buffer:false)
        guard currentExtra<=plan.extraFee else { throw EVMSendError.changed }
        try await simulation
    }
    public func submit(_ signed:EVMSignedSend,plan:EVMSendPlan,reconcileFirst:Bool = true) async throws -> EVMSendReceipt {
        guard plan.network==network else { throw EVMSendError.wrongNetwork };try EVMSendCrypto.verify(signed,plan:plan)
        // No re-signing or nonce advancement after an ambiguous send.
        if reconcileFirst {
            let current=try await status(signed,plan:plan)
            if current.outcome != .unknown { return current }
        } else { try plan.validate() } // Only a fresh, authorized, journaled send may bypass recovery reads.
        let result=try await rpc("eth_sendRawTransaction",[.string("0x"+TronSendCrypto.hex(signed.bytes))])
        guard result.string?.lowercased()==signed.hash else { throw EVMSendError.changed }
        return .init(hash:signed.hash,outcome:.accepted)
    }
    public func status(_ signed:EVMSignedSend,plan:EVMSendPlan) async throws -> EVMSendReceipt {
        guard plan.network==network else { throw EVMSendError.wrongNetwork };try EVMSendCrypto.verify(signed,plan:plan)
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
        let final=try await block(.string(network.finalityTag)),height=try Self.uint(final["number"])
        if network == .hyperevm { return .init(hash:signed.hash,outcome:tx.isNull ? .unknown:.accepted) }
        let consumed=try await Self.uint(rpc("eth_getTransactionCount",[.string(plan.sender),Self.hex(height)]))
        if consumed>plan.nonce {
            return try await replacement(signed,plan:plan,through:height)
        }
        return .init(hash:signed.hash,outcome:tx.isNull ? .unknown:.accepted)
    }
    private func matches(_ tx:SolanaJSON,signed:EVMSignedSend,plan:EVMSendPlan) throws {
        guard tx["hash"].string?.lowercased()==signed.hash,tx["from"].string?.lowercased()==plan.sender,
              tx["to"].string?.lowercased()==plan.receiver,try Self.uint(tx["chainId"])==network.chainID,
              try Self.uint(tx["type"])==(plan.legacy ? 0:plan.removal?.kind == .delegation ? 4:2),try Self.uint(tx["nonce"])==plan.nonce,try Self.uint(tx["gas"])==plan.gasLimit,
              try Self.uint(tx[plan.legacy ? "gasPrice":"maxFeePerGas"])==plan.maxFeePerGas,
              (try plan.legacy || Self.uint(tx["maxPriorityFeePerGas"])==plan.maxPriorityFeePerGas),
              try Self.quantity(tx["value"])==plan.value,tx["input"].string?.lowercased()=="0x"+TronSendCrypto.hex(try EVMSendCrypto.data(plan)) else { throw EVMSendError.changed }
    }
    private func settled(_ receipt:SolanaJSON,tx:SolanaJSON,signed:EVMSignedSend,plan:EVMSendPlan) async throws -> EVMSendReceipt {
        let height=try Self.uint(receipt["blockNumber"])
        guard receipt["transactionHash"].string?.lowercased()==signed.hash,receipt["from"].string?.lowercased()==plan.sender,
              receipt["to"].string?.lowercased()==plan.receiver,let hash=receipt["blockHash"].string,AnkrQuantity.hash(hash),
              tx["blockHash"].string==hash,try Self.uint(tx["blockNumber"])==height else { throw EVMSendError.changed }
        async let blockWork=block(Self.hex(height))
        async let finalWork=block(.string(network.finalityTag))
        let (included,final)=try await (blockWork,finalWork)
        guard included["hash"].string==hash else { throw EVMSendError.changed }
        if try Self.uint(final["number"])<height { return .init(hash:signed.hash,outcome:.accepted) }
        let gas=try Self.uint(receipt["gasUsed"]),price=try Self.uint(receipt["effectiveGasPrice"]),status=try Self.uint(receipt["status"])
        guard gas<=plan.gasLimit,price<=plan.maxFeePerGas,status<=1 else { throw EVMSendError.malformed }
        let success=status==1
        var delivered:String?
        if success,plan.reference != "native" {
            guard let logs=receipt["logs"].array,logs.count<=10_000 else { throw EVMSendError.malformed }
            let from="0x"+String(repeating:"0",count:24)+plan.sender.dropFirst(2),to="0x"+String(repeating:"0",count:24)+plan.recipient.dropFirst(2)
            var transferred="0"
            for log in logs where log["address"].string?.lowercased()==plan.reference {
                if let topics=log["topics"].array,topics.map({$0.string?.lowercased()})==[EVMSendIdentity.transferTopic,from,to] {
                    transferred=try EVMSendAmount.add(transferred,Self.quantity(log["data"]))
                }
            }
            delivered=transferred
            if transferred != plan.amount {
                OathDiagnostics.record(EVMSendError.execution,component:"evm_send",operation:"verify_token_delivery",context:["chain":network.rawValue,"stage":"receipt"])
            }
        }
        return .init(hash:signed.hash,outcome:success ? .confirmed:.failed,fee:try await actualFee(receipt,gas:gas,price:price,height:height),height:height,timestamp:Double(try Self.uint(included["timestamp"])),deliveredAmount:delivered)
    }
    private func replacement(_ signed:EVMSignedSend,plan:EVMSendPlan,through:UInt64) async throws -> EVMSendReceipt {
        guard through>=plan.blockHeight else { throw EVMSendError.changed }
        var low=plan.blockHeight,high=through
        // Find the first finalized block where this nonce was consumed. Bounded
        // binary search, never scan the entire chain or infer cancellation by age.
        for _ in 0..<63 {
            if low>=high { break };let mid=low+(high-low)/2
            let nonce=try await Self.uint(rpc("eth_getTransactionCount",[.string(plan.sender),Self.hex(mid)]))
            if nonce>plan.nonce { high=mid } else { low=mid+1 }
        }
        let candidate=try await block(Self.hex(low),full:true)
        guard let rows=candidate["transactions"].array,rows.count<=100_000 else { throw EVMSendError.malformed }
        for tx in rows where tx["from"].string?.lowercased()==plan.sender {
            if try Self.uint(tx["nonce"])==plan.nonce {
                guard let hash=tx["hash"].string?.lowercased(),AnkrQuantity.hash(hash) else { throw EVMSendError.malformed }
                if hash==signed.hash { return .init(hash:signed.hash,outcome:.accepted) }
                let cancelled=try tx["to"].string?.lowercased()==plan.sender && Self.quantity(tx["value"])=="0" && tx["input"].string=="0x"
                return .init(hash:signed.hash,outcome:cancelled ? .cancelled:.replaced,replacementHash:hash)
            }
        }
        // An incomplete/pruned provider cannot prove replacement.
        throw EVMSendError.malformed
    }
}

extension EVMSendClient {
    public func permissionState(owner:String,removal r:EVMPermissionRemoval,atBlock:UInt64?=nil) async throws -> String {
        let owner=try EVMSendIdentity.address(owner),tag=atBlock.map(Self.hex) ?? .string("latest")
        guard try EVMSendIdentity.address(r.contract)==r.contract,try EVMSendIdentity.address(r.spender)==r.spender else { throw PermissionError.malformed }
        let data:Data
        switch r.kind {
        case .delegation: guard r.contract==owner else {throw PermissionError.changed};return try await accountDelegation(owner:owner,atBlock:atBlock) ?? EVMPermissionRemoval.zero
        case .token: data=try EVMPermissionRemoval.selector("allowance(address,address)")+EVMPermissionRemoval.word(owner)+EVMPermissionRemoval.word(r.spender)
        case .collection: data=try EVMPermissionRemoval.selector("isApprovedForAll(address,address)")+EVMPermissionRemoval.word(owner)+EVMPermissionRemoval.word(r.spender)
        case .collectible:
            guard let id=r.tokenID else { throw PermissionError.malformed }
            let ownerData=try EVMPermissionRemoval.selector("ownerOf(uint256)")+TronSendCrypto.uint256(id)
            let actual=try await call(r.contract,"0x"+TronSendCrypto.hex(ownerData),tag)
            guard actual.string?.lowercased()=="0x"+TronSendCrypto.hex(try EVMPermissionRemoval.word(owner)) else { return EVMPermissionRemoval.zero }
            data=try EVMPermissionRemoval.selector("getApproved(uint256)")+TronSendCrypto.uint256(id)
        case .permit2,.permit2Nonce:
            guard r.contract==EVMPermissionRemoval.permit2,let token=r.tokenID else { throw PermissionError.malformed }
            data=try EVMPermissionRemoval.selector("allowance(address,address,address)")+EVMPermissionRemoval.word(owner)+EVMPermissionRemoval.word(token)+EVMPermissionRemoval.word(r.spender)
        }
        guard let raw=try await call(r.contract,"0x"+TronSendCrypto.hex(data),tag).string,
              raw.hasPrefix("0x") else { throw PermissionError.malformed }
        let bytes=try TronIdentity.hex(raw)
        if r.kind == .permit2 || r.kind == .permit2Nonce {
            guard bytes.count==96,bytes.prefix(12).allSatisfy({$0==0}),
                  bytes[32..<58].allSatisfy({$0==0}),bytes[64..<90].allSatisfy({$0==0}) else { throw PermissionError.malformed }
            return try stride(from:0,to:96,by:32).map { try AnkrQuantity.decimal("0x"+TronSendCrypto.hex(bytes[$0..<$0+32])) }.joined(separator:":")
        }
        guard bytes.count==32 else { throw PermissionError.malformed }
        if r.kind == .collectible { guard bytes.prefix(12).allSatisfy({$0==0}) else { throw PermissionError.malformed };return "0x"+TronSendCrypto.hex(bytes.suffix(20)) }
        let n=try AnkrQuantity.decimal(raw)
        if r.kind == .collection && n != "0" && n != "1" { throw PermissionError.malformed }
        return n
    }
    public func permissionRemoved(owner:String,removal:EVMPermissionRemoval,atBlock:UInt64?=nil) async throws -> Bool {
        let state=try await permissionState(owner:owner,removal:removal,atBlock:atBlock)
        switch removal.kind {
        case .delegation: return state==EVMPermissionRemoval.zero
        case .collectible: return state != removal.spender
        case .permit2: return state.split(separator:":").first == "0"
        case .permit2Nonce:
            guard let nonce=UInt64(state.split(separator:":").last ?? ""),let previous=UInt64(removal.expected.split(separator:":").last ?? "") else { throw PermissionError.malformed }
            return nonce>previous
        default:return state=="0"
        }
    }
    public func accountDelegation(owner:String,atBlock:UInt64?=nil) async throws -> String? {
        let owner=try EVMSendIdentity.address(owner)
        guard let raw=try await rpc("eth_getCode",[.string(owner),atBlock.map(Self.hex) ?? .string("latest")]).string else { throw PermissionError.malformed }
        let bytes=try TronIdentity.hex(raw)
        if bytes.count==23,bytes.prefix(3)==Data([0xef,1,0]) { return "0x"+TronSendCrypto.hex(bytes.suffix(20)) }
        return nil // A non-delegated EOA, or an ordinary contract, has no EIP-7702 delegation.
    }
}
