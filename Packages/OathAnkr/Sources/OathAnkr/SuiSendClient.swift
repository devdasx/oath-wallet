import Foundation
import OathDiagnostics

public enum SuiSendOutcome: String, Sendable { case confirmed, failed, unknown }
public struct SuiSendReceipt: Sendable {
    public let digest: String
    public let outcome: SuiSendOutcome
    public let fee: UInt64?
    /// A storage rebate can exceed the computation/storage charge.
    public let gasRefund: UInt64
    public init(digest: String, outcome: SuiSendOutcome, fee: UInt64?, gasRefund: UInt64 = 0) {
        self.digest = digest; self.outcome = outcome; self.fee = fee; self.gasRefund = gasRefund
    }
}
/// Current GraphQL execution API. No deprecated JSON-RPC unsafe builders and
/// no provider-built bytes enter the signer. All writes use one persisted digest.
public actor SuiSendClient {
    public let network: SuiSendNetwork
    private let endpoints: [URL]
    private var verifiedEndpoints:[URL:Date] = [:]
    private let transport: any AnkrTransport
    public init(network: SuiSendNetwork, apiKey: String? = nil, transport: any AnkrTransport = AnkrHTTPTransport()) throws {
        self.network = network; self.transport = transport
        if let apiKey, !apiKey.isEmpty, network == .mainnet {
            guard apiKey.count <= 256, apiKey.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }) else { throw SuiError.configuration }
            endpoints = [URL(string:"https://rpc.ankr.com/premium-http/sui_graphql")!.appendingPathComponent(apiKey), network.endpoint]
        } else { endpoints = [network.endpoint] }
    }
    private func query(_ text: String, _ variables: [String:SuiJSON] = [:], stage: String, mutation: Bool = false, endpointIndex: Int? = nil) async throws -> SuiJSON {
        for (index, endpoint) in endpoints.enumerated() where endpointIndex == nil || index == endpointIndex {
            do {
                try Task.checkCancellation()
                if mutation, verifiedEndpoints[endpoint].map({ (0..<30).contains(Date.now.timeIntervalSince($0)) }) != true {
                    // Verify the SAME destination before sending signed bytes.
                    _ = try await query("{chainIdentifier}",stage:"network_check",endpointIndex:index)
                }
                var request = URLRequest(url:endpoint); request.httpMethod = "POST"; request.timeoutInterval = 15
                request.setValue("application/json", forHTTPHeaderField:"Content-Type")
                request.httpBody = try JSONEncoder().encode(SuiJSON.object(["query":.string(text),"variables":.object(variables)]))
                let (bytes,status) = try await transport.send(request)
                guard status == 200 else { throw SuiSendError.http(status) }
                guard bytes.count <= 4_000_000 else { throw SuiSendError.malformed }
                let envelope = try JSONDecoder().decode(SuiJSON.self,from:bytes)
                if let errors = envelope["errors"].array, !errors.isEmpty {
                    for error in errors.prefix(4) {
                        OathDiagnostics.record(NSError(domain:"SuiGraphQL",code:1,userInfo:[NSLocalizedDescriptionKey:error["message"].string ?? "GraphQL request failed"]),
                            component:"sui_send",operation:stage,context:["chain":"sui","stage":stage,"rpc_code":error["extensions"]["code"].string ?? "GRAPHQL"])
                    }
                    throw SuiSendError.graphql
                }
                let data = envelope["data"]
                guard mutation || data["chainIdentifier"].string == network.chainIdentifier else { throw SuiSendError.wrongNetwork }
                if !mutation { verifiedEndpoints[endpoint] = .now }
                return data
            } catch {
                verifiedEndpoints.removeValue(forKey:endpoint)
                OathDiagnostics.record(error,component:"sui_send",operation:stage,context:["chain":"sui","stage":stage])
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                // A write's timeout is uncertain. Look up the same digest before
                // any recovery; never build/sign a replacement automatically.
                if mutation || index == endpoints.count-1 || (error as? SuiSendError) == .wrongNetwork { throw error }
            }
        }
        throw SuiSendError.transport
    }
    public func funds(owner: String, reference: String) async throws -> SuiSendFunds {
        let owner = try SuiIdentity.address(owner), type = try SuiIdentity.coinType(reference)
        var after: String?, seen = Set<String>(), coins = [SuiSendCoin](), addressBalance: UInt64?, checkpoint: UInt64?
        repeat {
            let queryText = """
            query($owner:SuiAddress!, $type:String!, $objectType:String!, $after:String, $checkpoint:UInt53) {
              chainIdentifier checkpoint { sequenceNumber }
              address(address:$owner,atCheckpoint:$checkpoint) { address
                balance(coinType:$type) { addressBalance }
                objects(first:10,after:$after,filter:{type:$objectType}) {
                  nodes { address version digest contents { json type { repr } } }
                  pageInfo { hasNextPage endCursor }
                }
              }
            }
            """
            let data = try await query(queryText,["owner":.string(owner),"type":.string(type),"objectType":.string("0x2::coin::Coin<\(type)>"),
                "after":after.map(SuiJSON.string) ?? .null,"checkpoint":checkpoint.map { .number(String($0)) } ?? .null],stage:"funding")
            if checkpoint == nil { checkpoint = try number(data["checkpoint"]["sequenceNumber"]) }
            let account = data["address"]
            guard account["address"].string == owner else { throw SuiSendError.wrongOwner }
            if case .null = account["balance"] { addressBalance = addressBalance ?? 0 }
            else { let balance = try number(account["balance"]["addressBalance"]); guard addressBalance == nil || addressBalance == balance else { throw SuiSendError.changed }; addressBalance = balance }
            guard let rows = account["objects"]["nodes"].array else { throw SuiSendError.malformed }
            for row in rows {
                guard let id = row["address"].string, let digest = row["digest"].string,
                      let actualType = row["contents"]["type"]["repr"].string,
                      try SuiIdentity.reference(actualType) == SuiIdentity.reference("0x2::coin::Coin<\(type)>") else { throw SuiSendError.malformed }
                let coin = SuiSendCoin(id:try SuiIdentity.address(id),digest:digest,version:try number(row["version"]),balance:try number(row["contents"]["json"]["balance"]))
                guard !coins.contains(where:{$0.id == coin.id}) else { throw SuiSendError.malformed }; coins.append(coin)
            }
            guard coins.count <= 128 else { throw SuiSendError.tooManyCoins }
            let page = account["objects"]["pageInfo"]
            guard case .bool(let more) = page["hasNextPage"] else { throw SuiSendError.malformed }
            if more {
                guard !rows.isEmpty, let cursor = page["endCursor"].string, seen.insert(cursor).inserted else { throw SuiSendError.malformed }; after = cursor
            } else { after = nil }
        } while after != nil
        return .init(coins:coins,addressBalance:addressBalance ?? 0)
    }
    public func quote(sender: String, recipient: String, reference: String, amount: UInt64, multisig: SuiMultisigPolicy? = nil) async throws -> SuiSendPlan {
        try await OathDiagnostics.$chain.withValue("sui") {
            try await OathDiagnostics.$operationID.withValue(UUID()) {
                let reference = try SuiIdentity.reference(reference)
                async let info = query("{ chainIdentifier epoch { epochId referenceGasPrice } }",stage:"gas_price")
                async let native = funds(owner:sender,reference:"native")
                async let token: SuiSendFunds? = reference == "native" ? nil : funds(owner:sender,reference:reference)
                let (state,nativeFunds,tokenFunds) = try await (info,native,token)
                let total = try nativeFunds.total
                guard total > 1 else { throw SendFeeFundingError.insufficientNativeBalance }
                let epoch = try number(state["epoch"]["epochId"]), price = try number(state["epoch"]["referenceGasPrice"])
                let nonce = UInt32.random(in:.min ... .max)
                func plan(_ budget:UInt64,_ fee:UInt64 = 0) throws -> SuiSendPlan {
                    try .make(network:network,sender:sender,recipient:recipient,reference:reference,amount:amount,
                              native:nativeFunds,asset:tokenFunds ?? nativeFunds,gasPrice:price,gasBudget:budget,estimatedFee:fee,epoch:epoch,nonce:nonce,multisig:multisig)
                }
                // The simulation budget must be payable by one gas source.
                // A mixed address/coin balance can exceed both sources; using
                // their sum here incorrectly rejects an otherwise cheap send.
                let coinGas = try SuiSendFunds.sum(nativeFunds.coins.map(\.balance))
                let initial = try plan(min(SuiSendPlan.maximumGasBudget, max(nativeFunds.addressBalance,coinGas), total-1))
                let estimate = try await simulate(initial, checks:false)
                let budget = max(2_000_000, try SuiSendFunds.sum([estimate.computation*2,estimate.storage,1_000_000]))
                guard budget <= SuiSendPlan.maximumGasBudget else { throw SuiSendError.feeTooHigh }
                let final = try plan(budget,estimate.fee)
                let checked = try await simulate(final,checks:true)
                guard checked.fee <= budget else { throw SuiSendError.feeTooHigh }
                return try plan(budget,checked.fee)
            }
        }
    }
    private static let effectsFields = "status transaction { digest } gasEffects { gasSummary { computationCost storageCost storageRebate } } executionError { message }"
    private func simulate(_ plan: SuiSendPlan, checks: Bool) async throws -> (computation:UInt64, storage:UInt64, fee:UInt64) {
        let bytes = try plan.transactionBytes()
        let data = try await query("query($tx:JSON!,$checks:Boolean!){chainIdentifier simulateTransaction(transaction:$tx,checksEnabled:$checks,doGasSelection:false){effects{\(Self.effectsFields)}}}",
            ["tx":.object(["bcs":.object(["value":.string(bytes.base64EncodedString())])]),"checks":.bool(checks)],stage:"simulate")
        let effects = data["simulateTransaction"]["effects"]
        guard effects["status"].string == "SUCCESS" else { reportExecution(effects,stage:"simulate"); throw SuiSendError.simulationFailed }
        let gas = effects["gasEffects"]["gasSummary"]
        let computation = try number(gas["computationCost"]), storage = try number(gas["storageCost"]), rebate = try number(gas["storageRebate"])
        guard computation <= SuiSendPlan.maximumGasBudget, storage <= SuiSendPlan.maximumGasBudget else { throw SuiSendError.feeTooHigh }
        let gross = try SuiSendFunds.sum([computation,storage])
        return (computation,storage,gross > rebate ? gross-rebate : 0)
    }
    public func submit(_ signed:SuiSignedSend, sender:String) async throws -> SuiSendReceipt {
        try SuiSendCrypto.verify(signed,sender:sender)
        for index in endpoints.indices {
            do {
                let data = try await query("mutation($tx:Base64!,$signatures:[Base64!]!){executeTransaction(transactionDataBcs:$tx,signatures:$signatures){effects{\(Self.effectsFields)}}}",
                    ["tx":.string(signed.bytes.base64EncodedString()),"signatures":.array([.string(signed.signature.base64EncodedString())])],stage:"broadcast",mutation:true,endpointIndex:index)
                return try receipt(data["executeTransaction"]["effects"],digest:signed.digest)
            } catch {
                OathDiagnostics.record(error,component:"sui_send",operation:"broadcast_result",context:["chain":"sui"])
                if Task.isCancelled { break }
                if let result = await OathDiagnostics.attempt("sui_reconcile",body:{ try await self.status(digest:signed.digest) }), result.outcome != .unknown { return result }
                // Fallback reuses the exact persisted bytes/signature/digest.
                // Sui execution is idempotent; no replacement spend is built.
            }
        }
        return .init(digest:signed.digest,outcome:.unknown,fee:nil)
    }

    public func status(digest:String) async throws -> SuiSendReceipt {
        guard try SuiSendCrypto.unbase58(digest).count == 32 else { throw SuiSendError.malformed }
        let data = try await query("query($digest:String!){chainIdentifier transaction(digest:$digest){effects{\(Self.effectsFields)}}}",["digest":.string(digest)],stage:"reconcile")
        if case .null = data["transaction"] { return .init(digest:digest,outcome:.unknown,fee:nil) }
        return try receipt(data["transaction"]["effects"],digest:digest)
    }
    private func receipt(_ effects:SuiJSON,digest:String) throws -> SuiSendReceipt {
        guard effects["transaction"]["digest"].string == digest else { throw SuiSendError.changed }
        let status = effects["status"].string
        guard status == "SUCCESS" || status == "FAILURE" else { throw SuiSendError.malformed }
        if status == "FAILURE" { reportExecution(effects,stage:"execution") }
        let gas = effects["gasEffects"]["gasSummary"]
        let gross = try SuiSendFunds.sum([number(gas["computationCost"]),number(gas["storageCost"])])
        let rebate = try number(gas["storageRebate"])
        return .init(digest:digest,outcome:status == "SUCCESS" ? .confirmed:.failed,fee:gross > rebate ? gross-rebate:0,gasRefund:rebate > gross ? rebate-gross:0)
    }
    private func reportExecution(_ effects:SuiJSON,stage:String) {
        OathDiagnostics.record(NSError(domain:"SuiExecution",code:1,userInfo:[NSLocalizedDescriptionKey:effects["executionError"]["message"].string ?? "Sui execution failed"]),
                               component:"sui_send",operation:stage,context:["chain":"sui","stage":stage])
    }
    private func number(_ value:SuiJSON) throws -> UInt64 {
        guard let text = value.text, !text.isEmpty, text.utf8.allSatisfy({(48...57).contains($0)}),let n = UInt64(text) else { throw SuiSendError.malformed }; return n
    }
}
