import Foundation
import OathDiagnostics

public actor TronSendClient {
    public let network:TronSendNetwork
    private let endpoints:[URL]
    private let transport:any AnkrTransport
    private var verified=Set<URL>()
    public init(network:TronSendNetwork,apiKey:String? = nil,transport:any AnkrTransport = AnkrHTTPTransport()) throws {
        self.network=network;self.transport=transport
        if network == .mainnet,let apiKey,!apiKey.isEmpty {
            guard apiKey.count<=256,apiKey.utf8.allSatisfy({(48...57).contains($0)||(65...90).contains($0)||(97...122).contains($0)}) else { throw TronSendError.configuration }
            endpoints=[URL(string:"https://rpc.ankr.com/premium-http/tron")!.appendingPathComponent(apiKey),network.endpoint]
        } else { endpoints=[network.endpoint] }
    }
    private func post(_ base:URL,_ method:String,_ params:[String:TronJSON] = [:]) async throws -> TronJSON {
        do {
            try Task.checkCancellation()
            var req=URLRequest(url:base.appendingPathComponent(method));req.httpMethod="POST";req.timeoutInterval=12
            req.setValue("application/json",forHTTPHeaderField:"Content-Type");req.httpBody=try JSONEncoder().encode(TronJSON.object(params))
            let (data,status)=try await transport.send(req)
            guard status==200 else { throw TronSendError.http(status) }
            guard data.count <= (method == "walletsolidity/getblockbylimitnext" ? 16_000_000:4_000_000) else { throw TronSendError.malformed }
            let value=try JSONDecoder().decode(TronJSON.self,from:data)
            guard value.fields != nil else { throw TronSendError.malformed }
            if !value["Error"].isNull || !value["error"].isNull || value["result"] == .bool(false) || value["result"]["result"] == .bool(false) {
                let raw=value["code"].string ?? value["result"]["code"].string ?? "UNKNOWN"
                let safe=["SIGERROR","CONTRACT_VALIDATE_ERROR","CONTRACT_EXE_ERROR","BANDWITH_ERROR","DUP_TRANSACTION_ERROR","TAPOS_ERROR","TOO_BIG_TRANSACTION_ERROR","TRANSACTION_EXPIRATION_ERROR","SERVER_BUSY","OTHER_ERROR"].contains(raw) ? raw:"UNKNOWN"
                // Provider messages can contain payloads, addresses and signed
                // transactions. Record only the original allowlisted code.
                throw TronSendError.rpc(safe)
            }
            return value
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            // A duplicate acknowledgement is expected during exact-byte recovery.
            if case TronSendError.rpc("DUP_TRANSACTION_ERROR")=error { throw error }
            var context=["chain":"tron","stage":method]
            if case TronSendError.rpc(let code)=error { context["rpc_code"]=code }
            OathDiagnostics.record(error,component:"tron_send",operation:method,context:context);throw error
        }
    }
    private func verifyNetwork(_ base:URL) async throws {
        if verified.contains(base) { return }
        let genesis=try await post(base,"wallet/getblockbynum",["num":.number("0")])
        guard let id=genesis["blockID"].string,id==network.genesisID else { throw TronSendError.wrongNetwork }
        verified.insert(base)
    }
    private static func retryable(_ error:Error)->Bool {
        switch error { case TronSendError.http(let n): [401,403,404,408,429].contains(n) || n>=500
        case TronSendError.transport, AnkrError.transport: true
        case TronSendError.rpc(let code): code=="SERVER_BUSY"
        default: false }
    }
    private static func n(_ value:TronJSON,zero:Bool = false) throws -> UInt64 {
        if zero,value.isNull { return 0 }
        guard let n=value.text.flatMap(UInt64.init),n<=UInt64(Int64.max) else { throw TronSendError.malformed };return n
    }
    private func account(_ base:URL,_ address:String) async throws -> TronJSON {
        let r=try await post(base,"wallet/getaccount",["address":.string(address),"visible":.bool(true)])
        if r.fields?.isEmpty == true { return r }
        guard r["address"].string == address else { throw TronSendError.wrongOwner };return r
    }
    static func validateOwner(_ a:TronJSON,sender:String) throws {
        guard a["address"].string==sender,a["type"].isNull || a["type"].string=="Normal" || a["type"].integer==0 else { throw TronSendError.unsupportedAccount }
        let permission=a["owner_permission"]
        if !permission.isNull {
            guard let keys=permission["keys"].array,!keys.isEmpty,let key=try keys.first(where:{try TronIdentity.address($0["address"].string ?? "")==sender}),
                  try n(key["weight"])>=n(permission["threshold"]),
                  try n(permission["threshold"])>0 else { throw TronSendError.unsupportedAccount }
        }
    }
    private func constant(_ base:URL,sender:String,contract:String,selector:String,parameter:String) async throws -> TronJSON {
        let v=try await post(base,"wallet/triggerconstantcontract",["owner_address":.string(TronSendCrypto.hex(try TronIdentity.bytes(sender))),"contract_address":.string(TronSendCrypto.hex(try TronIdentity.bytes(contract))),"function_selector":.string(selector),"parameter":.string(parameter),"visible":.bool(false)])
        guard v["result"]["result"] == .bool(true),v["result"]["message"].isNull,
              !(v["transaction"]["ret"].array ?? []).contains(where:{ !$0["ret"].isNull && $0["ret"].string != "SUCESS" && $0["ret"].string != "SUCCESS" || !$0["contractRet"].isNull && $0["contractRet"].string != "SUCCESS" }) else { throw TronSendError.simulation }
        return v
    }
    private func contractNumber(_ base:URL,sender:String,contract:String,selector:String,parameter:String="") async throws -> String {
        let v=try await constant(base,sender:sender,contract:contract,selector:selector,parameter:parameter)
        guard let values=v["constant_result"].array,values.count==1,let word=values.first?.string else { throw TronSendError.malformed }
        return try TronIdentity.uint256(word)
    }
    public func balance(owner:String,reference:String) async throws -> String {
        guard TronIdentity.isAddress(owner),reference=="native" || TronIdentity.isToken(reference) else { throw TronSendError.amount }
        return try await OathDiagnostics.$chain.withValue("tron") {
            try await OathDiagnostics.$operationID.withValue(OathDiagnostics.operationID ?? UUID()) {
                for (index,base) in endpoints.enumerated() {
                    do {
                        try await verifyNetwork(base)
                        if TronIdentity.isAddress(reference) {
                            return try await contractNumber(base,sender:owner,contract:reference,selector:"balanceOf(address)",parameter:String(repeating:"0",count:24)+TronSendCrypto.hex(TronIdentity.bytes(owner).dropFirst()))
                        }
                        let a=try await account(base,owner)
                        if reference=="native" { return String(try Self.n(a["balance"],zero:true)) }
                        let rows=a["assetV2"].array ?? []
                        return try TronIdentity.quantity(rows.first(where:{$0["key"].string==reference})?["value"] ?? .number("0"))
                    } catch {
                        if error is CancellationError || Task.isCancelled { throw CancellationError() }
                        OathDiagnostics.record(error,component:"tron_send",operation:"balance",context:["chain":"tron"])
                        if index==endpoints.count-1 || !Self.retryable(error) { throw error }
                    }
                };throw TronSendError.transport
            }
        }
    }

    public func quote(sender:String,recipient:String,reference:String,decimals:Int,amount:String,maximum:Bool=false,removal:TronPermissionRemoval?=nil,multisig:TronMultisigPolicy?=nil,multisigSetup:TronMultisigPolicy?=nil) async throws -> TronSendPlan {
        try await OathDiagnostics.$chain.withValue("tron") {
            try await OathDiagnostics.$operationID.withValue(OathDiagnostics.operationID ?? UUID()) {
                for (index,base) in endpoints.enumerated() {
                    do { return try await prepare(base,sender:sender,recipient:recipient,reference:reference,decimals:decimals,amount:amount,maximum:maximum,removal:removal,multisig:multisig,multisigSetup:multisigSetup) }
                    catch {
                        if error is CancellationError || Task.isCancelled { throw CancellationError() }
                        OathDiagnostics.record(error,component:"tron_send",operation:"quote",context:["chain":"tron"])
                        if index==endpoints.count-1 || !Self.retryable(error) { throw error }
                    }
                };throw TronSendError.transport
            }
        }
    }
    private func prepare(_ base:URL,sender:String,recipient:String,reference:String,decimals:Int,amount:String,maximum:Bool,removal:TronPermissionRemoval?,multisig:TronMultisigPolicy?,multisigSetup:TronMultisigPolicy?) async throws -> TronSendPlan {
        guard TronIdentity.isAddress(sender),TronIdentity.isAddress(recipient),(sender != recipient || removal?.control != nil || multisigSetup != nil),
              reference=="native" || TronIdentity.isToken(reference),(0...255).contains(decimals),try TronIdentity.quantity(.string(amount))==amount,(amount != "0" || removal != nil || multisigSetup != nil) else { throw TronSendError.amount }
        try multisig?.validate(); try multisigSetup?.validate()
        guard multisig == nil || (multisigSetup == nil && removal == nil) else { throw TronSendError.changed }
        if let setup = multisigSetup {
            guard removal == nil, sender == recipient, reference == "native", decimals == 6,
                  amount == "0", !maximum, !setup.signers.contains(sender) else { throw TronSendError.changed }
        }
        if let removal {
            try removal.validate()
            guard reference=="native",recipient==removal.contract,decimals==6,amount=="0",!maximum else { throw PermissionError.changed }
            if let control=removal.control {
                guard removal.contract==sender,try await control.matches(accountPermissions(owner:sender)) else {throw PermissionError.changed}
            } else { guard try await permissionAllowance(owner:sender,contract:removal.contract,spender:removal.spender)==removal.expected else { throw PermissionError.changed } }
        }
        _ = try TronSendCrypto.uint256(amount)
        try await verifyNetwork(base)
        async let ownerState=account(base,sender)
        async let recipientState=account(base,recipient)
        async let params=post(base,"wallet/getchainparameters")
        async let resources=post(base,"wallet/getaccountresource",["address":.string(sender),"visible":.bool(true)])
        async let blockState=post(base,"wallet/getnowblock")
        let (owner,destination,p,r,b)=try await(ownerState,recipientState,params,resources,blockState)
        if owner.fields?.isEmpty == true { throw TronSendError.senderInactive }
        if let multisig {
            guard try multisig.matches(owner) else { throw TronSendError.unsupportedAccount }
        } else if multisigSetup != nil { try TronMultisigPolicy.validateBootstrap(owner, address: sender) }
        else { try Self.validateOwner(owner,sender:sender) }
        let native=try Self.n(owner["balance"],zero:true)
        guard native<=UInt64(Int64.max),let rows=p["chainParameter"].array else { throw TronSendError.malformed }
        var parameters:[String:UInt64]=[:]
        let relevant:Set<String>=["getEnergyFee","getTransactionFee","getCreateNewAccountFeeInSystemContract","getCreateAccountFee","getCreateNewAccountBandwidthRate","getAllowSameTokenName","getMaxFeeLimit","getUpdateAccountPermissionFee","getMultiSignFee"]
        // Unrelated governance values legitimately include signed sentinels.
        for row in rows {
            guard let key=row["key"].string else { throw TronSendError.malformed }
            if relevant.contains(key) { guard parameters[key]==nil else { throw TronSendError.malformed };parameters[key]=try Self.n(row["value"],zero:true) }
        }
        func param(_ key:String) throws -> UInt64 { guard let n=parameters[key] else { throw TronSendError.malformed };return n }
        guard try param("getCreateNewAccountFeeInSystemContract")<=TronSendPlan.maximumFee,
              try param("getCreateAccountFee")<=TronSendPlan.maximumFee,
              try (1...100).contains(param("getCreateNewAccountBandwidthRate")) else { throw TronSendError.feeTooHigh }
        let energyPrice=try param("getEnergyFee"),bandwidthPrice=try param("getTransactionFee")
        guard (1...100_000).contains(energyPrice),(1...1_000_000).contains(bandwidthPrice),
              let blockID=b["blockID"].string,TronIdentity.hash(blockID),let blockNumber=b["block_header"]["raw_data"]["number"].integer,
              let timestamp=b["block_header"]["raw_data"]["timestamp"].integer,
              blockNumber<=UInt64(Int64.max)-121,timestamp<=UInt64(Int64.max)-180_000,
              abs(Double(timestamp)/1000-Date.now.timeIntervalSince1970)<60 else { throw TronSendError.malformed }
        let activation=removal==nil && multisigSetup==nil && destination.fields?.isEmpty==true && !TronIdentity.isAddress(reference)
        let assetBalance:String
        if reference=="native" { guard decimals==6 else { throw TronSendError.changed };assetBalance=String(native) }
        else if TronIdentity.isTRC10(reference) {
            guard try param("getAllowSameTokenName")==1 else { throw TronSendError.wrongNetwork }
            let info=try await post(base,"wallet/getassetissuebyid",["value":.string(reference)])
            guard info["id"].string==reference,try Self.n(info["precision"],zero:true)==UInt64(decimals) else { throw TronSendError.changed }
            assetBalance=try TronIdentity.quantity(owner["assetV2"].array?.first(where:{$0["key"].string==reference})?["value"] ?? .number("0"))
        } else {
            async let units=contractNumber(base,sender:sender,contract:reference,selector:"decimals()")
            async let available=contractNumber(base,sender:sender,contract:reference,selector:"balanceOf(address)",parameter:String(repeating:"0",count:24)+TronSendCrypto.hex(TronIdentity.bytes(sender).dropFirst()))
            let (d,a)=try await(units,available)
            guard Int(d)==decimals else { throw TronSendError.changed };assetBalance=a
        }
        let requestedAmount = maximum ? assetBalance:amount
        guard (requestedAmount != "0" || removal != nil || multisigSetup != nil), !XrplSendAmount.less(assetBalance,requestedAmount) else { throw TronSendError.insufficientFunds }
        var energy:UInt64=0,feeLimit:UInt64=0
        if TronIdentity.isAddress(reference) || (removal != nil && removal?.control == nil) {
            let simulation=try await constant(base,sender:sender,contract:removal?.contract ?? reference,selector:removal==nil ? "transfer(address,uint256)":"approve(address,uint256)",parameter:TronSendCrypto.hex((try removal?.calldata() ?? TronSendCrypto.transferData(recipient:recipient,amount:requestedAmount)).dropFirst(4)))
            if let removal { try Self.validateApproval(simulation,owner:sender,removal:removal) }
            else { try Self.validateTransfer(simulation,network:network,sender:sender,recipient:recipient,reference:reference,amount:requestedAmount) }
            energy=try Self.n(simulation["energy_used"])
            guard energy>0,energy<=10_000_000 else { throw TronSendError.feeTooHigh }
            // Include dynamic Energy already in energy_used, with 30% headroom.
            // fee_limit covers available staked Energy as well as TRX burn.
            feeLimit=(energy*13/10+1_000)*energyPrice
            guard feeLimit<=TronSendPlan.maximumFee,feeLimit <= (try param("getMaxFeeLimit")) else { throw TronSendError.feeTooHigh }
        }
        let now=Date.now
        var accountCreationFee:UInt64=0
        func plan(_ value:String,_ fee:UInt64,_ estimated:UInt64)->TronSendPlan {
            .init(network:network,sender:sender,recipient:recipient,reference:reference,amount:value,requestedAmount:requestedAmount,assetBalance:assetBalance,decimals:decimals,nativeBalance:native,fee:fee,estimatedFee:estimated,feeLimit:feeLimit,energyPrice:energyPrice,bandwidthPrice:bandwidthPrice,blockID:blockID,blockNumber:blockNumber,timestamp:timestamp,expiration:timestamp+180_000,createdAt:now,removal:removal,recipientNeedsActivation:removal == nil ? destination.fields?.isEmpty : nil,accountCreationFee:accountCreationFee,multisig:multisig,multisigSetup:multisigSetup)
        }
        let net=try Self.n(r["NetLimit"],zero:true),used=try Self.n(r["NetUsed"],zero:true)
        let free=try Self.n(r["freeNetLimit"],zero:true),freeUsed=try Self.n(r["freeNetUsed"],zero:true)
        let energyLimit=try Self.n(r["EnergyLimit"],zero:true),energyUsed=try Self.n(r["EnergyUsed"],zero:true)
        let energyAvailable=energyLimit>energyUsed ? energyLimit-energyUsed:0
        let energyEstimate=(energy>energyAvailable ? energy-energyAvailable:0)*energyPrice
        // Reserve burn after the currently available resources. fee_limit still
        // bounds total execution energy, including the part paid by staking.
        let byteCount=UInt64(TronSendCrypto.field(1,try TronSendCrypto.raw(plan(requestedAmount,0,0))).count+67*(multisig?.required ?? 1)+64)
        let activationFee=activation ? try param("getCreateNewAccountFeeInSystemContract"):0
        let bandwidthFee=activation ? try param("getCreateAccountFee"):byteCount*bandwidthPrice
        let requiredBandwidth=activation ? byteCount*(try param("getCreateNewAccountBandwidthRate")):byteCount
        let netAvailable=net>used ? net-used:0,freeAvailable=free>freeUsed ? free-freeUsed:0
        let covered=netAvailable>=requiredBandwidth || (!activation && freeAvailable>=requiredBandwidth)
        let energyBudget=feeLimit/energyPrice
        let energyBurn=(energyBudget>energyAvailable ? energyBudget-energyAvailable:0)*energyPrice
        let controlFee=removal?.control != nil || multisigSetup != nil ? try param("getUpdateAccountPermissionFee"):0
        let signatureFee = (multisig?.required ?? 1) > 1 ? try param("getMultiSignFee") : 0
        guard signatureFee <= TronSendPlan.maximumFee else { throw TronSendError.feeTooHigh }
        guard controlFee<=TronSendPlan.maximumFee else {throw TronSendError.feeTooHigh}
        accountCreationFee=activation ? activationFee+(covered ? 0:bandwidthFee):0
        let cap=energyBurn+(covered ? 0:bandwidthFee)+activationFee+controlFee+signatureFee
        guard cap<=TronSendPlan.maximumFee else { throw TronSendError.feeTooHigh }
        guard native>=cap, reference != "native" || native>cap || removal != nil || multisigSetup != nil else {
            if activation { throw TronSendError.activationFunds(cap) }
            throw SendFeeFundingError.insufficientNativeBalance
        }
        let estimated=min(cap,energyEstimate+(covered ? 0:bandwidthFee)+activationFee+controlFee+signatureFee)
        let sendAmount=reference=="native" && (maximum || UInt64(requestedAmount)!>native-cap) ? String(native-cap):requestedAmount
        let result=plan(sendAmount,cap,estimated);try result.validate();return result
    }
    static func validateTransfer(_ value:TronJSON,network:TronSendNetwork,sender:String,recipient:String,reference:String,amount:String) throws {
        let logs=value["logs"].array ?? value["log"].array ?? []
        let exact=try logs.contains { log in
            guard let c=log["address"].string,let topics=log["topics"].array,topics.count==3,
                  topics[0].string=="ddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef",
                  let from=topics[1].string,let to=topics[2].string,let data=log["data"].string else { return false }
            return try TronIdentity.address(c)==reference && TronIdentity.address(from)==sender && TronIdentity.address(to)==recipient && TronIdentity.uint256(data)==amount
        }
        guard exact else { throw TronSendError.simulation }
        if let result=value["constant_result"].array?.first?.string,!result.isEmpty {
            let word=try TronIdentity.uint256(result)
            let legacy=network == .mainnet ? TronIdentity.usdt:"TXYZopYRdj2D9XRtbG411XZZ3kM5VkAeBf"
            guard word=="1" || word=="0" && reference==legacy else { throw TronSendError.simulation }
        }
    }
    public func submit(_ signed:TronSignedSend,plan:TronSendPlan,reconcileFirst:Bool = true) async throws -> TronSendReceipt {
        try await OathDiagnostics.$chain.withValue("tron") {
            try await OathDiagnostics.$operationID.withValue(OathDiagnostics.operationID ?? UUID()) {
                try TronSendCrypto.verify(signed,plan:plan)
                guard plan.network==network else { throw TronSendError.wrongNetwork }
                for (index,base) in endpoints.enumerated() {
                    do {
                        try await verifyNetwork(base)
                        if reconcileFirst || Date.now.timeIntervalSince1970*1000+5_000>=Double(plan.expiration) {
                            let known=try await receipt(base,signed:signed,plan:plan)
                            if known.outcome != .unknown { return known }
                            guard Date.now.timeIntervalSince1970*1000+5_000<Double(plan.expiration) else { return known }
                        } else { try plan.validate() }
                        if reconcileFirst {
                        let pending=try await post(base,"wallet/gettransactionbyid",["value":.string(signed.hash)])
                        if pending.fields?.isEmpty == false {
                            guard pending["txID"].string==signed.hash,
                                  pending["raw_data_hex"].string==TronSendCrypto.hex(try TronSendCrypto.raw(plan)),
                                  pending["signature"].array == signed.signatures.map({ .string(TronSendCrypto.hex($0)) }) else { throw TronSendError.changed }
                            // Exact signed bytes are already on the head node.
                            // Submission is established; finality is still pending.
                            return .init(hash:signed.hash,outcome:.submitted)
                        }
                        }
                        // A permission update replaces the complete configuration.
                        // Never retry a stale snapshot over a newer key/threshold edit.
                        if let control=plan.removal?.control {
                            guard try await control.matches(account(base,plan.sender)) else {throw PermissionError.changed}
                        }
                        if let policy = plan.multisig {
                            guard try policy.matches(await account(base,plan.sender)) else { throw TronSendError.changed }
                        }
                        if plan.multisigSetup != nil {
                            try TronMultisigPolicy.validateBootstrap(await account(base,plan.sender), address:plan.sender)
                        }
                        do {
                            let sent=try await post(base,"wallet/broadcasthex",["transaction":.string(TronSendCrypto.hex(signed.bytes))])
                            guard sent["result"] == .bool(true),sent["txid"].isNull || sent["txid"].string==signed.hash else { throw TronSendError.changed }
                        } catch {
                            if error is CancellationError || Task.isCancelled { throw CancellationError() }
                            if case TronSendError.rpc("DUP_TRANSACTION_ERROR")=error { /* expected idempotent recovery */ }
                            else { OathDiagnostics.record(error,component:"tron_send",operation:"broadcast",context:["chain":"tron"]) }
                            // Rejection/timeout is not proof of non-execution.
                            // The only retry payload is the exact journaled bytes.
                            let observed=try await receipt(base,signed:signed,plan:plan)
                            if observed.outcome != .unknown { return observed }
                            if case TronSendError.rpc("DUP_TRANSACTION_ERROR")=error { return observed }
                            throw error
                        }
                        // Preserve the positive acknowledgement immediately. A
                        // solidity lookup can be empty for many blocks and must
                        // not turn accepted submission back into uncertainty.
                        return .init(hash:signed.hash,outcome:.submitted)
                    } catch {
                        if error is CancellationError || Task.isCancelled { throw CancellationError() }
                        OathDiagnostics.record(error,component:"tron_send",operation:"submit",context:["chain":"tron"])
                        if index==endpoints.count-1 || !Self.retryable(error) { throw error }
                    }
                };throw TronSendError.transport
            }
        }
    }
    public func status(_ signed:TronSignedSend,plan:TronSendPlan) async throws -> TronSendReceipt {
        try await OathDiagnostics.$chain.withValue("tron") {
            try await OathDiagnostics.$operationID.withValue(OathDiagnostics.operationID ?? UUID()) {
                try TronSendCrypto.verify(signed,plan:plan);guard plan.network==network else { throw TronSendError.wrongNetwork }
                for (index,base) in endpoints.enumerated() {
                    do { try await verifyNetwork(base);return try await receipt(base,signed:signed,plan:plan) }
                    catch {
                        if error is CancellationError || Task.isCancelled { throw CancellationError() }
                        OathDiagnostics.record(error,component:"tron_send",operation:"status",context:["chain":"tron"])
                        if index==endpoints.count-1 || !Self.retryable(error) { throw error }
                    }
                };throw TronSendError.transport
            }
        }
    }
    /// Prove absence in every solid block in the transaction's validity window.
    /// An empty lookup alone or a local clock timeout never releases a sender.
    private func expired(_ base:URL,signed:TronSignedSend,plan:TronSendPlan) async throws -> Bool {
        let solid=try await post(base,"walletsolidity/getnowblock")
        guard let height=solid["block_header"]["raw_data"]["number"].integer,
              let time=solid["block_header"]["raw_data"]["timestamp"].integer,
              height>plan.blockNumber,time>plan.expiration else { return false }
        let end=min(height,plan.blockNumber+120)
        var previous=plan.blockID,lastTime=plan.timestamp
        // Small bounded pages avoid pulling minutes of mainnet transactions in
        // one large response. Only the already-solidified view can prove expiry.
        for start in stride(from:plan.blockNumber,through:end,by:2) {
            let stop=min(start+2,end+1)
            let page=try await post(base,"walletsolidity/getblockbylimitnext",["startNum":.number(String(start)),"endNum":.number(String(stop))])
            guard let blocks=page["block"].array,blocks.count==Int(stop-start) else { return false }
            for (i,block) in blocks.enumerated() {
                let expected=start+UInt64(i)
                guard let id=block["blockID"].string,TronIdentity.hash(id),let number=block["block_header"]["raw_data"]["number"].integer,
                      number==expected,UInt64(id.prefix(16),radix:16)==number,
                      let timestamp=block["block_header"]["raw_data"]["timestamp"].integer,timestamp>=lastTime,
                      number==plan.blockNumber ? id==plan.blockID : block["block_header"]["raw_data"]["parentHash"].string==previous else { return false }
                guard block["transactions"].isNull || block["transactions"].array != nil else { return false }
                for tx in block["transactions"].array ?? [] {
                    guard let hash=tx["txID"].string,TronIdentity.hash(hash),hash != signed.hash else { return false }
                }
                previous=id;lastTime=timestamp
                if timestamp>plan.expiration { return true }
            }
        }
        return false
    }
    private func receipt(_ base:URL,signed:TronSignedSend,plan:TronSendPlan) async throws -> TronSendReceipt {
        async let tx=post(base,"walletsolidity/gettransactionbyid",["value":.string(signed.hash)])
        async let info=post(base,"walletsolidity/gettransactioninfobyid",["value":.string(signed.hash)])
        let (body,result)=try await(tx,info)
        if body.fields?.isEmpty==true || result.fields?.isEmpty==true {
            if body.fields?.isEmpty==true && result.fields?.isEmpty==true && Date.now.timeIntervalSince1970*1000>Double(plan.expiration),
               try await expired(base,signed:signed,plan:plan) { return .init(hash:signed.hash,outcome:.expired) }
            return .init(hash:signed.hash,outcome:.unknown)
        }
        guard body["raw_data_hex"].string==TronSendCrypto.hex(try TronSendCrypto.raw(plan)),
              body["signature"].array == signed.signatures.map({ .string(TronSendCrypto.hex($0)) }) else { throw TronSendError.changed }
        let decoded=try TronDecoding.transaction(hash:signed.hash,body:body,receipt:result)
        guard decoded.payer==plan.sender,let fee=UInt64(decoded.fee),decoded.block>0,
              decoded.timestamp*1000<=Double(plan.expiration),decoded.timestamp*1000>=Double(plan.timestamp) else { throw TronSendError.changed }
        var failed=decoded.failed
        if !failed,plan.removal==nil,plan.multisigSetup==nil,!decoded.events.contains(where:{$0.reference==plan.reference && $0.from==plan.sender && $0.to==plan.recipient && $0.amount==plan.amount}) { failed=true }
        if fee>plan.fee { OathDiagnostics.record(TronSendError.feeTooHigh,component:"tron_send",operation:"actual_fee",context:["chain":"tron"]) }
        return .init(hash:signed.hash,outcome:failed ? .failed:.confirmed,fee:fee,block:UInt64(decoded.block))
    }
}

extension TronSendClient {
    public func preflightPermission(_ plan:TronSendPlan) async throws {
        try plan.validate();guard plan.network==network,let removal=plan.removal else {throw PermissionError.changed}
        if let control=removal.control {
            guard try await control.matches(accountPermissions(owner:plan.sender)) else {throw PermissionError.changed}
        } else {guard try await permissionAllowance(owner:plan.sender,contract:removal.contract,spender:removal.spender)==removal.expected else {throw PermissionError.changed}}
    }
    public func permissionAllowance(owner:String,contract:String,spender:String) async throws -> String {
        guard [owner,contract,spender].allSatisfy(TronIdentity.isAddress) else { throw PermissionError.malformed }
        for (index,base) in endpoints.enumerated() {
            do {
                try await verifyNetwork(base)
                let data=try Data(repeating:0,count:12)+TronIdentity.bytes(owner).dropFirst()+Data(repeating:0,count:12)+TronIdentity.bytes(spender).dropFirst()
                return try await contractNumber(base,sender:owner,contract:contract,selector:"allowance(address,address)",parameter:TronSendCrypto.hex(data))
            } catch {
                OathDiagnostics.record(error,component:"permissions",operation:"tron_allowance",context:["chain":"tron"])
                if index==endpoints.count-1 || !Self.retryable(error) { throw error }
            }
        };throw PermissionError.unavailable
    }
    static func validateApproval(_ j:TronJSON,owner:String,removal:TronPermissionRemoval) throws {
        let logs=j["logs"].array ?? j["log"].array ?? []
        let expectedOwner=try TronSendCrypto.hex(Data(repeating:0,count:12)+TronIdentity.bytes(owner).dropFirst())
        let spender=try TronSendCrypto.hex(Data(repeating:0,count:12)+TronIdentity.bytes(removal.spender).dropFirst())
        guard try logs.contains(where:{ log in
            guard let address=log["address"].string,let topics=log["topics"].array,topics.count==3 else { return false }
            return try TronIdentity.address(address)==removal.contract && topics.map(\.string)==[String(PermissionDiscovery.approval.dropFirst(2)),expectedOwner,spender] && TronIdentity.uint256(log["data"].string ?? "")=="0"
        }) else { throw TronSendError.simulation }
    }
    /// Reads the confirmed permission state. An unfunded account is a normal
    /// setup state, not an error; a foreign permission set is never overwritten.
    public func multisigState(owner: String, policy: TronMultisigPolicy) async throws -> TronMultisigState {
        try policy.validate()
        guard TronIdentity.isAddress(owner), !policy.signers.contains(owner) else { throw TronSendError.wrongOwner }
        for (index, base) in endpoints.enumerated() {
            do {
                try await verifyNetwork(base)
                async let accountValue = post(base, "walletsolidity/getaccount", ["address": .string(owner), "visible": .bool(true)])
                async let parametersValue = post(base, "wallet/getchainparameters")
                let (a, parameters) = try await (accountValue, parametersValue)
                guard a.fields?.isEmpty == true || a["address"].string == owner,
                      let rows = parameters["chainParameter"].array,
                      let feeRow = rows.first(where: { $0["key"].string == "getUpdateAccountPermissionFee" }) else { throw TronSendError.malformed }
                let fee = try Self.n(feeRow["value"], zero: true)
                guard fee <= TronSendPlan.maximumFee else { throw TronSendError.feeTooHigh }
                let configured = try policy.matches(a)
                if !configured, a.fields?.isEmpty != true { try TronMultisigPolicy.validateBootstrap(a, address: owner) }
                return .init(configured: configured, balance: try Self.n(a["balance"], zero: true), permissionFee: fee)
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                OathDiagnostics.record(error, component: "tron_send", operation: "multisig_state", context: ["chain": "tron"])
                if index == endpoints.count - 1 || !Self.retryable(error) { throw error }
            }
        }
        throw TronSendError.transport
    }

    public func accountPermissions(owner:String) async throws -> TronJSON {
        guard TronIdentity.isAddress(owner) else { throw PermissionError.malformed }
        for (index,base) in endpoints.enumerated() {
            do {
                try await verifyNetwork(base)
                let a=try await account(base,owner)
                return .object(["owner_permission":a["owner_permission"],"active_permission":a["active_permission"],"witness_permission":a["witness_permission"]])
            } catch {
                if error is CancellationError || Task.isCancelled {throw CancellationError()}
                OathDiagnostics.record(error,component:"permissions",operation:"tron_control",context:["chain":"tron"])
                if index==endpoints.count-1 || !Self.retryable(error) {throw error}
            }
        };throw PermissionError.unavailable
    }
}
