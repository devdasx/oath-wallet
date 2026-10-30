import Foundation
import OathDiagnostics

public actor PolkadotSendClient {
    public let network: PolkadotSendNetwork
    private let endpoints: [URL], transport: any AnkrTransport
    private let permits = AnkrPermits(count: 4)
    private var verified: Set<URL> = []
    private var runtimes: [UInt32:PolkadotRuntime] = [:]
    private var scanned: [String:UInt64] = [:]
    public init(network: PolkadotSendNetwork = .mainnet, endpoints: [URL]? = nil, transport: any AnkrTransport = AnkrHTTPTransport()) throws {
        let endpoints = endpoints ?? (network == .mainnet ? [network.endpoint,URL(string:"https://asset-hub.selvagelabs.io")!] : [network.endpoint])
        guard !endpoints.isEmpty, endpoints.count <= 4, endpoints.allSatisfy({ $0.scheme == "https" }) else { throw PolkadotSendError.configuration }
        self.network=network;self.endpoints=endpoints;self.transport=transport
    }
    private func call(_ endpoint: URL, _ method: String, _ params: [SolanaJSON]) async throws -> SolanaJSON {
        var request = URLRequest(url:endpoint); request.timeoutInterval=25;request.httpMethod="POST"
        request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        request.httpBody=try JSONEncoder().encode(SolanaJSON.object(["jsonrpc":.string("2.0"),"id":.number("1"),"method":.string(method),"params":.array(params)]))
        try await permits.acquire()
        var ownsPermit = true
        do {
            let (data,status) = try await transport.send(request); await permits.release(); ownsPermit = false
            guard status == 200 else { throw PolkadotSendError.http(status) }
            guard data.count <= 16_000_000 else { throw PolkadotSendError.malformed }
            let reply = try JSONDecoder().decode(SolanaJSON.self,from:data)
            if DiagnosticHTTP.expectedPolkadotAlreadyImported(data, status: status, request: request),
               let hash = DiagnosticHTTP.submittedPolkadotHash { return .string(hash) }
            if !reply["error"].isNull {
                let code=Int(reply["error"]["code"].text ?? "") ?? -1
                OathDiagnostics.record(DiagnosticFailure(reply["error"]["message"].string ?? "Polkadot RPC failure"),component:"polkadot_send",operation:"rpc",context:["chain":"polkadot","method":method,"rpc_code":String(code)])
                throw PolkadotSendError.rpc(code)
            }
            guard reply["id"].text == "1", case .object(let fields) = reply, fields["result"] != nil else { throw PolkadotSendError.malformed }
            return reply["result"]
        } catch {
            if ownsPermit { await permits.release() }
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            var context=DiagnosticHTTP.context(request);context["chain"]="polkadot";context["rpc_method"]=method
            OathDiagnostics.record(error,component:"polkadot_send",operation:"transport",context:context);throw error
        }
    }
    func rpc(_ method: String, _ params: [SolanaJSON]) async throws -> SolanaJSON {
        var failure: any Error = PolkadotSendError.transport
        for endpoint in endpoints {
            do {
                if !verified.contains(endpoint) {
                    guard try await call(endpoint,"chain_getBlockHash",[.number("0")]).string == network.genesis else { throw PolkadotSendError.wrongNetwork }
                    verified.insert(endpoint)
                }
                return try await call(endpoint,method,params)
            } catch {
                try Task.checkCancellation(); if error is CancellationError { throw error }
                OathDiagnostics.record(error,component:"polkadot_send",operation:"fallback",context:["chain":"polkadot","method":method]);failure=error
                // Broadcast uncertainty is reconciled from the journal, never by creating a new signature.
                if method == "author_submitExtrinsic" { throw error }
            }
        }; throw failure
    }
    private func finalized() async throws -> (String,UInt64) {
        guard let hash=try await rpc("chain_getFinalizedHead",[]).string, try PolkadotIdentity.bytes(hash).count == 32,
              let height=try await rpc("chain_getHeader",[.string(hash)])["number"].string,
              let number=UInt64(height.dropFirst(2),radix:16), height.hasPrefix("0x"), number>0 else { throw PolkadotSendError.malformed }
        return (hash,number)
    }
    private func runtime(at hash: String) async throws -> (PolkadotRuntime,UInt32,UInt32) {
        let version = try await rpc("state_getRuntimeVersion",[.string(hash)])
        guard let spec=UInt32(version["specVersion"].text ?? ""), let tx=UInt32(version["transactionVersion"].text ?? "") else { throw PolkadotSendError.malformed }
        if let runtime=runtimes[spec] { return (runtime,spec,tx) }
        guard let hex=try await rpc("state_getMetadata",[.string(hash)]).string else { throw PolkadotSendError.malformed }
        let runtime=try PolkadotRuntime(PolkadotIdentity.bytes(hex)); if runtimes.count>=4 { runtimes.removeAll() };runtimes[spec]=runtime
        return (runtime,spec,tx)
    }
    private func storage(_ key: String, at hash: String) async throws -> Data {
        let result=try await rpc("state_getStorage",[.string(key),.string(hash)])
        if result.isNull { return Data() }; guard let hex=result.string else { throw PolkadotSendError.malformed };return try PolkadotIdentity.bytes(hex)
    }
    private func token(reference: String, at hash: String, known: PolkadotToken?) async throws -> PolkadotToken {
        if reference == "native" { return .init(reference:"native",name:"Polkadot",symbol:network == .mainnet ? "DOT" : network == .paseo ? "PAS" : "WND",decimals:network.decimals,pallet:"System",key:Data()) }
        let ref=try PolkadotIdentity.reference(reference), pallet:String, key:Data
        if ref.hasPrefix("foreign:") {
            let t:PolkadotToken
            if let known, known.pallet == "ForeignAssets", known.reference == ref,
               ref == "foreign:"+PolkadotIdentity.hex(SuiSendCrypto.hash(known.key)), !known.key.isEmpty, known.key.count <= 512 { t=known }
            else { guard network == .mainnet else { throw PolkadotSendError.runtimeUnsupported };t=try await PolkadotClient().currentMetadata(reference:ref) }
            pallet=t.pallet;key=t.key
        } else { pallet=ref.hasPrefix("assets:") ? "Assets":"PoolAssets";key=PolkadotScale.le(UInt32(ref.split(separator:":")[1])!) }
        guard let prefix=PolkadotStorage.pallets[pallet] else { throw PolkadotSendError.malformed }
        let storageKey="0x"+prefix+PolkadotStorage.metadata+PolkadotIdentity.hex(PolkadotIdentity.concat(key)).dropFirst(2)
        let raw=try await storage(storageKey,at:hash)
        return try PolkadotStorage.token(key:storageKey,value:.string(PolkadotIdentity.hex(raw.isEmpty ? Data(repeating:0,count:20):raw)),pallet:pallet)
    }
    public func quote(sender: String, recipient: String, reference: String, decimals: Int, amount: String, maximum: Bool = false, knownToken: PolkadotToken? = nil) async throws -> PolkadotSendPlan {
        let sender=try PolkadotIdentity.address(sender),recipient=try PolkadotIdentity.address(recipient)
        let (hash,height)=try await finalized()
        async let runtimeTask=runtime(at:hash)
        async let senderTask=storage(PolkadotStorage.nativeKey(sender),at:hash)
        async let recipientTask=storage(PolkadotStorage.nativeKey(recipient),at:hash)
        async let nonceTask=rpc("system_accountNextIndex",[.string(sender)])
        async let tokenTask=token(reference:reference,at:hash,known:knownToken)
        let ((runtime,spec,tx),senderRaw,recipientRaw,nonceJSON,token)=try await (runtimeTask,senderTask,recipientTask,nonceTask,tokenTask)
        guard token.decimals==decimals, let nonce=UInt32(nonceJSON.text ?? ""),
              let edRaw=runtime.pallets["Balances"]?.constants["ExistentialDeposit"] else { throw PolkadotSendError.metadataChanged }
        let account=try runtime.decode(senderRaw,pallet:"System",storage:"Account"), destination=try runtime.decode(recipientRaw,pallet:"System",storage:"Account")
        let free=try PolkadotIdentity.amount(account["data"]["free"]),reserved=try PolkadotIdentity.amount(account["data"]["reserved"]),frozen=try PolkadotIdentity.amount(account["data"]["frozen"]),ed=PolkadotIdentity.uint(edRaw)
        let lock=XrplSendAmount.less(reserved,frozen) ? try NearSendAmount.subtract(frozen,reserved):"0"
        let total=try NearSendAmount.add(free,reserved)
        let reserve=try NearSendAmount.add(reserved,XrplSendAmount.less(lock,ed) ? ed:lock)
        var assetReserve="0"
        var balance=total, minimum=ed, targetBalance=try PolkadotIdentity.amount(destination["data"]["free"]), callName="transfer_keep_alive"
        if reference != "native" {
            let prefix=PolkadotStorage.pallets[token.pallet]!, suffix=PolkadotIdentity.hex(PolkadotIdentity.concat(token.key)).dropFirst(2)
            async let detailsTask=storage("0x"+prefix+PolkadotStorage.asset+suffix,at:hash)
            async let sourceTask=storage(PolkadotStorage.accountKey(token,owner:sender),at:hash)
            async let targetTask=storage(PolkadotStorage.accountKey(token,owner:recipient),at:hash)
            let (detailsRaw,sourceRaw,targetRaw)=try await (detailsTask,sourceTask,targetTask)
            guard !detailsRaw.isEmpty, !sourceRaw.isEmpty else { throw PolkadotSendError.insufficientFunds }
            let details=try runtime.decode(detailsRaw,pallet:token.pallet,storage:"Asset"),source=try runtime.decode(sourceRaw,pallet:token.pallet,storage:"Account")
            guard details["status"]["type"].string == "Live", source["status"]["type"].string == "Liquid" else { throw PolkadotSendError.frozen }
            minimum=try PolkadotIdentity.amount(details["min_balance"]);balance=try PolkadotIdentity.amount(source["balance"])
            if targetRaw.isEmpty {
                targetBalance="0"
                if details["is_sufficient"] != .bool(true), destination["providers"].text == "0" { throw PolkadotSendError.recipientNeedsNative }
            } else {
                let target=try runtime.decode(targetRaw,pallet:token.pallet,storage:"Account")
                guard ["Liquid","Frozen"].contains(target["status"]["type"].string ?? "") else { throw PolkadotSendError.frozen }
                targetBalance=try PolkadotIdentity.amount(target["balance"])
            }
            var frozenAmount="0",heldAmount="0",hasConstraint=false
            if token.pallet == "Assets" {
                let accountSuffix=PolkadotIdentity.hex(PolkadotIdentity.concat(token.key)+PolkadotIdentity.concat(try PolkadotIdentity.publicKey(sender))).dropFirst(2)
                async let frozenTask=storage("0x35b7c66f50d9dd5ea57fd81d50aabe4e0aae5fbb94f8a30f52f9a263e67b53c8"+accountSuffix,at:hash)
                async let heldTask=storage("0x8c5b9c237726a63375a5d60e5cf1b0b3ea054aacc32ece6e888367287e12de1e"+accountSuffix,at:hash)
                let (frozenRaw,heldRaw)=try await (frozenTask,heldTask)
                guard runtime.pallets["AssetsFreezer"] != nil, runtime.pallets["AssetsHolder"] != nil else { throw PolkadotSendError.runtimeUnsupported }
                if !frozenRaw.isEmpty { frozenAmount=try PolkadotIdentity.amount(runtime.decode(frozenRaw,pallet:"AssetsFreezer",storage:"FrozenBalances"));hasConstraint=true }
                if !heldRaw.isEmpty { heldAmount=try PolkadotIdentity.amount(runtime.decode(heldRaw,pallet:"AssetsHolder",storage:"BalancesOnHold"));hasConstraint=true }
            }
            let locked=XrplSendAmount.less(heldAmount,frozenAmount) ? try NearSendAmount.subtract(frozenAmount,heldAmount):"0"
            // With a one-unit minimum there is no positive dust to sweep. Larger
            // minima retain an asset account so execution cannot exceed the review.
            if minimum == "1", !hasConstraint, amount == balance || maximum { callName="transfer" }
            else { assetReserve=XrplSendAmount.less(locked,minimum) ? minimum:locked }

        }
        let requested=maximum ? (reference == "native" ? balance : try NearSendAmount.subtract(balance,assetReserve)):amount
        _ = try NearSendAmount.checked(requested)
        guard requested != "0", !XrplSendAmount.less(balance,requested) else { throw PolkadotSendError.insufficientFunds }
        if reference != "native", XrplSendAmount.less(try NearSendAmount.subtract(balance,requested),assetReserve) { throw PolkadotSendError.minimumBalance }
        let (callIndex,fields)=try runtime.call(pallet:reference == "native" ? "Balances":token.pallet,name:callName)
        guard fields.map(\.name) == (reference == "native" ? ["dest","value"] : ["id","target","amount"]) else { throw PolkadotSendError.runtimeUnsupported }
        func plan(_ amount:String,_ fee:String) -> PolkadotSendPlan {
            var result=PolkadotSendPlan(network:network,sender:sender,recipient:recipient,token:token,requestedAmount:requested,amount:amount,assetBalance:balance,nativeBalance:total,reserve:reserve,fee:fee,nonce:nonce,specVersion:spec,transactionVersion:tx,blockHeight:height,blockHash:hash,metadataHash:runtime.fingerprint,callIndex:callIndex,extensions:runtime.extensions.map(\.name),createdAt:.now)
            result.minimumNativeBalance=ed;return result
        }
        var candidate=plan(requested,"1")
        try validateEncoding(candidate,runtime:runtime,fields:fields)
        var fee=try await estimate(candidate,at:hash)
        var quotedLength=try PolkadotSendCrypto.extrinsic(candidate,signature:Data(repeating:0,count:64)).count
        // Compact amount widths affect fees. A conservative fixed point bounds the
        // exact extrinsic and never raises the amount after the user reviews it.
        for _ in 0..<3 {
            let adjusted=try PolkadotSendPlan.transferAmount(requested:requested,balance:balance,reserve:reserve,fee:fee,native:reference == "native")
            candidate=plan(adjusted,fee)
            let length=try PolkadotSendCrypto.extrinsic(candidate,signature:Data(repeating:0,count:64)).count
            if length == quotedLength { break };quotedLength=length
            let next=try await estimate(candidate,at:hash)
            if !XrplSendAmount.less(fee,next) { break };fee=next
        }
        guard candidate.fee == fee else { throw PolkadotSendError.changed }
        guard !XrplSendAmount.less(try NearSendAmount.add(targetBalance,candidate.amount),minimum) else { throw PolkadotSendError.recipientMinimum }
        try candidate.validate(); return candidate
    }
    func validateEncoding(_ plan: PolkadotSendPlan, runtime: PolkadotRuntime, fields: [PolkadotRuntime.Field]) throws {
        let required:Set<String>=["CheckSpecVersion","CheckTxVersion","CheckGenesis","CheckMortality","CheckNonce","ChargeAssetTxPayment","CheckMetadataHash"]
        guard required.isSubset(of:Set(plan.extensions)) else { throw PolkadotSendError.runtimeUnsupported }
        for ext in runtime.extensions {
            let (extra,additional)=try PolkadotSendCrypto.extensionBytes(ext.name,plan:plan)
            for (bytes,type) in [(extra,ext.type),(additional,ext.additional)] {
                var r=PolkadotScale(bytes), budget=1000
                _ = try runtime.decode(type,reader:&r,depth:0,budget:&budget)
                guard r.offset == bytes.count else { throw PolkadotSendError.runtimeUnsupported }
            }
        }
        var reader=PolkadotScale(Data(try PolkadotSendCrypto.call(plan).dropFirst(2))),budget=1000
        for field in fields { _ = try runtime.decode(field.type,reader:&reader,depth:0,budget:&budget) }
        guard reader.offset == reader.data.count else { throw PolkadotSendError.runtimeUnsupported }
    }
    private func estimate(_ plan: PolkadotSendPlan, at hash: String) async throws -> String {
        let bytes=try PolkadotSendCrypto.extrinsic(plan,signature:Data(repeating:0,count:64))
        let result=try await rpc("payment_queryInfo",[.string(PolkadotIdentity.hex(bytes)),.string(hash)])
        let fee=try PolkadotIdentity.amount(result["partialFee"])
        // Reserve 25% for inclusion-time weight/fee changes; the actual fee is
        // taken from TransactionFeePaid after finalized execution.
        return try NearSendAmount.add(fee,NearSendAmount.add(divideFour(fee),"1"))
    }
    private func divideFour(_ n:String) -> String {
        var carry=0,result="";for digit in n.utf8 { let v=carry*10+Int(digit-48);result+=String(v/4);carry=v%4 };let s=String(result.drop(while:{$0=="0"}));return s.isEmpty ? "0":s
    }
    public func preflight(_ plan: PolkadotSendPlan) async throws {
        try plan.validate();guard plan.network==network else { throw PolkadotSendError.wrongNetwork }
        let fresh=try await quote(sender:plan.sender,recipient:plan.recipient,reference:plan.reference,decimals:plan.decimals,amount:plan.amount,knownToken:plan.token)
        guard fresh.nonce==plan.nonce, fresh.specVersion==plan.specVersion, fresh.transactionVersion==plan.transactionVersion,
              fresh.metadataHash==plan.metadataHash, fresh.token==plan.token, fresh.callIndex==plan.callIndex,
              fresh.amount==plan.amount, !XrplSendAmount.less(plan.fee,fresh.fee), fresh.blockHeight < plan.expiresAtHeight-8 else { throw PolkadotSendError.changed }
    }
    public func submit(_ signed: PolkadotSignedSend, plan: PolkadotSendPlan, reconcileFirst: Bool = true) async throws -> PolkadotSendReceipt {
        try PolkadotSendCrypto.verify(signed,plan:plan);guard plan.network==network else { throw PolkadotSendError.wrongNetwork }
        if reconcileFirst { let result=try await status(signed,plan:plan);if result.outcome != .unknown { return result } }
        let (_,height)=try await finalized();guard height < plan.expiresAtHeight else { return try await status(signed,plan:plan) }
        // The node can already have these journaled bytes after an uncertain
        // response or a restart. Exact pool acknowledgement remains pending;
        // status() still requires finalized inclusion and execution events.
        let result=try await DiagnosticHTTP.$submittedPolkadotHash.withValue(signed.hash) {
            try await rpc("author_submitExtrinsic",[.string(PolkadotIdentity.hex(signed.bytes))])
        }
        guard result.string==signed.hash else { throw PolkadotSendError.malformed }
        return .init(hash:signed.hash,outcome:.accepted)
    }
    public func status(_ signed: PolkadotSignedSend, plan: PolkadotSendPlan) async throws -> PolkadotSendReceipt {
        try PolkadotSendCrypto.verify(signed,plan:plan);guard plan.network==network else { throw PolkadotSendError.wrongNetwork }
        let (_,height)=try await finalized(), end=min(height,plan.expiresAtHeight-1)
        var next=max(plan.blockHeight,scanned[signed.hash] ?? plan.blockHeight)
        while next <= end {
            let start=next, upper=min(end,start+3)
            let found=try await withThrowingTaskGroup(of:(UInt64,String,Int?).self) { group in
                for number in start...upper {
                    group.addTask {
                        guard let hash=try await self.rpc("chain_getBlockHash",[.number(String(number))]).string,
                              try PolkadotIdentity.bytes(hash).count == 32 else { throw PolkadotSendError.malformed }
                        let block=try await self.rpc("chain_getBlock",[.string(hash)])["block"]
                        guard let encodedHeight=block["header"]["number"].string, encodedHeight.hasPrefix("0x"),
                              UInt64(encodedHeight.dropFirst(2),radix:16) == number,
                              let extrinsics=block["extrinsics"].array else { throw PolkadotSendError.malformed }
                        let index=try extrinsics.firstIndex { item in guard let text=item.string else { throw PolkadotSendError.malformed };return try PolkadotIdentity.bytes(text)==signed.bytes }
                        return (number,hash,index)
                    }
                }
                var match:(UInt64,String,Int)?
                for try await (number,hash,index) in group { if let index { guard match == nil else { throw PolkadotSendError.malformed };match=(number,hash,index) } };return match
            }
            if let (number,hash,index)=found {
                let (runtime,_,_)=try await runtime(at:hash)
                let raw=try await storage("0x26aa394eea5630e07c48ae0c9558cef780d41e5e16056765bc8461851072c9d7",at:hash)
                guard let events=try runtime.decode(raw,pallet:"System",storage:"Events").array else { throw PolkadotSendError.malformed }
                var success:Bool?,fee:String?
                for row in events where row["phase"]["type"].string == "ApplyExtrinsic" && row["phase"]["value"].text == String(index) {
                    let event=row["event"],pallet=event["type"].string,kind=event["value"]["type"].string,body=event["value"]["value"]
                    if pallet == "System",kind == "ExtrinsicSuccess" { success=true }
                    if pallet == "System",kind == "ExtrinsicFailed" { success=false }
                    if pallet == "TransactionPayment",kind == "TransactionFeePaid" { fee=try PolkadotIdentity.amount(body["actual_fee"]) }
                    if pallet == "AssetTxPayment",kind == "AssetTxFeePaid",body["asset_id"]["type"].string == "None" { fee=try PolkadotIdentity.amount(body["actual_fee"]) }
                }
                guard let success,let fee else { throw PolkadotSendError.malformed }
                if !success { OathDiagnostics.record(PolkadotSendError.execution,component:"polkadot_send",operation:"execution",context:["chain":"polkadot"]) }
                return .init(hash:signed.hash,outcome:success ? .confirmed:.failed,fee:fee,block:number,extrinsicIndex:index)
            }
            next=upper+1
            if scanned.count>128 { scanned.removeAll() };scanned[signed.hash]=next
        }
        return .init(hash:signed.hash,outcome:height >= plan.expiresAtHeight ? .expired:.unknown)
    }
}
