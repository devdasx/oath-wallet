import Foundation

/// Presentation only. Decodes bounded, canonical ABI from known router deployments.
/// It never changes the request, approves a contract, or predicts execution results.
/// Unknown ABI/commands are expected input, not diagnostic failures.
public struct WalletConnectCallDetails: Sendable, Equatable {
    public enum Operation: Sendable { case swap, transfer, wrap, unwrap, balanceCheck, unknown }
    public struct Value: Sendable, Equatable {
        public let label: WalletConnectEVMAction.Label
        public let value: String
        public var token: String? = nil
        public var routerBalance = false
        public init(label: WalletConnectEVMAction.Label, value: String, token: String? = nil, routerBalance: Bool = false) {
            self.label = label; self.value = value; self.token = token; self.routerBalance = routerBalance
        }
    }
    public struct Step: Sendable, Equatable {
        public let operation: Operation
        public let command: String
        public let optional: Bool
        public let values: [Value]
    }
    public let method: String?
    public let deadline: String?
    public let steps: [Step]
    public let isRouter: Bool
    public var fullyDecoded: Bool { !steps.isEmpty && steps.allSatisfy { $0.operation != .unknown } }

    public init(_ request: WalletConnectEVMRequest) {
        self.init(request, history: false)
    }

    // Executed history may include a frontend attribution suffix. Keep signing
    // previews strict and require the history classifier to verify receipt legs.
    init(history request: WalletConnectEVMRequest) {
        self.init(request, history: true)
    }

    private init(_ request: WalletConnectEVMRequest, history: Bool) {
        if let swap = Self.v2Swap(request) {
            method = swap.method; deadline = swap.deadline; steps = [swap.step]; isRouter = true
            return
        }
        let selector = String(request.call.hex.prefix(10))
        let hasDeadline = selector == "0x3593564c"
        let router = Self.routers[request.chainID]?.contains(request.recipient) == true
            || (history && EVMHistorySwap.latestRouters[request.chainID]?.contains(request.recipient) == true)
        guard router, hasDeadline || selector == "0x24856bc3",
              let batch = ABI(Array(request.call.bytes.dropFirst(4))).batch(head: hasDeadline ? 3 : 2, allowAttributionSuffix: history) else {
            method = WalletConnectEVMAction(request).method; deadline = nil; steps = []; isRouter = false
            return
        }
        method = hasDeadline ? "execute(bytes,bytes[],uint256)" : "execute(bytes,bytes[])"
        deadline = hasDeadline ? ABI(Array(request.call.bytes.dropFirst(4))).uint(2) : nil
        isRouter = true
        var budget = 64
        steps = Self.decode(batch, request: request, optional: false, depth: 0, history: history, budget: &budget)
    }

    // Official deployment registries; chain + address, never dApp metadata or
    // selector alone. See Documentation/WalletConnectReadableDetails.md.
    static let routers: [UInt64: Set<String>] = [
        1: ["0x65b382653f7c31bc0af67f188122035461ec9c76", "0x66a9893cc07d91d95644aedd05d03f95e1dba8af"],
        56: ["0x1906c1d672b88cd1b9ac7593301ca990f94eae07", "0xd9c500dff816a1da21a48a732d3498bf09dc9aeb", "0x1a0a18ac4becddbd6389559687d1a73d8927e416"],
        8453: ["0x6ff5693b99212da76ad316178a184ab56d299b43", "0xd9c500dff816a1da21a48a732d3498bf09dc9aeb", "0xfe6508f0015c778bdcc1fb5465ba5ebe224c9912"],
        42161: ["0xa51afafe0263b40edaef0df8781ea9aa03e381a3", "0xfe6508f0015c778bdcc1fb5465ba5ebe224c9912"],
        59144: ["0xfe6508f0015c778bdcc1fb5465ba5ebe224c9912"],
        204: ["0xb89a6778d1efe7a5b7096757a21b810cc2886fa1"],
        324: ["0xdaee41e335322c85ff2c5a6745c98e1351806e98"],
        10: ["0x851116d9223fabed8e56c0e6b8ad0c31d98b3507"],
        137: ["0x1095692a6237d83c6a72f3f5efedb9a670c49223"],
        130: ["0xef740bf23acae26f6492b10de645d6b98dc8eaf3"],
        11_155_111: ["0x3a9d48ab9751398bbfa63ad67599bb04e4bdf98b", "0x6a3d58cc25a92d90fa3a8f0f5d5e75ad01ccd7a6"]
    ]

    private static func decode(_ batch: [(UInt8, [UInt8])], request: WalletConnectEVMRequest,
                               optional: Bool, depth: Int, history: Bool, budget: inout Int) -> [Step] {
        var steps: [Step] = []
        for (command, bytes) in batch {
            let code = command & 0x3f
            let mayFail = optional || command & 0x80 != 0
            let name = "0x" + String(format: "%02x", command)
            func unknown() -> Step { .init(operation: .unknown, command: name, optional: mayFail, values: []) }
            guard budget > 0 else { steps.append(unknown()); break }
            budget -= 1
            let abi = ABI(bytes)
            if command & 0x40 != 0 { steps.append(unknown()); continue }
            if code == 0x21 {
                if depth < 3, let nested = abi.batch(head: 2), !nested.isEmpty {
                    steps += decode(nested, request: request, optional: mayFail, depth: depth + 1, history: history, budget: &budget)
                } else { steps.append(unknown()) }
                continue
            }
            func mapped(_ address: String) -> String {
                if address == "0x" + String(repeating: "0", count: 39) + "1" { return request.sender }
                if address == "0x" + String(repeating: "0", count: 39) + "2" { return request.recipient }
                return address
            }
            func amount(_ label: WalletConnectEVMAction.Label, _ value: String, token: String?, balance: Bool = false) -> Value {
                .init(label: label, value: value, token: token, routerBalance: balance && value == contractBalance)
            }
            var values: [Value] = []
            var operation: Operation = .unknown
            switch code {
            case 0x00, 0x01, 0x08, 0x09:
                if let recipient = abi.address(0), let first = abi.uint(1), let second = abi.uint(2),
                   let payer = abi.uint(4), ["0", "1"].contains(payer),
                   let path = abi.path(v3: code < 2, allowHopPrices: history), path.count >= 2 {
                    let exactOut = code == 1 || code == 9
                    let input = exactOut && code == 1 ? path.last! : path.first!
                    let output = exactOut && code == 1 ? path.first! : path.last!
                    values = [.init(label: .tokenIn, value: input),
                              amount(exactOut ? .maximumSpent : .amount, exactOut ? second : first, token: input, balance: !exactOut),
                              .init(label: .tokenOut, value: output),
                              amount(exactOut ? .amount : .minimumReceived, exactOut ? first : second, token: output),
                              .init(label: .recipient, value: mapped(recipient)),
                              .init(label: .owner, value: payer == "1" ? request.sender : request.recipient)]
                    operation = .swap
                }
            case 0x02, 0x04, 0x05:
                if bytes.count == 96, let token = abi.address(0), let recipient = abi.address(1), let value = abi.uint(2),
                   code != 2 || abi.word(2)?.prefix(12).allSatisfy({ $0 == 0 }) == true {
                    values = [.init(label: .tokenIn, value: token),
                              .init(label: .owner, value: code == 2 ? request.sender : request.recipient),
                              .init(label: .recipient, value: mapped(recipient)),
                              // Native transfers use the literal amount. Only
                              // ERC-20 transfers recognize CONTRACT_BALANCE.
                              amount(code == 4 ? .minimumReceived : .amount, value, token: token,
                                     balance: code == 5 && token != zeroAddress)]
                    operation = .transfer
                }
            case 0x0b, 0x0c:
                if bytes.count == 64, let recipient = abi.address(0), let value = abi.uint(1) {
                    values = [.init(label: .recipient, value: mapped(recipient)),
                              amount(code == 0x0b ? .amount : .minimumReceived, value, token: "native", balance: code == 0x0b)]
                    operation = code == 0x0b ? .wrap : .unwrap
                }
            case 0x0e:
                if bytes.count == 96, let owner = abi.address(0), let token = abi.address(1), let value = abi.uint(2) {
                    values = [.init(label: .owner, value: owner), .init(label: .tokenIn, value: token),
                              amount(.minimumReceived, value, token: token)]
                    operation = .balanceCheck
                }
            default: break
            }
            steps.append(.init(operation: operation, command: name, optional: mayFail, values: values))
        }
        return steps
    }

    private static let contractBalance = "57896044618658097711785492504343953926634992332820282019728792003956564819968"
    private static let zeroAddress = "0x" + String(repeating: "0", count: 40)

    // Official PancakeSwap V2 deployments and Uniswap's Ethereum Router02.
    // V2's ETH-named methods also represent BNB and other chains' native coins.
    private static let v2Routers: [UInt64: Set<String>] = [
        1: ["0x7a250d5630b4cf539739df2c5dacb4c659f2488d", "0xeff92a263d31888d860bd50809a8d171709b7b1c"],
        56: ["0x10ed43c718714eb63d5aa57b78b54704e256024e"],
        42161: ["0x8cfe327cec66d1c090dd72bd0ff11d690c33a2eb"],
        59144: ["0x8cfe327cec66d1c090dd72bd0ff11d690c33a2eb"],
        8453: ["0x8cfe327cec66d1c090dd72bd0ff11d690c33a2eb"],
        204: ["0x8cfe327cec66d1c090dd72bd0ff11d690c33a2eb"],
        324: ["0x5aeaf2883fbf30f3d62471154eda3c0c1b05942d"],
        143: ["0xb1bc24c34e88f7d43d5923034e3a14b24daacff9"],
        4663: ["0x8cfe327cec66d1c090dd72bd0ff11d690c33a2eb"]
    ]
    private static func v2Swap(_ request: WalletConnectEVMRequest) -> (method: String, deadline: String, step: Step)? {
        guard v2Routers[request.chainID]?.contains(request.recipient) == true else { return nil }
        let selector = String(request.call.hex.prefix(10))
        let methods = [
            "0x38ed1739": "swapExactTokensForTokens", "0x8803dbee": "swapTokensForExactTokens",
            "0x7ff36ab5": "swapExactETHForTokens", "0xfb3bdb41": "swapETHForExactTokens",
            "0x18cbafe5": "swapExactTokensForETH", "0x4a25d94a": "swapTokensForExactETH",
            "0x5c11d795": "swapExactTokensForTokensSupportingFeeOnTransferTokens",
            "0xb6f9de95": "swapExactETHForTokensSupportingFeeOnTransferTokens",
            "0x791ac947": "swapExactTokensForETHSupportingFeeOnTransferTokens"
        ]
        guard let method = methods[selector] else { return nil }
        let nativeIn = ["0x7ff36ab5", "0xfb3bdb41", "0xb6f9de95"].contains(selector)
        let nativeOut = ["0x18cbafe5", "0x4a25d94a", "0x791ac947"].contains(selector)
        let exactOut = ["0x8803dbee", "0xfb3bdb41", "0x4a25d94a"].contains(selector)
        let abi = ABI(Array(request.call.bytes.dropFirst(4)))
        let pathIndex = nativeIn ? 1 : 2, head = nativeIn ? 4 : 5
        guard nativeIn || request.value == "0", abi.integer(pathIndex) == head * 32,
              let count = abi.integer(head), (2...32).contains(count), abi.bytes.count == (head + 1 + count) * 32,
              let recipient = abi.address(pathIndex + 1), let deadline = abi.uint(pathIndex + 2),
              let first = abi.uint(0) else { return nil }
        let path = (0..<count).compactMap { abi.address(head + 1 + $0) }
        guard path.count == count, let second = nativeIn ? request.value : abi.uint(1) else { return nil }
        let input = nativeIn ? "native" : path[0], output = nativeOut ? "native" : path[count - 1]
        let amountIn = nativeIn ? request.value : exactOut ? second : first
        let amountOut = nativeIn ? first : exactOut ? first : second
        let values: [Value] = [
            .init(label: .tokenIn, value: input),
            .init(label: exactOut ? .maximumSpent : .amount, value: amountIn, token: input),
            .init(label: .tokenOut, value: output),
            .init(label: exactOut ? .amount : .minimumReceived, value: amountOut, token: output),
            .init(label: .recipient, value: recipient), .init(label: .owner, value: request.sender)
        ]
        return (method, deadline, .init(operation: .swap, command: selector, optional: false, values: values))
    }

    struct ABI {
        let bytes: [UInt8]
        init(_ bytes: [UInt8]) { self.bytes = bytes }
        func word(_ index: Int) -> [UInt8]? {
            guard index >= 0, index < bytes.count / 32 else { return nil }
            return Array(bytes[index * 32..<(index + 1) * 32])
        }
        func integer(_ index: Int) -> Int? {
            guard let word = word(index), word.prefix(28).allSatisfy({ $0 == 0 }) else { return nil }
            return word.suffix(4).reduce(0) { $0 * 256 + Int($1) }
        }
        func uint(_ index: Int) -> String? {
            guard let word = word(index) else { return nil }
            return try? AnkrQuantity.decimal("0x" + TronSendCrypto.hex(Data(word)))
        }
        func address(_ index: Int) -> String? {
            guard let word = word(index), word.prefix(12).allSatisfy({ $0 == 0 }) else { return nil }
            return "0x" + TronSendCrypto.hex(Data(word.suffix(20)))
        }
        func blob(_ offset: Int) -> (value: [UInt8], end: Int)? {
            guard offset % 32 == 0, let count = integer(offset / 32), count <= bytes.count,
                  offset <= bytes.count - 32 else { return nil }
            let start = offset + 32, end = start + ((count + 31) / 32) * 32
            guard end <= bytes.count, bytes[(start + count)..<end].allSatisfy({ $0 == 0 }) else { return nil }
            return (Array(bytes[start..<(start + count)]), end)
        }
        func batch(head: Int, allowAttributionSuffix: Bool = false) -> [(UInt8, [UInt8])]? {
            guard integer(0) == head * 32, let commands = blob(head * 32), commands.value.count <= 64,
                  let arrayOffset = integer(1), arrayOffset == commands.end,
                  let count = integer(arrayOffset / 32), count == commands.value.count else { return nil }
            let base = arrayOffset + 32
            var cursor = base + count * 32
            guard cursor <= bytes.count else { return nil }
            var result: [(UInt8, [UInt8])] = []
            for i in 0..<count {
                guard let offset = integer(base / 32 + i), offset == cursor - base, let input = blob(cursor) else { return nil }
                result.append((commands.value[i], input.value)); cursor = input.end
            }
            return cursor == bytes.count || (allowAttributionSuffix && bytes.count - cursor <= 64) ? result : nil
        }
        func path(v3: Bool, allowHopPrices: Bool = false) -> [String]? {
            guard let offset = integer(3), offset == 160 || (allowHopPrices && offset == 192) else { return nil }
            let result: [String], end: Int
            if v3 {
                guard let data = blob(offset), data.value.count >= 43,
                      (data.value.count - 20) % 23 == 0 else { return nil }
                result = stride(from: 0, through: data.value.count - 20, by: 23).map {
                    "0x" + TronSendCrypto.hex(Data(data.value[$0..<$0+20]))
                }
                end = data.end
            } else {
                let head = offset / 32
                guard let count = integer(head), (2...32).contains(count) else { return nil }
                result = (0..<count).compactMap { address(head + 1 + $0) }
                guard result.count == count else { return nil }
                end = (head + 1 + count) * 32
            }
            if offset == 160 {
                guard end == bytes.count else { return nil }
            } else {
                // New Universal Router commands append uint256[] minHopPriceX36.
                // The array is either empty or has exactly one value per pool.
                guard integer(5) == end, let count = integer(end / 32),
                      count == 0 || count == result.count - 1,
                      end + 32 + count * 32 == bytes.count else { return nil }
            }
            return result
        }
    }
}
