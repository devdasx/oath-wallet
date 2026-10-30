import Foundation
import OathDiagnostics

/// Historical factory lookups authenticate pools used by previously unknown
/// routers. All lookups are pinned to the receipt block and scoped to its chain.
public struct EVMHistoryPool: Codable, Sendable {
    public let chainID: UInt64
    public let blockHash: String
    public let address: String
    public let factory: String
    public let token0: String
    public let token1: String
    public let kind: String
    public let registeredPool: String

    var verified: Bool {
        Self.factories[chainID]?[kind]?.contains(factory) == true && registeredPool == address && token0 != token1
    }

    static func connected(_ logs: [SolanaJSON], pools: [Self], chainID: UInt64, block: String,
                          owner: String, input: String, output: String, native: EVMHistoryTrace.Movement? = nil) throws -> Bool {
        guard pools.count <= 8 else { return false }
        var graph: [String: Set<String>] = [:]
        var exchangeEdges = Set<String>()
        func node(_ token: String, _ account: String) -> String { token + ":" + account }
        func edge(_ from: String, _ to: String) { graph[from, default: []].insert(to) }
        for transfer in native?.transfers ?? [] { edge(node("native", transfer.from), node("native", transfer.to)) }
        let depositTopic = EVMHistorySwap.topic("Deposit(address,uint256)")
        let withdrawalTopic = EVMHistorySwap.topic("Withdrawal(address,uint256)")
        var swaps = 0
        for log in logs {
            guard let emitter = log["address"].string?.lowercased(), let topics = log["topics"].array,
                  let raw = log["data"].string, let bytes = try? TronIdentity.hex(raw) else { return false }
            let abi = WalletConnectCallDetails.ABI(Array(bytes))
            func topicAddress(_ i: Int) -> String? {
                guard topics.count > i, let text = topics[i].string, let b = try? TronIdentity.hex(text), b.count == 32 else { return nil }
                return WalletConnectCallDetails.ABI(Array(b)).address(0)
            }
            if topics.first?.string == EVMHistorySwap.transferTopic,
               topics.count == 3, bytes.count == 32, abi.uint(0) != "0",
               let from = topicAddress(1), let to = topicAddress(2) {
                edge(node(emitter, from), node(emitter, to))
            }
            if native != nil, emitter == EVMHistoryTrace.wrappedNative[chainID],
               topics.count == 2, bytes.count == 32, abi.uint(0) != "0", let holder = topicAddress(1) {
                if topics.first?.string == depositTopic { edge(node("native", emitter), node(emitter, holder)) }
                if topics.first?.string == withdrawalTopic { edge(node(emitter, holder), node("native", emitter)) }
            }
            guard let pool = pools.first(where: { $0.address == emitter && $0.verified && $0.chainID == chainID && $0.blockHash == block }) else { continue }
            let incoming: String, outgoing: String
            if pool.kind == "v3", [EVMHistorySwap.v3Topic, EVMHistorySwap.pancakeV3Topic].contains(topics.first?.string ?? ""),
               topics.count == 3, bytes.count == (topics.first?.string == EVMHistorySwap.pancakeV3Topic ? 224 : 160) {
                guard let a = abi.word(0), let b = abi.word(1), a.contains(where: { $0 != 0 }), b.contains(where: { $0 != 0 }),
                      (a[0] & 128 != 0) != (b[0] & 128 != 0) else { continue }
                incoming = a[0] & 128 == 0 ? pool.token0 : pool.token1
                outgoing = a[0] & 128 == 0 ? pool.token1 : pool.token0
            } else if pool.kind == "v2", topics.first?.string == EVMHistorySwap.v2Topic, topics.count == 3, bytes.count == 128 {
                let amounts = (0..<4).compactMap { abi.uint($0) }
                guard amounts.count == 4 else { continue }
                if amounts[0] != "0", amounts[1] == "0", amounts[2] == "0", amounts[3] != "0" {
                    incoming = pool.token0; outgoing = pool.token1
                } else if amounts[0] == "0", amounts[1] != "0", amounts[2] != "0", amounts[3] == "0" {
                    incoming = pool.token1; outgoing = pool.token0
                } else { continue }
            } else { continue }
            swaps += 1
            let from = node(incoming, emitter), to = node(outgoing, emitter)
            edge(from, to); exchangeEdges.insert(from + ">" + to)
        }
        guard swaps > 0 else { return false }
        struct State: Hashable { let node: String; let exchanged: Bool }
        var queue = [State(node: node(input, owner), exchanged: false)], seen = Set(queue), cursor = 0
        let destination = node(output, owner)
        while cursor < queue.count, queue.count <= 8192 {
            let current = queue[cursor]; cursor += 1
            if current.node == destination && current.exchanged { return true }
            for next in graph[current.node] ?? [] {
                let state = State(node: next, exchanged: current.exchanged || exchangeEdges.contains(current.node + ">" + next))
                if seen.insert(state).inserted { queue.append(state) }
            }
        }
        return false
    }

    // Pinned from developers.uniswap.org/deployments.json, 2026-10-29.
    // Entries authorize pool factories, not arbitrary frontend/router addresses.
    static let factories: [UInt64: [String: Set<String>]] = {
        var rows: [UInt64: [String: Set<String>]] = [
        1: ["v2": ["0x5c69bee701ef814a2b6a3edd4b1652cb9cc5aa6f"], "v3": ["0x1f98431c8ad98523631ae4a59f267346ea31f984"]],
        10: ["v2": ["0x0c3c1c532f1e39edf36be9fe0be1410313e074bf"], "v3": ["0x1f98431c8ad98523631ae4a59f267346ea31f984"]],
        56: ["v2": ["0x8909dc15e40173ff4699343b6eb8132c65e18ec6"], "v3": ["0xdb1d10011ad0ff90774d0c6bb92e5c5c8b4461f7"]],
        100: ["v3": ["0xe32f7dd7e3f098d518ff19a22d5f028e076489b1"]],
        130: ["v2": ["0x1f98400000000000000000000000000000000002"], "v3": ["0x1f98400000000000000000000000000000000003"]],
        137: ["v2": ["0x9e5a52f57b3038f1b8eee45f28b3c1967e22799c"], "v3": ["0x1f98431c8ad98523631ae4a59f267346ea31f984"]],
        143: ["v2": ["0x182a927119d56008d921126764bf884221b10f59"], "v3": ["0x204faca1764b154221e35c0d20abb3c525710498"]],
        146: ["v3": ["0xcb2436774c3e191c85056d248ef4260ce5f27a9d"]],
        196: ["v2": ["0xdf38f24fe153761634be942f9d859f3dba857e95"], "v3": ["0x4b2ab38dbf28d31d467aa8993f6c2585981d6804"]],
        232: ["v3": ["0xe0704db90bcaa1eafc00e958ff815ab7aa11ef47"]],
        288: ["v3": ["0xffcd7aed9c627e82a765c3247d562239507f6f1b"]],
        314: ["v3": ["0xb4c47ed546fc31e26470a186ec2c5f19ef09ba41"]],
        324: ["v3": ["0x8fda5a7a8dca67bbcdd10f02fa0649a937215422"]],
        480: ["v2": ["0x5c69bee701ef814a2b6a3edd4b1652cb9cc5aa6f"], "v3": ["0x7a5028bda40e7b173c278c5342087826455ea25a"]],
        999: ["v2": ["0x89e5db8b5aa49aa85ac63f691524311aeb649eba"], "v3": ["0xf0db7b58379503491d857db50ac9ece64c653918"]],
        1284: ["v3": ["0x28f1158795a3585caaa3cd6469cd65382b89bb70"]],
        1301: ["v2": ["0x5c69bee701ef814a2b6a3edd4b1652cb9cc5aa6f"], "v3": ["0x1f98431c8ad98523631ae4a59f267346ea31f984"]],
        1329: ["v3": ["0x75fc67473a91335b5b8f8821277262a13b38c9b3"]],
        1868: ["v2": ["0x97febbc2adbd5644ba22736e962564b23f5828ce"], "v3": ["0x42ae7ec7ff020412639d443e245d936429fbe717"]],
        4217: ["v2": ["0xf9ec577a4e45b5278bb7cf60fcbc20c3acaef68f"], "v3": ["0x24a3d4757e330890a8b8978028c9e58e04611fd6"]],
        4326: ["v2": ["0xbf56488c857a881ae7e3bed27cf99c10a7ab7e50"], "v3": ["0x3a5f0cd7d62452b7f899b2a5758bfa57be0de478"]],
        4663: ["v2": ["0x8bceaa40b9acdfaedf85adf4ff01f5ad6517937f"], "v3": ["0x1f7d7550b1b028f7571e69a784071f0205fd2efa"]],
        5000: ["v3": ["0x0d922fb1bc191f64970ac40376643808b4b74df9"]],
        5042: ["v2": ["0x89e5db8b5aa49aa85ac63f691524311aeb649eba"], "v3": ["0xf0db7b58379503491d857db50ac9ece64c653918"]],
        8453: ["v2": ["0x8909dc15e40173ff4699343b6eb8132c65e18ec6"], "v3": ["0x33128a8fc17869897dce68ed026d694621f6fdfd"]],
        10143: ["v2": ["0x733e88f248b742db6c14c0b1713af5ad7fdd59d0"], "v3": ["0x961235a9020b05c44df1026d956d1f4d78014276"]],
        42161: ["v2": ["0xf1d7cc64fb4452f05c498126312ebe29f30fbcf9"], "v3": ["0x1f98431c8ad98523631ae4a59f267346ea31f984"]],
        42220: ["v2": ["0x79a530c8e2fa8748b7b40dd3629c0520c2ccf03f"], "v3": ["0xafe208a311b21f13ef87e33a90049fc17a7acdec"]],
        43114: ["v2": ["0x9e5a52f57b3038f1b8eee45f28b3c1967e22799c"], "v3": ["0x740b1c1de25031c31ff4fc9a62f554a55cdc1bad"]],
        44787: ["v3": ["0x229fd76da9062c1a10eb4193768e192bdea99572"]],
        57073: ["v2": ["0xfe57a6ba1951f69ae2ed4abe23e0f095df500c04"], "v3": ["0x640887a9ba3a9c53ed27d0f7e8246a4f933f3424"]],
        59144: ["v2": ["0x114a43df6c5f54ebb8a9d70cd1951d3dd68004c7"], "v3": ["0x31fafd4889fa1269f7a13a66ee0fb458f27d72a9"]],
        84532: ["v3": ["0x4752ba5dbc23f44d87826276bf6fd6b1c372ad24"]],
        167000: ["v3": ["0x75fc67473a91335b5b8f8821277262a13b38c9b3"]],
        421614: ["v3": ["0x248ab79bbb9bc29bb72f7cd42f17e054fc40188e"]],
        534352: ["v3": ["0x70c62c8b8e801124a4aa81ce07b637a3e83cb919"]],
        7777777: ["v2": ["0x0f797dc7efaea995bb916f268d919d0a1950ee3c"], "v3": ["0x7145f8aeef1f6510e92164038e1b6f8cb2c42cbb"]],
        11155111: ["v2": ["0xb7f907f7a9ebc822a80bd25e224be42ce0a698a0"], "v3": ["0x0227628f3f023bb0b980b67d528571c95c6dac1c"]],
        11155420: ["v3": ["0x8ce191193d15ea94e11d327b4c7ad8bbe520f6af"]],
        999999999: ["v3": ["0x4324a677d74764f46f33ed447964252441aa8db6"]],
        ]
        // pancakeswap/pancake-developer: contracts/v2/addresses.md and v3/addresses.md.
        for chain: UInt64 in [1,56,97,42161,59144,8453,204,143,4663] {
            rows[chain, default: [:]]["v3", default: []].insert("0x0bfbcf9fa4f9c56b0f40a671ad40e0805a091865")
        }
        rows[324, default: [:]]["v3", default: []].insert("0x1bb72e0cbbea93c08f535fc7856e0338d7f7a8ab")
        for (chain, factory): (UInt64, String) in [(56,"0xca143ce32fe78f1f7019d7d551a6402fc5350c73"),
            (1,"0x1097053fd2ea711dad45caccc45eff7548fcb362"), (324,"0xd03d8d566183f0086d8d09a84e1e30b58dd5619d"),
            (97,"0x6725f303b657a9451d8ba641348b6761a6cc7a17")] {
            rows[chain, default: [:]]["v2", default: []].insert(factory)
        }
        for chain: UInt64 in [42161,59144,8453,204,143,4663] {
            rows[chain, default: [:]]["v2", default: []].insert("0x02a84c1b3bbd7401a5f7fa98a384ebc70bb5749e")
        }
        return rows
    }()
}

extension EVMSendClient {
    func historyPoolEvidence(_ evidence: EVMHistoryEvidence) async throws -> [EVMHistoryPool] {
        guard let block = evidence.receipt["blockHash"].string, let logs = evidence.receipt["logs"].array,
              let height = evidence.receipt["blockNumber"].string else { return [] }
        var candidates: [String: String] = [:]
        for log in logs {
            guard let address = log["address"].string?.lowercased() else { continue }
            switch log["topics"].array?.first?.string {
            case EVMHistorySwap.v2Topic: candidates[address] = "v2"
            case EVMHistorySwap.v3Topic, EVMHistorySwap.pancakeV3Topic: candidates[address] = "v3"
            default: break
            }
        }
        guard candidates.count <= 8 else { return [] }
        return try await withThrowingTaskGroup(of: EVMHistoryPool?.self) { group in
            for (address, kind) in candidates {
                group.addTask { try await self.historyPool(address, kind: kind, block: block, height: height) }
            }
            var pools: [EVMHistoryPool] = []
            for try await pool in group { if let pool { pools.append(pool) } }
            return pools
        }
    }
    private func historyPool(_ address: String, kind: String, block: String, height: String) async throws -> EVMHistoryPool? {
        func query(_ target: String, _ selector: String) async throws -> WalletConnectCallDetails.ABI? {
            let result = try await rpc("eth_call", [.object(["to": .string(target), "data": .string(selector)]), .string(height)], optionalContractProbe: true)
            guard let text = result.string, let bytes = try? TronIdentity.hex(text), bytes.count == 32 else { return nil }
            return .init(Array(bytes))
        }
        do {
            async let factoryResult = query(address, "0xc45a0155")
            async let token0Result = query(address, "0x0dfe1681")
            async let token1Result = query(address, "0xd21220a7")
            guard let factory = try await factoryResult?.address(0),
                  EVMHistoryPool.factories[network.chainID]?[kind]?.contains(factory) == true,
                  let token0 = try await token0Result?.address(0), let token1 = try await token1Result?.address(0), token0 != token1 else { return nil }
            let selector: String
            var args = String(repeating: "0", count: 24) + token0.dropFirst(2) + String(repeating: "0", count: 24) + token1.dropFirst(2)
            if kind == "v3" {
                guard let fee = try await query(address, "0xddca3f43")?.word(0), fee.prefix(29).allSatisfy({ $0 == 0 }) else { return nil }
                args += TronSendCrypto.hex(Data(fee)); selector = "0x1698ee82"
            } else { selector = "0xe6a43905" }
            guard let registered = try await query(factory, selector + args)?.address(0), registered == address else { return nil }
            return .init(chainID: network.chainID, blockHash: block, address: address, factory: factory,
                         token0: token0, token1: token1, kind: kind, registeredPool: registered)
        } catch is CancellationError { throw CancellationError() }
        catch {
            if Task.isCancelled { throw CancellationError() }
            OathDiagnostics.record(error, component: "history_execution", operation: "pool_proof", context: ["chain": network.rawValue])
            return nil
        }
    }
}
