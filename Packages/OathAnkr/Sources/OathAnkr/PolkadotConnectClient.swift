import Foundation
import OathDiagnostics

public actor PolkadotConnectClient {
    public let network: PolkadotConnectNetwork
    private let transport: any AnkrTransport
    private let permits = AnkrPermits(count:4)
    private var verified: Set<URL> = []
    private var runtimes: [UInt32:PolkadotRuntime] = [:]
    public init(network: PolkadotConnectNetwork, transport: any AnkrTransport = AnkrHTTPTransport()) {
        self.network = network; self.transport = transport
    }
    private func call(_ base: URL, _ method: String, _ params: [SolanaJSON]) async throws -> SolanaJSON {
        var request = URLRequest(url:base); request.timeoutInterval = 25; request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField:"Content-Type")
        request.httpBody = try JSONEncoder().encode(SolanaJSON.object(["jsonrpc":.string("2.0"),"id":.number("1"),"method":.string(method),"params":.array(params)]))
        try await permits.acquire()
        let response: (Data, Int)
        do { response = try await transport.send(request) }
        catch {
            // Release only; rpc records the original transport failure before retrying.
            // diagnostics: polkadot-connect-permit-cleanup
            await permits.release(); throw error
        }
        await permits.release()
        guard response.1 == 200 else { throw PolkadotSendError.http(response.1) }
        guard response.0.count <= 16_000_000 else { throw PolkadotSendError.malformed }
        let json = try JSONDecoder().decode(SolanaJSON.self, from:response.0)
        if !json["error"].isNull {
            let code = Int(json["error"]["code"].text ?? "") ?? -1
            OathDiagnostics.record(DiagnosticFailure(json["error"]["message"].string ?? "Polkadot RPC failure"), component:"polkadot_walletconnect", operation:"rpc", context:["chain":"polkadot","rpc_code":String(code),"method":method])
            throw PolkadotSendError.rpc(code)
        }
        guard json["id"].text == "1", case .object(let fields) = json, fields["result"] != nil else { throw PolkadotSendError.malformed }
        return json["result"]
    }
    private func rpc(_ method: String, _ params: [SolanaJSON]) async throws -> SolanaJSON {
        var failure: any Error = PolkadotSendError.transport
        for base in network.endpoints {
            do {
                if !verified.contains(base) {
                    guard try await call(base,"chain_getBlockHash",[.number("0")]).string == network.genesis else { throw PolkadotSendError.wrongNetwork }
                    verified.insert(base)
                }
                return try await call(base,method,params)
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                OathDiagnostics.record(error, component:"polkadot_walletconnect", operation:"transport", context:["chain":"polkadot","method":method,"host":base.host ?? ""])
                failure = error
            }
        }
        throw failure
    }
    private func runtime(hash: String, spec: UInt32) async throws -> PolkadotRuntime {
        if let cached = runtimes[spec] { return cached }
        guard let metadata = try await rpc("state_getMetadata",[.string(hash)]).string else { throw PolkadotSendError.malformed }
        let runtime = try PolkadotRuntime(PolkadotIdentity.bytes(metadata))
        if runtimes.count >= 4 { runtimes.removeAll() }; runtimes[spec] = runtime
        return runtime
    }
    public func review(_ request: WalletConnectPolkadotRequest) async throws -> PolkadotConnectReview {
        try await OathDiagnostics.$chain.withValue("polkadot") {
            try await OathDiagnostics.$operationID.withValue(OathDiagnostics.operationID ?? UUID()) {
                try await prepare(request)
            }
        }
    }
    private func prepare(_ request: WalletConnectPolkadotRequest) async throws -> PolkadotConnectReview {
        guard request.network == network, request.message == nil else { throw PolkadotSendError.wrongNetwork }
        let life = try request.lifetime()
        guard let hash = try await rpc("chain_getFinalizedHead",[]).string else { throw PolkadotSendError.malformed }
        async let versionTask = rpc("state_getRuntimeVersion",[.string(hash)])
        async let heightTask = rpc("chain_getHeader",[])
        async let nonceTask = rpc("system_accountNextIndex",[.string(request.account)])
        async let blockTask = rpc("chain_getBlockHash",[.number(String(life.birth))])
        async let balanceTask = rpc("state_getStorage",[.string(try PolkadotStorage.nativeKey(request.account)),.string(hash)])
        let (version,header,nonce,block,balance) = try await (versionTask,heightTask,nonceTask,blockTask,balanceTask)
        guard let spec = UInt32(version["specVersion"].text ?? ""), let tx = UInt32(version["transactionVersion"].text ?? ""),
              let number = header["number"].string, number.hasPrefix("0x"), let height = UInt64(number.dropFirst(2),radix:16) else { throw PolkadotSendError.malformed }
        guard spec == request.specVersion, tx == request.transactionVersion else { throw PolkadotSendError.metadataChanged }
        guard height >= life.birth, height < life.death else { throw PolkadotSendError.expired }
        guard block.string == request.blockHash else { throw PolkadotSendError.wrongNetwork }
        guard nonce.text == String(request.nonce) else { throw PolkadotSendError.changed }
        let runtime = try await runtime(hash:hash,spec:spec)
        guard runtime.extensions.map(\.name) == request.extensions else { throw PolkadotSendError.runtimeUnsupported }
        let required: Set<String> = ["CheckSpecVersion","CheckTxVersion","CheckGenesis","CheckNonce"]
        guard required.isSubset(of:Set(request.extensions)), request.extensions.contains("CheckMortality") || request.extensions.contains("CheckEra"),
              request.extensions.contains("ChargeAssetTxPayment") || request.extensions.contains("ChargeTransactionPayment") else { throw PolkadotSendError.runtimeUnsupported }
        for ext in runtime.extensions {
            let pair = try request.extensionBytes(ext.name)
            for (bytes,id) in [(pair.0,ext.type),(pair.1,ext.additional)] {
                var reader = PolkadotScale(bytes), budget = 1_000
                _ = try runtime.decode(id,reader:&reader,depth:0,budget:&budget)
                guard reader.offset == bytes.count else { throw PolkadotSendError.runtimeUnsupported }
            }
        }
        let decoded = try Self.decodeCall(request.call,runtime:runtime)
        let bytes = try request.extrinsic(signature:Data(repeating:0,count:64))
        let info = try await rpc("payment_queryInfo",[.string(PolkadotIdentity.hex(bytes)),.string(hash)])
        let fee = try PolkadotIdentity.amount(info["partialFee"])
        guard fee != "0", !XrplSendAmount.less("1" + String(repeating:"0",count:network.decimals),fee) else { throw PolkadotSendError.feeTooHigh }
        guard !balance.isNull else { throw SendFeeFundingError.insufficientNativeBalance }
        let raw = try PolkadotIdentity.bytes(balance.string ?? "")
        let owner = try runtime.decode(raw,pallet:"System",storage:"Account")
        let free = try PolkadotIdentity.amount(owner["data"]["free"]), frozen = try PolkadotIdentity.amount(owner["data"]["frozen"])
        let reserved = try PolkadotIdentity.amount(owner["data"]["reserved"])
        let locked = XrplSendAmount.less(reserved,frozen) ? try NearSendAmount.subtract(frozen,reserved) : "0"
        // Include the explicitly reviewed tip; never alter a dApp's requested call.
        let charge = try NearSendAmount.add(fee,request.tip)
        guard !XrplSendAmount.less(free,try NearSendAmount.add(locked,charge)) else { throw SendFeeFundingError.insufficientNativeBalance }
        if let amount = decoded.amount, decoded.recipient != request.account {
            guard !XrplSendAmount.less(free,try NearSendAmount.add(locked,NearSendAmount.add(charge,amount))) else { throw PolkadotSendError.insufficientFunds }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]
        return .init(request:request,callName:decoded.name,details:String(decoding:try encoder.encode(decoded.fields),as:UTF8.self),fee:charge,metadataHash:runtime.fingerprint,recipient:decoded.recipient,nativeAmount:decoded.amount,createdAt:.now)
    }
    static func decodeCall(_ bytes: Data, runtime: PolkadotRuntime) throws -> (name:String,fields:SolanaJSON,recipient:String?,amount:String?) {
        guard bytes.count >= 2, let pallet = runtime.pallets.first(where: { $0.value.index == bytes[0] }),
              let type = pallet.value.calls, case .variants(let calls) = runtime.types[type],
              let call = calls.first(where: { $0.index == bytes[1] }) else { throw PolkadotSendError.runtimeUnsupported }
        var reader = PolkadotScale(Data(bytes.dropFirst(2))), budget = 20_000, fields: [String:SolanaJSON] = [:]
        for (index,field) in call.fields.enumerated() { fields[field.name ?? String(index)] = try runtime.decode(field.type,reader:&reader,depth:0,budget:&budget) }
        guard reader.offset == reader.data.count else { throw PolkadotSendError.malformed }
        var recipient: String?, amount: String?
        if pallet.key == "Balances", ["transfer_keep_alive","transfer_allow_death","transfer"].contains(call.name) {
            let dest = fields["dest"] ?? .null
            if dest["type"].string == "Id", let values = dest["value"].array, values.count == 32 {
                let bytes = values.compactMap { UInt8($0.text ?? "") }
                if bytes.count == 32 { recipient = try PolkadotIdentity.address(publicKey:Data(bytes)) }
            }
            amount = try PolkadotIdentity.amount(fields["value"] ?? .null)
        }
        return (pallet.key + "." + call.name,.object(fields),recipient,amount)
    }
    public func preflight(_ review: PolkadotConnectReview) async throws {
        try review.validate()
        let fresh = try await self.review(review.request)
        guard fresh.metadataHash == review.metadataHash, fresh.details == review.details,
              !XrplSendAmount.less(review.fee,fresh.fee) else { throw PolkadotSendError.changed }
    }
}
