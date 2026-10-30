import Foundation
import OathDiagnostics

/// Independent state reads overlap. Public index traffic is bounded and paced;
/// cancellation never becomes provider failover or transaction resubmission.
public actor TonSendClient {
    public nonisolated let network:TonSendNetwork
    private let endpoints:[URL],transport:any AnkrTransport
    private var verified=Set<URL>()
    private let nodeGate=AnkrPermits(count:1),indexGate=AnkrPermits(count:1)
    private var lastIndex=Date.distantPast,lastNode=Date.distantPast
    private let interval:Double
    public init(network:TonSendNetwork = .mainnet,apiKey:String?=nil,transport:any AnkrTransport=AnkrHTTPTransport(),indexInterval:Double=4.2) throws {
        self.network=network;self.transport=transport;self.interval=indexInterval
        var urls=[URL]()
        if network == .mainnet,let apiKey,!apiKey.isEmpty {
            guard apiKey.count<=256,apiKey.utf8.allSatisfy({(48...57).contains($0)||(65...90).contains($0)||(97...122).contains($0)}) else { throw TonSendError.configuration }
            urls.append(URL(string:"https://rpc.ankr.com/ton_api_v2")!.appendingPathComponent(apiKey))
        }
        urls.append(URL(string:network == .mainnet ? "https://toncenter.com/api/v2/jsonRPC":"https://testnet.toncenter.com/api/v2/jsonRPC")!);endpoints=urls
    }
    private func request(_ url:URL,body:TonJSON?=nil,index:Bool=false,optional:Bool=false) async throws -> TonJSON? {
        let gate=index ? indexGate:nodeGate;try await gate.acquire()
        do {
            let paced=index || url.host?.contains("toncenter")==true
            if paced,interval>0 { let last=index ? lastIndex:lastNode;let delay=(index ? interval:1.1)-Date.now.timeIntervalSince(last);if delay>0 { try await Task.sleep(for:.seconds(delay)) };if index { lastIndex = .now } else { lastNode = .now } }
            var req=URLRequest(url:url);req.timeoutInterval=20;req.setValue("application/json",forHTTPHeaderField:"Content-Type")
            if let body { req.httpMethod="POST";req.httpBody=try JSONEncoder().encode(body) }
            var response: (Data,Int)?
            for attempt in 0..<3 {
                let next=try await transport.send(req)
                if (next.1==429 || next.1>=500) && attempt<2 {
                    OathDiagnostics.record(TonSendError.http(next.1),component:"ton_send",operation:"request_retry",context:["chain":"ton","attempt":String(attempt+1)])
                    try await Task.sleep(for:.seconds(index ? 5:2));continue
                }
                response=next;break
            }
            guard let (data,status)=response else { throw TonSendError.transport }
            if optional && status==404,let missing=try? JSONDecoder().decode(TonJSON.self,from:data),missing["error"].string=="entity not found" { await gate.release();return nil } // Not indexed yet is expected.
            guard (200..<300).contains(status) else { throw TonSendError.http(status) }
            guard data.count<=8*1024*1024 else { throw TonSendError.malformed }
            let value=data.isEmpty ? TonJSON.object([:]):try JSONDecoder().decode(TonJSON.self,from:data)
            await gate.release();return value
        } catch {
            await gate.release();if error is CancellationError || Task.isCancelled { throw CancellationError() }
            OathDiagnostics.record(error,component:"ton_send",operation:index ? "index":"rpc",context:["chain":"ton"]);throw error
        }
    }
    private func node(_ method:String,_ params:[String:TonJSON],url:URL) async throws -> TonJSON {
        let j=try await request(url,body:.object(["jsonrpc":.string("2.0"),"id":.number("1"),"method":.string(method),"params":.object(params)]))!
        if !j["error"].isNull || j["ok"] == .bool(false) {
            let code=j["error"]["code"].text.flatMap(Int.init) ?? j["code"].text.flatMap(Int.init) ?? -1
            OathDiagnostics.record(NSError(domain:"TonRPC",code:code,userInfo:[NSLocalizedDescriptionKey:j["error"]["message"].string ?? j["error"].string ?? "RPC rejected request"]),component:"ton_send",operation:"provider_envelope",context:["chain":"ton","rpc_code":String(code)])
            throw TonSendError.rpc(code)
        }
        // Toncenter v2 returns its documented {ok,result,@extra} envelope
        // even at /jsonRPC; other providers return JSON-RPC 2.0.
        let rpcEnvelope=j["jsonrpc"].string=="2.0" && j["id"].text=="1"
        let legacyEnvelope=j["jsonrpc"].isNull && j["id"].isNull && j["ok"] == .bool(true)
        guard rpcEnvelope || legacyEnvelope,!j["result"].isNull else { throw TonSendError.malformed };return j["result"]
    }
    private func rpc(_ method:String,_ params:[String:TonJSON]=[:]) async throws -> TonJSON {
        var last:Error=TonSendError.transport
        for url in endpoints {
            do {
                if !verified.contains(url) {
                    let j=try await node("getMasterchainInfo",[:],url:url)
                    let genesis=network == .mainnet ? TonIdentity.genesis:"gj+B8wb/AmlPk1z1AhVI484rhrUpgSr2oSFIh56VoSg="
                    guard j["init"]["root_hash"].string==genesis else { throw TonSendError.wrongNetwork };verified.insert(url)
                }
                return try await node(method,params,url:url)
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                if error as? TonSendError == .wrongNetwork { throw error }
                OathDiagnostics.record(error,component:"ton_send",operation:"provider_fallback",context:["chain":"ton"]);last=error
            }
        };throw last
    }
    private func index(_ path:String,body:TonJSON?=nil,optional:Bool=false,query:String="") async throws -> TonJSON? {
        guard let url=URL(string:network.indexURL.absoluteString+path+query) else { throw TonSendError.configuration }
        return try await request(url,body:body,index:true,optional:optional)
    }
    static func uint(_ j:TonJSON) throws -> UInt64 {
        guard let s=j.text,!s.isEmpty,s.count<=20,s.utf8.allSatisfy({(48...57).contains($0)}),let n=UInt64(s) else { throw TonSendError.malformed };return n
    }
    struct Account:Sendable { let balance:UInt64,sequence:UInt32,active:Bool,code:TonCell?,data:TonCell? }
    private func account(_ raw:String,seqno:UInt64?=nil) async throws -> Account {
        var params:[String:TonJSON]=["address":.string(raw)]
        if let seqno { params["seqno"] = .number(String(seqno)) }
        let j=try await rpc("getAddressInformation",params),balance=try Self.uint(j["balance"])
        guard let state=j["state"].string,["active","uninitialized"].contains(state) else { throw TonSendError.wrongOwner }
        if state=="uninitialized" { return .init(balance:balance,sequence:0,active:false,code:nil,data:nil) }
        guard let code=j["code"].string.flatMap(TonIdentity.base64),let data=j["data"].string.flatMap(TonIdentity.base64) else { throw TonSendError.malformed }
        let c=try TonCell.parse(code),d=try TonCell.parse(data)
        let seq=d.bits.count>=32 ? d.bits.prefix(32).reduce(UInt32(0)){($0<<1)|UInt32($1)}:0
        return .init(balance:balance,sequence:seq,active:true,code:c,data:d)
    }
    private func validateWallet(_ a:Account,publicKey:Data,multisig:TonMultisigPolicy? = nil) throws {
        if !a.active { return }
        if let multisig { try multisig.validateState(code:a.code,data:a.data,network:network); return }
        guard a.code?.hash == (try TonSendCrypto.code().hash),let data=a.data,data.bits.count>=321,
              data.bits[32..<64].reduce(UInt64(0),{($0<<1)|UInt64($1)})==TonSendPlan.walletID,
              Data(stride(from:64,to:320,by:8).map{data.bits[$0..<$0+8].reduce(0){($0<<1)|$1}})==publicKey else { throw TonSendError.wrongOwner }
    }
    private func getter(_ address:String,_ method:String,_ stack:[TonJSON]=[]) async throws -> [TonJSON] {
        let j=try await rpc("runGetMethod",["address":.string(address),"method":.string(method),"stack":.array(stack)])
        guard j["exit_code"].integer==0,let result=j["stack"].array,result.count<=16 else { throw TonSendError.malformed };return result
    }
    static func stackCell(_ item:TonJSON) throws -> TonCell {
        guard let a=item.array,a.count==2,["cell","slice"].contains(a[0].string ?? "") else { throw TonSendError.malformed }
        if let boc=(a[1]["bytes"].string ?? a[1].string).flatMap(TonIdentity.base64) { return try TonCell.parse(boc) }
        let o=a[1]["object"]
        guard o["special"] == .bool(false),o["refs"].array?.isEmpty==true,let count=o["data"]["len"].integer,count>=0,count<=1023,
              let bytes=o["data"]["b64"].string.flatMap(TonIdentity.base64),bytes.count*8>=count else { throw TonSendError.malformed }
        return try TonCell(Array(bytes.flatMap{b in (0..<8).reversed().map{(b>>$0)&1}}.prefix(Int(count))))
    }
    static func stackAddress(_ j:TonJSON) throws -> String {
        let c=try stackCell(j);guard c.bits.count==267,Array(c.bits.prefix(3))==[1,0,0] else { throw TonSendError.malformed }
        let data=Data(stride(from:3,to:267,by:8).map { c.bits[$0..<$0+8].reduce(0){($0<<1)|$1} })
        return String(Int8(bitPattern:data[0]))+":"+TronSendCrypto.hex(Data(data.dropFirst()))
    }
    private func jettonWallet(master:String,owner:String) async throws -> String {
        let s=try await getter(master,"get_wallet_address",[.array([.string("tvm.Slice"),.string(try TonIdentity.addressSlice(owner))])])
        guard s.count==1 else { throw TonSendError.malformed };return try Self.stackAddress(s[0])
    }
    private func jettonBalance(master:String,wallet:String,owner:String) async throws -> TonAmount {
        let s=try await getter(wallet,"get_wallet_data")
        guard s.count==4,try Self.stackAddress(s[1])==owner,try Self.stackAddress(s[2])==master,
              let a=s[0].array,a.count==2,a[0].string=="num",let value=a[1].string else { throw TonSendError.wrongOwner }
        guard let n=TonAmount(value.hasPrefix("0x") ? String(value.dropFirst(2)):value,radix:value.hasPrefix("0x") ? 16:10) else { throw TonSendError.amount };return n
    }
    public func quote(sender:String,recipient:String,reference:String,publicKey:Data,decimals:Int,amount:String,maximum:Bool=false,memo:String="",multisig:TonMultisigPolicy? = nil) async throws -> TonSendPlan {
        let sender=try network.address(sender),recipient=try network.address(recipient),reference=reference=="native" ? reference:try network.address(reference)
        guard sender == (try multisig?.address(network:network) ?? TonSendCrypto.address(publicKey:publicKey)),(0...255).contains(decimals),memo.utf8.count<=120,let requested=TonAmount(amount),requested>0 else { throw TonSendError.amount }
        async let source=account(sender);async let destination=account(recipient)
        let (a,d)=try await (source,destination);try validateWallet(a,publicKey:publicKey,multisig:multisig)
        var balance=TonAmount(a.balance),wallet:String?,recipientWallet:String?
        if reference != "native" {
            async let fromWallet=jettonWallet(master:reference,owner:sender);async let toWallet=jettonWallet(master:reference,owner:recipient)
            (wallet,recipientWallet)=try await (fromWallet,toWallet)
            balance=try await jettonBalance(master:reference,wallet:wallet!,owner:sender)
            let metadata=try await index("jettons/"+reference)
            guard metadata?["metadata"]["decimals"].text.flatMap(UInt64.init)==UInt64(decimals),
                  try network.address(metadata?["metadata"]["address"].string ?? "")==reference else { throw TonSendError.metadataChanged }
        }
        let now=Date.now,expiry=UInt32(now.timeIntervalSince1970)+(multisig == nil ? 300 : 3900)
        let query = multisig == nil ? UInt64.random(in:1...UInt64.max) : (UInt64(expiry)<<32)|UInt64.random(in:1...UInt64(UInt32.max))
        func plan(_ amount:TonAmount,_ fee:UInt64,_ reserve:UInt64) -> TonSendPlan {
            .init(network:network,sender:sender,recipient:recipient,reference:reference,publicKey:publicKey,decimals:decimals,requestedAmount:maximum ? balance:requested,amount:amount,assetBalance:balance,nativeBalance:a.balance,sequence:multisig == nil ? a.sequence : 0,expiration:expiry,deploy:!a.active,bounce:reference != "native" || d.active,fee:fee,feeReserve:reserve,attached:reference=="native" ? (amount.uint64 ?? UInt64.max):150_000_000,jettonWallet:wallet,recipientJettonWallet:recipientWallet,queryID:query,memo:memo,createdAt:now,multisig:multisig)
        }
        // Simulate a small native amount for Max before reserving the measured fee.
        let initial=plan(maximum && reference=="native" ? TonAmount(min(a.balance/2,1_000_000)):maximum ? balance:requested,1,1)
        try initial.validate()
        let estimate=try await simulate(initial),reserve=try Self.reserve(estimate)
        guard reference != "native" || a.balance>reserve else { throw SendFeeFundingError.insufficientNativeBalance }
        let final=plan(maximum ? (reference=="native" ? balance-reserve:balance):requested,estimate,reserve)
        try final.validate()
        if maximum && reference=="native" { let actual=try await simulate(final);guard actual<=reserve else { throw TonSendError.feeTooHigh } }
        return final
    }
    static func reserve(_ fee:UInt64) throws -> UInt64 {
        guard fee>0,fee<=200_000_000 else { throw TonSendError.feeTooHigh };return fee+fee/2+1_000_000
    }
    private func simulate(_ plan:TonSendPlan) async throws -> UInt64 {
        let trace=try await index("traces/emulate",body:.object(["boc":.string(try TonSendCrypto.unsigned(plan).base64EncodedString())]),query:"?ignore_signature_check=true")!
        let bodyHash=TronSendCrypto.hex(try TonSendCrypto.body(plan,Data(repeating:0,count:64)).hash)
        let proof=try TonSendProof.decode(trace,plan:plan,bodyHash:bodyHash,messageHash:TronSendCrypto.hex(try TonCell.parse(TonSendCrypto.unsigned(plan)).hash),emulated:true)
        guard proof.complete,proof.success else { throw TonSendError.simulationFailed };return proof.fee
    }
    public func preflight(_ plan:TonSendPlan) async throws {
        try plan.validate();guard plan.network==network else { throw TonSendError.wrongNetwork }
        async let simulation = simulate(plan)
        let a=try await account(plan.sender);try validateWallet(a,publicKey:plan.publicKey,multisig:plan.multisig)
        guard (plan.multisig != nil || a.sequence==plan.sequence),a.active != plan.deploy,a.balance>=plan.attached+plan.feeReserve else { throw TonSendError.changed }
        if let wallet=plan.jettonWallet {
            async let source = jettonWallet(master:plan.reference,owner:plan.sender)
            async let destination = jettonWallet(master:plan.reference,owner:plan.recipient)
            async let balance = jettonBalance(master:plan.reference,wallet:wallet,owner:plan.sender)
            let (senderWallet, recipientWallet, amount) = try await (source, destination, balance)
            guard senderWallet==wallet,recipientWallet==plan.recipientJettonWallet,
                  amount>=plan.amount else { throw TonSendError.changed }
        }
        guard try await simulation<=plan.feeReserve else { throw TonSendError.feeTooHigh }
    }
    public func submit(_ signed:TonSignedSend,plan:TonSendPlan) async throws -> TonSendReceipt {
        try TonSendCrypto.verify(signed,plan:plan);guard plan.network==network else { throw TonSendError.wrongNetwork }
        if Date.now.timeIntervalSince1970>=Double(plan.expiration) { return try await status(signed,plan:plan) }
        do {
            let accepted=try await rpc("sendBoc",["boc":.string(signed.bytes.base64EncodedString())])
            guard accepted["@type"].string=="ok" else { throw TonSendError.malformed }
            return .init(hash:signed.hash,outcome:.accepted)
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            OathDiagnostics.record(error,component:"ton_send",operation:"broadcast",context:["chain":"ton"])
            return try await status(signed,plan:plan)
        }
    }
    public func status(_ signed:TonSignedSend,plan:TonSendPlan) async throws -> TonSendReceipt {
        try TonSendCrypto.verify(signed,plan:plan);guard plan.network==network else { throw TonSendError.wrongNetwork }
        // The index accepts normalized external-message hashes. A missing trace
        // never proves failure, expiry, replacement, or a successful transfer.
        if let trace=try await index("traces/"+signed.hash,optional:true) {
            let p=try TonSendProof.decode(trace,plan:plan,bodyHash:signed.bodyHash,messageHash:TronSendCrypto.hex(try TonCell.parse(signed.bytes).hash),emulated:false)
            if p.complete { return .init(hash:signed.hash,outcome:p.success ? .confirmed:.failed,transactionHash:p.hash,fee:p.fee,lt:p.lt,timestamp:p.timestamp) }
            return .init(hash:signed.hash,outcome:.accepted)
        }
        // Multisig uses a replay dictionary, not a sequential counter. Expiry
        // requires proof that its query was never accepted, using pinned state.
        if Date.now.timeIntervalSince1970>Double(plan.expiration)+60 {
            let head=try await rpc("getMasterchainInfo"),block=head["last"]
            let seqno=try Self.uint(block["seqno"])
            guard let shard=block["shard"].text else { throw TonSendError.malformed }
            let header=try await rpc("getBlockHeader",["workchain":.number("-1"),"shard":.string(shard),"seqno":.number(String(seqno))])
            if try Self.uint(header["gen_utime"])>UInt64(plan.expiration)+60 {
                // Pin the account read to that masterchain block. Wall-clock
                // expiry or an index miss alone must never release a send.
                let state=try await account(plan.sender,seqno:seqno)
                if let multisig = plan.multisig {
                    try validateWallet(state,publicKey:plan.publicKey,multisig:multisig)
                    let neverAccepted = try state.data.map { try TonMultisigPolicy.queryWasNeverAccepted(plan.queryID,data:$0) } ?? false
                    if !state.active || neverAccepted {
                        return .init(hash:signed.hash,outcome:.expired)
                    }
                } else if state.sequence==plan.sequence {
                    try validateWallet(state,publicKey:plan.publicKey)
                    return .init(hash:signed.hash,outcome:.expired)
                }
            }
        }
        return .init(hash:signed.hash,outcome:.unknown)
    }
}

extension TonSendClient {
    public func walletConnectReview(_ request: WalletConnectTonRequest, publicKey: Data) async throws -> WalletConnectTonPlan {
        let rebuilt = try WalletConnectTonRequest(method:request.method, chain:request.network.walletConnectChain, account:request.account, domain:request.domain, params:JSONEncoder().encode(request.params))
        guard request == rebuilt else { throw TonSendError.changed }
        guard request.network == network, request.broadcasts, try TonSendCrypto.address(publicKey:publicKey) == request.account else { throw TonSendError.wrongOwner }
        let a=try await account(request.account); try validateWallet(a,publicKey:publicKey)
        let now=Date.now, expiration=min(request.expiration ?? UInt32.max,UInt32(now.timeIntervalSince1970)+300)
        func plan(_ fee: UInt64, _ reserve: UInt64) -> WalletConnectTonPlan {
            .init(request:request,publicKey:publicKey,sequence:a.sequence,expiration:expiration,deploy:!a.active,fee:fee,feeReserve:reserve,createdAt:now)
        }
        guard request.amount < a.balance else { throw SendFeeFundingError.insufficientNativeBalance }
        let estimate=try await walletConnectSimulate(plan(1,1)), reserve=try Self.reserve(estimate.walletFee)
        guard reserve <= a.balance-request.amount else { throw SendFeeFundingError.insufficientNativeBalance }
        let result=plan(estimate.fee,reserve); try result.validate(); return result
    }
    private func walletConnectSimulate(_ plan: WalletConnectTonPlan) async throws -> WalletConnectTonProof {
        let bytes=try WalletConnectTonCrypto.unsigned(plan)
        let trace=try await index("traces/emulate",body:.object(["boc":.string(bytes.base64EncodedString())]),query:"?ignore_signature_check=true")!
        let proof=try WalletConnectTonProof.decode(trace,plan:plan,bytes:bytes,emulated:true)
        guard proof.complete, proof.success else { throw TonSendError.simulationFailed }; return proof
    }
    public func walletConnectPreflight(_ plan: WalletConnectTonPlan) async throws {
        try plan.validate(); guard plan.request.network == network else { throw TonSendError.wrongNetwork }
        async let simulation=walletConnectSimulate(plan)
        let a=try await account(plan.request.account); try validateWallet(a,publicKey:plan.publicKey)
        guard a.sequence==plan.sequence, a.active != plan.deploy, a.balance >= plan.request.amount,
              plan.feeReserve <= a.balance-plan.request.amount else { throw TonSendError.changed }
        guard try await simulation.walletFee <= plan.feeReserve else { throw TonSendError.feeTooHigh }
    }
    public func walletConnectSubmit(_ signed: TonSignedSend, plan: WalletConnectTonPlan) async throws -> TonSendReceipt.Outcome {
        try WalletConnectTonCrypto.verify(signed,plan:plan); guard plan.request.network==network else { throw TonSendError.wrongNetwork }
        if Date.now.timeIntervalSince1970 >= Double(plan.expiration) { return try await walletConnectStatus(signed,plan:plan) }
        do {
            let accepted=try await rpc("sendBoc",["boc":.string(signed.bytes.base64EncodedString())])
            guard accepted["@type"].string=="ok" else { throw TonSendError.malformed }; return .accepted
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            OathDiagnostics.record(error,component:"walletconnect",operation:"ton_broadcast",context:["chain":"ton"])
            return try await walletConnectStatus(signed,plan:plan)
        }
    }
    public func walletConnectStatus(_ signed: TonSignedSend, plan: WalletConnectTonPlan) async throws -> TonSendReceipt.Outcome {
        try WalletConnectTonCrypto.verify(signed,plan:plan); guard plan.request.network==network else { throw TonSendError.wrongNetwork }
        if let trace=try await index("traces/"+signed.hash,optional:true) {
            let proof=try WalletConnectTonProof.decode(trace,plan:plan,bytes:signed.bytes,emulated:false)
            return proof.complete ? (proof.success ? .confirmed:.failed):.accepted
        }
        if Date.now.timeIntervalSince1970 > Double(plan.expiration)+60 {
            let head=try await rpc("getMasterchainInfo"), block=head["last"], seqno=try Self.uint(block["seqno"])
            guard let shard=block["shard"].text else { throw TonSendError.malformed }
            let header=try await rpc("getBlockHeader",["workchain":.number("-1"),"shard":.string(shard),"seqno":.number(String(seqno))])
            if try Self.uint(header["gen_utime"]) > UInt64(plan.expiration)+60 {
                let state=try await account(plan.request.account,seqno:seqno); try validateWallet(state,publicKey:plan.publicKey)
                if state.sequence==plan.sequence { return .expired }
            }
        }
        return .unknown
    }
}
