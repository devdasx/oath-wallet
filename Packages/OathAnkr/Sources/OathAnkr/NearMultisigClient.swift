import Foundation
import OathDiagnostics

public struct NearMultisigState: Sendable {
    public let configured: Bool
    public let balance: String
    public let stage: NearMultisigContext.Stage?
    public let minimumFunding:String
    init(configured:Bool,balance:String,stage:NearMultisigContext.Stage?,minimumFunding:String="0") {
        self.configured=configured;self.balance=balance;self.stage=stage;self.minimumFunding=minimumFunding
    }
}
extension NearSendClient {
    /// Reject unknown code, changed membership, or any unexpected full-access key.
    func multisigState(_ policy: NearMultisigPolicy, block: String) async throws -> (NearMultisigState, [UInt64]) {
        try policy.validate()
        let state=try await account(policy.address,block:block)
        let list=try await query(["request_type":.string("view_access_key_list"),"account_id":.string(policy.address)],block:block)
        guard let keys=list["keys"].array,keys.count<=policy.publicKeys.count+1 else { throw NearSendError.changed }
        let balance=try NearIdentity.amount(state["amount"])
        if state["code_hash"].string == String(repeating:"1",count:32) {
            guard keys.count==1,keys[0]["public_key"].string==NearSendCrypto.keyString(policy.bootstrap),keys[0]["access_key"]["permission"].string=="FullAccess",let nonce=keys[0]["access_key"]["nonce"].integer,nonce<UInt64.max else { throw NearSendError.changed }
            return (.init(configured:false,balance:balance,stage:.deploy),[nonce+1])
        }
        guard state["code_hash"].string == (try NearMultisigPolicy.codeHash) else { throw NearSendError.changed }
        async let membersWork=call(policy.address,"get_members",block:block)
        async let thresholdWork=call(policy.address,"get_num_confirmations",block:block)
        let (members,threshold)=try await (membersWork,thresholdWork)
        guard threshold.integer==UInt64(policy.required),let members=members.array,members.count==policy.publicKeys.count,
              Set(members.compactMap { $0["public_key"].string }) == Set(policy.publicKeys.map(NearSendCrypto.keyString)) else { throw NearSendError.changed }
        var nonces=[UInt64]()
        for publicKey in policy.publicKeys {
            let matching=keys.filter { $0["public_key"].string==NearSendCrypto.keyString(publicKey) }
            guard matching.count==1,let key=matching.first,let nonce=key["access_key"]["nonce"].integer,nonce<UInt64.max-1 else { throw NearSendError.changed }
            let p=key["access_key"]["permission"]["FunctionCall"]
            guard p["allowance"].isNull,p["receiver_id"].string==policy.address,let names=p["method_names"].array,
                  names.count==NearMultisigPolicy.methods.count,Set(names.compactMap(\.string))==Set(NearMultisigPolicy.methods) else { throw NearSendError.changed }
            nonces.append(nonce+1)
        }
        if keys.count==policy.publicKeys.count { return (.init(configured:true,balance:balance,stage:nil),nonces) }
        let bootstrap=keys.filter { $0["public_key"].string==NearSendCrypto.keyString(policy.bootstrap) }
        guard bootstrap.count==1,bootstrap[0]["access_key"]["permission"].string=="FullAccess",let nonce=bootstrap[0]["access_key"]["nonce"].integer,nonce<UInt64.max else { throw NearSendError.changed }
        return (.init(configured:false,balance:balance,stage:.secure),[nonce+1])
    }
    public func multisigSetup(_ policy: NearMultisigPolicy) async throws -> (NearMultisigState, NearSendPlan?) {
        let header=try await finalBlock(),hash=try NearIdentity.hash(header["hash"])
        let state:NearMultisigState,nonces:[UInt64]
        do { (state,nonces)=try await multisigState(policy,block:hash) }
        catch NearError.accountMissing { state = .init(configured:false,balance:"0",stage:.deploy); nonces=[1] }
        guard let stage=state.stage else { return (state,nil) }
        async let configWork=rpc("EXPERIMENTAL_protocol_config",.object(["block_id":.string(hash)]))
        async let priceWork=rpc("gas_price",.array([.string(hash)]))
        let (config,price)=try await (configWork,priceWork)
        guard config["chain_id"].string==network.rawValue,let height=header["height"].integer,let validity=config["transaction_validity_period"].integer else { throw NearSendError.malformed }
        let market=try NearIdentity.amount(price["gas_price"])
        let floor=config["runtime_config"]["min_gas_purchase_price"].isNull ? "0":try NearIdentity.amount(config["runtime_config"]["min_gas_purchase_price"])
        let ceiling=try NearSendAmount.multiply(XrplSendAmount.less(market,floor) ? floor:market,2)
        let fee=try NearSendAmount.multiply(ceiling,200_000_000_000_000)
        // Contract bytes, members, access keys, and a bounded outstanding-request
        // allowance remain funded after activation. This is a reserve, not an Oath fee.
        let reserve=try NearSendAmount.multiply(NearIdentity.amount(config["runtime_config"]["storage_amount_per_byte"]),UInt64(try NearMultisigPolicy.code().count+32_768))
        let minimum=try NearSendAmount.add(reserve,NearSendAmount.add(fee,"1"))
        let fundedState=NearMultisigState(configured:false,balance:state.balance,stage:stage,minimumFunding:minimum)
        if XrplSendAmount.less(state.balance,minimum) { return (fundedState,nil) }
        let plan=NearSendPlan(network:network,sender:policy.address,recipient:policy.address,reference:"native",publicKey:policy.bootstrap,decimals:24,requestedAmount:"1",amount:"1",assetBalance:state.balance,nativeBalance:state.balance,reserve:reserve,storageDeposit:"0",fee:fee,gasPriceCeiling:ceiling,gas:0,storageGas:0,nonce:nonces[0],blockHash:hash,blockHeight:height,validityPeriod:validity,multisig:.init(policy:policy,stage:stage,nonces:nonces))
        try plan.validate();return (fundedState,plan)
    }
    func multisigPreflight(_ plan: NearSendPlan) async throws {
        guard let c=plan.multisig else { throw NearSendError.changed }
        if c.stage != .transfer {
            let (_,current)=try await multisigSetup(c.policy)
            guard let current,current.multisig?.stage==c.stage,current.multisig?.nonces==c.nonces,
                  !XrplSendAmount.less(plan.fee,current.fee),!XrplSendAmount.less(plan.reserve,current.reserve) else { throw NearSendError.changed }
        } else {
            let current=try await quote(sender:plan.sender,recipient:plan.recipient,reference:plan.reference,publicKey:plan.publicKey,decimals:plan.decimals,amount:plan.amount,multisig:c.policy)
            guard current.multisig==c,current.amount==plan.amount,!XrplSendAmount.less(plan.fee,current.fee),
                  !XrplSendAmount.less(plan.storageDeposit,current.storageDeposit),!XrplSendAmount.less(plan.reserve,current.reserve) else { throw NearSendError.changed }
        }
    }
    /// Recovery reuses exact signed bytes. Confirmations are released only after
    /// the proposal's returned ID and immutable on-chain payload match this intent.
    func multisigSubmit(_ signed: NearSignedSend, plan: NearSendPlan, broadcast: Bool) async throws -> NearSendReceipt {
        try NearSendCrypto.verifyMultisig(signed,plan:plan)
        guard plan.network==network,let c=plan.multisig,let parts=signed.multisigParts else { throw NearSendError.wrongNetwork }
        let raw=try NearSendCrypto.multisigRaw(plan)
        var fee="0",block:UInt64=plan.blockHeight
        for (i,part) in parts.enumerated() {
            let cached=multisigFinalParts[part.hash]
            let response=try await cached == nil ? rpc("tx",.object(["tx_hash":.string(part.hash),"sender_account_id":.string(plan.sender),"wait_until":.string("NONE")]),unknownAllowed:true):NearJSON.null
            if cached == nil && response.isNull {
                guard broadcast else { return .init(hash:signed.hash,outcome:.unknown) }
                let header=try await finalBlock(),hash=try NearIdentity.hash(header["hash"])
                guard let height=header["height"].integer else { throw NearSendError.malformed }
                if height>plan.blockHeight+plan.validityPeriod {
                    // Only an unused nonce proves this exact part cannot execute.
                    // A partial proposal never transfers funds; final confirmation is the payment.
                    let key=try await query(["request_type":.string("view_access_key"),"account_id":.string(plan.sender),"public_key":.string(NearSendCrypto.keyString(part.publicKey))],block:hash)
                    guard let nonce=key["nonce"].integer,nonce<raw[i].nonce else { return .init(hash:signed.hash,outcome:.unknown) }
                    return .init(hash:signed.hash,outcome:.expired)
                }
                let (state,_)=try await multisigState(c.policy,block:hash)
                guard c.stage == .transfer ? state.configured : state.stage==c.stage else { throw NearSendError.changed }
                if c.stage == .transfer && i>0 {
                    let request=try await call(plan.sender,"get_request",["request_id":.number(String(c.requestID))],block:hash)
                    guard request == (try c.request(plan)) else { throw NearSendError.changed }
                }
                let result=try await rpc("broadcast_tx_async",.array([.string(part.bytes.base64EncodedString())]),unknownAllowed:true)
                guard result.isNull || result.string==part.hash else { throw NearSendError.changed }
                // Do not block the UI for finality; the durable journal drives each
                // dependent confirmation on subsequent reconciliation passes.
                return .init(hash:signed.hash,outcome:.unknown)
            }
            let receipt:NearSendReceipt
            let returnedID:UInt32?
            if let cached { receipt=cached.receipt; returnedID=cached.returnedID }
            else {
                receipt=try await self.receipt(response,signed:part.signed,plan:plan,expectedNonce:raw[i].nonce)
                // A proposal returns its numeric ID; other successful actions return
                // null/boolean. These decode alternatives are expected protocol shapes.
                returnedID=response["status"]["SuccessValue"].string.flatMap { Data(base64Encoded:$0) }.flatMap { try? JSONDecoder().decode(UInt32.self,from:$0) }
                if receipt.outcome == .confirmed || receipt.outcome == .failed {
                    if multisigFinalParts.count>=128 { multisigFinalParts.removeAll(keepingCapacity:true) }
                    multisigFinalParts[part.hash] = .init(receipt:receipt,returnedID:returnedID)
                }
            }
            guard receipt.outcome == .confirmed else {
                return .init(hash:signed.hash,outcome:receipt.outcome,fee:receipt.fee.map { AptosIdentity.add(fee,$0) },block:receipt.block)
            }
            fee=try NearSendAmount.add(fee,receipt.fee ?? "0");block=max(block,receipt.block ?? block)
            if c.stage == .transfer && i==0 {
                guard returnedID==c.requestID else {
                    // The proposal was added under a different ID (concurrent external proposal).
                    // None of this bundle's confirmations has been released. Never confirm a different request.
                    OathDiagnostics.record(NearSendError.changed,component:"near_send",operation:"multisig_request_binding",context:["chain":"near"])
                    return .init(hash:signed.hash,outcome:.failed,fee:fee,block:block)
                }
            }
        }
        return .init(hash:signed.hash,outcome:.confirmed,fee:fee,block:block)
    }
}
