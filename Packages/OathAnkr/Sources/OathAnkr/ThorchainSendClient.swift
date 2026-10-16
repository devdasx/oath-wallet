import Foundation
import CryptoKit
import OathDiagnostics

/// Broadcast acknowledges CheckTx immediately; block inclusion is owned by the
/// durable status worker. Retries always reuse the exact signed transaction.
public actor ThorchainSendClient {
    public nonisolated let network:ThorchainSendNetwork
    private let api:URL,rpc:URL,transport:any AnkrTransport
    private let permits=AnkrPermits(count:4)
    public init(network:ThorchainSendNetwork = .mainnet,localAPI:URL?=nil,localRPC:URL?=nil,transport:any AnkrTransport = AnkrHTTPTransport()) throws {
        self.network=network;self.transport=transport
        if network == .mainnet {
            guard localAPI==nil,localRPC==nil else {throw ThorchainSendError.configuration}
            api=ThorchainClient.node;rpc=ThorchainClient.rpc
        } else {
            guard let a=localAPI,let r=localRPC else {throw ThorchainSendError.configuration}
            for url in [a,r] {
                guard url.scheme=="http",["127.0.0.1","localhost"].contains(url.host ?? ""),url.user==nil,url.password==nil else {throw ThorchainSendError.configuration}
            }
            api=a;rpc=r
        }
    }
    private func read(_ base:URL,_ path:String,query:[URLQueryItem]=[],body:SolanaJSON?=nil,missing:Bool=false,missingAccount:Bool=false,operation:String) async throws -> SolanaJSON {
        var url=URLComponents(url:base.appendingPathComponent(path),resolvingAgainstBaseURL:false)!
        if !query.isEmpty {url.queryItems=query}
        var request=URLRequest(url:url.url!);request.timeoutInterval=15
        request.setValue("OathWallet/1.0",forHTTPHeaderField:"User-Agent");request.setValue("oath-wallet",forHTTPHeaderField:"x-client-id")
        if let body {request.httpMethod="POST";request.httpBody=try JSONEncoder().encode(body);request.setValue("application/json",forHTTPHeaderField:"Content-Type")}
        var reported=false
        do {
            try await permits.acquire()
            let data:Data,status:Int
            do {(data,status)=try await transport.send(request)} catch {
                await permits.release()
                OathDiagnostics.record(error,component:"thorchain_send",operation:operation,context:["chain":"thorchain"])
                reported=true;throw error
            }
            await permits.release();try Task.checkCancellation()
            guard data.count<=4_194_304 else {throw ThorchainSendError.malformed}
            let decoded=Result { try JSONDecoder().decode(SolanaJSON.self,from:data) }
            let json=try? decoded.get()
            // An absent transaction is expected while waiting for inclusion.
            if missing,let json,let code=json["error"]["code"].text,code=="-32603",
               json["error"]["data"].string?.contains("not found")==true {return .null}
            if missingAccount,status==404,json?["code"].text=="5" {return .null}
            DiagnosticHTTP.response(data,status:status,request:request)
            guard status==200 else {throw ThorchainSendError.http(status)}
            guard let json else {
                // Preserve the original decoding failure before mapping it to
                // the stable app error. Never attach the response body.
                if case .failure(let error)=decoded {
                    OathDiagnostics.record(error,component:"thorchain_send",operation:operation,
                        context:["chain":"thorchain","stage":"decode_response","http_status":String(status)])
                    reported=true
                }
                throw ThorchainSendError.malformed
            }
            if !json["error"].isNull {
                OathDiagnostics.record(DiagnosticFailure(json["error"]["message"].string ?? "THORChain RPC failure"),component:"thorchain_send",operation:operation,context:["chain":"thorchain","rpc_code":json["error"]["code"].text ?? "unknown"])
                throw ThorchainSendError.transport
            }
            return json
        } catch {
            if !reported {OathDiagnostics.record(error,component:"thorchain_send",operation:operation,context:["chain":"thorchain"])}
            if error is CancellationError || Task.isCancelled {throw CancellationError()}
            throw error
        }
    }
    static func uint(_ j:SolanaJSON) throws -> UInt64 {
        guard let s=j.text,let value=UInt64(s),String(value)==s else {throw ThorchainSendError.malformed};return value
    }
    /// Response validation happens after transport. Keep its fixed operation
    /// name so parallel quote failures do not collapse into an opaque "quote"
    /// error. The caller's task-local operation ID is inherited unchanged.
    private func validated<T>(_ operation:String,_ body:() throws -> T) throws -> T {
        do {return try body()}
        catch {
            OathDiagnostics.record(error,component:"thorchain_send",operation:operation,
                context:["chain":"thorchain","stage":"validate_response"])
            throw error
        }
    }
    private func head() async throws -> (UInt64,UInt64) {
        let j=try await read(rpc,"status",operation:"status_head")["result"]
        return try validated("status_head") {
            guard j["node_info"]["network"].string==network.chainID,j["sync_info"]["catching_up"] == .bool(false),
                  let timestamp=j["sync_info"]["latest_block_time"].string else {throw ThorchainSendError.wrongNetwork}
            let parser=ISO8601DateFormatter();parser.formatOptions=timestamp.contains(".") ? [.withInternetDateTime,.withFractionalSeconds]:[.withInternetDateTime]
            guard let date=parser.date(from:timestamp),abs(date.timeIntervalSinceNow)<90 else {throw ThorchainSendError.expired}
            return try (Self.uint(j["sync_info"]["latest_block_height"]),Self.uint(j["sync_info"]["earliest_block_height"]))
        }
    }
    private func account(_ owner:String) async throws -> (UInt64,UInt64) {
        let j=try await read(api,"cosmos/auth/v1beta1/accounts/"+owner,operation:"account")["account"]
        return try validated("account") {
            guard j["@type"].string=="/cosmos.auth.v1beta1.BaseAccount",j["address"].string==owner else {throw ThorchainSendError.wrongOwner}
            return try (Self.uint(j["account_number"]),Self.uint(j["sequence"]))
        }
    }
    public func balance(owner:String,reference:String) async throws -> String {
        _ = try ThorchainSendCrypto.addressBytes(owner,network:network);_ = try ThorchainIdentity.reference(reference)
        let denom=reference=="native" ? "rune":reference
        let j=try await read(api,"cosmos/bank/v1beta1/balances/"+owner+"/by_denom",query:[.init(name:"denom",value:denom)],operation:"balance")["balance"]
        return try validated("balance") {
            guard j["denom"].string==denom,let amount=j["amount"].string else {throw ThorchainSendError.malformed}
            return try ThorchainSendAmount.checked(amount)
        }
    }
    private func fee() async throws -> UInt64 {
        let j=try await read(api,"thorchain/network",operation:"fee")
        return try validated("fee") {
            let value=try Self.uint(j["native_tx_fee_rune"])
            guard value>0,value<=ThorchainSendPlan.feeLimit else {throw ThorchainSendError.feeTooHigh};return value
        }
    }
    private func validateRecipient(_ recipient:String) async throws {
        let j=try await read(api,"cosmos/auth/v1beta1/accounts/"+recipient,missingAccount:true,operation:"recipient_account")
        if j.isNull {return} // A payment creates an ordinary unfunded account.
        try validated("recipient_account") {
            guard j["account"]["@type"].string=="/cosmos.auth.v1beta1.BaseAccount",j["account"]["address"].string==recipient else {throw ThorchainSendError.moduleRecipient}
        }
    }

    private func enabled(height:UInt64) async throws {
        let j=try await read(api,"thorchain/mimir",operation:"chain_status")
        try validated("chain_status") {
            guard case .object = j else {throw ThorchainSendError.malformed}
            for name in ["HALTCHAINGLOBAL","HALTTHORCHAIN"] {
                if let n=j[name].text.flatMap(Int64.init),n>0,UInt64(n)<=height {throw ThorchainSendError.halted}
            }
        }
    }
    private func decimals(_ reference:String) async throws -> Int {
        if ThorchainIdentity.hasProtocolDecimals(reference) {return 8}
        var key:String?,seen=Set<String>()
        for _ in 0..<50 {
            var query=[URLQueryItem(name:"pagination.limit",value:"100")]
            if let key {query.append(.init(name:"pagination.key",value:key))}
            let j=try await read(api,"cosmos/bank/v1beta1/denoms_metadata",query:query,operation:"metadata")
            let result:Int? = try validated("metadata") {
                guard let rows=j["metadatas"].array else {throw ThorchainSendError.malformed}
                if let row=rows.first(where:{$0["base"].string==reference}),let units=row["denom_units"].array {
                    guard units.contains(where:{$0["denom"].string==reference && $0["exponent"].integer==0}) else {throw ThorchainSendError.metadataChanged}
                    let powers=Set(units.compactMap{$0["exponent"].integer}.filter{$0>0})
                    let power=powers.first ?? 0
                    guard powers.count<=1,power<=255 else {throw ThorchainSendError.metadataChanged}
                    return Int(power)
                }
                key=j["pagination"]["next_key"].string.flatMap{$0.isEmpty ? nil:$0}
                if key==nil {throw ThorchainSendError.metadataChanged}
                guard seen.insert(key!).inserted else {throw ThorchainSendError.malformed}
                return nil
            }
            if let result {return result}
        }
        return try validated("metadata") {throw ThorchainSendError.malformed}
    }
    public func quote(sender:String,recipient:String,reference:String,publicKey:Data,decimals:Int,amount:String,memo:String="",maximum:Bool=false) async throws -> ThorchainSendPlan {
        _ = try ThorchainSendCrypto.addressBytes(sender,network:network);_ = try ThorchainSendCrypto.addressBytes(recipient,network:network)
        _ = try ThorchainIdentity.reference(reference);_ = try ThorchainSendAmount.checked(amount)
        guard try ThorchainSendCrypto.address(publicKey:publicKey,network:network)==sender else {throw ThorchainSendError.wrongOwner}
        let height=try await head().0
        async let state=account(sender)
        async let nativeWork=balance(owner:sender,reference:"native")
        async let tokenWork:String? = reference=="native" ? nil:balance(owner:sender,reference:reference)
        async let feeWork=fee()
        async let unitsWork=self.decimals(reference)
        async let recipientWork:Void=validateRecipient(recipient)
        async let enabledWork:Void=enabled(height:height)
        let (account,native,token,fee,units,_,_)=try await (state,nativeWork,tokenWork,feeWork,unitsWork,recipientWork,enabledWork)
        guard units==decimals else {throw ThorchainSendError.metadataChanged}
        let asset=token ?? native,requested=maximum ? asset:amount
        let value=maximum && reference=="native" ? try ThorchainSendAmount.subtract(asset,String(fee)):requested
        let plan=ThorchainSendPlan(network:network,sender:sender,recipient:recipient,reference:reference,memo:memo,publicKey:publicKey,decimals:decimals,requestedAmount:requested,amount:value,assetBalance:asset,nativeBalance:native,accountNumber:account.0,sequence:account.1,fee:fee,height:height,timeoutHeight:height+30)
        try plan.validate();return plan
    }
    public func preflight(_ plan:ThorchainSendPlan) async throws {
        try plan.validate();guard plan.network==network else {throw ThorchainSendError.wrongNetwork}
        async let current=quote(sender:plan.sender,recipient:plan.recipient,reference:plan.reference,publicKey:plan.publicKey,decimals:plan.decimals,amount:plan.amount,memo:plan.memo)
        let value=try await current
        guard value.accountNumber==plan.accountNumber,value.sequence==plan.sequence,value.fee==plan.fee,value.height<plan.timeoutHeight else {throw ThorchainSendError.changed}
    }
    /// Resolve the actual protocol fee and token units before displaying a dApp
    /// request. The dApp's empty Cosmos fee array does not mean a free transfer.
    public func walletConnectReview(_ request: ThorchainWalletConnectRequest) async throws -> ThorchainWalletConnectReview {
        guard request.network == network else { throw ThorchainSendError.wrongNetwork }
        async let headWork = head()
        async let accountWork = account(request.sender)
        async let feeWork = fee()
        async let nativeWork = balance(owner: request.sender, reference: "native")
        let (head, account, fee, native) = try await (headWork, accountWork, feeWork, nativeWork)
        guard account.0 == request.accountNumber, account.1 == request.sequence,
              request.timeoutHeight == 0 || request.timeoutHeight > head.0 else { throw ThorchainSendError.changed }
        try await enabled(height: head.0)
        if let recipient = request.recipient { try await validateRecipient(recipient) }
        let nativeAmount = request.coins.first(where: { $0.reference == "native" })?.amount ?? "0"
        guard !ThorchainSendAmount.less(native, try ThorchainSendAmount.add(nativeAmount, String(fee))) else { throw ThorchainSendError.insufficientFunds }
        let units = try await withThrowingTaskGroup(of: (String, Int).self) { group in
            for coin in request.coins {
                group.addTask {
                    async let units = self.decimals(coin.reference)
                    if coin.reference != "native" {
                        let balance = try await self.balance(owner: request.sender, reference: coin.reference)
                        guard !ThorchainSendAmount.less(balance, coin.amount) else { throw ThorchainSendError.insufficientFunds }
                    }
                    return try await (coin.reference, units)
                }
            }
            var result = [String: Int]()
            for try await (reference, decimals) in group { result[reference] = decimals }
            return result
        }
        return .init(fee: fee, decimals: units)
    }
    public func submit(_ signed:ThorchainSignedSend,plan:ThorchainSendPlan,reconcileFirst:Bool=true) async throws -> ThorchainSendReceipt {
        guard plan.network==network else {throw ThorchainSendError.wrongNetwork};try ThorchainSendCrypto.verify(signed,plan:plan)
        if reconcileFirst {let receipt=try await status(signed,plan:plan);if receipt.outcome != .unknown {return receipt}}
        else {try plan.validate()}
        let head=try await head();guard head.0<=plan.timeoutHeight else {return .init(hash:signed.hash,outcome:.unknown)}
        let body=SolanaJSON.object(["jsonrpc":.string("2.0"),"id":.number("1"),"method":.string("broadcast_tx_sync"),"params":.object(["tx":.string(signed.bytes.base64EncodedString())])])
        let j=try await read(rpc,"",body:body,operation:"broadcast")["result"]
        guard j["hash"].string?.uppercased()==signed.hash else {throw ThorchainSendError.changed}
        let code=try Self.uint(j["code"])
        if code==0 {return .init(hash:signed.hash,outcome:.accepted)}
        OathDiagnostics.record(DiagnosticFailure(j["log"].string ?? "THORChain CheckTx rejected"),component:"thorchain_send",operation:"broadcast",context:["chain":"thorchain","rpc_code":String(code)])
        // A duplicate/mempool sequence error can follow a lost acknowledgement.
        // Only committed evidence or expired unused sequence ends tracking.
        return try await status(signed,plan:plan)
    }
    public func status(_ signed:ThorchainSignedSend,plan:ThorchainSendPlan) async throws -> ThorchainSendReceipt {
        guard plan.network==network else {throw ThorchainSendError.wrongNetwork};try ThorchainSendCrypto.verify(signed,plan:plan)
        let latest=try await head()
        let j=try await read(rpc,"tx",query:[.init(name:"hash",value:"0x"+signed.hash)],missing:true,operation:"transaction")
        if !j.isNull {
            let value=try receipt(j["result"],signed:signed,plan:plan)
            let block=try await read(rpc,"block",query:[.init(name:"height",value:String(value.height!))],operation:"receipt_block")["result"]["block"]["header"]
            guard block["chain_id"].string==network.chainID,try Self.uint(block["height"])==value.height,let time=block["time"].string else {throw ThorchainSendError.changed}
            let parser=ISO8601DateFormatter();parser.formatOptions=time.contains(".") ? [.withInternetDateTime,.withFractionalSeconds]:[.withInternetDateTime]
            guard let date=parser.date(from:time) else {throw ThorchainSendError.malformed}
            return .init(hash:value.hash,outcome:value.outcome,fee:value.fee,height:value.height,timestamp:date.timeIntervalSince1970)
        }
        let state=try await account(plan.sender)
        guard state.0==plan.accountNumber else {throw ThorchainSendError.changed}
        // A missing/pruned receipt is not proof of a failed payment. Expiry is
        // proven only when the timeout passed and the sequence is still unused.
        if state.1<=plan.sequence,latest.0>plan.timeoutHeight+2,latest.1<=plan.height {return .init(hash:signed.hash,outcome:.expired)}
        if state.1>plan.sequence {
            let query="tx.acc_seq='\(plan.sender)/\(plan.sequence)' AND tx.height>=\(plan.height)"
            let found=try await read(rpc,"tx_search",query:[.init(name:"query",value:"\""+query+"\""),.init(name:"per_page",value:"\"10\""),.init(name:"order_by",value:"\"desc\"")],operation:"replacement")["result"]
            guard let txs=found["txs"].array,txs.count<=10 else {throw ThorchainSendError.malformed}
            for tx in txs {
                guard let hash=tx["hash"].string,hash != signed.hash,let raw=tx["tx"].string.flatMap({Data(base64Encoded:$0)}),hash==TronSendCrypto.hex(Data(SHA256.hash(data:raw))).uppercased(),try Self.uint(tx["height"])>=plan.height else {continue}
                if try ThorchainSendCrypto.committedSequence(raw,publicKey:plan.publicKey,accountNumber:plan.accountNumber,network:network)==plan.sequence {
                    return .init(hash:signed.hash,outcome:.replaced,replacementHash:hash)
                }
            }
        }
        return .init(hash:signed.hash,outcome:.unknown)
    }
    func receipt(_ j:SolanaJSON,signed:ThorchainSignedSend,plan:ThorchainSendPlan) throws -> ThorchainSendReceipt {
        guard j["hash"].string?.uppercased()==signed.hash,let raw=j["tx"].string.flatMap({Data(base64Encoded:$0)}),raw==signed.bytes else {throw ThorchainSendError.changed}
        let height=try Self.uint(j["height"]),code=try Self.uint(j["tx_result"]["code"])
        guard height>plan.height,height<=plan.timeoutHeight,let events=j["tx_result"]["events"].array else {throw ThorchainSendError.changed}
        if code != 0 {OathDiagnostics.record(DiagnosticFailure(j["tx_result"]["log"].string ?? "THORChain execution failed"),component:"thorchain_send",operation:"execution",context:["chain":"thorchain","rpc_code":String(code)])}
        var fee:UInt64=0,transferred="0"
        // Cosmos module IDs use SHA256(name)[:20], not account HASH160.
        let reserveAddress=ThorchainSendCrypto.bech32(Data(SHA256.hash(data:Data("reserve".utf8))).prefix(20),prefix:network.prefix)
        for event in events where event["type"].string=="transfer" {
            guard let attrs=event["attributes"].array else {throw ThorchainSendError.malformed}
            func value(_ key:String)->String? {attrs.first{$0["key"].string==key}?["value"].string}
            if value("sender")==plan.sender,value("recipient")==reserveAddress,value("msg_index")==nil,
               let coin=value("amount"),coin.hasSuffix("rune"),let n=UInt64(coin.dropLast(4)) {
                let sum=fee.addingReportingOverflow(n);guard !sum.overflow else {throw ThorchainSendError.malformed};fee=sum.partialValue
            }
            if value("sender")==plan.sender,value("recipient")==plan.recipient,value("amount")==plan.amount+plan.denom {transferred=try ThorchainSendAmount.add(transferred,plan.amount)}
        }
        guard code != 0 || transferred==plan.amount,fee>0 else {throw ThorchainSendError.changed}
        return .init(hash:signed.hash,outcome:code==0 ? .confirmed:.failed,fee:fee,height:height,timestamp:nil)
    }
}
