import Foundation

/// A display projection of executed movements, never a quote or signing input.
public struct EVMHistorySwap: Codable, Sendable, Equatable {
    public static let version = 6
    public let chainID: UInt64
    public let hash: String
    public let blockHash: String
    public let input: String
    public let output: String
    public let spent: String
    public let received: String

    public static func reference(_ address: String, chainID: UInt64) throws -> String {
        let address = try EVMSendIdentity.reference(address.lowercased())
        if chainID == 42220 && address == "0x471ece3750da237f93b8e339c536989b8978a438" { return "native" }
        return address
    }

    /// Unknown calls, absent receipts, and inconclusive evidence are expected
    /// coverage gaps. Return nil and retain the original transfers.
    public static func classify(transaction tx: SolanaJSON, receipt: SolanaJSON,
                                owner: String, chainID: UInt64, trace: EVMHistoryTrace? = nil, pools: [EVMHistoryPool] = []) throws -> Self? {
        let owner = try EVMSendIdentity.address(owner)
        guard let hash = tx["hash"].string?.lowercased(), hash.count == 66,
              receipt["transactionHash"].string?.lowercased() == hash,
              let block = receipt["blockHash"].string?.lowercased(), block.count == 66,
              tx["blockHash"].string?.lowercased() == block,
              receipt["status"].string == "0x1",
              tx["from"].string?.lowercased() == owner,
              receipt["from"].string?.lowercased() == owner,
              let to = tx["to"].string?.lowercased(), to != EVMPermissionRemoval.zero,
              receipt["to"].string?.lowercased() == to,
              let input = tx["input"].string, let value = tx["value"].string,
              let logs = receipt["logs"].array, logs.count <= 2048 else { return nil }
        if let reported = tx["chainId"].string, try AnkrQuantity.decimal(reported) != String(chainID) { return nil }
        let native = try trace?.movements(transaction: tx, receipt: receipt, owner: owner, chainID: chainID)
        guard try AnkrQuantity.decimal(value) == "0" || native != nil else { return nil }
        // Historical zero-address transfers are valid chain records, but not
        // swap calls. The guard above retains them as ordinary history without
        // passing them through the stricter new-signing request validation.
        let params = try JSONEncoder().encode(SolanaJSON.array([.object([
            "from": .string(owner), "to": .string(to), "data": .string(input), "value": .string(value)
        ])]))
        let request = try WalletConnectEVMRequest(params: params, account: owner, chainID: chainID)
        let details = WalletConnectCallDetails(history: request)
        let action = WalletConnectEVMAction(request)
        let decodedRoute = details.fullyDecoded && details.steps.contains { $0.operation == .swap }
            && details.steps.allSatisfy { step in
                !step.optional && [.swap, .transfer, .balanceCheck, .wrap, .unwrap].contains(step.operation)
                    && step.values.filter { $0.label == .recipient }.allSatisfy {
                        $0.value == owner || $0.value == to
                    }
            }
        let singleSwap = action.kind == .swap && action.fields.contains { $0.label == .recipient && $0.value == owner }
        let standard = decodedRoute || singleSwap
        let v4 = v4Call(request)
        guard standard || v4 || !pools.isEmpty else { return nil }
        var seen: [String: SolanaJSON] = [:]
        var credits: [String: String] = [:], debits: [String: String] = [:]
        var swapEvent = false
        for log in logs {
            guard log["removed"] != .bool(true), log["transactionHash"].string?.lowercased() == hash,
                  log["blockHash"].string?.lowercased() == block,
                  let index = log["logIndex"].string,
                  let address = log["address"].string,
                  let topics = log["topics"].array?.compactMap(\.string), !topics.isEmpty else { return nil }
            let key = try AnkrQuantity.decimal(index)
            if let old = seen[key] { guard old == log else { return nil }; continue }
            seen[key] = log
            let topic = topics[0].lowercased()
            if v4, address.lowercased() == managers[chainID], topic == v4Topic,
               topics.count == 3, topicAddress(topics[2]) == to { swapEvent = true }
            if standard, [v2Topic, v3Topic, pancakeV3Topic].contains(topic), topics.count == 3,
               topicAddress(topics[1]) == to { swapEvent = true }
            guard topic == transferTopic else { continue }
            guard topics.count == 3, let from = topicAddress(topics[1]), let to = topicAddress(topics[2]),
                  let data = log["data"].string, data.count == 66 else { return nil }
            let amount = try EVMSendAmount.checked(AnkrQuantity.decimal(data))
            // EIP-7708 logs duplicate native call values. Only omit a system log
            // when the independent trace proves that exact transfer on this chain.
            if address.lowercased() == "0xfffffffffffffffffffffffffffffffffffffffe",
               native?.transfers.contains(where: { $0.from == from && $0.to == to && $0.amount == amount }) == true { continue }
            let ref = try reference(address, chainID: chainID)
            // Celo's native ERC20 alias also emits gas fee transfers. Without
            // fee-currency/trace evidence it cannot be treated as a token leg.

            if from == owner { debits[ref] = try EVMSendAmount.add(debits[ref] ?? "0", amount) }
            if to == owner { credits[ref] = try EVMSendAmount.add(credits[ref] ?? "0", amount) }
        }
        guard swapEvent || !pools.isEmpty else { return nil }
        if chainID == 42220, credits["native"] != nil || debits["native"] != nil {
            // CELO's ERC20 interface emits the gas payment too. Remove only a
            // proven exact gas-only debit, never guess a native swap amount.
            let fee = try EVMSendAmount.multiply(AnkrQuantity.decimal(receipt["gasUsed"].string ?? ""),
                AnkrQuantity.decimal(receipt["effectiveGasPrice"].string ?? ""))
            guard credits["native"] == nil, debits["native"] == fee else { return nil }
            debits.removeValue(forKey: "native")
        }
        if let native {
            guard credits["native"] == nil, debits["native"] == nil else { return nil }
            credits["native"] = native.credits; debits["native"] = native.debits
        }
        var outgoing: [(String,String)] = [], incoming: [(String,String)] = []
        for ref in Set(credits.keys).union(debits.keys) {
            let credit = credits[ref] ?? "0", debit = debits[ref] ?? "0"
            if EVMSendAmount.less(credit, debit) { outgoing.append((ref, try EVMSendAmount.subtract(debit, credit))) }
            if EVMSendAmount.less(debit, credit) { incoming.append((ref, try EVMSendAmount.subtract(credit, debit))) }
        }
        guard outgoing.count == 1, incoming.count == 1 else { return nil }
        let poolRoute = try native != nil && EVMHistoryPool.connected(Array(seen.values), pools: pools, chainID: chainID,
            block: block, owner: owner, input: outgoing[0].0, output: incoming[0].0, native: native)
        guard (standard || v4) && swapEvent || poolRoute else { return nil }
        if standard && !poolRoute {
            // A recognized swap inside a larger call is not enough: both wallet
            // legs must belong to its decoded route, not unrelated transfers.
            let inputs = details.steps.filter { $0.operation == .swap }.flatMap(\.values)
                .filter { $0.label == .tokenIn }.map(\.value)
                + action.fields.filter { $0.label == .tokenIn }.map(\.value)
            let outputs = details.steps.filter { $0.operation == .swap }.flatMap(\.values)
                .filter { $0.label == .tokenOut }.map(\.value)
                + action.fields.filter { $0.label == .tokenOut }.map(\.value)
            func matches(_ token: String, _ leg: String) throws -> Bool {
                if try reference(token, chainID: chainID) == leg { return true }
                return native != nil && leg == "native" && token == EVMHistoryTrace.wrappedNative[chainID]
            }
            guard try inputs.contains(where: { try matches($0, outgoing[0].0) }),
                  try outputs.contains(where: { try matches($0, incoming[0].0) }) else { return nil }
        }
        return .init(chainID: chainID, hash: hash, blockHash: block, input: outgoing[0].0,
                     output: incoming[0].0, spent: outgoing[0].1, received: incoming[0].1)
    }

    private static func topicAddress(_ value: String) -> String? {
        guard value.count == 66, value.lowercased().hasPrefix("0x" + String(repeating: "0", count: 24)) else { return nil }
        return try? EVMSendIdentity.address("0x" + value.suffix(40))
    }
    static func topic(_ signature: String) -> String {
        "0x" + TronSendCrypto.hex(TronSendCrypto.keccak(Data(signature.utf8)))
    }
    static let transferTopic = topic("Transfer(address,address,uint256)")
    static let v2Topic = topic("Swap(address,uint256,uint256,uint256,uint256,address)")
    static let v3Topic = topic("Swap(address,address,int256,int256,uint160,uint128,int24)")
    static let pancakeV3Topic = topic("Swap(address,address,int256,int256,uint160,uint128,int24,uint128,uint128)")
    static let v4Topic = topic("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)")

    // Official Uniswap V4 deployment registry. Unknown deployments fall back
    // to transfer history instead of trusting user-supplied router metadata.
    static let managers: [UInt64:String] = [
        1:"0x000000000004444c5dc75cb358380d2e3de08a90", 56:"0x28e2ea090877bf75740558f6bfb36a5ffee9e9df",
        10:"0x9a13f98cb987694c9f086b1f5eb990eea8264ec3", 8453:"0x498581ff718922c3f8e6a244956af099b2652b2b",
        42161:"0x360e68faccca8ca495c1b759fd9eee466db9fb32", 137:"0x67366782805870060151383f4bbff9dab53e5cd6",
        130:"0x1f98400000000000000000000000000000000004", 43114:"0x06380c0e0912312b5150364b9dc4542ba0dbbc85",
        196:"0x360e68faccca8ca495c1b759fd9eee466db9fb32",
        42220:"0x288dc841a52fca2707c6947b3a777c5e56cd87bc",
        143:"0x188d586ddcf52439676ca21a244753fa19f9ea8e",
        4663:"0x8366a39cc670b4001a1121b8f6a443a643e40951",
        5042:"0x8366a39cc670b4001a1121b8f6a443a643e40951",
        999:"0x12d4fd9c5dedd00ab8a0bce2cf0167bbf94b6b1f"
    ]
    static let latestRouters: [UInt64:Set<String>] = [
        11_155_111:["0x7dfd4f31be6814d2906bde155c3e1b146eac1468", "0x7e4f6c5e954da5c61b3423d81e2277431ac043f3"],
        42220:["0xcb695bc5d3aa22cad1e6df07801b061a05a0233a","0x8b844f885672f333bc0042cb669255f93a4c1e6b","0xe2023f3fa515cf070e07fd9d51c1d236e07843f4"],
        143:["0x0d97dc33264bfc1c226207428a79b26757fb9dc3","0xfdf682f51fe81aa4898f0ae2163d8a55c127fbc7","0xa6ce4f10d83dbddac17e68e1837ca9ce6a1b596e"],
        4663:["0x8876789976decbfcbbbe364623c63652db8c0904","0x204faca1764b154221e35c0d20abb3c525710498"],
        5042:["0x4fca4a51ab4f23a7447b3284fbd7d73289a89fb1","0x8702463e73f74d0b6765abceb314ef07acb92650"],
        999:["0xed270a1bcdc63cf1356d695e7f40961d4819d6bf"],
        1:["0x23617e59a5925b2a4bf75d73ff6711cd0b29de85","0x4c82d1fbfe28c977cbb58d8c7ff8fcf9f70a2cca"],
        56:["0xdc264714f68d84cf29bc605589405e78bdbe7c9f","0x8b844f885672f333bc0042cb669255f93a4c1e6b"],
        137:["0xdc264714f68d84cf29bc605589405e78bdbe7c9f","0x8b844f885672f333bc0042cb669255f93a4c1e6b"],
        10:["0xc09255d86db563cbc11c2fcf4a0c512e160111b4","0x8b844f885672f333bc0042cb669255f93a4c1e6b"],
        8453:["0xd6145b2d3f379919e8cdeda7b97e37c4b2ca9c40","0xfdf682f51fe81aa4898f0ae2163d8a55c127fbc7"],
        42161:["0x2d01411773c8c24805306e89a41f7855c3c4fe65","0x8b844f885672f333bc0042cb669255f93a4c1e6b"],
        130:["0xd1b797d92d87b688193a2b976efc8d577d204343","0xfdf682f51fe81aa4898f0ae2163d8a55c127fbc7"],
        43114:["0x94b75331ae8d42c1b61065089b7d48fe14aa73b7","0x8b844f885672f333bc0042cb669255f93a4c1e6b","0x661e93cca42afacb172121ef892830ca3b70f08d"],
        196:["0xda00ae15d3a71466517129255255db7c0c0956d3","0x1cd182c94fcf42277b80dbb9060f88024809e61e","0x8b844f885672f333bc0042cb669255f93a4c1e6b"]
    ]
    private static func v4Call(_ request: WalletConnectEVMRequest) -> Bool {
        guard managers[request.chainID] != nil,
              latestRouters[request.chainID]?.contains(request.recipient) == true || WalletConnectCallDetails.routers[request.chainID]?.contains(request.recipient) == true else { return false }
        // Deployed routers accept a bounded trailing attribution tag (including
        // the Uniswap frontend tag in the real receipts). Signing decoders remain strict.
        let selector = String(request.call.hex.prefix(10))
        guard ["0x3593564c","0x24856bc3"].contains(selector),
              let batch = WalletConnectCallDetails.ABI(Array(request.call.bytes.dropFirst(4))).batch(head: selector == "0x3593564c" ? 3 : 2, allowAttributionSuffix: true) else { return false }
        var hasSwap = false
        for (command, data) in batch {
            switch command {
            case 0x0a: break // Permit2 permit, no asset movement.
            case 0x10:
                guard let actions = WalletConnectCallDetails.ABI(data).batch(head: 2), !actions.isEmpty else { return false }
                for (action, _) in actions {
                    if (6...9).contains(action) { hasSwap = true }
                    else if !(0x0b...0x14).contains(action) { return false }
                }
            default: return false // Includes liquidity, subplans and optional-failure commands.
            }
        }
        return hasSwap
    }
}

public struct EVMHistoryEvidence: Codable, Sendable {
    // Transaction, receipt and optional execution trace are bounded RPC results.
    // The cache accepts complete results, including provider extensions;
    // stripping fields could change later classification or duplicate checks.
    public static let maximumEncodedBytes = 3 * EVMSendClient.maximumRPCResponseBytes
    public let transaction: SolanaJSON
    public let receipt: SolanaJSON
    public let trace: EVMHistoryTrace?
    public let pools: [EVMHistoryPool]?
    public init(transaction: SolanaJSON, receipt: SolanaJSON, trace: EVMHistoryTrace? = nil, pools: [EVMHistoryPool]? = nil) {
        self.transaction = transaction; self.receipt = receipt; self.trace = trace; self.pools = pools
    }
}
extension EVMSendClient {
    /// Existing RPC client enforces the chain ID, transport budgets and diagnostics.
    public func historyEvidence(hash: String, includeExecution: Bool = true) async throws -> EVMHistoryEvidence {
        guard hash.count == 66, hash.hasPrefix("0x"), (try? TronIdentity.hex(hash)) != nil else { throw EVMSendError.malformed }
        async let transaction = rpc("eth_getTransactionByHash", [.string(hash)])
        async let receipt = rpc("eth_getTransactionReceipt", [.string(hash)])
        let evidence = try await EVMHistoryEvidence(transaction: transaction, receipt: receipt)
        return includeExecution ? try await historyExecutionEvidence(evidence) : evidence
    }
}
