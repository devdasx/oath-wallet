import Foundation
import OathDiagnostics

/// Confirmed-state quotes and finalized receipts. Every request is bounded;
/// independent preparation reads overlap, while a signed send is only replayed.
public actor SolanaSendClient {
    public nonisolated let network:SolanaSendNetwork
    private let endpoints:[URL],transport:any AnkrTransport
    private let permits=AnkrPermits(count:4)
    private var verified=[URL:Date]()
    public init(network:SolanaSendNetwork = .mainnet,apiKey:String?=nil,transport:any AnkrTransport = AnkrHTTPTransport()) throws {
        self.network=network;self.transport=transport
        if let apiKey {
            guard network == .mainnet,!apiKey.isEmpty,apiKey.count<=256,apiKey.utf8.allSatisfy({(48...57).contains($0)||(65...90).contains($0)||(97...122).contains($0)}) else { throw SolanaSendError.configuration }
            endpoints=[URL(string:"https://rpc.ankr.com/solana")!.appendingPathComponent(apiKey),network.endpoint]
        } else { endpoints=[network.endpoint] }
    }
    private func request(_ url:URL,_ method:String,_ params:[SolanaJSON]) async throws -> SolanaJSON {
        var request=URLRequest(url:url);request.httpMethod="POST";request.timeoutInterval=10
        request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        request.httpBody=try JSONEncoder().encode(SolanaJSON.object(["jsonrpc":.string("2.0"),"id":.number("1"),"method":.string(method),"params":.array(params)]))
        try await permits.acquire()
        let data:Data,status:Int
        do { (data,status)=try await transport.send(request) }
        catch { await permits.release();OathDiagnostics.record(error,component:"solana_send",operation:method,context:["chain":"solana"]);if Task.isCancelled || error is CancellationError { throw CancellationError() };throw SolanaSendError.transport }
        await permits.release();try Task.checkCancellation()
        DiagnosticHTTP.response(data,status:status,request:request)
        guard status==200 else { throw SolanaSendError.http(status) }
        guard data.count<=4_194_304 else { throw SolanaSendError.malformed }
        let j=try JSONDecoder().decode(SolanaJSON.self,from:data)
        guard j["id"].integer==1,j["jsonrpc"].string=="2.0" else { throw SolanaSendError.malformed }
        if !j["error"].isNull {
            guard case .number(let raw)=j["error"]["code"],let code=Int(raw) else { throw SolanaSendError.malformed }
            OathDiagnostics.record(SolanaSendError.rpc(code),component:"solana_send",operation:method,context:["chain":"solana","rpc_code":String(code)])
            throw SolanaSendError.rpc(code)
        }
        guard case .object(let object)=j,object["result"] != nil else { throw SolanaSendError.malformed }
        return j["result"]
    }
    func rpc(_ method:String,_ params:[SolanaJSON]=[]) async throws -> SolanaJSON {
        let providers = method=="getTransaction" ? Array(endpoints.reversed()):endpoints
        for (index,url) in providers.enumerated() {
            do {
                if Date.now.timeIntervalSince(verified[url] ?? .distantPast)>60 {
                    let genesis=try await request(url,"getGenesisHash",[])
                    guard genesis.string==network.genesis else { throw SolanaSendError.wrongNetwork }
                    verified[url] = .now
                }
                let result=try await request(url,method,params)
                if result.isNull,method=="getTransaction",index+1<providers.count { continue }
                return result
            } catch {
                OathDiagnostics.record(error,component:"solana_send",operation:method,context:["chain":"solana"])
                let retry:Bool
                switch error {
                case SolanaSendError.http(let code):retry=code==429 || code==408 || code>=500
                case SolanaSendError.rpc(let code):retry=[-32005,-32016,429,-32429].contains(code)
                case SolanaSendError.transport:retry=true
                default:retry=false
                }
                guard retry,index+1<providers.count else { throw error }
            }
        }
        throw SolanaSendError.transport
    }
    private func config(_ slot:UInt64=0,encoding:Bool=false,finalized:Bool=false) -> SolanaJSON {
        var v:[String:SolanaJSON]=["commitment":.string(finalized ? "finalized":"confirmed")]
        if slot>0 { v["minContextSlot"] = .number(String(slot)) }
        if encoding { v["encoding"] = .string("jsonParsed") }
        return .object(v)
    }
    private func value(_ response:SolanaJSON,slot:UInt64) throws -> SolanaJSON {
        guard let observed=response["context"]["slot"].integer,observed>=slot,case .object(let j)=response,j["value"] != nil else { throw SolanaSendError.malformed }
        return response["value"]
    }
    private func account(_ owner:String,slot:UInt64) async throws -> SolanaJSON { try value(await rpc("getAccountInfo",[.string(owner),config(slot,encoding:true)]),slot:slot) }
    private func balance(_ owner:String,slot:UInt64) async throws -> UInt64 {
        guard let n=try value(await rpc("getBalance",[.string(owner),config(slot)]),slot:slot).integer else { throw SolanaSendError.malformed };return n
    }
    private func newRecipientReserve(_ recipient:String,slot:UInt64) async throws -> UInt64 {
        guard try await account(recipient,slot:slot).isNull else { return 0 }
        guard let minimum=try await rpc("getMinimumBalanceForRentExemption",[.number("0"),config(slot)]).integer,
              minimum>0,minimum<=100_000_000 else { throw SolanaSendError.malformed }
        return minimum
    }
    private struct Tokens:Sendable { let program:String,balance:UInt64,sources:[SolanaSendSource],fees:[UInt64],rent:UInt64 }
    private func tokens(sender:String,recipient:String,mint:String,decimals:Int,requested:UInt64,maximum:Bool,slot:UInt64,memo:String) async throws -> Tokens {
        async let mintWork=account(mint,slot:slot)
        async let sourceWork=rpc("getTokenAccountsByOwner",[.string(sender),.object(["mint":.string(mint)]),config(slot,encoding:true)])
        let (mintAccount,sourceResponse)=try await (mintWork,sourceWork)
        guard let program=mintAccount["owner"].string,[SolanaIdentity.tokenProgram,SolanaIdentity.token2022Program].contains(program),
              mintAccount["data"]["parsed"]["type"].string=="mint" else { throw SolanaSendError.metadataChanged }
        let info=mintAccount["data"]["parsed"]["info"]
        guard info["isInitialized"] == .bool(true),info["decimals"].integer==UInt64(decimals) else { throw SolanaSendError.metadataChanged }
        let extensions=try tokenExtensions(info)
        let allowed:Set<String>=["transferFeeConfig","mintCloseAuthority","metadataPointer","tokenMetadata","permanentDelegate","groupPointer","tokenGroup","groupMemberPointer","tokenGroupMember","defaultAccountState"]
        var defaultFrozen=false
        for e in extensions {
            guard let name=e["extension"].string,allowed.contains(name) else { throw SolanaSendError.unsupportedToken }
            if name=="defaultAccountState" {
                guard let state=e["state"]["accountState"].string,["initialized","frozen"].contains(state) else { throw SolanaSendError.malformed }
                defaultFrozen=state=="frozen"
            }
        }
        let feeConfig=extensions.first { $0["extension"].string=="transferFeeConfig" }
        let destination=try SolanaSendCrypto.associatedAddress(owner:recipient,mint:mint,program:program)
        async let destWork=account(destination,slot:slot)
        async let recipientWork=account(recipient,slot:slot)
        async let epochWork:SolanaJSON? = feeConfig == nil ? nil:rpc("getEpochInfo",[config(slot)])
        let (dest,recipientAccount,epoch)=try await (destWork,recipientWork,epochWork)
        // Receiving wallet addresses must not be mistaken for token accounts.
        if [SolanaIdentity.tokenProgram,SolanaIdentity.token2022Program].contains(recipientAccount["owner"].string ?? "") { throw SolanaSendError.wrongOwner }
        if !dest.isNull { _ = try validateTokenAccount(dest,owner:recipient,mint:mint,program:program,decimals:decimals,memo:memo,incoming:true) }
        var rent:UInt64=0
        if dest.isNull {
            guard !defaultFrozen else { throw SolanaSendError.frozen }
            let size=program==SolanaIdentity.tokenProgram ? 165:(feeConfig == nil ? 170:182)
            guard let n=try await rpc("getMinimumBalanceForRentExemption",[.number(String(size)),config(slot)]).integer,n<=100_000_000 else { throw SolanaSendError.feeTooHigh };rent=n
        }
        guard let accounts=try value(sourceResponse,slot:slot).array,accounts.count<=2048 else { throw SolanaSendError.malformed }
        var all=[SolanaSendSource](),balance:UInt64=0
        for a in accounts {
            let spendable=try validateTokenAccount(a["account"],owner:sender,mint:mint,program:program,decimals:decimals,memo:memo,incoming:false)
            guard let address=a["pubkey"].string,SolanaIdentity.isAddress(address),let raw=a["account"]["data"]["parsed"]["info"]["tokenAmount"]["amount"].string,let n=UInt64(raw) else { throw SolanaSendError.malformed }
            // A frozen account does not prevent spending a separate unfrozen
            // account for this mint. Its balance is excluded from Max.
            if !spendable { continue }
            let sum=balance.addingReportingOverflow(n);guard !sum.overflow else { throw SolanaSendError.amount };balance=sum.partialValue
            if n>0 { all.append(.init(address:address,amount:n)) }
        }
        var remaining=maximum ? balance:requested
        guard remaining>0,remaining<=balance else { throw SolanaSendError.insufficientFunds }
        all.sort { $0.amount==$1.amount ? $0.address<$1.address:$0.amount>$1.amount }
        var sources=[SolanaSendSource](),fees=[UInt64]()
        var bps:UInt64=0,cap:UInt64=0
        if let feeConfig {
            let state=feeConfig["state"]
            guard let current=epoch?["epoch"].integer,let newerEpoch=state["newerTransferFee"]["epoch"].integer else { throw SolanaSendError.malformed }
            let f=state[current>=newerEpoch ? "newerTransferFee":"olderTransferFee"]
            guard let b=f["transferFeeBasisPoints"].integer,b<=10_000,
                  let c=f["maximumFee"].string.flatMap(UInt64.init) ?? f["maximumFee"].integer else { throw SolanaSendError.malformed };bps=b;cap=c
        }
        for s in all where remaining>0 {
            let n=min(s.amount,remaining);sources.append(.init(address:s.address,amount:n));remaining-=n
            // ceil(amount*bps/10_000) without overflowing u64.
            if feeConfig != nil { fees.append(min(cap,(n/10_000)*bps+((n%10_000)*bps+9999)/10_000)) }
        }
        guard sources.count<=12 else { throw SolanaSendError.amount }
        return .init(program:program,balance:balance,sources:sources,fees:fees,rent:rent)
    }
    private func tokenExtensions(_ info:SolanaJSON) throws -> [SolanaJSON] {
        guard case .object(let fields)=info else { throw SolanaSendError.malformed }
        // An omitted extensions field is normal for classic SPL accounts.
        guard let raw=fields["extensions"] else { return [] }
        guard let entries=raw.array,entries.count<=32 else { throw SolanaSendError.malformed }
        let names=entries.compactMap { $0["extension"].string }
        guard names.count==entries.count,Set(names).count==names.count else { throw SolanaSendError.malformed }
        return entries
    }
    private func validateTokenAccount(_ a:SolanaJSON,owner:String,mint:String,program:String,decimals:Int,memo:String,incoming:Bool) throws -> Bool {
        let parsed=a["data"]["parsed"],i=parsed["info"]
        guard a["owner"].string==program,parsed["type"].string=="account",i["owner"].string==owner,i["mint"].string==mint,i["tokenAmount"]["decimals"].integer==UInt64(decimals) else { throw SolanaSendError.wrongOwner }
        guard ["initialized","frozen"].contains(i["state"].string ?? "") else { throw SolanaSendError.malformed }
        if incoming,i["state"].string=="frozen" { throw SolanaSendError.frozen }
        for e in try tokenExtensions(i) {
            guard let name=e["extension"].string,["immutableOwner","transferFeeAmount","memoTransfer","cpiGuard"].contains(name) else { throw SolanaSendError.unsupportedToken }
            if incoming,name=="memoTransfer",e["state"]["requireIncomingTransferMemos"] == .bool(true),memo.isEmpty { throw SolanaSendError.unsupportedToken }
        }
        return i["state"].string=="initialized"
    }
    public func quote(sender:String,recipient:String,reference:String,decimals:Int,amount:String,maximum:Bool=false,memo:String="") async throws -> SolanaSendPlan {
        guard SolanaIdentity.isAddress(sender),SolanaIdentity.isAddress(recipient),sender != recipient,reference=="native" || SolanaIdentity.isAddress(reference),
              let requested=UInt64(amount),requested>0,(0...255).contains(decimals),memo.utf8.count<=128 else { throw SolanaSendError.amount }
        let block=try await rpc("getLatestBlockhash",[config()])
        guard let slot=block["context"]["slot"].integer,let hash=block["value"]["blockhash"].string,let height=block["value"]["lastValidBlockHeight"].integer else { throw SolanaSendError.malformed }
        async let nativeWork=balance(sender,slot:slot)
        async let senderWork=account(sender,slot:slot)
        async let reserveWork:UInt64 = reference=="native" ? newRecipientReserve(recipient,slot:slot):0
        async let tokenWork:Tokens? = reference=="native" ? nil:tokens(sender:sender,recipient:recipient,mint:reference,decimals:decimals,requested:requested,maximum:maximum,slot:slot,memo:memo)
        async let priorityWork=rpc("getRecentPrioritizationFees",[.array([.string(sender)])])
        let (native,senderAccount,token,priorities,recipientReserve)=try await (nativeWork,senderWork,tokenWork,priorityWork,reserveWork)
        guard senderAccount["owner"].string==SolanaSendCrypto.system,senderAccount["executable"] == .bool(false),senderAccount["space"].integer==0 else { throw SolanaSendError.wrongOwner }
        guard let samples=priorities.array,samples.count<=150 else { throw SolanaSendError.malformed }
        let rates=try samples.map { j -> UInt64 in guard let n=j["prioritizationFee"].integer else { throw SolanaSendError.malformed };return n }.sorted()
        let rate=min(1_000_000,rates.isEmpty ? 0:rates[rates.count/2])
        var units:UInt32=reference=="native" && memo.isEmpty ? 10_000:UInt32(min(1_400_000,200_000*(token?.sources.count ?? 1))),fee:UInt64=5_000+(UInt64(units)*rate+999_999)/1_000_000
        let asset=token?.balance ?? native,requestedAmount=maximum ? asset:requested,rent=token?.rent ?? 0
        guard requestedAmount<=asset else { throw SolanaSendError.insufficientFunds }
        func plan() throws -> SolanaSendPlan {
            guard native>=fee+rent else { throw rent > 0 ? SolanaSendError.accountRent : SolanaSendError.insufficientFunds }
            let value=reference=="native" ? min(requestedAmount,native-fee-rent):requestedAmount
            let p=SolanaSendPlan(network:network,sender:sender,recipient:recipient,reference:reference,program:token?.program ?? "",decimals:decimals,
                requestedAmount:requestedAmount,amount:value,assetBalance:asset,nativeBalance:native,blockhash:hash,lastValidBlockHeight:height,slot:slot,
                transactionFee:fee,rent:rent,computeUnits:units,microLamports:rate,sources:token?.sources ?? [],tokenFees:token?.fees ?? [],memo:memo,recipientReserve:recipientReserve)
            try p.validate();return p
        }
        var p=try plan()
        let simulation=try await simulate(p)
        guard let used=simulation["unitsConsumed"].integer,used>0,used<=1_400_000 else { throw SolanaSendError.simulationFailed }
        units=UInt32(min(1_400_000,max(10_000,used+used/5)))
        p=try plan()
        let feeResponse=try await rpc("getFeeForMessage",[.string(try SolanaSendCrypto.message(p).base64EncodedString()),config(slot)])
        guard let actual=try value(feeResponse,slot:slot).integer,actual>0,actual<=10_000_000 else { throw SolanaSendError.expired }
        fee=actual;p=try plan();_ = try await simulate(p)
        return p
    }
    private func simulate(_ p:SolanaSendPlan) async throws -> SolanaJSON {
        let bytes=try Data([1])+Data(repeating:0,count:64)+SolanaSendCrypto.message(p)
        let j=try await rpc("simulateTransaction",[.string(bytes.base64EncodedString()),.object(["encoding":.string("base64"),"sigVerify":.bool(false),"replaceRecentBlockhash":.bool(false),"commitment":.string("confirmed"),"minContextSlot":.number(String(p.slot))])])
        let v=try value(j,slot:p.slot)
        guard case .object(let fields)=v,fields["err"] != nil else { throw SolanaSendError.malformed }
        guard v["err"].isNull else {
            OathDiagnostics.record(Self.simulationError(v["err"]),component:"solana_send",operation:"simulate",context:["chain":"solana","stage":"quote"])
            // Keep the original diagnostic above. Resolve only the explicit rent
            // failure, never infer account activation from a generic rejection.
            if v["err"]["InsufficientFundsForRent"]["account_index"].integer != nil {
                if p.reference == "native", p.removal == nil,
                   v["err"]["InsufficientFundsForRent"]["account_index"].integer == 1 {
                    let destination = try await account(p.recipient,slot:p.slot)
                    if destination.isNull {
                        guard let minimum = try await rpc("getMinimumBalanceForRentExemption",[.number("0"),config(p.slot)]).integer,
                              minimum > 0, minimum <= 100_000_000 else { throw SolanaSendError.malformed }
                        if p.amount < minimum { throw SolanaSendError.recipientMinimum(minimum) }
                    }
                }
                throw SolanaSendError.storageBalance
            }
            throw SolanaSendError.simulationFailed
        };return v
    }
    /// Preserve only protocol classifications, never logs or echoed accounts.
    static func simulationError(_ value:SolanaJSON) -> NSError {
        let allowed:Set<String>=["InsufficientFundsForRent","InsufficientFundsForFee","AccountNotFound","BlockhashNotFound","InvalidAccountData","InsufficientFunds","InvalidArgument","InvalidInstructionData","InvalidSeeds","IncorrectProgramId","MissingRequiredSignature","ComputationalBudgetExceeded","AccountNotRentExempt"]
        if let pair=value["InstructionError"].array,pair.count==2,let index=pair[0].integer,index<32 {
            if let code=pair[1]["Custom"].integer,code<=UInt32.max { return NSError(domain:"Solana.Program",code:Int(code),userInfo:[NSLocalizedDescriptionKey:"Instruction \(index) returned custom program error \(code)"]) }
            if let name=pair[1].string,allowed.contains(name) { return NSError(domain:"Solana.Simulation",code:-1,userInfo:[NSLocalizedDescriptionKey:name]) }
        }
        if let name=value.string,allowed.contains(name) { return NSError(domain:"Solana.Simulation",code:-1,userInfo:[NSLocalizedDescriptionKey:name]) }
        if case .object(let object)=value,object["InsufficientFundsForRent"] != nil { return NSError(domain:"Solana.Simulation",code:-1,userInfo:[NSLocalizedDescriptionKey:"InsufficientFundsForRent"]) }
        return NSError(domain:"Solana.Simulation",code:-1,userInfo:[NSLocalizedDescriptionKey:"Transfer simulation failed"])
    }
    public func preflight(_ p:SolanaSendPlan) async throws {
        try p.validate();guard p.network==network else { throw SolanaSendError.wrongNetwork }
        if let removal=p.removal { try await validateRemoval(owner:p.sender,removal:removal,slot:p.slot) }
        let validity=try await rpc("isBlockhashValid",[.string(p.blockhash),config(p.slot)])
        guard try value(validity,slot:p.slot) == .bool(true) else { throw SolanaSendError.expired }
        _ = try await simulate(p)
    }
    public func submit(_ signed:SolanaSignedSend,plan:SolanaSendPlan,reconcileFirst:Bool = true) async throws -> SolanaSendReceipt {
        try SolanaSendCrypto.verify(signed,plan:plan);guard plan.network==network else { throw SolanaSendError.wrongNetwork }
        if reconcileFirst {
            let before=try await status(signed,plan:plan)
            if before.outcome != .unknown { return before }
        } else { try plan.validate() } // Only a fresh, authorized, journaled send may bypass recovery reads.
        let result=try await rpc("sendTransaction",[.string(signed.bytes.base64EncodedString()),.object(["encoding":.string("base64"),"skipPreflight":.bool(false),"preflightCommitment":.string("confirmed"),"maxRetries":.number("3"),"minContextSlot":.number(String(plan.slot))])])
        guard result.string==signed.hash else { throw SolanaSendError.changed }
        return .init(hash:signed.hash,outcome:.accepted)
    }
    public func status(_ signed:SolanaSignedSend,plan:SolanaSendPlan) async throws -> SolanaSendReceipt {
        try SolanaSendCrypto.verify(signed,plan:plan);guard plan.network==network else { throw SolanaSendError.wrongNetwork }
        let statuses=try await rpc("getSignatureStatuses",[.array([.string(signed.hash)]),.object(["searchTransactionHistory":.bool(true)])])
        guard let values=statuses["value"].array,values.count==1 else { throw SolanaSendError.malformed }
        let status=values[0]
        if !status.isNull {
            guard ["processed","confirmed","finalized"].contains(status["confirmationStatus"].string ?? "") else { throw SolanaSendError.malformed }
            if status["confirmationStatus"].string != "finalized" { return .init(hash:signed.hash,outcome:.accepted) }
            return try await receipt(signed,plan:plan)
        }
        // A null recent cache is not failure. Only expiry rooted by a finalized
        // height plus an archive transaction lookup releases this authorization.
        guard let height=try await rpc("getBlockHeight",[config(finalized:true)]).integer else { throw SolanaSendError.malformed }
        if height>plan.lastValidBlockHeight {
            let receipt=try await receipt(signed,plan:plan)
            if receipt.outcome != .unknown { return receipt }
            // After a long offline interval, a pruned node's null is not proof
            // of non-submission. Retain the journal until archive coverage is
            // available instead of releasing an authorization that may have paid.
            guard let first=try await rpc("getFirstAvailableBlock").integer,first<=plan.slot else {
                throw SolanaSendError.rpc(-32001)
            }
            return .init(hash:signed.hash,outcome:.expired)
        }
        return .init(hash:signed.hash,outcome:.unknown)
    }
    private func receipt(_ signed:SolanaSignedSend,plan:SolanaSendPlan) async throws -> SolanaSendReceipt {
        let j=try await rpc("getTransaction",[.string(signed.hash),.object(["encoding":.string("base64"),"commitment":.string("finalized"),"maxSupportedTransactionVersion":SolanaTransactionRead.maximumVersion])])
        if j.isNull { return .init(hash:signed.hash,outcome:.unknown) }
        guard let tx=j["transaction"].array,tx.count==2,tx[1].string=="base64",let encoded=tx[0].string,Data(base64Encoded:encoded)==signed.bytes,
              let fee=j["meta"]["fee"].integer,fee<=plan.transactionFee,let slot=j["slot"].integer,slot>=plan.slot,
              let time=j["blockTime"].integer,case .object(let meta)=j["meta"],meta["err"] != nil else { throw SolanaSendError.changed }
        return .init(hash:signed.hash,outcome:j["meta"]["err"].isNull ? .confirmed:.failed,fee:fee,slot:slot,timestamp:Double(time))
    }
}

extension SolanaSendClient {
    private func validateRemoval(owner:String,removal:SolanaPermissionRemoval,slot:UInt64) async throws {
        try removal.validate()
        let a=try await account(removal.account,slot:slot),i=a["data"]["parsed"]["info"]
        guard a["owner"].string==removal.program,a["data"]["parsed"]["type"].string=="account",i["owner"].string==owner,
              i["mint"].string==removal.mint,i["delegate"].string==removal.delegate,i["delegatedAmount"]["amount"].string==String(removal.amount) else { throw PermissionError.changed }
    }
    public func permissionRemoved(owner:String,removal:SolanaPermissionRemoval,minimumSlot:UInt64=0) async throws -> Bool {
        try removal.validate()
        let a=try await account(removal.account,slot:minimumSlot)
        if a.isNull { return true } // Closed accounts cannot retain a delegate.
        let i=a["data"]["parsed"]["info"]
        guard a["owner"].string==removal.program,i["owner"].string==owner,i["mint"].string==removal.mint else { throw PermissionError.changed }
        return i["delegate"].isNull || i["delegate"].string != removal.delegate
    }
    public func quoteRemoval(owner:String,removal:SolanaPermissionRemoval) async throws -> SolanaSendPlan {
        guard SolanaIdentity.isAddress(owner) else { throw PermissionError.malformed }
        let block=try await rpc("getLatestBlockhash",[config()])
        guard let slot=block["context"]["slot"].integer,let hash=block["value"]["blockhash"].string,let height=block["value"]["lastValidBlockHeight"].integer else { throw SolanaSendError.malformed }
        async let validated:Void=validateRemoval(owner:owner,removal:removal,slot:slot)
        async let funds=balance(owner,slot:slot)
        let (native,_)=try await(funds,validated)
        var units:UInt32=100_000,fee:UInt64=5_000
        func plan()->SolanaSendPlan {
            .init(network:network,sender:owner,recipient:removal.account,requestedAmount:0,amount:0,assetBalance:native,nativeBalance:native,
                  blockhash:hash,lastValidBlockHeight:height,slot:slot,transactionFee:fee,computeUnits:units,removal:removal)
        }
        let simulated=try await simulate(plan())
        guard let used=simulated["unitsConsumed"].integer,used>0,used<1_000_000 else { throw SolanaSendError.simulationFailed }
        units=UInt32(max(10_000,used+used/5))
        guard let amount=try value(await rpc("getFeeForMessage",[.string(try SolanaSendCrypto.message(plan()).base64EncodedString()),config(slot)]),slot:slot).integer else { throw SolanaSendError.expired }
        fee=amount;let p=plan();try p.validate();_ = try await simulate(p);return p
    }
    public func permissions(owner:String) async throws -> PermissionScan {
        guard SolanaIdentity.isAddress(owner) else { throw PermissionError.malformed }
        async let classic=rpc("getTokenAccountsByOwner",[.string(owner),.object(["programId":.string(SolanaIdentity.tokenProgram)]),config(encoding:true)])
        async let extended=rpc("getTokenAccountsByOwner",[.string(owner),.object(["programId":.string(SolanaIdentity.token2022Program)]),config(encoding:true)])
        let responses=try await [classic,extended]
        var permissions=[WalletPermission](),mints=Set<String>()
        for (index,response) in responses.enumerated() {
            let program=index==0 ? SolanaIdentity.tokenProgram:SolanaIdentity.token2022Program
            guard let rows=try value(response,slot:0).array,rows.count<=2048 else { throw PermissionError.incomplete }
            for row in rows {
                let a=row["account"],i=a["data"]["parsed"]["info"]
                guard a["owner"].string==program,i["owner"].string==owner,let mint=i["mint"].string,SolanaIdentity.isAddress(mint),let address=row["pubkey"].string,SolanaIdentity.isAddress(address) else { throw PermissionError.malformed }
                if let delegate=i["delegate"].string {
                    guard SolanaIdentity.isAddress(delegate),let amount=i["delegatedAmount"]["amount"].string,UInt64(amount) != nil else { throw PermissionError.malformed }
                    permissions.append(.init(network:"solana",owner:owner,contract:mint,spender:delegate,kind:.delegate,amount:amount,program:program,tokenAccount:address))
                }
                if index==1 { mints.insert(mint) }
            }
        }
        let all=Array(mints).sorted()
        for start in stride(from:0,to:all.count,by:100) {
            let batch=Array(all[start..<min(start+100,all.count)])
            let result=try await rpc("getMultipleAccounts",[.array(batch.map(SolanaJSON.string)),config(encoding:true)])
            guard let rows=try value(result,slot:0).array,rows.count==batch.count else { throw PermissionError.malformed }
            for (i,a) in rows.enumerated() {
                guard a["owner"].string==SolanaIdentity.token2022Program else { throw PermissionError.changed }
                for e in try tokenExtensions(a["data"]["parsed"]["info"]) where e["extension"].string=="permanentDelegate" {
                    if let delegate=e["state"]["delegate"].string,SolanaIdentity.isAddress(delegate) {
                        permissions.append(.init(network:"solana",owner:owner,contract:batch[i],spender:delegate,kind:.permanentDelegate,amount:"0"))
                    }
                }
            }
        }
        return .init(network:"solana",owner:owner,permissions:permissions,coverage:.checked)
    }
}
